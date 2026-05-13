import Foundation
import OSLog

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "SarvamEngine")

/// Adapter that exposes the existing `SarvamStreamingClient` through the engine-agnostic
/// `TranscriptionEngine` protocol.
///
/// Owns:
/// - Sarvam API key lookup (from Keychain)
/// - Mode/language string → typed conversion
/// - Reconnect on unexpected WebSocket close (moved out of SessionCoordinator)
/// - Per-chunk send timestamp for round-trip latency reporting
final class SarvamEngine: NSObject, TranscriptionEngine {

    weak var delegate: TranscriptionEngineDelegate?

    private let client = SarvamStreamingClient()

    // Active session config — captured on `start`, used on reconnect.
    private var apiKey: String = ""
    private var mode: SarvamMode = .transcribe
    private var languageCode: String = "unknown"
    private var isSessionActive = false
    private var reconnectAttempts = 0

    /// Timestamp of the last audio chunk handed to the client.
    /// Surfaces back to the coordinator with each transcript for latency display.
    private var lastAudioSentAt: Date?

    override init() {
        super.init()
        client.delegate = self
    }

    // MARK: - TranscriptionEngine

    /// No preparation needed — the WebSocket connects on `start`. Cheap no-op.
    func prepare() async throws {}

    func start(mode: String, languageCode: String) throws {
        guard let parsedMode = SarvamMode(rawValue: mode) else {
            throw EngineError.invalidMode(mode)
        }
        guard let key = KeychainStore.shared.apiKey(), !key.isEmpty else {
            throw EngineError.notConfigured("Sarvam API key not set")
        }

        self.apiKey = key
        self.mode = parsedMode
        self.languageCode = languageCode
        self.reconnectAttempts = 0
        self.isSessionActive = true

        client.connect(apiKey: key, mode: parsedMode, languageCode: languageCode)
    }

    func send(audio pcm: Data) {
        lastAudioSentAt = Date()
        client.sendAudio(pcm)
    }

    func flush() {
        client.flush()
    }

    func stop() {
        isSessionActive = false
        client.disconnect()
    }

    // MARK: - Errors

    enum EngineError: LocalizedError {
        case invalidMode(String)
        case notConfigured(String)

        var errorDescription: String? {
            switch self {
            case .invalidMode(let m):    return "Sarvam: invalid mode '\(m)'"
            case .notConfigured(let m):  return m
            }
        }
    }
}

// MARK: - SarvamStreamingDelegate

extension SarvamEngine: SarvamStreamingDelegate {

    func sarvamClient(_ client: SarvamStreamingClient, didReceiveTranscript text: String) {
        let sentAt = lastAudioSentAt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectAttempts = 0
            self.delegate?.transcriptionEngine(self, didEmit: text, sentAt: sentAt)
        }
    }

    func sarvamClient(_ client: SarvamStreamingClient, didReceiveVADEvent event: VADEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.transcriptionEngine(self, didEmit: event)
        }
    }

    func sarvamClient(_ client: SarvamStreamingClient, didFailWithError error: Error) {
        // Sarvam server-side errors are almost always recoverable; sarvamClientDidClose
        // fires next and triggers reconnect. Log only — never bubble up to the coordinator
        // unless the close handler later determines we are out of options.
        log.debug("[SarvamEngine] transient error: \(error.localizedDescription, privacy: .public)")
    }

    func sarvamClientDidClose(_ client: SarvamStreamingClient,
                              code: URLSessionWebSocketTask.CloseCode,
                              reason: String?) {
        guard isSessionActive else { return }

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        // No cap on attempts: Sarvam server-side closes (idle timeout, session limit) are
        // common and should never hard-stop the user's session.
        let delay = min(0.3 * Double(attempt), 2.0)
        log.debug("[SarvamEngine] reconnect attempt \(attempt, privacy: .public) after \(delay, privacy: .public)s — close code:\(code.rawValue, privacy: .public) reason:\(reason ?? "nil", privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isSessionActive else { return }
            self.client.connect(apiKey: self.apiKey,
                                mode: self.mode,
                                languageCode: self.languageCode)
        }
    }
}
