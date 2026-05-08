import ApplicationServices
import AppKit

/// Best-effort check for whether the currently focused UI element is a secure text field.
/// This is inherently limited: some apps do not expose AX attributes for security reasons.
final class SecureFieldGuard {

    static let shared = SecureFieldGuard()
    private init() {}

    /// Returns true if the currently focused element appears to be a secure text input.
    func isFocusedElementSecure() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp,
                                                   kAXFocusedUIElementAttribute as CFString,
                                                   &focusedElement)
        guard result == .success, let element = focusedElement else { return false }

        // Check role: AXSecureTextField
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement,
                                      kAXRoleAttribute as CFString,
                                      &role)
        if let roleStr = role as? String, roleStr == "AXSecureTextField" {
            return true
        }

        // Fallback: check subrole
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement,
                                      kAXSubroleAttribute as CFString,
                                      &subrole)
        if let sub = subrole as? String, sub.lowercased().contains("secure") {
            return true
        }

        return false
    }
}
