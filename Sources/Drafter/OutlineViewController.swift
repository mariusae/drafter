import AppKit
import DrafterCore

/// The inspector: the draft's headings as a tree. It follows along, marking
/// the section being written or read, and a click goes there.
@MainActor
final class OutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node: NSObject {
        let index: Int
        let heading: MarkdownDocument.Heading
        var children: [Node] = []

        init(index: Int, heading: MarkdownDocument.Heading) {
            self.index = index
            self.heading = heading
        }
    }

    var onChoose: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    private var outlineView: OutlineView!
    private var emptyField: NSTextField!
    private var roots: [Node] = []
    private var nodes: [Node] = []  // by heading index
    private var suppressSelection = false

    override func loadView() {
        let container = NSView()

        let header = NSTextField(labelWithString: "Outline")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        outlineView = OutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 12
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("heading"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.onReturn = { [weak self] in self?.onReturn?() }
        outlineView.setAccessibilityLabel("Outline")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyField = NSTextField(labelWithString: "No Headings")
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = .tertiaryLabelColor
        emptyField.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, scrollView, emptyField!] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
        ])
        view = container
    }

    func focus() {
        view.window?.makeFirstResponder(outlineView)
    }

    /// Rebuilds the tree: each heading nests under the nearest heading above
    /// it of a higher level.
    func update(_ headings: [MarkdownDocument.Heading], current: Int?) {
        roots = []
        nodes = []
        var stack: [Node] = []
        for (index, heading) in headings.enumerated() {
            let node = Node(index: index, heading: heading)
            nodes.append(node)
            while let last = stack.last, last.heading.level >= heading.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        emptyField.isHidden = !headings.isEmpty
        mark(current)
    }

    /// Marks the current section without going anywhere.
    func mark(_ index: Int?) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let index, nodes.indices.contains(index) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: nodes[index])
        guard row >= 0 else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        outlineView.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? Node else { return }
        onChoose?(node.index)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let level = node.heading.level
        cell.textField?.stringValue = node.heading.title.isEmpty ? "Untitled" : node.heading.title
        cell.textField?.font = .systemFont(ofSize: level <= 1 ? 13 : 12.5, weight: level <= 1 ? .semibold : level == 2 ? .medium : .regular)
        cell.toolTip = node.heading.title
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Arrowing through the outline goes along, as in a source list.
        guard !suppressSelection, outlineView.window?.firstResponder === outlineView,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
        onChoose?(node.index)
        outlineView.window?.makeFirstResponder(outlineView)
    }
}

/// Return goes back to the text.
final class OutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { onReturn?() } else { super.keyDown(with: event) }
    }
}
