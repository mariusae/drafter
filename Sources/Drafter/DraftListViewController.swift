import AppKit
import DrafterCore

/// What the left column is showing: a folder's drafts, or the timeline.
enum ListMode: Int {
    case inbox, archive, timeline

    var name: String { ["Inbox", "Archive", "Timeline"][rawValue] }
    var folder: Folder? { self == .timeline ? nil : Folder(rawValue: rawValue) }
    init(_ folder: Folder) { self = folder == .inbox ? .inbox : .archive }
}

/// The left column: the drafts of one folder, newest first, in the manner of
/// NetNewsWire's timeline — a bold title, a few lines of what follows it, and
/// when it was last touched. Or the timeline: what was written lately, as the
/// blocks that moved.
@MainActor
final class DraftListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let store: DraftStore
    private(set) var mode: ListMode = .inbox
    private(set) var rows: [Draft] = []
    private(set) var changes: [TimelineChange] = []

    var onSelect: ((URL?) -> Void)?
    var onSelectChange: ((TimelineChange) -> Void)?
    var onReturn: (() -> Void)?
    var onModeChange: ((ListMode) -> Void)?
    /// The context menu's actions go to whoever handles them for the window.
    weak var actionTarget: AnyObject?

    private var tableView: DraftTableView!
    private var folderControl: NSSegmentedControl!
    private var statusField: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var statusTimer: Timer?
    private var emptyField: NSTextField!
    private var suppressSelection = false
    private var pendingChangeID: String?

    init(store: DraftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedURL: URL? {
        let row = tableView.selectedRow
        return mode != .timeline && row >= 0 && row < rows.count ? rows[row].url : nil
    }

    private var selectedChangeID: String? {
        let row = tableView.selectedRow
        return mode == .timeline && row >= 0 && row < changes.count ? changes[row].id : nil
    }

    /// The draft a context menu is about: the row's draft, or a timeline
    /// entry's.
    var clickedOrSelectedDraft: Draft? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        if mode == .timeline {
            guard row >= 0, row < changes.count else { return nil }
            return store.draft(at: store.directory.root.appendingPathComponent(changes[row].name))
        }
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    override func loadView() {
        let container = NSView()

        folderControl = NSSegmentedControl(labels: ["Inbox", "Archive", "Timeline"], trackingMode: .selectOne,
                                           target: self, action: #selector(folderControlChanged))
        folderControl.selectedSegment = 0
        folderControl.segmentDistribution = .fillEqually
        folderControl.controlSize = .large
        folderControl.translatesAutoresizingMaskIntoConstraints = false
        folderControl.setToolTip("Inbox (⌘1)", forSegment: 0)
        folderControl.setToolTip("Archive (⌘2)", forSegment: 1)
        folderControl.setToolTip("Timeline: what was written lately (⌘3)", forSegment: 2)

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

        emptyField = NSTextField(labelWithString: "")
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = .tertiaryLabelColor
        emptyField.alignment = .center
        emptyField.translatesAutoresizingMaskIntoConstraints = false

        for view in [folderControl!, scrollView, statusField!, statusSpinner!, emptyField!] as [NSView] {
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

            emptyField.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -40),
        ])
        view = container

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(draftsDidChange), name: .draftsDidChange, object: store)
        center.addObserver(self, selector: #selector(updateStatus), name: .syncStatusDidChange, object: store)
        center.addObserver(self, selector: #selector(timelineDidChange), name: .timelineDidChange, object: store)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, tableView.numberOfRows > 0 {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    /// Takes the keyboard back without touching the selection.
    func focusKeepingSelection() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: Mode

    @objc private func folderControlChanged() {
        let mode = ListMode(rawValue: folderControl.selectedSegment) ?? .inbox
        if let folder = mode.folder { show(folder: folder, select: nil) } else { showTimeline() }
    }

    /// Shows a folder, and a draft in it when one is named. Switching folders
    /// otherwise selects its newest draft.
    func show(folder: Folder, select url: URL?) {
        let changed = setMode(ListMode(folder))
        reloadRows(keeping: url ?? (changed ? nil : selectedURL))
        if changed, url == nil { onSelect?(selectedURL) }
    }

    /// Shows the timeline. The draft on screen stays where it is until an
    /// entry is chosen; an entry named is selected, once history is read.
    func showTimeline(selecting id: String? = nil) {
        pendingChangeID = id
        guard setMode(.timeline) else { return }
        reloadChanges(keeping: nil)
    }

    private func setMode(_ mode: ListMode) -> Bool {
        let changed = mode != self.mode
        self.mode = mode
        folderControl.selectedSegment = mode.rawValue
        store.wantsTimeline = mode == .timeline
        if changed {
            rows = []
            changes = []
            tableView.reloadData()
            onModeChange?(mode)
        }
        return changed
    }

    // MARK: Rows

    @objc private func draftsDidChange() {
        guard mode != .timeline else { return }
        reloadRows(keeping: selectedURL)
    }

    @objc private func timelineDidChange() {
        guard mode == .timeline else { return }
        reloadChanges(keeping: selectedChangeID)
    }

    private func reloadChanges(keeping id: String?) {
        suppressSelection = true
        defer { suppressSelection = false }
        let fresh = store.timeline
        if fresh != changes {
            changes = fresh
            tableView.reloadData()
        }
        let wanted = id ?? pendingChangeID
        if store.timelineLoaded { pendingChangeID = nil }
        if let wanted, let index = changes.firstIndex(where: { $0.id == wanted }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        updateEmpty()
    }

    private func updateEmpty() {
        switch mode {
        case .timeline:
            emptyField.stringValue = store.timelineLoaded ? "Nothing written yet" : "Reading history…"
            emptyField.isHidden = !changes.isEmpty
        case .inbox, .archive:
            emptyField.stringValue = mode == .inbox ? "No Drafts" : "Nothing Archived"
            emptyField.isHidden = !rows.isEmpty
        }
    }

    /// Re-reads the rows from the store, keeping the selection on the same
    /// draft wherever it has moved to.
    private func reloadRows(keeping url: URL?) {
        guard let folder = mode.folder else { return }
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
        updateEmpty()
    }

    func select(_ url: URL?) {
        reloadRows(keeping: url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { mode == .timeline ? changes.count : rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if mode == .timeline {
            let cell = tableView.makeView(withIdentifier: TimelineCellView.identifier, owner: self) as? TimelineCellView ?? TimelineCellView()
            cell.configure(with: changes[row])
            return cell
        }
        let cell = tableView.makeView(withIdentifier: DraftCellView.identifier, owner: self) as? DraftCellView ?? DraftCellView()
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = tableView.tableColumns[0].width
        if mode == .timeline { return TimelineCellView.height(for: changes[row], width: width) }
        return DraftCellView.height(for: rows[row], width: width)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        if mode == .timeline {
            let row = tableView.selectedRow
            if row >= 0, row < changes.count { onSelectChange?(changes[row]) }
        } else {
            onSelect?(selectedURL)
        }
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

/// A timeline entry: which draft, when, and the blocks that moved, as written.
final class TimelineCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineCell")
    static let maxLines = 8
    static let excerptFont = NSFont.systemFont(ofSize: 12)

    private let titleField = NSTextField(labelWithString: "")
    private let excerptField = NSTextField(wrappingLabelWithString: "")
    private let timeField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.font = DraftCellView.titleFont
        titleField.lineBreakMode = .byTruncatingTail
        excerptField.font = Self.excerptFont
        excerptField.maximumNumberOfLines = Self.maxLines
        excerptField.lineBreakMode = .byWordWrapping
        excerptField.cell?.truncatesLastVisibleLine = true
        timeField.font = .systemFont(ofSize: 11)
        timeField.alignment = .right

        for field in [titleField, excerptField, timeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isSelectable = false
            addSubview(field)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        excerptField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeField.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: timeField.leadingAnchor, constant: -6),
            timeField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            excerptField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            excerptField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            excerptField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with change: TimelineChange) {
        titleField.stringValue = change.title.isEmpty ? "Untitled" : change.title
        timeField.stringValue = Self.format(change.when)
        excerptField.stringValue = Self.excerpt(change)
        setAccessibilityLabel("\(titleField.stringValue), \(timeField.stringValue)")
        toolTip = change.name
    }

    static func height(for change: TimelineChange, width: CGFloat) -> CGFloat {
        let titleHeight = ceil(DraftCellView.titleFont.ascender - DraftCellView.titleFont.descender + DraftCellView.titleFont.leading)
        let line = ceil(excerptFont.ascender - excerptFont.descender + excerptFont.leading)
        let bounds = (excerpt(change) as NSString).boundingRect(
            with: NSSize(width: max(width - 16, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: excerptFont])
        return 8 + titleHeight + 3 + min(ceil(bounds.height), line * CGFloat(maxLines)) + 10
    }

    /// The blocks, each dedented to itself, runs of blank lines closed up,
    /// and an ellipsis between blocks that are apart in the draft.
    static func excerpt(_ change: TimelineChange) -> String {
        change.blocks.map { block in
            let lines = block.text.components(separatedBy: "\n")
            let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
            var result: [String] = []
            for line in lines {
                let text = String(line.dropFirst(min(indent, line.prefix(while: { $0 == " " || $0 == "\t" }).count)))
                if text.trimmingCharacters(in: .whitespaces).isEmpty, result.last?.isEmpty ?? true { continue }
                result.append(text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : text)
            }
            return result.joined(separator: "\n")
        }.joined(separator: "\n…\n")
    }

    /// The resolution that tells writing apart: the time today, the weekday
    /// and time this week, the date beyond.
    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return DraftCellView.format(date)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    override func layout() {
        let width = max(0, bounds.width - 16)
        if excerptField.preferredMaxLayoutWidth != width { excerptField.preferredMaxLayoutWidth = width }
        super.layout()
    }

    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized
        titleField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        excerptField.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.85) : .secondaryLabelColor
        timeField.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .tertiaryLabelColor
    }
}
