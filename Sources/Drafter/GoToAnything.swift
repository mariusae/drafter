import AppKit
import DrafterCore

struct QuickCommand {
    var title: String
    var symbol: String
    var shortcut: String = ""
    var isEnabled: () -> Bool = { true }
    var perform: () -> Void
}

/// ⌘K: one field that goes to any draft by its title, to any line of any
/// draft by what is written on it, or runs any command. `>` narrows it to
/// commands.
@MainActor
final class GoToAnythingController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Result {
        case draft(Draft, ranges: [NSRange])
        case line(Draft, text: String, ranges: [NSRange], location: NSRange)
        case command(QuickCommand, ranges: [NSRange])
    }

    private let store: DraftStore
    private let commands: () -> [QuickCommand]
    private let open: (Draft, NSRange?) -> Void

    private var panel: GoToPanel?
    private var field: NSTextField!
    private var table: NSTableView!
    private var scrollView: NSScrollView!
    private var heightConstraint: NSLayoutConstraint!
    private var results: [Result] = []

    private static let width: CGFloat = 640
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 9
    private static let fieldHeight: CGFloat = 56

    init(store: DraftStore, commands: @escaping () -> [QuickCommand], open: @escaping (Draft, NSRange?) -> Void) {
        self.store = store
        self.commands = commands
        self.open = open
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(over window: NSWindow?) {
        if isVisible { close() } else { show(over: window) }
    }

    func show(over window: NSWindow?, query: String = "") {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.stringValue = query
        update()
        if let window {
            let frame = window.frame
            let origin = NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.22)
            panel.setFrameTopLeftPoint(origin)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Panel

    private func makePanel() -> GoToPanel {
        let panel = GoToPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Go to draft, text, or > command"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("result")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.refusesFirstResponder = true

        scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(icon)
        background.addSubview(field)
        background.addSubview(separator)
        background.addSubview(scrollView)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            heightConstraint,
            background.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = background
        return panel
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { update() }

    private func update() {
        results = search(field.stringValue)
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        let visible = min(results.count, Self.maxVisibleRows)
        heightConstraint.constant = visible == 0 ? 0 : CGFloat(visible) * Self.rowHeight + 12
        if let panel {
            let top = panel.frame.maxY
            panel.layoutIfNeeded()
            let size = panel.contentView!.fittingSize
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                           display: true)
        }
    }

    private func search(_ raw: String) -> [Result] {
        let query = raw.trimmingCharacters(in: .whitespaces)
        let available = commands().filter { $0.isEnabled() }
        let drafts = store.drafts  // inbox first, each newest first

        if query.hasPrefix(">") {
            let rest = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return available.compactMap { command in
                Fuzzy.match(rest, in: command.title).map { (command, $0) }
            }
            .sorted { $0.1.score > $1.1.score }
            .map { .command($0.0, ranges: $0.1.ranges) }
        }
        if query.isEmpty {
            return drafts.prefix(30).map { .draft($0, ranges: []) }
        }

        var scored: [(Int, Result)] = []
        for draft in drafts {
            guard let match = Fuzzy.match(query, in: draft.title) else { continue }
            // What is still being written ranks over what was put away.
            scored.append((match.score + (draft.folder == .inbox ? 3 : 0), .draft(draft, ranges: match.ranges)))
        }
        for command in available {
            guard let match = Fuzzy.match(query, in: command.title), match.score > query.count * 4 else { continue }
            scored.append((match.score - 2, .command(command, ranges: match.ranges)))
        }
        scored.sort { $0.0 > $1.0 }

        var lines: [Result] = []
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if query.count >= 2 {
            outer: for draft in drafts {
                let text = draft.text as NSString
                text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, stop in
                    guard let line, !line.isEmpty else { return }
                    let lower = line.lowercased()
                    guard terms.allSatisfy({ lower.contains($0) }) else { return }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // A title found by its line is already found by its title.
                    if DraftText.title(of: draft.text) == trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) { return }
                    let lead = (line as NSString).length - (line.drop(while: { $0 == " " || $0 == "\t" }) as Substring).utf16.count
                    let hit = (trimmed as NSString).range(of: terms[0], options: .caseInsensitive)
                    let location = NSRange(location: range.location + lead + hit.location, length: hit.length)
                    // A line of prose is a paragraph: show the part of it around the match.
                    let excerpt = Self.excerpt(trimmed, around: hit)
                    let ranges = terms.compactMap { term -> NSRange? in
                        let found = (excerpt as NSString).range(of: term, options: .caseInsensitive)
                        return found.location == NSNotFound ? nil : found
                    }
                    lines.append(.line(draft, text: excerpt, ranges: ranges, location: location))
                    if lines.count >= 60 { stop.pointee = true }
                }
                if lines.count >= 60 { break outer }
            }
        }
        return scored.map(\.1) + lines
    }

    private static func excerpt(_ line: String, around hit: NSRange, before: Int = 30) -> String {
        let text = line as NSString
        guard hit.location > before + 10 else { return line }
        var start = hit.location - before
        // Begin at a word.
        let space = text.range(of: " ", options: [], range: NSRange(location: start, length: hit.location - start))
        if space.location != NSNotFound { start = space.location + 1 }
        return "…" + text.substring(from: start)
    }

    // MARK: Choosing

    private func choose(_ row: Int) {
        guard row >= 0, row < results.count else { return }
        let result = results[row]
        close()
        switch result {
        case .draft(let draft, _): open(draft, nil)
        case .line(let draft, _, _, let location): open(draft, location)
        case .command(let command, _): command.perform()
        }
    }

    @objc private func tableClicked() { choose(table.clickedRow) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(Self.maxVisibleRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ResultCellView.identifier, owner: self) as? ResultCellView ?? ResultCellView()
        switch results[row] {
        case .draft(let draft, let ranges):
            cell.configure(symbol: draft.folder == .inbox ? "doc.text" : "archivebox",
                           title: draft.title.isEmpty ? "Untitled" : draft.title, highlights: ranges,
                           subtitle: draft.snippet,
                           accessory: draft.folder == .archive ? "Archive" : DraftCellView.format(draft.modified))
        case .line(let draft, let text, let ranges, _):
            cell.configure(symbol: "text.alignleft", title: text, highlights: ranges,
                           subtitle: draft.title, accessory: draft.folder == .archive ? "Archive" : "")
        case .command(let command, let ranges):
            cell.configure(symbol: command.symbol, title: command.title, highlights: ranges,
                           subtitle: "", accessory: command.shortcut)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ResultRowView()
    }
}

final class GoToPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// A rounded, inset selection, as in Spotlight.
final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

final class ResultCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ResultCell")

    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let accessoryField = NSTextField(labelWithString: "")
    private var title = ""
    private var highlights: [NSRange] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        subtitleField.maximumNumberOfLines = 1
        subtitleField.usesSingleLineMode = true
        subtitleField.font = .systemFont(ofSize: 11.5)
        subtitleField.lineBreakMode = .byTruncatingTail
        accessoryField.font = .systemFont(ofSize: 12)
        accessoryField.alignment = .right

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        for view in [icon, stack, accessoryField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryField.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryField.leadingAnchor, constant: -10),
            accessoryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            accessoryField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, title: String, highlights: [NSRange], subtitle: String, accessory: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title = title
        self.highlights = highlights
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        accessoryField.stringValue = accessory
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: primary,
            .paragraphStyle: paragraph,
        ])
        let length = attributed.length
        for range in highlights where NSMaxRange(range) <= length {
            attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: range)
            if !selected { attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range) }
        }
        titleField.attributedStringValue = attributed
        subtitleField.textColor = secondary
        accessoryField.textColor = secondary
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
