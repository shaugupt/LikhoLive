import Foundation
import OSLog
import Combine

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "WhisperEngine")

/// Local whisper.cpp transcription backend, fronted by the `TranscriptionEngine`
/// protocol so `SessionCoordinator` can drive it identically to `SarvamEngine`.
///
/// Pipeline overview:
///   AudioCaptureService ──60 ms Int16 chunks──> send(audio:)
///                                                   │
///                                                   ▼
///                       audioQueue ── append PCM, run EnergyVAD, drive UtteranceTracker
///                                                   │
///                                            on `.emitUtterance`:
///                                                   ▼
///                       inferenceQueue ── slice samples, WhisperWrapper.transcribe
///                                                   │
///                                                   ▼
///                       main queue ── delegate.transcriptionEngine(didEmit text)
///
/// Concurrency: the class is plain (not @MainActor). All mutable state lives on
/// `audioQueue` (a serial DispatchQueue). Inference runs on a separate serial
/// `inferenceQueue` so a long decode doesn't block VAD on the next chunk.
/// Delegate callbacks hop to `DispatchQueue.main` — the protocol contract
/// allows any thread, but the coordinator is `@MainActor` and the consistent
/// hop simplifies reasoning.
///
/// `@unchecked Sendable` is correct because every mutable property is only
/// touched on `audioQueue` (or, for the wrapper, while a single inference is
/// in flight on `inferenceQueue` — which itself is fed only from `audioQueue`).
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {

    weak var delegate: TranscriptionEngineDelegate?

    // MARK: - Tunables (matching the protocol's expectations)

    private let sampleRate: Int = 16_000
    /// Drop oldest samples once the rolling buffer would otherwise exceed this
    /// many frames. 30 s is plenty: the hard utterance cap is 15 s, so even
    /// during continuous speech we never need more.
    private var maxBufferedFrames: Int { sampleRate * 30 }

    // MARK: - Queues

    private let audioQueue     = DispatchQueue(label: "com.shaugupt.LikhoLive.whisper.audio",
                                               qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "com.shaugupt.LikhoLive.whisper.inference",
                                               qos: .userInitiated)

    // MARK: - State (audioQueue-only)

    private var wrapper: WhisperWrapper?
    private var isSessionActive = false
    private var currentMode: WhisperMode = .transcribe
    /// `nil` ⇒ auto-detect.
    private var currentLanguage: String?

    private var pcmBuffer: [Float] = []
    /// Absolute frame index of `pcmBuffer[0]`. Increases as we trim the buffer.
    private var bufferStartFrame: Int64 = 0
    /// Total frames appended since session start (== `bufferStartFrame + pcmBuffer.count`).
    private var totalFrames: Int64 = 0

    private let vad     = EnergyVAD()
    private var tracker = UtteranceTracker(sampleRate: 16_000)

    /// Wall-clock at which the most-recent utterance's first sample was
    /// captured — used as `sentAt` for round-trip latency reporting.
    private var currentUtteranceStartedAt: Date?

    /// After 10 min of inactivity (no active session), free the loaded model
    /// to reclaim 200 MB–1 GB of RAM. Reloaded on next `start()`.
    private var idleUnloadWork: DispatchWorkItem?
    private let idleUnloadDelay: TimeInterval = 10 * 60

    // MARK: - Combine

    private var cancellables = Set<AnyCancellable>()

    init() {
        // If the user picks a different model, drop the cached wrapper so the
        // next session loads the new one. Done on the audioQueue so we never
        // race with an in-flight inference.
        AppSettings.shared.$whisperModelID
            .dropFirst()  // ignore initial publish
            .sink { [weak self] newID in
                self?.audioQueue.async { [weak self] in
                    guard let self else { return }
                    if self.wrapper != nil {
                        log.info("Whisper model id changed to \(newID, privacy: .public); discarding loaded wrapper")
                        self.wrapper = nil
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - TranscriptionEngine

    /// Loads the selected model into a `WhisperWrapper` if not already loaded.
    /// Called by `SessionCoordinator` (or implicitly by `start`) so that
    /// pressing the start button feels instant on subsequent sessions.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: WhisperEngineError.deallocated); return
                }
                if self.wrapper != nil { cont.resume(); return }
                do {
                    try self.loadWrapper()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func start(mode: String, languageCode: String) throws {
        let parsedMode = WhisperMode(rawValue: mode) ?? .transcribe
        let parsedLanguage: String? = (languageCode == whisperLanguageAuto || languageCode.isEmpty)
            ? nil
            : languageCode

        cancelIdleUnload()

        // Synchronously load the model on the calling thread (typically main)
        // if not already loaded. First launch costs ~100–300 ms; subsequent
        // sessions reuse the cached wrapper with zero wait.
        try audioQueue.sync {
            if self.wrapper == nil {
                try self.loadWrapper()
            }
            self.currentMode      = parsedMode
            self.currentLanguage  = parsedLanguage
            self.pcmBuffer.removeAll(keepingCapacity: true)
            self.bufferStartFrame = 0
            self.totalFrames      = 0
            self.tracker.reset()
            self.currentUtteranceStartedAt = nil
            self.isSessionActive  = true
            log.info("Whisper session started — mode=\(parsedMode.rawValue, privacy: .public) lang=\(parsedLanguage ?? "auto", privacy: .public)")
        }
    }

    func send(audio pcm: Data) {
        // Convert Int16 LE bytes → Float32 in [-1, 1] on the calling thread —
        // it's cheap (~1 KB per 60 ms chunk) and decouples the audio thread
        // from our serial queue's depth.
        let floatChunk = Self.int16BytesToFloats(pcm)
        audioQueue.async { [weak self] in
            self?.processChunk(floatChunk)
        }
    }

    func flush() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let action = self.tracker.forceFlush(currentFrame: self.totalFrames)
            self.handleTrackerAction(action)
        }
    }

    func stop() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.isSessionActive = false
            // Surface anything still in flight as a final emit.
            let action = self.tracker.forceFlush(currentFrame: self.totalFrames)
            self.handleTrackerAction(action)
            // Free the rolling buffer; keep the wrapper warm for the next session.
            self.pcmBuffer.removeAll(keepingCapacity: false)
            self.bufferStartFrame = 0
            self.totalFrames = 0
            log.info("Whisper session stopped")
        }
        scheduleIdleUnload()
    }

    // MARK: - Audio pipeline (audioQueue-only)

    /// Append a new chunk, classify VAD, drive the tracker, possibly emit.
    private func processChunk(_ chunk: [Float]) {
        guard isSessionActive else { return }
        guard !chunk.isEmpty else { return }

        pcmBuffer.append(contentsOf: chunk)
        totalFrames += Int64(chunk.count)

        let chunkClass = vad.classify(samples: chunk)
        let action = tracker.process(chunk: chunkClass, chunkEndFrame: totalFrames)
        handleTrackerAction(action)

        trimBufferIfNeeded()
    }

    private func handleTrackerAction(_ action: UtteranceTracker.Action) {
        switch action {
        case .none:
            return

        case .speechStarted:
            currentUtteranceStartedAt = Date()
            emitVADEvent(.speechStart)

        case .emitUtterance(let sliceStart, let sliceEnd, let reason):
            // Slice the buffer from absolute frame range → array indices.
            // `sliceStart` may be < bufferStartFrame if the trim trimmed past
            // it (shouldn't happen with our buffer policy, but be defensive).
            let startIdx = max(0, Int(sliceStart - bufferStartFrame))
            let endIdx   = min(pcmBuffer.count, Int(sliceEnd - bufferStartFrame))
            guard endIdx > startIdx else {
                emitVADEvent(.speechEnd)
                return
            }
            // Materialise into a fresh array so the inference queue owns it
            // and we can free the front of the rolling buffer right away.
            let utterance = Array(pcmBuffer[startIdx..<endIdx])
            let sentAt    = currentUtteranceStartedAt
            currentUtteranceStartedAt = nil
            log.debug("Whisper utterance ready (\(utterance.count) samples, reason=\(String(describing: reason), privacy: .public))")
            emitVADEvent(.speechEnd)
            dispatchInference(samples: utterance, sentAt: sentAt)
            // Drop everything we just consumed.
            dropFront(uptoAbsoluteFrame: sliceEnd)
        }
    }

    /// Trim the rolling buffer to at most `maxBufferedFrames`. Keeps the most
    /// recent frames so the next utterance's lookback is intact.
    private func trimBufferIfNeeded() {
        if pcmBuffer.count > maxBufferedFrames {
            let drop = pcmBuffer.count - maxBufferedFrames
            pcmBuffer.removeFirst(drop)
            bufferStartFrame += Int64(drop)
        }
    }

    /// Drop everything strictly before the given absolute frame from the front
    /// of the buffer. Safe to call with a frame that's already past the buffer
    /// start — no-op in that case.
    private func dropFront(uptoAbsoluteFrame frame: Int64) {
        let dropCount = Int(frame - bufferStartFrame)
        guard dropCount > 0 else { return }
        let actual = min(dropCount, pcmBuffer.count)
        pcmBuffer.removeFirst(actual)
        bufferStartFrame += Int64(actual)
    }

    // MARK: - Inference dispatch

    /// Hands a finalized utterance to the inference queue. Multiple emissions
    /// queue up serially — typical decode is faster than utterance pace, so
    /// the queue rarely backs up in practice.
    private func dispatchInference(samples: [Float], sentAt: Date?) {
        guard let wrapper else { return }
        let mode = currentMode
        let language = currentLanguage

        inferenceQueue.async { [weak self, weak delegate = self.delegate] in
            guard let self else { return }
            let cfg = WhisperWrapper.InferenceConfig(
                language: language,
                translate: mode == .translate
            )
            do {
                let text = try wrapper.transcribe(samples: samples, config: cfg)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                DispatchQueue.main.async {
                    delegate?.transcriptionEngine(self, didEmit: trimmed, sentAt: sentAt)
                }
            } catch {
                // Inference failures are non-fatal — log, drop, keep the
                // session alive so the user can keep dictating. (A model that
                // truly cannot run would have failed at load time, surfacing
                // through `start()`.)
                log.error("Whisper inference failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func emitVADEvent(_ event: VADEvent) {
        DispatchQueue.main.async { [weak self, weak delegate = self.delegate] in
            guard let self else { return }
            delegate?.transcriptionEngine(self, didEmit: event)
        }
    }

    // MARK: - Idle unload
    //
    // `idleUnloadWork` is read/written only from the main queue:
    //   - `start()` and `stop()` are invoked by `SessionCoordinator`, a `@MainActor`.
    //   - The scheduled work item itself runs on main (asyncAfter on main),
    //     then hops to `audioQueue` to clear the wrapper.

    /// Schedule a 10-minute timer to free the loaded model. If a new session
    /// starts before the timer fires, `cancelIdleUnload` aborts it.
    private func scheduleIdleUnload() {
        dispatchPrecondition(condition: .onQueue(.main))
        idleUnloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.audioQueue.async {
                guard !self.isSessionActive, self.wrapper != nil else { return }
                log.info("Whisper idle for \(Int(self.idleUnloadDelay/60)) min — unloading model to free memory")
                self.wrapper = nil
            }
        }
        idleUnloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleUnloadDelay, execute: work)
    }

    private func cancelIdleUnload() {
        dispatchPrecondition(condition: .onQueue(.main))
        idleUnloadWork?.cancel()
        idleUnloadWork = nil
    }

    // MARK: - Wrapper loading (audioQueue-only)

    private func loadWrapper() throws {
        // Read the selected id from UserDefaults directly — `AppSettings.shared`
        // is `@MainActor`-leaning and we're on `audioQueue`. UserDefaults is
        // thread-safe, and a same-bundle read is < 1 µs.
        let modelID = UserDefaults.standard.string(forKey: "whisper_model_id")
            ?? WhisperModelCatalog.defaultModelID
        guard let model = WhisperModelCatalog.model(id: modelID) else {
            throw WhisperEngineError.unknownModelID(modelID)
        }
        guard let url = ModelManager.installedURL(for: modelID) else {
            throw WhisperEngineError.modelNotInstalled(model.displayName)
        }
        wrapper = try WhisperWrapper(modelURL: url, useGPU: true, flashAttn: false)
    }

    // MARK: - Helpers

    /// Re-interpret a Data of little-endian Int16 samples as Float32 in
    /// [-1, 1]. Bytes-to-floats with one allocation; safe for unaligned data.
    fileprivate static func int16BytesToFloats(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                out[i] = Float(int16Ptr[i]) / 32768.0
            }
        }
        return out
    }
}

// MARK: - Errors

enum WhisperEngineError: LocalizedError {
    case modelNotInstalled(String)
    case unknownModelID(String)
    case deallocated

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name):
            return "Whisper model '\(name)' is not downloaded. Open the model manager to download it."
        case .unknownModelID(let id):
            return "Whisper model id '\(id)' is not in the catalog."
        case .deallocated:
            return "Whisper engine was released before it could finish loading."
        }
    }
}
