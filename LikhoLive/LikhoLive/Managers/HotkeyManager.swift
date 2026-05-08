import AppKit

/// Registers a global hotkey (Control + Option + Space) using NSEvent
/// global monitor — reliable across all macOS versions and Swift 6.
final class HotkeyManager {

    static let shared = HotkeyManager()

    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRegistered = false

    private init() {}

    // MARK: - Registration

    func register() {
        guard !isRegistered else { return }

        // Global monitor fires when another app is active
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }

        // Local monitor fires when LikhoLive's own panel is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isHotkey(event: event) == true {
                self?.onToggle?()
                return nil // consume the event
            }
            return event
        }

        isRegistered = true
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isRegistered = false
    }

    // MARK: - Private

    private func handle(event: NSEvent) {
        guard isHotkey(event: event) else { return }
        onToggle?()
    }

    /// Returns true if the event matches Control + Option + Space
    private func isHotkey(event: NSEvent) -> Bool {
        let requiredFlags: NSEvent.ModifierFlags = [.control, .option]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == requiredFlags && event.keyCode == 49 // kVK_Space = 49
    }
}
