import AppKit
import UserNotifications
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Apply Launch at Login setting
        LaunchAtLoginHelper.setEnabled(AppSettings.shared.launchAtLogin)

        // Request notification permission for error/recovery alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Set up status bar
        statusBarController = StatusBarController()

        // Set up global hotkey
        if AppSettings.shared.hotkeyEnabled {
            HotkeyManager.shared.onToggle = {
                Task { @MainActor in
                    let coordinator = SessionCoordinator.shared
                    if coordinator.state.isActive {
                        coordinator.stopSession()
                    } else {
                        coordinator.startSession()
                    }
                }
            }
            HotkeyManager.shared.register()
        }

        // Observe session state changes and post notification for StatusBarController
        Task {
            await observeSessionState()
        }

        // Request microphone permission on first launch
        // This triggers the system permission dialog
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted {
                    let alert = NSAlert()
                    alert.messageText = "Microphone Access Required"
                    alert.informativeText = "LikhoLive needs microphone access to transcribe speech.\n\nPlease enable it in System Settings → Privacy & Security → Microphone."
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        PermissionManager.shared.openMicrophoneSettings()
                    }
                }
                // Accessibility: do NOT auto-prompt (binary path changes each Xcode run
                // causing macOS to revoke and re-ask on every launch).
                // The panel UI shows a warning row if Accessibility is missing.
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
    }

    @MainActor
    private func observeSessionState() async {
        let coordinator = SessionCoordinator.shared
        var lastState = coordinator.state

        // Poll for state changes every 200ms (lightweight for a menu bar app)
        while true {
            try? await Task.sleep(for: .milliseconds(200))
            let current = coordinator.state
            if current != lastState {
                lastState = current
                NotificationCenter.default.post(name: .sessionStateDidChange, object: nil)
            }
        }
    }
}
