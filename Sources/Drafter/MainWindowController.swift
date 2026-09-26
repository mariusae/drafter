import AppKit
import DrafterCore

extension NSToolbarItem.Identifier {
    static let newDraft = Self("NewDraft")
    static let sync = Self("Sync")
    static let archive = Self("Archive")
    static let goToAnything = Self("GoToAnything")
    static let outline = Self("Outline")
    static let copyContents = Self("CopyContents")
}

/// The one window: drafts on the left, the draft on the right.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation {
    let store: DraftStore
    let list: DraftListViewController
    let editor: EditorViewController
    let notesEditor: EditorViewController
    let outline = OutlineViewController()
    private let split = NSSplitViewController()
    private var outlineItem: NSSplitViewItem!
    /// The draft over its notes.
    private let pages = NSSplitViewController()
    private var notesItem: NSSplitViewItem!
    private var goTo: GoToAnythingController!
    private var restored = false
    /// A link that arrived before the directory was read, to follow once it is.
    private var pendingLink: URL?
    private let session = SessionState.shared

    init(store: DraftStore) {
        self.store = store
        list = DraftListViewController(store: store)
        editor = EditorViewController(store: store)
        notesEditor = EditorViewController(store: store, role: .notes)

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
        let notesPane = NotesPaneViewController(editor: notesEditor)
        pages.splitView.isVertical = false
        pages.splitView.dividerStyle = .thin
        let page = NSSplitViewItem(viewController: editor)
        page.minimumThickness = 120
        page.holdingPriority = .init(rawValue: 260)
        notesItem = NSSplitViewItem(viewController: notesPane)
        notesItem.minimumThickness = 90
        notesItem.canCollapse = true
        notesItem.isCollapsed = true
        pages.addSplitViewItem(page)
        pages.addSplitViewItem(notesItem)
        pages.splitView.autosaveName = "PagesSplit"
        notesPane.onClose = { [weak self] in self?.hideNotes() }

        let content = NSSplitViewItem(viewController: pages)
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
        list.onModeChange = { [weak self] mode in
            guard let self else { return }
            if restored {
                session.listMode = mode
                if mode != .timeline { session.timelineEntry = nil }
            }
            updateTitle()
        }
        list.onSelectChange = { [weak self] change in
            self?.session.timelineEntry = change.id
            self?.open(change)
        }
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
        editor.onURLChange = { [weak self] in self?.updateNotes() }
        notesEditor.onEscape = { [weak self] in self?.editor.focus() }
        store.flushPendingEdits = { [weak self] in
            self?.editor.saveNow()
            self?.notesEditor.saveNow()
        }

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
        guard restored else { return }
        session.openDraft = url
    }

    /// The first reading of the directory puts everything back as it was
    /// left: the list, the draft (whose own cursor and scroll the editor puts
    /// back), the timeline entry, and the pane that had the keyboard.
    @objc private func draftsDidChange() {
        guard !restored else {
            updateTitle()
            updateNotes()  // notes made elsewhere, or come down in a pull
            return
        }
        // Only a draft of this directory: the one remembered may belong to
        // a directory since left.
        let open = session.openDraft.flatMap {
            store.directory.folder(of: $0) != nil && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let mode = session.listMode
        if let folder = mode.folder {
            if let open, let draft = store.draft(at: open), draft.folder == folder {
                list.show(folder: folder, select: draft.url)
            } else {
                list.show(folder: folder, select: nil)
                if open == nil, let first = store.drafts(in: folder).first {
                    list.select(first.url)
                    editor.show(first.url)
                }
            }
        } else {
            list.showTimeline(selecting: session.timelineEntry)
        }
        if let open { editor.show(open) }
        restored = true
        if let url = editor.url { session.openDraft = url }
        if let link = pendingLink {
            pendingLink = nil
            openLink(link)
            updateTitle()
            return
        }
        updateNotes()
        switch session.focus {
        case .list: list.focusKeepingSelection()
        case .notes where !notesItem.isCollapsed: notesEditor.focus()
        case .outline where !outlineItem.isCollapsed: outline.focus()
        default: editor.focus()
        }
        updateTitle()
    }

    /// Notes which pane has the keyboard, and where the cursor is, for the
    /// next launch.
    func recordState() {
        editor.recordPosition()
        notesEditor.recordPosition()
        let responder = window?.firstResponder as? NSView
        if responder === editor.textView {
            session.focus = .editor
        } else if responder === notesEditor.textView {
            session.focus = .notes
        } else if let responder, responder.isDescendant(of: outline.view) {
            session.focus = .outline
        } else if let responder, responder.isDescendant(of: list.view) {
            session.focus = .list
        }
        session.saveNow()
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

    // MARK: Links and copying

    /// Follows a drafter:// link to its draft, wherever it is filed.
    func openLink(_ link: URL) {
        guard restored else {
            pendingLink = link  // launched by the link: follow it once there is a directory
            return
        }
        showWindow(nil)
        NSApp.activate()
        guard let url = DraftLink.resolve(link, in: store.directory) else {
            let alert = NSAlert()
            alert.messageText = "No Such Draft"
            let name = link.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            alert.informativeText = "There is no draft called “\(name)” in \(store.directory.root.path), or in its archive."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        open(url)
    }

    /// A link to the draft: its drafter:// URL as text, and as a link titled
    /// with the draft's title for anything that pastes rich text.
    @objc func copyLink(_ sender: Any?) {
        guard let url = target(sender) else { return }
        let link = DraftLink.url(for: url).absoluteString
        let title = store.draft(at: url)?.title ?? editor.currentTitle
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let item = NSPasteboardItem()
        item.setString(link, forType: .string)
        item.setString(link, forType: .URL)
        item.setString("<a href=\"\(link)\">\(escaped)</a>", forType: .html)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        acknowledge(.copyContents, symbol: "link")
    }

    /// The whole draft, as plain text: what is on screen for the draft on
    /// screen, saved or not; what is on disk for any other.
    @objc func copyContents(_ sender: Any?) {
        guard let url = target(sender) else { return }
        let text = url.standardizedFileURL == editor.url
            ? editor.textView.string
            : (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        acknowledge(.copyContents, symbol: "checkmark")
    }

    /// Says a copy happened, the way a toolbar can: the button shows it for
    /// a moment.
    private func acknowledge(_ id: NSToolbarItem.Identifier, symbol: String) {
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == id }) else { return }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Contents")
        }
    }

    // MARK: Notes

    /// The draft the notes pane is about: the one on screen, unless that is
    /// itself a notes file, whose notes are itself.
    private var notesOwner: URL? {
        guard let url = editor.url, DraftsDirectory.notes(for: url) != url else { return nil }
        return url
    }

    private var notesFocused: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: notesEditor.view) ?? false
    }

    /// Keeps the pane in step with the draft: its notes are shown when it
    /// has some, unless they were put away.
    private func updateNotes() {
        guard let owner = notesOwner else {
            notesEditor.show(nil)
            notesItem.isCollapsed = true
            return
        }
        let notes = DraftsDirectory.notes(for: owner)
        if FileManager.default.fileExists(atPath: notes.path), !session.notesHidden(for: owner) {
            notesEditor.show(notes)
            expandNotes(animated: false)
        } else {
            notesEditor.show(nil)
            notesItem.isCollapsed = true
        }
    }

    /// Brings the notes up and goes to them, making them if there are none.
    private func showNotes() {
        if editor.isNew { editor.saveNow() }  // a draft with no file has nowhere for notes to go
        guard let owner = notesOwner else {
            NSSound.beep()
            return
        }
        do {
            let existed = FileManager.default.fileExists(atPath: DraftsDirectory.notes(for: owner).path)
            let notes = try store.notes(for: owner, title: editor.currentTitle)
            session.setNotesHidden(false, for: owner)
            notesEditor.show(notes)
            if !existed { notesEditor.moveToEnd() }  // below the heading they open with
            expandNotes(animated: true)
            notesEditor.focus()
        } catch {
            presentError(error)
        }
    }

    /// Opens the pane at the height it was left at; the first time, or if
    /// it was left squeezed to nothing, at a third of the page.
    private func expandNotes(animated: Bool) {
        guard notesItem.isCollapsed else { return }
        let splitView = pages.splitView
        // Sized once the pane is out: mid-animation it is still no height.
        let size = { [weak self] in
            guard let self else { return }
            splitView.layoutSubtreeIfNeeded()
            let height = splitView.bounds.height
            if notesItem.viewController.view.frame.height < 140, height > 300 {
                splitView.setPosition(round(height * 0.66), ofDividerAt: 0)
            }
        }
        guard animated else {
            notesItem.isCollapsed = false
            size()
            return
        }
        NSAnimationContext.runAnimationGroup({ _ in
            notesItem.animator().isCollapsed = false
        }, completionHandler: { MainActor.assumeIsolated { size() } })
    }

    /// Puts the notes away, and keeps them away for this draft.
    private func hideNotes() {
        guard !notesItem.isCollapsed else { return }
        let hadFocus = notesFocused
        notesEditor.saveNow()
        notesEditor.recordPosition()
        if let owner = notesOwner { session.setNotesHidden(true, for: owner) }
        notesItem.animator().isCollapsed = true
        if hadFocus { editor.focus() }
    }

    /// ⌘J: bring up the notes and go to them; from the notes, put them away.
    @objc func toggleNotes(_ sender: Any?) {
        if notesItem.isCollapsed {
            showNotes()
        } else if notesFocused {
            hideNotes()
        } else {
            notesEditor.focus()
        }
    }

    /// From a row's menu: that draft, with its notes up.
    @objc func openNotes(_ sender: Any?) {
        if let url = target(sender), url.standardizedFileURL != editor.url { open(url) }
        showNotes()
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

    /// Type size is the notes' own while in the notes, the draft's elsewhere.
    private var focusedEditor: EditorViewController { notesFocused ? notesEditor : editor }
    @objc func makeTextBigger(_ sender: Any?) { focusedEditor.makeTextBigger(sender) }
    @objc func makeTextSmaller(_ sender: Any?) { focusedEditor.makeTextSmaller(sender) }
    @objc func makeTextStandardSize(_ sender: Any?) { focusedEditor.makeTextStandardSize(sender) }

    // MARK: Commands for ⌘K

    private func commands() -> [QuickCommand] {
        let hasDraft: () -> Bool = { [weak self] in self?.editor.url != nil }
        let archived = currentDraft?.folder == .archive
        return [
            QuickCommand(title: "New Draft", symbol: "square.and.pencil", shortcut: "⌘N") { [weak self] in self?.newDraft(nil) },
            QuickCommand(title: archived ? "Move Draft to Inbox" : "Archive Draft", symbol: archived ? "tray.and.arrow.up" : "archivebox",
                         shortcut: "⌃⌘A", isEnabled: hasDraft) { [weak self] in self?.toggleArchive(nil) },
            QuickCommand(title: "Rename Draft to Match Title", symbol: "character.cursor.ibeam", isEnabled: hasDraft) { [weak self] in self?.renameToTitle(nil) },
            QuickCommand(title: notesItem.isCollapsed ? "Show Notes" : "Hide Notes", symbol: "note.text", shortcut: "⌘J",
                         isEnabled: hasDraft) { [weak self] in self?.toggleNotes(nil) },
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
            QuickCommand(title: "Copy Link to Draft", symbol: "link", shortcut: "⇧⌘C", isEnabled: hasDraft) { [weak self] in self?.copyLink(nil) },
            QuickCommand(title: "Copy Draft Contents", symbol: "doc.on.doc", shortcut: "⌥⇧⌘C", isEnabled: hasDraft) { [weak self] in self?.copyContents(nil) },
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
        case #selector(renameToTitle(_:)), #selector(copyPath(_:)), #selector(copyLink(_:)), #selector(copyContents(_:)):
            return editor.url != nil
        case #selector(openNotes(_:)):
            return true
        case #selector(toggleNotes(_:)):
            title(notesItem.isCollapsed ? "Show Notes" : "Hide Notes")
            return notesOwner != nil || editor.isNew
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
         .flexibleSpace, .copyContents, .archive, .goToAnything, .inspectorTrackingSeparator, .flexibleSpace, .outline]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .inspectorTrackingSeparator, .flexibleSpace, .space,
         .newDraft, .sync, .copyContents, .archive, .goToAnything, .outline]
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
        case .copyContents: return item("Copy Contents", "doc.on.doc", #selector(copyContents(_:)))
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
