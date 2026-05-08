import AppKit

/// Manages the floating settings and status panel.
@MainActor
final class PanelWindowController: NSWindowController {

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "LikhoLive"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(white: 0.94, alpha: 1.0)

        self.init(window: panel)

        let vc = SettingsViewController()
        panel.contentViewController = vc

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 420
            let y = screen.visibleFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func showPanel() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }
}
