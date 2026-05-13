import AppKit
import Combine

/// Modal-style window listing every Whisper GGML in the catalog with per-row
/// download / cancel / use / delete actions and a live progress bar during
/// downloads.
///
/// Reachable from the settings panel ("Whisper Models…" button) and from the
/// first-run prompt ("Choose a different model…" alternate button).
@MainActor
final class ModelManagerWindowController: NSWindowController {

    static let shared = ModelManagerWindowController()

    private convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "Whisper Models"
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
        w.contentViewController = ModelManagerViewController()
    }

    func showAndFocus() {
        showWindow(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View controller

@MainActor
final class ModelManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let manager  = ModelManager.shared
    private let settings = AppSettings.shared

    private let table = NSTableView()
    private var scrollView: NSScrollView!
    private let footerLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 460))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = v
        buildLayout()
        bindState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        manager.refreshInstalled()
        table.reloadData()
        updateFooter()
    }

    // MARK: - Layout

    private func buildLayout() {
        let header = NSTextField(labelWithString:
            "Choose a Whisper model to download. Smaller models run faster but produce lower-quality transcripts. Models live in ~/Library/Application Support/LikhoLive/models/.")
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 0
        header.preferredMaxLayoutWidth = 500
        header.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("model"))
        col.title = ""
        col.minWidth = 480
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.gridStyleMask = []
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self

        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .lineBorder
        sv.drawsBackground = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        scrollView = sv

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(sv)
        view.addSubview(footerLabel)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            sv.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sv.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -12),

            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            footerLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -8),

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Binding

    private func bindState() {
        manager.$installedIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.table.reloadData()
                self?.updateFooter()
            }
            .store(in: &cancellables)

        manager.$downloadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.table.reloadData()
            }
            .store(in: &cancellables)

        settings.$whisperModelID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.table.reloadData()
            }
            .store(in: &cancellables)
    }

    private func updateFooter() {
        let bytes = manager.totalDiskUsageBytes
        let display = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let count = manager.installedIDs.count
        footerLabel.stringValue = count == 0
            ? "No models installed."
            : "\(count) model\(count == 1 ? "" : "s") installed · \(display) on disk"
    }

    // MARK: - Actions

    @objc private func closeWindow() {
        view.window?.performClose(nil)
    }

    fileprivate func startDownload(for id: String) {
        Task { [weak self] in
            do {
                try await self?.manager.download(id)
            } catch is CancellationError {
                // user-initiated, no UI alert needed
            } catch {
                self?.showAlert(for: error)
            }
        }
    }

    fileprivate func cancelDownload() {
        manager.cancelCurrent()
    }

    fileprivate func selectModel(_ id: String) {
        settings.whisperModelID = id
    }

    fileprivate func deleteModel(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Delete this Whisper model?"
        alert.informativeText = "The file will be removed from \(manager.modelsDirectory.path). You can re-download it any time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try manager.delete(id)
            // If the user just deleted their selected model, fall back to the
            // catalog default (which may itself not be installed — that's OK,
            // first-run prompt handles the empty case next session).
            if settings.whisperModelID == id {
                settings.whisperModelID = WhisperModelCatalog.defaultModelID
            }
        } catch {
            showAlert(for: error)
        }
    }

    private func showAlert(for error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        WhisperModelCatalog.all.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let model = WhisperModelCatalog.all[row]
        let isInstalled = manager.isInstalled(model.id)
        let isSelected  = settings.whisperModelID == model.id
        let download = currentDownloadInfo(for: model.id)

        let cell = WhisperModelRowView(
            model: model,
            isInstalled: isInstalled,
            isSelected: isSelected,
            download: download
        )
        cell.onDownload = { [weak self] in self?.startDownload(for: model.id) }
        cell.onCancel   = { [weak self] in self?.cancelDownload() }
        cell.onUse      = { [weak self] in self?.selectModel(model.id) }
        cell.onDelete   = { [weak self] in self?.deleteModel(model.id) }
        return cell
    }

    /// Pull download state for a specific model id (if it's the active one).
    private func currentDownloadInfo(for id: String) -> WhisperModelRowView.DownloadInfo? {
        switch manager.downloadState {
        case .idle:
            return nil
        case .downloading(let activeID, let received, let expected) where activeID == id:
            return .downloading(received: received, expected: expected)
        case .verifying(let activeID) where activeID == id:
            return .verifying
        default:
            return nil
        }
    }
}

// MARK: - Row view

