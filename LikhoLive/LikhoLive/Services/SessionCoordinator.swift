import Foundation
import AppKit
import UserNotifications
import OSLog

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "SessionCoordinator")

/// The central coordinator for a live transcription session.
/// Owns: audio capture, the active transcription engine, silence detection, text injection.
///
/// The coordinator is engine-agnostic — it drives only the `TranscriptionEngine` protocol.
/// All backend-specific concerns (API keys, reconnect, model loading) live inside the engine.
@MainActor
final class SessionCoordinator: ObservableObject {

    static let shared = SessionCoordinator()

    // MARK: - Published state
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var sessionTranscript: String = ""
    @Published private(set) var pendingText: String = ""
    /// Most recent transcription round-trip latency in milliseconds. nil = no measurement yet.
    @Published private(set) var lastLatencyMs: Int? = nil

    // MARK: - Services
    private let audio    = AudioCaptureService()
    /// `nonisolated` because the reference is set once at init and never mutated; the
    /// audio-capture delegate calls into the engine from a background thread and the
    /// engine itself owns its own thread-safety. Without this annotation Swift 6 mode
    /// rejects the cross-isolation read of a protocol-existential property.
    nonisolated private let engine: TranscriptionEngine = SessionCoordinator.makeEngine(for: AppSettings.shared.engine)
    private let silence  = SilenceDetector()
    private let settings = AppSettings.shared

    private var segments: [TranscriptSegment] = []
    private var needsSpaceBefore = false
    private var periodicFlushTask: Task<Void, Never>?

    private init() {
        audio.delegate   = self
        engine.delegate  = self
        silence.delegate = self
    }

    // MARK: - Engine factory

    /// Constructs the concrete engine for the given selection.
    ///
    /// `nonisolated` so the `nonisolated let engine` property initializer can call it.
    /// Engine swapping at runtime (e.g. user toggles between Whisper/Sarvam after
    /// launch) is a Phase 5 concern; today the choice is fixed at app start and
    /// changes require a relaunch.
    nonisolated private static func makeEngine(for selection: Engine) -> TranscriptionEngine {
        switch selection {
        case .sarvam:  return SarvamEngine()
        case .whisper: return WhisperEngine()
        }
    }

    // MARK: - Start

    func startSession() {
        guard state == .idle || state == .stopped else { return }
        guard PermissionManager.shared.allPermissionsGranted else {
            state = .error("Permissions required"); return
        }
        if SecureFieldGuard.shared.isFocusedElementSecure() {
            state = .error("Cannot dictate into a secure field"); return
        }

        sessionTranscript = ""
        pendingText = ""
        segments = []
        needsSpaceBefore = false
        lastLatencyMs = nil

        // Engine-specific validation (e.g. Sarvam API key, Whisper model loaded)
        // happens inside `engine.start`. Doing this before `playSound` ensures
        // we never play a misleading start chime when the session can't actually
        // begin. Mode/language strings are routed per-engine via AppSettings.
        do {
            try engine.start(mode: settings.currentEngineMode,
                             languageCode: settings.currentEngineLanguageCode)
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        // Play start sound BEFORE the audio engine starts to avoid AudioQueue racing
        // with the tap setup.
        playSound(.start)

        do {
            try audio.start()
        } catch {
            state = .error(error.localizedDescription)
            engine.stop()
            return
        }

        silence.silenceDuration = settings.silenceTimerDuration
        if settings.autoStopEnabled {
            silence.start()
        }
        startPeriodicFlush()

        state = .listening
    }

    // MARK: - Stop

    func stopSession(reason: StopReason = .user) {
        guard state.isActive else { return }

        state = .finalizing
        silence.stop()
        periodicFlushTask?.cancel()
        periodicFlushTask = nil
        audio.stop()
        engine.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finalizeSession(reason: reason)
            // Play stop sound AFTER audio is fully torn down to prevent AudioQueue
            // teardown (~10 s later) from pulling down the shared audio session
            // and removing the AVAudioEngine tap on the next session.
            self?.playSound(.stop)
        }
    }

