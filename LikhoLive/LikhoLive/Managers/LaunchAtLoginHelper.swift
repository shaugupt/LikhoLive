import ServiceManagement
import OSLog

private let loginLog = Logger(subsystem: "com.shaugupt.LikhoLive", category: "LaunchAtLogin")

/// Manages Launch at Login using the modern SMAppService API (macOS 13+).
enum LaunchAtLoginHelper {

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Non-fatal: log and move on
            loginLog.error("[LikhoLive] LaunchAtLogin error: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
