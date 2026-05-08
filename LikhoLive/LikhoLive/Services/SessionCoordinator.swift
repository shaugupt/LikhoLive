import Foundation
import AppKit
import UserNotifications
import OSLog

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "SessionCoordinator")

/// The central coordinator for a live transcription session.
/// Owns: audio, WebSocket, silence detection, focus monitoring, text injection.
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
    private let sarvam   = SarvamStreamingClient()
    private let silence  = SilenceDetector()
    private let settings = AppSettings.shared

    private var segments: [TranscriptSegment] = []
    private var needsSpaceBefore = false
    private var periodicFlushTask: Task<Void, Never>?

    // Latency: timestamp of the last flush or audio chunk send
    private var lastAudioSentAt: Date? = nil

    // Reconnect
    private var reconnectAttempts = 0

    private init() {
        audio.delegate   = self
        sarvam.delegate  = self
        silence.delegate = self
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
        guard let apiKey = KeychainStore.shared.apiKey(), !apiKey.isEmpty else {
            state = .error("Sarvam API key not set"); return
        }

        sessionTranscript = ""
        pendingText = ""
        segments = []
        needsSpaceBefore = false
        lastLatencyMs = nil
        reconnectAttempts = 0

        // Play start sound BEFORE engine starts to avoid AudioQueue racing with the tap setup.
        playSound(.start)

        connectSarvam(apiKey: apiKey)

        do {
            try audio.start()
        } catch {
            self.state = .error(error.localizedDescription)
            sarvam.disconnect()
            return
        }

        silence.start()
        startPeriodicFlush()

        state = .listening
    }

    private func connectSarvam(apiKey: String) {
        sarvam.connect(apiKey: apiKey,
                       mode: settings.mode,
                       languageCode: settings.languageCode)
    }

    // MARK: - Stop

    func stopSession(reason: StopReason = .user) {
        guard state.isActive else { return }

        state = .finalizing
        silence.stop()
        periodicFlushTask?.cancel()
        periodicFlushTask = nil
        audio.stop()
        sarvam.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finalizeSession(reason: reason)
            // Play stop sound AFTER audio is fully torn down to prevent AudioQueue
            // teardown (~10 s later) from pulling down the shared audio session
            // and removing the AVAudioEngine tap on the next session.
            self?.playSound(.stop)
        }
    }

    private func finalizeSession(reason: StopReason) {
        sarvam.disconnect()

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

    // MARK: - Reconnect (on unexpected WebSocket close during active session)

    private func handleUnexpectedClose() {
        guard state == .listening else { return }
        guard let apiKey = KeychainStore.shared.apiKey(), !apiKey.isEmpty else { return }

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        log.debug("[Coordinator] Reconnecting attempt \(attempt, privacy: .public) after unexpected close")

        // Brief pause then reconnect — audio capture keeps running the whole time.
        // We do NOT cap reconnect attempts: Sarvam server-side closes are common
        // (idle timeout, session limit) and should never hard-stop the user's session.
        let delay: Double = min(0.3 * Double(attempt), 2.0)  // 0.3s, 0.6s, 0.9s … capped at 2s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .listening else { return }
            self.sarvam.connect(apiKey: apiKey,
                                mode: self.settings.mode,
                                languageCode: self.settings.languageCode)
        }
    }

    // MARK: - Periodic flush

    private func startPeriodicFlush() {
        periodicFlushTask?.cancel()
        periodicFlushTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.state == .listening else { break }
                self.lastAudioSentAt = Date()
                self.sarvam.flush()
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
        // Timestamp every send for latency measurement
        Task { @MainActor in self.lastAudioSentAt = Date() }
        sarvam.sendAudio(pcmData)
    }

    nonisolated func audioCaptureService(_ service: AudioCaptureService, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .error(error.localizedDescription)
            self.stopSession(reason: .networkError)
        }
    }
}

// MARK: - SarvamStreamingDelegate

extension SessionCoordinator: SarvamStreamingDelegate {
    nonisolated func sarvamClient(_ client: SarvamStreamingClient, didReceiveTranscript text: String) {
        Task { @MainActor in
            let sentAt = self.lastAudioSentAt
            let segment = TranscriptSegment(text: text)
            self.segments.append(segment)
            self.deliverText(text, sentAt: sentAt)
            // Reset reconnect counter on successful transcript
            self.reconnectAttempts = 0
        }
    }

    nonisolated func sarvamClient(_ client: SarvamStreamingClient, didReceiveVADEvent event: VADEvent) {
        Task { @MainActor in
            self.silence.handleVADEvent(event)
        }
    }

    nonisolated func sarvamClient(_ client: SarvamStreamingClient, didFailWithError error: Error) {
        Task { @MainActor in
            log.debug("[Coordinator] didFailWithError: \(error, privacy: .public) state:\(String(describing: self.state), privacy: .public)")
            // sarvamClientDidClose fires right after this and handles reconnect.
            // Never hard-stop here — server-side errors are transient and recoverable.
        }
    }

    nonisolated func sarvamClientDidClose(_ client: SarvamStreamingClient,
                                          code: URLSessionWebSocketTask.CloseCode,
                                          reason: String?) {
        Task { @MainActor in
            log.debug("[Coordinator] WebSocket closed — code:\(code.rawValue, privacy: .public) reason:\((reason ?? "nil"), privacy: .public) state:\(String(describing: self.state), privacy: .public)")
            if self.state == .listening {
                self.handleUnexpectedClose()
            }
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
