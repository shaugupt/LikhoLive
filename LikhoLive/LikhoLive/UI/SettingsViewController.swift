import AppKit
import Combine

/// Main settings and status panel — compact, fixed height, no scroll.
@MainActor
final class SettingsViewController: NSViewController {

    private let coordinator = SessionCoordinator.shared
    private let settings    = AppSettings.shared
    private let permissions = PermissionManager.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - UI Elements

    private let statusDot       = NSView()
    private let statusLabel     = NSTextField(labelWithString: "Idle")
    private let startStopButton = NSButton()
    private let latencyLabel    = NSTextField(labelWithString: "")
    private let transcriptText  = NSTextView()
    private var transcriptScroll: NSScrollView!

    private let modePopup       = NSPopUpButton()
    private let langPopup       = NSPopUpButton()

    private let clipboardToggle = NSSwitch()
    private let launchToggle    = NSSwitch()
    private let autoStopToggle  = NSSwitch()
    private let autoStopSlider  = NSSlider()
    private let autoStopValueLabel = NSTextField(labelWithString: "7s")

    private let micStatusLabel  = NSTextField(labelWithString: "")
    private let axStatusLabel   = NSTextField(labelWithString: "")
    private let micButton       = NSButton()
    private let axButton        = NSButton()

    private let apiKeyField     = NSSecureTextField()
    private let apiKeySaveBtn   = NSButton()

    private let historyTable    = NSTableView()

    // MARK: - Lifecycle

    override func loadView() {
        let bg = NSColor(white: 0.94, alpha: 1.0) // subtle light grey
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        v.wantsLayer = true
        v.layer?.backgroundColor = bg.cgColor
        view = v
        buildLayout()
        bindState()
        populate()
    }

    // MARK: - Layout

