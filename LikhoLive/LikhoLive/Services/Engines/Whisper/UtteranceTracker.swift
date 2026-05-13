import Foundation

/// State machine that converts a stream of `VADChunkClass` events into
/// utterance-boundary actions. Pure value semantics — easy to reason about and
/// test in isolation, no threading concerns.
///
/// Frame indexing: callers operate in *absolute frame counts* over the entire
/// session. This keeps slice math simple even when the engine periodically
/// trims the underlying audio buffer to free memory.
struct UtteranceTracker {

    // MARK: - Tunables

    /// Sample rate of the audio fed to `process(...)`. Frame counts below are
    /// derived from this — change once and everything else follows.
    let sampleRate: Int

    /// How much pre-utterance audio to include in the slice. Speech onset is
    /// noisy: by the time RMS crosses `speechThreshold` we've already missed
    /// the leading edge of the first phoneme. 200 ms catches it.
    var lookbackFrames: Int { (sampleRate * 200) / 1000 }

    /// Trailing silence we want included in the slice so whisper has audible
    /// "the speaker just stopped" cues for end-of-segment detection.
    var trailingSilenceFrames: Int { (sampleRate * 200) / 1000 }

    /// How long of silence-after-speech triggers a flush.
    var silenceFlushFrames: Int { (sampleRate * 800) / 1000 }

    /// Hard cap on a single utterance — even if the user keeps talking,
    /// emit a chunk at this length to bound text-injection latency.
    var maxUtteranceFrames: Int { sampleRate * 15 }

    // MARK: - State

    /// Internal state. Use the `Action` returned by `process` to drive the
    /// engine; this enum is intentionally hidden.
    private enum State {
        case idle
        case speaking(startFrame: Int64, lastSpeechFrame: Int64)
    }
    private var state: State = .idle

    // MARK: - Actions

    /// Outcome of processing one chunk.
    enum Action: Equatable {
        case none
        /// Speech started this chunk — parent should fire a `speechStart` VAD event.
        case speechStarted
        /// An utterance is ready: extract `[sliceStartFrame, sliceEndFrame)`
        /// from the rolling buffer and run inference. Tracker is reset to idle
        /// before returning, so a new utterance can begin immediately.
        case emitUtterance(sliceStartFrame: Int64,
                           sliceEndFrame: Int64,
                           reason: EmitReason)
    }

    /// Why we emitted — useful for logging and telemetry.
    enum EmitReason: Equatable {
        case silenceTimeout
        case maxLengthExceeded
        case forcedFlush
    }

    init(sampleRate: Int = 16_000) {
        self.sampleRate = sampleRate
    }

    // MARK: - Driver

    /// Process one chunk's worth of audio. `chunkEndFrame` is the absolute
    /// frame index of the *first frame after* this chunk (i.e. it's exclusive).
    mutating func process(chunk: VADChunkClass, chunkEndFrame: Int64) -> Action {
        switch state {
        case .idle:
            if chunk == .speech {
                state = .speaking(startFrame: chunkEndFrame,
                                  lastSpeechFrame: chunkEndFrame)
                return .speechStarted
            }
            return .none

        case .speaking(let startFrame, var lastSpeechFrame):
            if chunk == .speech {
                lastSpeechFrame = chunkEndFrame
                state = .speaking(startFrame: startFrame, lastSpeechFrame: lastSpeechFrame)
            }
            // Hard-cap takes precedence over silence (a long monologue without
            // pauses still needs to flush periodically).
            if chunkEndFrame - startFrame >= maxUtteranceFrames {
                let action = Action.emitUtterance(
                    sliceStartFrame: max(0, startFrame - Int64(lookbackFrames)),
                    sliceEndFrame: chunkEndFrame,
                    reason: .maxLengthExceeded
                )
                state = .idle
                return action
            }
            if chunkEndFrame - lastSpeechFrame >= silenceFlushFrames {
                // Include a small trailing tail so whisper sees the breath.
                let end = lastSpeechFrame + Int64(trailingSilenceFrames)
                let action = Action.emitUtterance(
                    sliceStartFrame: max(0, startFrame - Int64(lookbackFrames)),
                    sliceEndFrame: min(end, chunkEndFrame),
                    reason: .silenceTimeout
                )
                state = .idle
                return action
            }
            return .none
        }
    }

    /// Force-emit whatever is currently buffered (mid-utterance or not).
    /// Returns `.none` if not currently speaking — the caller should not
    /// emit anything in that case.
    mutating func forceFlush(currentFrame: Int64) -> Action {
        switch state {
        case .idle:
            return .none
        case .speaking(let startFrame, _):
            let action = Action.emitUtterance(
                sliceStartFrame: max(0, startFrame - Int64(lookbackFrames)),
                sliceEndFrame: currentFrame,
                reason: .forcedFlush
            )
            state = .idle
            return action
        }
    }

    /// Drop all state, no emission. For session reset.
    mutating func reset() {
        state = .idle
    }

    /// Whether we're currently inside a detected utterance. Exposed only for
    /// the engine's `flush()` logic — no other state details leak out.
    var isSpeaking: Bool {
        if case .speaking = state { return true }
        return false
    }
}
