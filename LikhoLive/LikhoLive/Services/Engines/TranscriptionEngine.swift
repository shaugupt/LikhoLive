import Foundation

/// Voice-activity detection event surfaced by an engine.
/// Drives the silence detector and (in the future) the local Whisper utterance boundary logic.
enum VADEvent {
    case speechStart
    case speechEnd
}

/// Delegate callbacks an engine emits during a session.
///
/// All methods may be invoked from any thread; conformers are responsible for
/// hopping to the correct queue/actor before mutating state.
protocol TranscriptionEngineDelegate: AnyObject {
    /// A finalized transcript chunk is ready for delivery to the user.
    /// `sentAt` is the timestamp at which the audio that produced this transcript was
    /// handed to the engine; the coordinator uses it for round-trip latency display.
    func transcriptionEngine(_ engine: TranscriptionEngine,
                             didEmit transcript: String,
                             sentAt: Date?)

    /// Speech-start / speech-end signal. Drives silence-based auto-stop.
    func transcriptionEngine(_ engine: TranscriptionEngine,
                             didEmit vadEvent: VADEvent)

    /// A fatal, non-recoverable error. Engines handle their own transient errors
    /// (reconnects, retries) internally and only surface this when the session
    /// truly cannot continue.
    func transcriptionEngine(_ engine: TranscriptionEngine,
                             didFailWith error: Error)
}

/// Abstract transcription backend.
///
/// Concrete engines (Sarvam over WebSocket, Whisper local) own all backend-specific
/// concerns: connection state, model loading, reconnect, mode/language validation.
/// The coordinator drives only this protocol and never imports engine-specific types.
protocol TranscriptionEngine: AnyObject {

    var delegate: TranscriptionEngineDelegate? { get set }

    /// One-time preparation. Idempotent. Cheap if already prepared.
    /// Called when the panel opens and when the active engine changes, to give the
    /// engine a chance to warm up (e.g. preload a Whisper model) before the user
    /// presses Start.
    func prepare() async throws

    /// Begin a transcription session.
    ///
    /// `mode` and `languageCode` are opaque strings — each engine validates and maps
    /// them to its own typed enum / code namespace. Throws if the engine is not
    /// configured (missing API key, missing model, etc.).
    func start(mode: String, languageCode: String) throws

    /// Submit a 16 kHz mono Int16 little-endian PCM chunk.
    /// Best-effort; engines may buffer or silently drop if not in an active session.
    func send(audio pcm: Data)

    /// Force any buffered transcript to be emitted now and reset the utterance buffer.
    /// Used at session-stop and (legacy) for periodic flushes.
    func flush()

    /// End the current session. Tears down per-session state but keeps the engine
    /// in a "prepared" state so the next `start` is fast.
    func stop()
}
