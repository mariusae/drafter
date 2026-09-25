import AppKit
import DrafterCore

extension NSToolbarItem.Identifier {
    static let newDraft = Self("NewDraft")
    static let sync = Self("Sync")
    static let archive = Self("Archive")
    static let goToAnything = Self("GoToAnything")
    static let outline = Self("Outline")
}

/// The one window: drafts on the left, the draft on the right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation {
    let store: DraftStore
    let list: DraftListViewController
    let editor: EditorViewController
    let outline = OutlineViewController()
    private let split = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    private var goTo: GoToAnythingController!
    private var restored = false

    static let lastDraftKey = "LastDraftPath"

    init(store: DraftStore) {
        self.store = store
        list = DraftListViewController(store: store)
        editor = EditorViewController(store: store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 400)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.title = "Drafter"
        window.tabbingMode = .disallowed
        super.init(window: window)

        let sidebar = NSSplitViewItem(sidebarWithViewController: list)
        sidebar.minimumThickness = 240
        sidebar.maximumThickness = 460
        sidebar.canCollapse = true
        sidebar.allowsFullHeightLayout = true
        let content = NSSplitViewItem(viewController: editor)
        content.minimumThickness = 360
        outlineItem = NSSplitViewItem(inspectorWithViewController: outline)
        outlineItem.minimumThickness = 180
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.addSplitViewItem(outlineItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.delegate = self

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        goTo = GoToAnythingController(store: store, commands: { [weak self] in self?.commands() ?? [] },
                                      headings: { [weak self] in self?.editor.headings ?? [] },
                                      open: { [weak self] draft, range in self?.open(draft.url, selecting: range) },
                                      goToHeading: { [weak self] index in self?.editor.goToHeading(index) })

        list.actionTarget = self
        list.onSelect = { [weak self] url in self?.listSelected(url) }
        list.onReturn = { [weak self] in self?.editor.focus() }
        list.onModeChange = { [weak self] _ in self?.updateTitle() }
        list.onSelectChange = { [weak self] change in self?.open(change) }
        editor.onEscape = { [weak self] in self?.list.focus() }
        editor.onFiled = { [weak self] url in self?.list.select(url); self?.remember(url) }
        editor.onTitleChange = { [weak self] in self?.updateTitle() }
        editor.onHeadingsChange = { [weak self] in
            guard let self else { return }
            outline.update(editor.headings, current: editor.currentHeading)
        }
        editor.onCurrentHeadingChange = { [weak self] in
            guard let self else { return }
            outline.mark(editor.currentHeading)
        }
        outline.onChoose = { [weak self] index in self?.editor.goToHeading(index) }
        outline.onReturn = { [weak self] in self?.editor.focus() }
        store.flushPendingEdits = { [weak self] in self?.editor.saveNow() }

        NotificationCenter.default.addObserver(self, selector: #selector(draftsDidChange),
                                               name: .draftsDidChange, object: store)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Selection

    private func listSelected(_ url: URL?) {
        editor.show(url)
        if let url { remember(url) }
        updateTitle()
    }

    /// Opens a draft wherever it is filed, switching folders to show it.
    func open(_ url: URL, selecting range: NSRange? = nil) {
        let url = url.standardizedFileURL
        if let folder = store.directory.folder(of: url), store.draft(at: url) != nil {
            list.show(folder: folder, select: url)
        } else {
            list.select(nil)  // notes, which are not listed
        }
        editor.show(url, selecting: range)
        remember(url)
        updateTitle()
        window?.makeKeyAndOrderFront(nil)
        editor.focus()
    }

    private func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.lastDraftKey)
    }

    /// The first reading of the directory reopens the draft last worked on.
    @objc private func draftsDidChange() {
        guard !restored else {
            updateTitle()
            return
        }
        restored = true
        if let path = UserDefaults.standard.string(forKey: Self.lastDraftKey),
           let draft = store.draft(at: URL(fileURLWithPath: path)) {
            list.show(folder: draft.folder, select: draft.url)
            editor.show(draft.url)
        } else if let first = store.drafts(in: .inbox).first {
            list.show(folder: .inbox, select: first.url)
            editor.show(first.url)
        }
        updateTitle()
    }

    /// Opens a timeline entry: the draft, at the blocks that moved. The
    /// entry may show the draft as it stood some time ago, so the blocks are
    /// looked for by their text before their lines are trusted.
    private func open(_ change: TimelineChange) {
        let url = store.directory.root.appendingPathComponent(change.name).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        editor.show(url)
        remember(url)
        updateTitle()
        guard let block = change.blocks.first else { return }
        let text = editor.textView.string as NSString
        let found = text.range(of: block.text)
        let range = found.location != NSNotFound ? found : editor.rangeOfLines(block.line, block.endLine)
        editor.reveal(range, atTop: false, flash: true)
        // Keep the keyboard in the timeline, to read on down it.
        list.focusKeepingSelection()
    }

    private var currentDraft: Draft? { editor.url.flatMap { store.draft(at: $0) } }

    private func updateTitle() {
        guard let window else { return }
        if editor.isShowingDraft {
            window.title = editor.currentTitle
            if let draft = currentDraft {
                window.subtitle = "\(draft.folder.name) · \(DraftCellView.format(draft.modified))"
            } else if let url = editor.url, DraftsDirectory.isNotesName(url.lastPathComponent) {
                window.subtitle = "Notes"
            } else {
                window.subtitle = editor.isNew ? "New Draft" : ""
            }
        } else if let folder = list.mode.folder {
            window.title = folder.name
            let count = store.drafts(in: folder).count
            window.subtitle = "\(count) \(count == 1 ? "draft" : "drafts")"
        } else {
            window.title = "Timeline"
            window.subtitle = ""
        }
        window.toolbar?.validateVisibleItems()
    }

    // MARK: Actions

    @objc func newDraft(_ sender: Any?) {
        list.show(folder: .inbox, select: nil)
        list.select(nil)
        editor.beginNew()
        updateTitle()
    }

    @objc func saveDraft(_ sender: Any?) {
        editor.saveNow()
    }

    /// The draft an action is about: the row it was invoked on, else the one
    /// on screen.
    private func target(_ sender: Any?) -> URL? {
        if let item = sender as? NSMenuItem, let url = item.representedObject as? URL { return url }
        return editor.url
    }

    @objc func toggleArchive(_ sender: Any?) {
        guard let url = target(sender), let folder = store.directory.folder(of: url) else { return }
        let showing = editor.url == url.standardizedFileURL
        // The neighbor that takes the archived draft's place in the list.
        let rows = list.rows
        let index = rows.firstIndex { $0.url == url.standardizedFileURL }
        do {
            let moved = folder == .inbox ? try store.archive(url) : try store.unarchive(url)
            if showing { editor.moved(to: moved) }
            if showing, let index {
                let remaining = rows.filter { $0.url != url.standardizedFileURL }
                let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].url
                list.select(next)
                editor.show(next)
            }
            updateTitle()
        } catch {
            presentError(error)
        }
    }

    @objc func renameToTitle(_ sender: Any?) {
        guard let url = target(sender) else { return }
        do {
            let moved = try store.rename(url)
            if editor.url == url.standardizedFileURL { editor.moved(to: moved) }
            list.select(moved)
        } catch {
            presentError(error)
        }
    }

    @objc func openNotes(_ sender: Any?) {
        guard let url = target(sender) else { return }
        if DraftsDirectory.isNotesName(url.lastPathComponent), store.draft(at: url) == nil {
            // In the notes already: go back to the draft they are about.
            open(url.deletingLastPathComponent().appendingPathComponent(
                String(url.lastPathComponent.dropLast(DraftsDirectory.notesSuffix.count)) + ".md"))
            return
        }
        let draft = store.draft(at: url) ?? Draft(url: url, folder: .inbox, title: editor.currentTitle,
                                                  snippet: "", text: "", modified: Date(), name: url.lastPathComponent)
        do {
            open(try store.notes(for: draft))
        } catch {
            presentError(error)
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        if let url = target(sender) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(store.directory.root)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        guard let url = target(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func showInbox(_ sender: Any?) { list.show(folder: .inbox, select: nil); list.focus() }
    @objc func showArchive(_ sender: Any?) { list.show(folder: .archive, select: nil); list.focus() }
    /// For snapshots: choose the first row of whatever the list shows.
    func nextDraftOrEntry() { list.focus() }
    @objc func showTimeline(_ sender: Any?) { list.showTimeline(); list.focus() }
    @objc func goToHeading(_ sender: Any?) { goTo.show(over: window, query: "@") }
    @objc func nextHeading(_ sender: Any?) { editor.nextHeading(sender) }
    @objc func previousHeading(_ sender: Any?) { editor.previousHeading(sender) }
    @objc func focusOutline(_ sender: Any?) {
        if outlineItem.isCollapsed { outlineItem.animator().isCollapsed = false }
        outline.focus()
    }
    @objc func toggleOutline(_ sender: Any?) { outlineItem.animator().isCollapsed.toggle() }
    @objc func syncNow(_ sender: Any?) { store.sync() }
    @objc func goToAnything(_ sender: Any?) { goTo.toggle(over: window) }
    func goToAnything(query: String) { goTo.show(over: window, query: query) }
    @objc func runCommand(_ sender: Any?) { goTo.show(over: window, query: "> ") }
    @objc func focusList(_ sender: Any?) { list.focus() }
    @objc func focusEditor(_ sender: Any?) { editor.focus() }

    @objc func nextDraft(_ sender: Any?) { step(1) }
    @objc func previousDraft(_ sender: Any?) { step(-1) }

    private func step(_ delta: Int) {
        let rows = list.rows
        guard !rows.isEmpty else { return }
        let current = editor.url.flatMap { url in rows.firstIndex { $0.url == url } } ?? (delta > 0 ? -1 : rows.count)
        let next = max(0, min(rows.count - 1, current + delta))
        list.select(rows[next].url)
        listSelected(rows[next].url)
    }

    @objc func makeTextBigger(_ sender: Any?) { editor.makeTextBigger(sender) }
    @objc func makeTextSmaller(_ sender: Any?) { editor.makeTextSmaller(sender) }
    @objc func makeTextStandardSize(_ sender: Any?) { editor.makeTextStandardSize(sender) }

    // MARK: Commands for ⌘K

    private func commands() -> [QuickCommand] {
        let hasDraft: () -> Bool = { [weak self] in self?.editor.url != nil }
        let archived = currentDraft?.folder == .archive
        return [
            QuickCommand(title: "New Draft", symbol: "square.and.pencil", shortcut: "⌘N") { [weak self] in self?.newDraft(nil) },
            QuickCommand(title: archived ? "Move Draft to Inbox" : "Archive Draft", symbol: archived ? "tray.and.arrow.up" : "archivebox",
                         shortcut: "⌃⌘A", isEnabled: hasDraft) { [weak self] in self?.toggleArchive(nil) },
            QuickCommand(title: "Rename Draft to Match Title", symbol: "character.cursor.ibeam", isEnabled: hasDraft) { [weak self] in self?.renameToTitle(nil) },
            QuickCommand(title: "Open Notes", symbol: "note.text", shortcut: "⌥⌘N", isEnabled: hasDraft) { [weak self] in self?.openNotes(nil) },
            QuickCommand(title: "Show Inbox", symbol: "tray", shortcut: "⌘1") { [weak self] in self?.showInbox(nil) },
            QuickCommand(title: "Show Archive", symbol: "archivebox", shortcut: "⌘2") { [weak self] in self?.showArchive(nil) },
            QuickCommand(title: "Show Timeline", symbol: "clock", shortcut: "⌘3") { [weak self] in self?.showTimeline(nil) },
            QuickCommand(title: "Go to Heading…", symbol: "list.bullet.indent", shortcut: "⇧⌘O", isEnabled: hasDraft) { [weak self] in self?.goToHeading(nil) },
            QuickCommand(title: "Next Heading", symbol: "chevron.down", shortcut: "⌃⌘↓", isEnabled: hasDraft) { [weak self] in self?.nextHeading(nil) },
            QuickCommand(title: "Previous Heading", symbol: "chevron.up", shortcut: "⌃⌘↑", isEnabled: hasDraft) { [weak self] in self?.previousHeading(nil) },
            QuickCommand(title: "Toggle Outline", symbol: "sidebar.right", shortcut: "⌥⌘I") { [weak self] in self?.toggleOutline(nil) },
            QuickCommand(title: "Sync Now", symbol: "arrow.triangle.2.circlepath", shortcut: "⌘R") { [weak self] in self?.syncNow(nil) },
            QuickCommand(title: "Show in Finder", symbol: "folder") { [weak self] in self?.revealInFinder(nil) },
            QuickCommand(title: "Copy Path", symbol: "doc.on.clipboard", isEnabled: hasDraft) { [weak self] in self?.copyPath(nil) },
            QuickCommand(title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: "⌃⌘S") { [weak self] in self?.split.toggleSidebar(nil) },
            QuickCommand(title: "Choose Drafts Folder…", symbol: "folder.badge.gearshape") {
                (NSApp.delegate as? AppDelegate)?.chooseDraftsFolder(nil)
            },
        ]
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validate(item.action, title: { item.title = $0 })
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action) { title in
            item.label = title
            item.toolTip = title
            if item.itemIdentifier == .archive {
                let archived = self.currentDraft?.folder == .archive
                item.image = NSImage(systemSymbolName: archived ? "tray.and.arrow.up" : "archivebox",
                                     accessibilityDescription: title)
            }
        }
    }

    private func validate(_ action: Selector?, title: (String) -> Void) -> Bool {
        switch action {
        case #selector(toggleArchive(_:)):
            let url = editor.url
            let folder = url.flatMap { store.directory.folder(of: $0) }
            title(folder == .archive ? "Move to Inbox" : "Archive")
            return url != nil && store.draft(at: url!) != nil
        case #selector(renameToTitle(_:)), #selector(copyPath(_:)):
            return editor.url != nil
        case #selector(openNotes(_:)):
            if let url = editor.url, DraftsDirectory.isNotesName(url.lastPathComponent), store.draft(at: url) == nil {
                title("Back to Draft")
            } else {
                title("Open Notes")
            }
            return editor.url != nil
        case #selector(saveDraft(_:)):
            return editor.isShowingDraft
        case #selector(goToHeading(_:)), #selector(nextHeading(_:)), #selector(previousHeading(_:)):
            return !editor.headings.isEmpty
        case #selector(toggleOutline(_:)):
            title(outlineItem.isCollapsed ? "Show Outline" : "Hide Outline")
            return true
        case #selector(syncNow(_:)):
            return store.git != nil
        default:
            return true
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .sync, .newDraft, .sidebarTrackingSeparator,
         .flexibleSpace, .archive, .goToAnything, .inspectorTrackingSeparator, .flexibleSpace, .outline]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator, .flexibleSpace, .space,
         .newDraft, .sync, .archive, .goToAnything, .outline]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.target = self
            item.isBordered = true
            return item
        }
        switch id {
        case .newDraft: return item("New Draft", "square.and.pencil", #selector(newDraft(_:)))
        case .sync: return item("Sync", "arrow.triangle.2.circlepath", #selector(syncNow(_:)))
        case .archive: return item("Archive", "archivebox", #selector(toggleArchive(_:)))
        case .goToAnything: return item("Go to Anything", "magnifyingglass", #selector(goToAnything(_:)))
        case .outline: return item("Outline", "sidebar.right", #selector(toggleOutline(_:)))
        default: return nil
        }
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        editor.saveNow()
    }

    func windowWillClose(_ notification: Notification) {
        editor.saveNow()
    }
}