@MainActor
final class WhisperModelRowView: NSTableCellView {

    enum DownloadInfo {
        case downloading(received: Int64, expected: Int64)
        case verifying
    }

    var onDownload: (() -> Void)?
    var onCancel:   (() -> Void)?
    var onUse:      (() -> Void)?
    var onDelete:   (() -> Void)?

    init(model: WhisperModel,
         isInstalled: Bool,
         isSelected: Bool,
         download: DownloadInfo?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        // ── Title row: name + size + primary action ──
        let title = NSTextField(labelWithString: model.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let size = NSTextField(labelWithString: model.sizeDisplay)
        size.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .secondaryLabelColor
        size.setContentHuggingPriority(.required, for: .horizontal)

        let primary = makePrimaryControl(model: model,
                                         isInstalled: isInstalled,
                                         isSelected: isSelected,
                                         download: download)
        primary.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [title, size, primary])
        topRow.orientation = .horizontal
        topRow.alignment   = .centerY
        topRow.spacing     = 8

        // ── Note row: small grey caption + optional delete link ──
        let note = NSTextField(labelWithString: noteText(model: model,
                                                        isSelected: isSelected,
                                                        download: download))
        note.font = .systemFont(ofSize: 11)
        note.textColor = isSelected ? .systemBlue : .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomRow: NSStackView
        if isInstalled, !isDownloadActive(download) {
            let del = NSButton(title: "Delete", target: nil, action: nil)
            del.bezelStyle = .inline
            del.controlSize = .mini
            del.font = .systemFont(ofSize: 10)
            del.contentTintColor = .systemRed
            del.target = self
            del.action = #selector(deleteTapped)
            del.setContentHuggingPriority(.required, for: .horizontal)
            bottomRow = NSStackView(views: [note, del])
        } else {
            bottomRow = NSStackView(views: [note])
        }
        bottomRow.orientation = .horizontal
        bottomRow.alignment   = .centerY
        bottomRow.spacing     = 8

        // ── Optional progress bar (only while downloading) ──
        let outer = NSStackView(views: [topRow, bottomRow])
        if case .downloading(let received, let expected) = download {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = expected <= 0
            if !bar.isIndeterminate {
                bar.minValue = 0
                bar.maxValue = Double(expected)
                bar.doubleValue = Double(received)
            } else {
                bar.startAnimation(nil)
            }
            bar.controlSize = .small
            outer.addArrangedSubview(bar)
        }
        outer.orientation = .vertical
        outer.alignment   = .leading
        outer.spacing     = 2
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Helpers

    private func isDownloadActive(_ d: DownloadInfo?) -> Bool {
        guard let d else { return false }
        switch d {
        case .downloading, .verifying: return true
        }
    }

    private func noteText(model: WhisperModel,
                         isSelected: Bool,
                         download: DownloadInfo?) -> String {
        if let d = download {
            switch d {
            case .downloading(let received, let expected):
                let pct = expected > 0 ? Int(Double(received) / Double(expected) * 100) : 0
                let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                let expectedStr = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                return "Downloading… \(receivedStr) / \(expectedStr) (\(pct)%)"
            case .verifying:
                return "Verifying checksum…"
            }
        }
        if isSelected {
            return "✓ Selected — \(model.note ?? "")"
        }
        return model.note ?? ""
    }

    private func makePrimaryControl(model: WhisperModel,
                                    isInstalled: Bool,
                                    isSelected: Bool,
                                    download: DownloadInfo?) -> NSView {
        let btn = NSButton()
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.target = self

        if let d = download {
            switch d {
            case .downloading:
                btn.title = "Cancel"
                btn.action = #selector(cancelTapped)
            case .verifying:
                btn.title = "Verifying…"
                btn.isEnabled = false
            }
            return btn
        }

        if !isInstalled {
            btn.title = "Download"
            btn.action = #selector(downloadTapped)
            // Highlight the recommended/default model
            if model.id == WhisperModelCatalog.defaultModelID {
                btn.bezelColor = .systemBlue
            }
        } else if isSelected {
            btn.title = "Selected"
            btn.isEnabled = false
        } else {
            btn.title = "Use"
            btn.action = #selector(useTapped)
        }
        return btn
    }

    @objc private func downloadTapped() { onDownload?() }
    @objc private func cancelTapped()   { onCancel?() }
    @objc private func useTapped()      { onUse?() }
    @objc private func deleteTapped()   { onDelete?() }
}
