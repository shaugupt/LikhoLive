import AppKit
import ApplicationServices
import Carbon

/// Injects text into the currently focused application.
///
/// Strategy:
///   1. Try direct Unicode keystroke injection via CGEvent.
///   2. Fall back to pasteboard paste if direct injection is blocked or unreliable.
///
/// Clipboard contents are preserved and restored (based on user setting).
final class TextInjector {

    static let shared = TextInjector()
    private init() {}

    /// Injects text into the focused app, respecting user's clipboard-restore preference.
    func inject(_ text: String, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }

        // Try direct injection first
        if injectDirectly(text) { return }

        // Fall back to paste
        injectViaPaste(text, restoreClipboard: restoreClipboard)
    }

    // MARK: - Direct Unicode injection

    @discardableResult
    private func injectDirectly(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let source = CGEventSource(stateID: .hidSystemState)

        // Post the entire string as a single keyDown/keyUp pair.
        // CGEvent supports multi-character Unicode strings directly —
        // faster than char-by-char and handles Devanagari correctly.
        var scalars = Array(text.utf16)
        let length  = scalars.count

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: &scalars)
        keyUp.keyboardSetUnicodeString(stringLength: length,   unicodeString: &scalars)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - Paste fallback

    private func injectViaPaste(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard if needed
        var savedContents: [(NSPasteboard.PasteboardType, Data)] = []
        if restoreClipboard {
            savedContents = pasteboard.pasteboardItems?.compactMap { item in
                item.types.first.flatMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            } ?? []
        }

        // Write transcript to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9  // 'v'

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)

        cmdDown?.flags = .maskCommand
        vDown?.flags   = .maskCommand
        vUp?.flags     = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // Restore clipboard after a small delay to ensure paste completes
        if restoreClipboard && !savedContents.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pasteboard.clearContents()
                for (type, data) in savedContents {
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }
}
