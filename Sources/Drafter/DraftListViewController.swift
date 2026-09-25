import AppKit
import DrafterCore

/// The left column: the drafts of one folder, newest first, in the manner of
/// NetNewsWire's timeline — a bold title, a few lines of what follows it, and
/// when it was last touched.
@MainActor
final class DraftListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let store: DraftStore
    private(set) var folder: Folder = .inbox
    private(set) var rows: [Draft] = []

    var onSelect: ((URL?) -> Void)?
    var onReturn: (() -> Void)?
    var onFolderChange: ((Folder) -> Void)?
    /// The context menu's actions go to whoever handles them for the window.
    weak var actionTarget: AnyObject?

    private var tableView: DraftTableView!
    private var folderControl: NSSegmentedControl!
    private var statusField: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var statusTimer: Timer?
    private var suppressSelection = false

    init(store: DraftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedURL: URL? {
        let row = tableView.selectedRow
        return row >= 0 && row < rows.count ? rows[row].url : nil
    }

    var clickedOrSelectedDraft: Draft? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    override func loadView() {
        let container = NSView()

        folderControl = NSSegmentedControl(labels: Folder.allCases.map(\.name), trackingMode: .selectOne,
                                           target: self, action: #selector(folderControlChanged))
        folderControl.selectedSegment = 0
        folderControl.segmentDistribution = .fillEqually
        folderControl.controlSize = .large
        folderControl.translatesAutoresizingMaskIntoConstraints = false
        folderControl.setToolTip("Inbox (⌘1)", forSegment: 0)
        folderControl.setToolTip("Archive (⌘2)", forSegment: 1)

        tableView = DraftTableView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.addTableColumn(NSTableColumn(identifier: .init("draft")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onReturn = { [weak self] in self?.onReturn?() }
        tableView.setAccessibilityLabel("Drafts")
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusField = NSTextField(labelWithString: "")
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(statusClicked)))

        statusSpinner = NSProgressIndicator()
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false

        for view in [folderControl!, scrollView, statusField!, statusSpinner!] as [NSView] {
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            folderControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            folderControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            folderControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: folderControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -6),

            statusSpinner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusSpinner.centerYAnchor.constraint(equalTo: statusField.centerYAnchor),
            statusField.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 4),
            statusField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            statusField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(draftsDidChange), name: .draftsDidChange, object: store)
        center.addObserver(self, selector: #selector(updateStatus), name: .syncStatusDidChange, object: store)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, !rows.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    // MARK: Folder

    @objc private func folderControlChanged() {
        show(folder: Folder(rawValue: folderControl.selectedSegment) ?? .inbox, select: nil)
    }

    /// Shows a folder, and a draft in it when one is named. Switching folders
    /// otherwise selects its newest draft.
    func show(folder: Folder, select url: URL?) {
        let changed = folder != self.folder
        self.folder = folder
        folderControl.selectedSegment = folder.rawValue
        reloadRows(keeping: url ?? (changed ? nil : selectedURL))
        if changed {
            onFolderChange?(folder)
            if url == nil { onSelect?(selectedURL) }
        }
    }

    // MARK: Rows

    @objc private func draftsDidChange() {
        reloadRows(keeping: selectedURL)
    }

    /// Re-reads the rows from the store, keeping the selection on the same
    /// draft wherever it has moved to.
    private func reloadRows(keeping url: URL?) {
        let fresh = store.drafts(in: folder)
        suppressSelection = true
        defer { suppressSelection = false }
        if fresh.map(\.id) == rows.map(\.id) {
            let changed = IndexSet(fresh.indices.filter { fresh[$0] != rows[$0] })
            rows = fresh
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
                tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
        } else {
            rows = fresh
            tableView.reloadData()
        }
        if let url, let index = rows.firstIndex(where: { $0.url == url.standardizedFileURL }) {
            if tableView.selectedRow != index {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
            }
            tableView.scrollRowToVisible(index)
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
    }

    func select(_ url: URL?) {
        reloadRows(keeping: url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: DraftCellView.identifier, owner: self) as? DraftCellView ?? DraftCellView()
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        DraftCellView.height(for: rows[row], width: tableView.tableColumns[0].width)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelect?(selectedURL)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let draft = clickedOrSelectedDraft else { return }
        let target = actionTarget
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = draft.url
        }
        add(draft.folder == .inbox ? "Archive" : "Move to Inbox", #selector(MainWindowController.toggleArchive(_:)))
        add("Rename to Match Title", #selector(MainWindowController.renameToTitle(_:)))
        add("Open Notes", #selector(MainWindowController.openNotes(_:)))
        menu.addItem(.separator())
        add("Show in Finder", #selector(MainWindowController.revealInFinder(_:)))
        add("Copy Path", #selector(MainWindowController.copyPath(_:)))
    }

    // MARK: Status

    @objc private func statusClicked() { store.sync() }

    @objc func updateStatus() {
        guard statusField != nil else { return }
        statusField.textColor = .secondaryLabelColor
        statusField.toolTip = nil
        switch store.status {
        case .syncing:
            statusSpinner.startAnimation(nil)
            statusField.stringValue = "Syncing…"
        case .idle(let last):
            statusSpinner.stopAnimation(nil)
            if let last {
                let ago = Date().timeIntervalSince(last) < 60
                    ? "just now"
                    : RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
                statusField.stringValue = "Synced \(ago)"
            } else {
                statusField.stringValue = ""
            }
            statusField.toolTip = "Click to sync now (⌘R)"
        case .failed(let message):
            statusSpinner.stopAnimation(nil)
            statusField.stringValue = "⚠︎ " + message
            statusField.textColor = .systemRed
            statusField.toolTip = message + "\n\nClick to try again."
        case .unversioned:
            statusSpinner.stopAnimation(nil)
            statusField.stringValue = "Not under version control"
        }
    }
}

/// Return goes to the editor, as in Mail and NetNewsWire.
final class DraftTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        // Return, Enter, and Tab.
        if plain, [36, 76, 48].contains(event.keyCode) {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class DraftCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DraftCell")

    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let snippetField = NSTextField(wrappingLabelWithString: "")
    private let dateField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.font = Self.titleFont
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byWordWrapping
        titleField.cell?.truncatesLastVisibleLine = true
        snippetField.font = Self.snippetFont
        snippetField.maximumNumberOfLines = 3
        snippetField.lineBreakMode = .byWordWrapping
        snippetField.cell?.truncatesLastVisibleLine = true
        dateField.font = .systemFont(ofSize: 11)
        dateField.alignment = .right

        for field in [titleField, snippetField, dateField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isSelectable = false
            addSubview(field)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snippetField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: dateField.leadingAnchor, constant: -6),
            dateField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snippetField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            snippetField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            snippetField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snippetField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let snippetFont = NSFont.systemFont(ofSize: 12)

    /// A row's height, measured the way the cell will lay it out.
    static func height(for draft: Draft, width: CGFloat) -> CGFloat {
        func measure(_ text: String, _ font: NSFont, _ width: CGFloat, lines: Int) -> CGFloat {
            let line = ceil(font.ascender - font.descender + font.leading)
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            return min(ceil(bounds.height), line * CGFloat(lines))
        }
        let date = (format(draft.modified) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        var height = 8 + measure(draft.title.isEmpty ? "Untitled" : draft.title, titleFont, width - 16 - date - 10, lines: 2)
        if !draft.snippet.isEmpty {
            height += 2 + measure(draft.snippet, snippetFont, width - 20, lines: 3)
        }
        return height + 9
    }

    func configure(with draft: Draft) {
        titleField.stringValue = draft.title.isEmpty ? "Untitled" : draft.title
        snippetField.stringValue = draft.snippet
        snippetField.isHidden = draft.snippet.isEmpty
        dateField.stringValue = Self.format(draft.modified)
        setAccessibilityLabel("\(titleField.stringValue), \(dateField.stringValue)")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// Wrapping labels need to know how wide they may be to know how tall
    /// they are.
    override func layout() {
        let titleWidth = max(0, bounds.width - 16 - dateField.intrinsicContentSize.width - 6)
        let snippetWidth = max(0, bounds.width - 16)
        var changed = false
        if titleField.preferredMaxLayoutWidth != titleWidth {
            titleField.preferredMaxLayoutWidth = titleWidth
            changed = true
        }
        if snippetField.preferredMaxLayoutWidth != snippetWidth {
            snippetField.preferredMaxLayoutWidth = snippetWidth
            changed = true
        }
        super.layout()
        if changed { needsLayout = true }
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        titleField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        snippetField.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        dateField.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .tertiaryLabelColor
    }

    /// The resolution that tells drafts apart: a time today, a weekday this
    /// week, a date beyond it.
    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
