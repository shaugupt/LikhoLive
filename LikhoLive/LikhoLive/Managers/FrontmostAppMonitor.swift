import AppKit
import ApplicationServices

/// Monitors which app is in the foreground and fires a callback
/// when the frontmost app changes during an active session.
final class FrontmostAppMonitor {

    var onFocusChanged: (() -> Void)?

    private var lockedApp: NSRunningApplication?
    private var observer: Any?
    /// Ignore focus changes for this long after lock() — lets the panel dismiss
    /// and the target app regain focus without triggering a false stop.
    private var ignoreUntil: Date = .distantPast

    // MARK: - Session lifecycle

    /// Lock onto the current frontmost app. Call this at session start.
    func lock() {
        lockedApp = NSWorkspace.shared.frontmostApplication
        // Give 1.5s grace: panel will dismiss, target app will re-activate.
        ignoreUntil = Date().addingTimeInterval(1.5)
        startObserving()
    }

    /// Update the locked app (e.g. after the panel dismisses and target app regains focus).
    func relockToCurrentApp() {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != "com.shaugupt.LikhoLive" {
            lockedApp = current
        }
    }

    /// Clear the lock. Call this at session end.
    func unlock() {
        lockedApp = nil
        stopObserving()
    }

    /// The process identifier of the locked app.
    var lockedPID: pid_t? { lockedApp?.processIdentifier }

    // MARK: - Private

    private func startObserving() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFocus()
        }
    }

    private func stopObserving() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func checkFocus() {
        // During the grace period, update the lock to whatever becomes frontmost
        // (excluding LikhoLive itself) — so we track the real target app.
        if Date() < ignoreUntil {
            relockToCurrentApp()
            return
        }

        guard let locked = lockedApp else { return }
        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier != locked.processIdentifier &&
           current?.bundleIdentifier != "com.shaugupt.LikhoLive" {
            onFocusChanged?()
        }
    }
}
