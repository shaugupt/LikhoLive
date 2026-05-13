import Foundation

/// User-configurable settings, persisted via UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Engine
    /// Active transcription backend. Phase-1 default is `.sarvam` to preserve v1 behavior;
    /// Phase 4 flips this to `.whisper` (with a migration heuristic that keeps existing
    /// Sarvam users on Sarvam if they already have an API key set).
    @Published var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    // MARK: - Sarvam
    @Published var mode: SarvamMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: Keys.languageCode) }
    }

    // MARK: - Whisper
    /// Selected GGML model id from `WhisperModelCatalog`. Always points at a
    /// catalog entry — if a saved id was renamed/removed in a later release,
    /// we fall back to the catalog default at load time.
    @Published var whisperModelID: String {
        didSet { defaults.set(whisperModelID, forKey: Keys.whisperModelID) }
    }

    // MARK: - Behaviour
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Keys.restoreClipboard) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLoginHelper.setEnabled(launchAtLogin)
        }
    }

    // MARK: - Hotkey
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Keys.hotkeyEnabled) }
    }

    // MARK: - Auto-stop
    /// When false, the app stays in continuous listening mode (no auto-stop).
    @Published var autoStopEnabled: Bool {
        didSet { defaults.set(autoStopEnabled, forKey: Keys.autoStopEnabled) }
    }
    /// User-facing auto-stop delay in seconds (silence + finalize combined).
    /// Range: 1.5 … 60. The silence timer is this value minus 1.5s finalize overhead.
    @Published var autoStopDelay: Double {
        didSet { defaults.set(autoStopDelay, forKey: Keys.autoStopDelay) }
    }

    /// The silence-detector duration derived from the user-facing delay.
    var silenceTimerDuration: TimeInterval {
        max(0.5, autoStopDelay - 1.5)
    }

    private init() {
        engine       = Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .sarvam
        mode         = SarvamMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .transcribe
        languageCode = defaults.string(forKey: Keys.languageCode) ?? SarvamLanguage.defaultLanguage.id

        // Whisper model id: validate against the current catalog so a stale
        // saved value (e.g. an id removed in a future release) doesn't leave
        // the user pointed at nothing. Fall back to the catalog default.
        let savedWhisperModelID = defaults.string(forKey: Keys.whisperModelID) ?? ""
        whisperModelID = WhisperModelCatalog.model(id: savedWhisperModelID) != nil
            ? savedWhisperModelID
            : WhisperModelCatalog.defaultModelID

        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        launchAtLogin    = defaults.object(forKey: Keys.launchAtLogin)    as? Bool ?? true
        hotkeyEnabled    = defaults.object(forKey: Keys.hotkeyEnabled)    as? Bool ?? true
        autoStopEnabled  = defaults.object(forKey: Keys.autoStopEnabled)  as? Bool ?? true
        autoStopDelay    = defaults.object(forKey: Keys.autoStopDelay)    as? Double ?? 7.0
    }

    private enum Keys {
        static let engine           = "engine"
        static let mode             = "sarvam_mode"
        static let languageCode     = "sarvam_language_code"
        static let whisperModelID   = "whisper_model_id"
        static let restoreClipboard = "restore_clipboard"
        static let launchAtLogin    = "launch_at_login"
        static let hotkeyEnabled    = "hotkey_enabled"
        static let autoStopEnabled  = "auto_stop_enabled"
        static let autoStopDelay    = "auto_stop_delay"
    }
}