    private func buildLayout() {
        // Root vertical stack pinned to view edges with padding
        let root = vstack(spacing: 10)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // ── Status row ──────────────────────────────────────────
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        pin(statusDot, width: 10, height: 10)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        startStopButton.bezelStyle = .rounded
        startStopButton.title = "Start"
        startStopButton.font = .systemFont(ofSize: 12, weight: .medium)
        startStopButton.controlSize = .small
        startStopButton.target = self
        startStopButton.action = #selector(toggleDictation)
        startStopButton.setContentHuggingPriority(.required, for: .horizontal)

        root.addArrangedSubview(hstack([statusDot, statusLabel, startStopButton], spacing: 6))

        // ── Latency indicator ────────────────────────────────────
        latencyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        latencyLabel.textColor = .tertiaryLabelColor
        latencyLabel.stringValue = ""
        root.addArrangedSubview(latencyLabel)

        // ── Transcript ──────────────────────────────────────────
        transcriptText.isEditable = false
        transcriptText.isSelectable = true
        transcriptText.font = .systemFont(ofSize: 12)
        transcriptText.textColor = .labelColor
        transcriptText.backgroundColor = .clear
        transcriptText.drawsBackground = false

        let sv = NSScrollView()
        sv.documentView = transcriptText
        sv.hasVerticalScroller = true
        sv.drawsBackground = true
        sv.wantsLayer = true
        sv.layer?.cornerRadius = 6
        sv.layer?.backgroundColor = NSColor(white: 0.88, alpha: 1).cgColor
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.heightAnchor.constraint(equalToConstant: 56).isActive = true
        transcriptScroll = sv
        root.addArrangedSubview(sv)

        root.addArrangedSubview(divider())

        // ── Mode + Language ──────────────────────────────────────
        for m in SarvamMode.allCases {
            modePopup.addItem(withTitle: m.rawValue)
            modePopup.lastItem?.representedObject = m
        }
        modePopup.controlSize = .small
        modePopup.font = .systemFont(ofSize: 11)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        for lang in SarvamLanguage.all {
            langPopup.addItem(withTitle: lang.displayName)
            langPopup.lastItem?.representedObject = lang
        }
        langPopup.controlSize = .small
        langPopup.font = .systemFont(ofSize: 11)
        langPopup.target = self
        langPopup.action = #selector(languageChanged)

        root.addArrangedSubview(labelRow("Mode", modePopup))
        root.addArrangedSubview(labelRow("Language", langPopup))
        root.addArrangedSubview(divider())

        // ── Toggles ──────────────────────────────────────────────
        clipboardToggle.controlSize = .small
        clipboardToggle.target = self
        clipboardToggle.action = #selector(clipboardToggleChanged)

        launchToggle.controlSize = .small
        launchToggle.target = self
        launchToggle.action = #selector(launchToggleChanged)

        root.addArrangedSubview(toggleRow("Restore clipboard after paste", clipboardToggle))
        root.addArrangedSubview(toggleRow("Launch at Login", launchToggle))

        // ── Auto-stop ────────────────────────────────────────────
        autoStopToggle.controlSize = .small
        autoStopToggle.target = self
        autoStopToggle.action = #selector(autoStopToggleChanged)

        autoStopSlider.minValue = 1.5
        autoStopSlider.maxValue = 60.0
        autoStopSlider.doubleValue = settings.autoStopDelay
        autoStopSlider.controlSize = .small
        autoStopSlider.target = self
        autoStopSlider.action = #selector(autoStopSliderChanged)
        autoStopSlider.isContinuous = true
        autoStopSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        autoStopValueLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        autoStopValueLabel.textColor = .secondaryLabelColor
        autoStopValueLabel.alignment = .right
        autoStopValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        pin(autoStopValueLabel, width: 32, height: 14)

        root.addArrangedSubview(toggleRow("Auto-stop on silence", autoStopToggle))
        let sliderRow = hstack([autoStopSlider, autoStopValueLabel], spacing: 6)
        root.addArrangedSubview(sliderRow)

        root.addArrangedSubview(divider())

        // ── Permissions ──────────────────────────────────────────
        micButton.bezelStyle = .rounded
        micButton.controlSize = .small
        micButton.font = .systemFont(ofSize: 10)
        micButton.target = self
        micButton.action = #selector(openMicSettings)
        micButton.setContentHuggingPriority(.required, for: .horizontal)

        axButton.bezelStyle = .rounded
        axButton.controlSize = .small
        axButton.font = .systemFont(ofSize: 10)
        axButton.target = self
        axButton.action = #selector(openAXSettings)
        axButton.setContentHuggingPriority(.required, for: .horizontal)

        micStatusLabel.font = .systemFont(ofSize: 11)
        micStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        axStatusLabel.font  = .systemFont(ofSize: 11)
        axStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(hstack([micStatusLabel, micButton], spacing: 6))
        root.addArrangedSubview(hstack([axStatusLabel,  axButton],  spacing: 6))
        root.addArrangedSubview(divider())

        // ── API Key ───────────────────────────────────────────────
        apiKeyField.placeholderString = "sk_…"
        apiKeyField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        apiKeyField.controlSize = .small
        apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        apiKeySaveBtn.title = "Save"
        apiKeySaveBtn.bezelStyle = .rounded
        apiKeySaveBtn.controlSize = .small
        apiKeySaveBtn.font = .systemFont(ofSize: 11)
        apiKeySaveBtn.target = self
        apiKeySaveBtn.action = #selector(saveAPIKey)
        apiKeySaveBtn.setContentHuggingPriority(.required, for: .horizontal)

        root.addArrangedSubview(labeledField("API Key", apiKeyField, apiKeySaveBtn))
        root.addArrangedSubview(divider())

        // ── History ───────────────────────────────────────────────
        let col = NSTableColumn(identifier: .init("text"))
        col.title = "Transcript"
        historyTable.addTableColumn(col)
        historyTable.headerView = nil
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.doubleAction = #selector(copyHistoryItem)
        historyTable.target = self
        historyTable.backgroundColor = .clear
        historyTable.rowHeight = 18

        let hsv = NSScrollView()
        hsv.documentView = historyTable
        hsv.hasVerticalScroller = true
        hsv.drawsBackground = true
        hsv.wantsLayer = true
        hsv.layer?.cornerRadius = 6
        hsv.layer?.backgroundColor = NSColor(white: 0.88, alpha: 1).cgColor
        hsv.translatesAutoresizingMaskIntoConstraints = false
        hsv.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let histHeader = sectionLabel("Recent Sessions")
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearHistory))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small
        clearBtn.font = .systemFont(ofSize: 10)
        clearBtn.setContentHuggingPriority(.required, for: .horizontal)

        root.addArrangedSubview(hstack([histHeader, clearBtn], spacing: 6))
        root.addArrangedSubview(hsv)
    }

    // MARK: - Helpers

    private func vstack(spacing: CGFloat) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text.uppercased())
        f.font = .systemFont(ofSize: 9, weight: .semibold)
        f.textColor = .secondaryLabelColor
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    private func pin(_ view: NSView, width: CGFloat, height: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    /// Label + popup/control on one line.
    private func labelRow(_ labelText: String, _ control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor
        lbl.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return hstack([lbl, control], spacing: 8)
    }

    /// Label on left, toggle on right.
    private func toggleRow(_ labelText: String, _ toggle: NSSwitch) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = .labelColor
        lbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return hstack([lbl, toggle], spacing: 8)
    }

    /// Small label + text field + save button.
    private func labeledField(_ labelText: String, _ field: NSView, _ btn: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = .secondaryLabelColor
        lbl.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return hstack([lbl, field, btn], spacing: 6)
    }

    // MARK: - Bind

    private func bindState() {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.updateForState(s) }
            .store(in: &cancellables)

        coordinator.$sessionTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.transcriptText.string = text
                self?.transcriptText.scrollToEndOfDocument(nil)
            }
            .store(in: &cancellables)

        coordinator.$lastLatencyMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ms in
                guard let self else { return }
                if let ms {
                    let color: NSColor = ms < 500 ? .systemGreen : ms < 1000 ? .systemOrange : .systemRed
                    self.latencyLabel.stringValue = "⏱ Last transcription latency: \(ms) ms"
                    self.latencyLabel.textColor = color
                } else {
                    self.latencyLabel.stringValue = ""
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Populate

    private func populate() {
        for (i, item) in modePopup.itemArray.enumerated() {
            if let m = item.representedObject as? SarvamMode, m == settings.mode {
                modePopup.selectItem(at: i); break
            }
        }
        for (i, item) in langPopup.itemArray.enumerated() {
            if let l = item.representedObject as? SarvamLanguage, l.id == settings.languageCode {
                langPopup.selectItem(at: i); break
            }
        }
        clipboardToggle.state = settings.restoreClipboard ? .on : .off
        launchToggle.state    = settings.launchAtLogin    ? .on : .off
        autoStopToggle.state  = settings.autoStopEnabled  ? .on : .off
        autoStopSlider.doubleValue = settings.autoStopDelay
        updateAutoStopUI()
        if let key = KeychainStore.shared.apiKey() {
            apiKeyField.placeholderString = "Saved: \(String(key.prefix(8)))…"
        }
        updatePermissionRows()
    }

    private func updateForState(_ state: SessionState) {
        statusLabel.stringValue = state.displayLabel
        startStopButton.title = state.isActive ? "Stop" : "Start"
        switch state {
        case .idle, .stopped:  statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        case .listening:       statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        case .finalizing:      statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .error:           statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
        startStopButton.isEnabled = permissions.allPermissionsGranted
        updatePermissionRows()
        historyTable.reloadData()
    }

    private func updatePermissionRows() {
        let micOK = permissions.microphoneGranted
        micStatusLabel.stringValue = micOK ? "Mic ✓" : "Mic: Not granted"
        micStatusLabel.textColor   = micOK ? .systemGreen : .systemRed
        micButton.title    = micOK ? "✓" : "Fix"
        micButton.isEnabled = !micOK

        let axOK = permissions.accessibilityGranted
        axStatusLabel.stringValue = axOK ? "Accessibility ✓" : "Accessibility: Not granted"
        axStatusLabel.textColor   = axOK ? .systemGreen : .systemRed
        axButton.title    = axOK ? "✓" : "Fix"
        axButton.isEnabled = !axOK
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        if coordinator.state.isActive { coordinator.stopSession() } else { coordinator.startSession() }
    }
    @objc private func modeChanged() {
        guard let m = modePopup.selectedItem?.representedObject as? SarvamMode else { return }
        settings.mode = m
    }
    @objc private func languageChanged() {
        guard let l = langPopup.selectedItem?.representedObject as? SarvamLanguage else { return }
        settings.languageCode = l.id
    }
    @objc private func clipboardToggleChanged() { settings.restoreClipboard = clipboardToggle.state == .on }
    @objc private func launchToggleChanged()    { settings.launchAtLogin    = launchToggle.state == .on }

    @objc private func autoStopToggleChanged() {
        settings.autoStopEnabled = autoStopToggle.state == .on
        updateAutoStopUI()
    }
    @objc private func autoStopSliderChanged() {
        // Snap to 0.5s increments
        let snapped = (autoStopSlider.doubleValue * 2).rounded() / 2
        settings.autoStopDelay = snapped
        updateAutoStopUI()
    }
    private func updateAutoStopUI() {
        let enabled = settings.autoStopEnabled
        autoStopSlider.isEnabled = enabled
        autoStopValueLabel.isHidden = !enabled
        if enabled {
            let val = settings.autoStopDelay
            if val >= 10 {
                autoStopValueLabel.stringValue = "\(Int(val))s"
            } else {
                autoStopValueLabel.stringValue = String(format: "%.1fs", val)
            }
        }
    }
    @objc private func openMicSettings()        { permissions.openMicrophoneSettings() }
    @objc private func openAXSettings()         { permissions.openAccessibilitySettings() }

    @objc private func saveAPIKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        KeychainStore.shared.save(apiKey: key)
        apiKeyField.stringValue = ""
        apiKeyField.placeholderString = "Saved: \(String(key.prefix(8)))…"
    }
    @objc private func copyHistoryItem() {
        let row = historyTable.clickedRow
        guard row >= 0, row < HistoryStore.shared.sessions.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HistoryStore.shared.sessions[row].fullText, forType: .string)
    }
    @objc private func clearHistory() {
        HistoryStore.shared.clearAll()
        historyTable.reloadData()
    }
}

// MARK: - Table

extension SettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { HistoryStore.shared.sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = HistoryStore.shared.sessions[row]
        let cell = NSTextField(labelWithString: String(session.fullText.prefix(120)))
        cell.font = .systemFont(ofSize: 11)
        cell.textColor = .labelColor
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = session.fullText
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 18 }
}
