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

    private init() {
        mode         = SarvamMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .transcribe
        languageCode = defaults.string(forKey: Keys.languageCode) ?? SarvamLanguage.defaultLanguage.id
        restoreClipboard = defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true
        launchAtLogin    = defaults.object(forKey: Keys.launchAtLogin)    as? Bool ?? true
        hotkeyEnabled    = defaults.object(forKey: Keys.hotkeyEnabled)    as? Bool ?? true
    }

    private enum Keys {
        static let mode             = "sarvam_mode"
        static let languageCode     = "sarvam_language_code"
        static let restoreClipboard = "restore_clipboard"
        static let launchAtLogin    = "launch_at_login"
        static let hotkeyEnabled    = "hotkey_enabled"
    }
}
