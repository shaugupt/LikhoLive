import Foundation
import OSLog

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "SilenceDetector")

@MainActor
protocol SilenceDetectorDelegate: AnyObject {
    func silenceDetectorDidDetectSilence(_ detector: SilenceDetector)
}

/// Monitors Sarvam VAD events (START_SPEECH / END_SPEECH) and fires when
/// no speech is detected for `silenceDuration` seconds after the last
/// END_SPEECH event.
///
/// This replaces the old RMS-based detector which was unreliable because
/// local mic RMS levels are too low and variable to distinguish speech
/// from silence. Sarvam's server-side VAD is far more accurate.
///
/// Thread safety: all mutable state is accessed on the main actor.
@MainActor
final class SilenceDetector {

    weak var delegate: SilenceDetectorDelegate?

    /// How long silence must be sustained before firing (seconds). Default 10s.
    var silenceDuration: TimeInterval = 10.0

    // MARK: - Private state

    private var isActive = false
    private var fired = false
    private var silenceTimer: Timer?
    private var isSpeaking = false

    // MARK: - Lifecycle

    func start() {
        isActive = true
        fired = false
        isSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        log.debug("[SilenceDetector] started — silenceDuration:\(self.silenceDuration, privacy: .public)s (VAD-based)")
        // Start the silence timer immediately — if Sarvam never sends START_SPEECH
        // within silenceDuration, the session should auto-stop.
        startSilenceTimer()
    }

    func stop() {
        isActive = false
        fired = false
        isSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        log.debug("[SilenceDetector] stopped")
    }

    // MARK: - Feed VAD events

    func handleVADEvent(_ event: VADEvent) {
        guard isActive, !fired else { return }

        switch event {
        case .speechStart:
            isSpeaking = true
            silenceTimer?.invalidate()
            silenceTimer = nil
            log.debug("[SilenceDetector] speech started — silence timer cancelled")

        case .speechEnd:
            isSpeaking = false
            log.debug("[SilenceDetector] speech ended — starting \(self.silenceDuration, privacy: .public)s silence timer")
            startSilenceTimer()
        }
    }

    // MARK: - Private

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fireSilence()
            }
        }
    }

    private func fireSilence() {
        guard isActive, !fired, !isSpeaking else { return }
        fired = true
        log.debug("[SilenceDetector] silence threshold reached (\(self.silenceDuration, privacy: .public)s) — firing delegate")
        delegate?.silenceDetectorDidDetectSilence(self)
    }
}