    private func finalizeSession(reason: StopReason) {
        engine.stop()

        if !segments.isEmpty {
            let session = TranscriptSession(segments: segments,
                                            mode: settings.mode,
                                            languageCode: settings.languageCode)
            HistoryStore.shared.save(session: session)
        }

        state = .stopped

        if reason == .focusChange && !pendingText.isEmpty {
            showRecoveryNotification(text: pendingText)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.state == .stopped { self?.state = .idle }
        }
    }

    // MARK: - Periodic flush

    private func startPeriodicFlush() {
        periodicFlushTask?.cancel()
        periodicFlushTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.state == .listening else { break }
                self.engine.flush()
            }
        }
    }

    // MARK: - Text delivery

    private func deliverText(_ text: String, sentAt: Date?) {
        guard state.isActive || state == .finalizing else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Measure latency if we have a send timestamp
        if let sentAt {
            lastLatencyMs = Int(Date().timeIntervalSince(sentAt) * 1000)
        }

        let toInsert = needsSpaceBefore ? " \(trimmed)" : trimmed
        needsSpaceBefore = true
        sessionTranscript = sessionTranscript.isEmpty ? trimmed : sessionTranscript + " " + trimmed
        pendingText = toInsert
        TextInjector.shared.inject(toInsert, restoreClipboard: settings.restoreClipboard)
        pendingText = ""
    }

    // MARK: - Sounds

    private func playSound(_ type: SoundType) {
        let path: String
        switch type {
        case .start: path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/begin_record.caf"
        case .stop:  path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/end_record.caf"
        }
        if let sound = NSSound(contentsOfFile: path, byReference: true) { sound.play() }
    }

    // MARK: - Recovery notification

    private func showRecoveryNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "LikhoLive — Session interrupted"
        content.body  = "Undelivered text: \(text.prefix(200))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Types

    enum StopReason { case user, silence, focusChange, networkError }
    private enum SoundType { case start, stop }
}

// MARK: - AudioCaptureDelegate

extension SessionCoordinator: AudioCaptureDelegate {
    nonisolated func audioCaptureService(_ service: AudioCaptureService, didCapture pcmData: Data) {
        engine.send(audio: pcmData)
    }

    nonisolated func audioCaptureService(_ service: AudioCaptureService, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .error(error.localizedDescription)
            self.stopSession(reason: .networkError)
        }
    }
}

// MARK: - TranscriptionEngineDelegate

extension SessionCoordinator: TranscriptionEngineDelegate {

    nonisolated func transcriptionEngine(_ engine: TranscriptionEngine,
                                         didEmit transcript: String,
                                         sentAt: Date?) {
        Task { @MainActor in
            let segment = TranscriptSegment(text: transcript)
            self.segments.append(segment)
            self.deliverText(transcript, sentAt: sentAt)
        }
    }

    nonisolated func transcriptionEngine(_ engine: TranscriptionEngine,
                                         didEmit vadEvent: VADEvent) {
        Task { @MainActor in
            self.silence.handleVADEvent(vadEvent)
        }
    }

    nonisolated func transcriptionEngine(_ engine: TranscriptionEngine,
                                         didFailWith error: Error) {
        Task { @MainActor in
            log.debug("[Coordinator] engine fatal error: \(error.localizedDescription, privacy: .public) state:\(String(describing: self.state), privacy: .public)")
            // The engine handles its own transient/recoverable errors. If we get here, the
            // session is over.
            self.state = .error(error.localizedDescription)
            self.stopSession(reason: .networkError)
        }
    }
}

// MARK: - SilenceDetectorDelegate

extension SessionCoordinator: SilenceDetectorDelegate {
    func silenceDetectorDidDetectSilence(_ detector: SilenceDetector) {
        guard self.state == .listening else { return }
        self.stopSession(reason: .silence)
    }
}
