import AVFoundation
import ApplicationServices
import AppKit

/// Checks and requests Microphone and Accessibility permissions.
final class PermissionManager {

    static let shared = PermissionManager()
    private init() {}

    // MARK: - Microphone

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Accessibility

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings to the Microphone privacy pane.
    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Combined check

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
