import Foundation

/// User-configurable settings, persisted via UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Sarvam
    @Published var mode: SarvamMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: Keys.languageCode) }
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
        mode         = SarvamMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .transcribe
        languageCode = defaults.string(forKey: Keys.languageCode) ?? SarvamLanguage.defaultLanguage.id
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        launchAtLogin    = defaults.object(forKey: Keys.launchAtLogin)    as? Bool ?? true
        hotkeyEnabled    = defaults.object(forKey: Keys.hotkeyEnabled)    as? Bool ?? true
        autoStopEnabled  = defaults.object(forKey: Keys.autoStopEnabled)  as? Bool ?? true
        autoStopDelay    = defaults.object(forKey: Keys.autoStopDelay)    as? Double ?? 7.0
    }

    private enum Keys {
        static let mode             = "sarvam_mode"
        static let languageCode     = "sarvam_language_code"
        static let restoreClipboard = "restore_clipboard"
        static let launchAtLogin    = "launch_at_login"
        static let hotkeyEnabled    = "hotkey_enabled"
        static let autoStopEnabled  = "auto_stop_enabled"
        static let autoStopDelay    = "auto_stop_delay"
    }
}
