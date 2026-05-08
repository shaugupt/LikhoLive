import AppKit

/// Manages the menu bar status item for LikhoLive.
@MainActor
final class StatusBarController {

    private var statusItem: NSStatusItem!
    private let coordinator = SessionCoordinator.shared
    private var panelController: PanelWindowController?
    private var stateObserver: Any?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        updateIcon(state: .idle)
        observeState()
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Start Dictation",
                                    action: #selector(toggleDictation),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.tag = 1
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let panelItem = NSMenuItem(title: "Settings & Status…",
                                   action: #selector(openPanel),
                                   keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LikhoLive",
                                  action: #selector(quitApp),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateToggleItem() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: 1) else { return }
        let isActive = coordinator.state.isActive
        item.title = isActive ? "Stop Dictation" : "Start Dictation"
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        if coordinator.state.isActive {
            coordinator.stopSession()
        } else {
            coordinator.startSession()
        }
    }

    @objc private func openPanel() {
        if panelController == nil {
            panelController = PanelWindowController()
        }
        panelController?.showPanel()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - State observation

    private func observeState() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: .sessionStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateIcon(state: self.coordinator.state)
                self.updateToggleItem()
            }
        }
    }

    // MARK: - Icon

    private func updateIcon(state: SessionState) {
        guard let button = statusItem.button else { return }

        switch state {
        case .idle, .stopped:
            button.image = NSImage(systemSymbolName: "mic",
                                   accessibilityDescription: "LikhoLive idle")
            button.image?.isTemplate = true
            button.toolTip = "LikhoLive — Idle"

        case .listening:
            button.image = NSImage(systemSymbolName: "mic.fill",
                                   accessibilityDescription: "LikhoLive listening")
            button.image?.isTemplate = false
            button.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            )
            button.toolTip = "LikhoLive — Listening"

        case .finalizing:
            button.image = NSImage(systemSymbolName: "mic.badge.ellipsis",
                                   accessibilityDescription: "LikhoLive finalizing")
            button.image?.isTemplate = true
            button.toolTip = "LikhoLive — Finalizing…"

        case .error:
            button.image = NSImage(systemSymbolName: "mic.slash.fill",
                                   accessibilityDescription: "LikhoLive error")
            button.image?.isTemplate = true
            button.toolTip = "LikhoLive — Error"
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let sessionStateDidChange = Notification.Name("LikhoLive.sessionStateDidChange")
}
