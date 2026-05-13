import Foundation

/// User-configurable settings, persisted via UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Engine
    /// Active transcription backend. Default is `.whisper` (local, offline-first);
    /// existing users with a Sarvam API key already saved at first launch are
    /// migrated to `.sarvam` so v1 behavior is preserved (see init).
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
    /// Whisper inference mode (transcribe / translate-to-English).
    @Published var whisperMode: WhisperMode {
        didSet { defaults.set(whisperMode.rawValue, forKey: Keys.whisperMode) }
    }
    /// ISO 639-1 / 639-3 language code, or `whisperLanguageAuto` for auto-detect.
    @Published var whisperLanguageCode: String {
        didSet { defaults.set(whisperLanguageCode, forKey: Keys.whisperLanguageCode) }
    }

    // MARK: - Per-engine helpers

    /// Mode string passed to `engine.start(mode:languageCode:)` — opaque to the
    /// coordinator, validated by each concrete engine.
    var currentEngineMode: String {
        switch engine {
        case .sarvam:  return mode.rawValue
        case .whisper: return whisperMode.rawValue
        }
    }

    /// Language code passed to `engine.start(mode:languageCode:)`.
    var currentEngineLanguageCode: String {
        switch engine {
        case .sarvam:  return languageCode
        case .whisper: return whisperLanguageCode
        }
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
        // Engine: load saved choice if any. On first launch (no saved value),
        // migrate based on whether a Sarvam API key already exists in the
        // keychain — existing v1 users keep their Sarvam-cloud setup; brand-new
        // users default to local Whisper.
        if let savedEngine = defaults.string(forKey: Keys.engine),
           let parsed = Engine(rawValue: savedEngine) {
            engine = parsed
        } else if KeychainStore.shared.apiKey() != nil {
            engine = .sarvam   // existing Sarvam user — preserve v1 behavior
        } else {
            engine = .whisper  // new install — local, offline default
        }

        mode         = SarvamMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .transcribe
        languageCode = defaults.string(forKey: Keys.languageCode) ?? SarvamLanguage.defaultLanguage.id

        // Whisper model id: validate against the current catalog so a stale
        // saved value (e.g. an id removed in a future release) doesn't leave
        // the user pointed at nothing. Fall back to the catalog default.
        let savedWhisperModelID = defaults.string(forKey: Keys.whisperModelID) ?? ""
        whisperModelID = WhisperModelCatalog.model(id: savedWhisperModelID) != nil
            ? savedWhisperModelID
            : WhisperModelCatalog.defaultModelID

        whisperMode = WhisperMode(rawValue: defaults.string(forKey: Keys.whisperMode) ?? "") ?? .transcribe
        whisperLanguageCode = defaults.string(forKey: Keys.whisperLanguageCode) ?? whisperLanguageAuto

        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        launchAtLogin    = defaults.object(forKey: Keys.launchAtLogin)    as? Bool ?? true
        hotkeyEnabled    = defaults.object(forKey: Keys.hotkeyEnabled)    as? Bool ?? true
        autoStopEnabled  = defaults.object(forKey: Keys.autoStopEnabled)  as? Bool ?? true
        autoStopDelay    = defaults.object(forKey: Keys.autoStopDelay)    as? Double ?? 7.0
    }

    private enum Keys {
        static let engine              = "engine"
        static let mode                = "sarvam_mode"
        static let languageCode        = "sarvam_language_code"
        static let whisperModelID      = "whisper_model_id"
        static let whisperMode         = "whisper_mode"
        static let whisperLanguageCode = "whisper_language_code"
        static let restoreClipboard    = "restore_clipboard"
        static let launchAtLogin       = "launch_at_login"
        static let hotkeyEnabled       = "hotkey_enabled"
        static let autoStopEnabled     = "auto_stop_enabled"
        static let autoStopDelay       = "auto_stop_delay"
    }
}
