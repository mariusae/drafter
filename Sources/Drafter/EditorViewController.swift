import AppKit
import DrafterCore

/// The text view: a centered column of proportional type, like a page.
final class DraftTextView: NSTextView {
    static let columnWidth: CGFloat = 700
    var onEscape: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(36, (newSize.width - Self.columnWidth) / 2)
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: 36)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// Edits one draft at a time, saving as the writer pauses.
///
/// A draft is saved a moment after typing stops, when another draft is
/// chosen, and when the app is left. A new draft is not a file until there is
/// something in it: its first save names it after what was written.
@MainActor
final class EditorViewController: NSViewController, NSTextViewDelegate {
    let store: DraftStore
    private(set) var url: URL?
    private(set) var isNew = false
    private var savedText = ""
    private var saveTimer: Timer?

    /// Told when the draft on screen becomes a file, or moves.
    var onFiled: ((URL) -> Void)?
    var onEscape: (() -> Void)?
    var onTitleChange: (() -> Void)?
    /// Told when the headings change, and when the section being written or
    /// read moves to another heading.
    var onHeadingsChange: (() -> Void)?
    var onCurrentHeadingChange: (() -> Void)?

    private(set) var headings: [MarkdownDocument.Heading] = []
    private(set) var currentHeading: Int?
    private var outlineTimer: Timer?
    private var positionTimer: Timer?
    /// Set while a draft is being put on screen, when the cursor and scroll
    /// move for reasons that are not the writer's.
    private var restoring = false

    private var scrollView: NSScrollView!
    private(set) var textView: DraftTextView!
    private var placeholder: NSTextField!
    private let styler: MarkdownStyler

    static let defaultFontSize: CGFloat = 17
    static let fontSizeKey = "EditorFontSize"

    var isDirty: Bool { textView.string != savedText }
    var isShowingDraft: Bool { url != nil || isNew }
    var currentTitle: String {
        let title = DraftText.title(of: textView.string, fileName: url?.lastPathComponent ?? "")
        return title.isEmpty ? "Untitled" : title
    }

    init(store: DraftStore) {
        self.store = store
        let size = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        styler = MarkdownStyler(fontSize: size > 0 ? size : Self.defaultFontSize)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = DraftTextView(usingTextLayoutManager: true)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        // Markdown is plain text: a curly quote or an em dash typed for you
        // is a character you did not write.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = styler.baseAttributes
        textView.textStorage?.delegate = styler
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.onEscape?() }
        textView.setAccessibilityLabel("Draft")
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        placeholder = NSTextField(labelWithString: "No Draft Selected")
        placeholder.font = .systemFont(ofSize: 20, weight: .regular)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        updatePlaceholder()

        NotificationCenter.default.addObserver(
            self, selector: #selector(draftsDidChange), name: .draftsDidChange, object: store)
    }

    // MARK: Showing

    /// Shows a draft, saving whatever was on screen first.
    /// Otherwise it opens where it was left: the same cursor, the same scroll.
    func show(_ url: URL?, selecting range: NSRange? = nil) {
        if url?.standardizedFileURL == self.url, url != nil {
            if let range { select(range) }
            return
        }
        saveNow()
        recordPosition()
        self.url = url?.standardizedFileURL
        isNew = false
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        load(text)
        if let range { select(range) } else { restorePosition() }
    }

    /// Begins a draft that is not yet a file.
    func beginNew() {
        saveNow()
        recordPosition()
        url = nil
        isNew = true
        load("")
        view.window?.makeFirstResponder(textView)
    }

    private func load(_ text: String) {
        restoring = true
        defer { restoring = false }
        savedText = text
        textView.string = text
        if let storage = textView.textStorage { styler.styleAll(storage) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
        updatePlaceholder()
        refreshHeadings()
        onTitleChange?()
    }

    private func select(_ range: NSRange) {
        let length = (textView.string as NSString).length
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location, length: min(range.length, length - range.location))
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        textView.showFindIndicator(for: clamped)
    }

    private func updatePlaceholder() {
        let showing = isShowingDraft
        scrollView.isHidden = !showing
        placeholder.isHidden = showing
    }

    func focus() {
        guard isShowingDraft else { return }
        view.window?.makeFirstResponder(textView)
    }

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        onTitleChange?()
        outlineTimer?.invalidate()
        outlineTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHeadings() }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCurrentHeading()
        schedulePositionRecord()
    }

    @objc private func didScroll() {
        updateCurrentHeading()
        schedulePositionRecord()
    }

    // MARK: Where the writer was

    private func schedulePositionRecord() {
        guard !restoring, url != nil else { return }
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPosition() }
        }
    }

    /// Notes the cursor and scroll of the draft on screen.
    func recordPosition() {
        positionTimer?.invalidate()
        positionTimer = nil
        guard !restoring, let url, textView != nil else { return }
        let selection = textView.selectedRange()
        let clip = scrollView.contentView.bounds
        SessionState.shared.setPosition(.init(
            selection: selection.location, selectionLength: selection.length,
            scrollY: clip.origin.y, width: clip.width, fontSize: styler.fontSize,
            topCharacter: topVisibleCharacter(), used: Date()), for: url)
    }

    /// Puts the cursor and scroll back where they were left. The scroll
    /// offset is trusted only while the page is laid out as it was then;
    /// otherwise the line that was at the top is brought back to the top.
    private func restorePosition() {
        guard let url, let position = SessionState.shared.position(for: url) else { return }
        restoring = true
        defer { restoring = false }
        let length = (textView.string as NSString).length
        let location = min(position.selection, length)
        textView.setSelectedRange(NSRange(location: location, length: min(position.selectionLength, length - location)))
        // Lay the whole draft out, so an offset far down means what it meant.
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        let clip = scrollView.contentView.bounds
        if abs(clip.width - position.width) < 1, position.fontSize == styler.fontSize {
            scroll(toY: position.scrollY)
        } else {
            scrollToTop(of: NSRange(location: min(position.topCharacter, length), length: 0), margin: 0)
        }
        updateCurrentHeading(force: true)
    }

    private func scroll(toY y: CGFloat) {
        let inset = scrollView.contentView.contentInsets.top
        let limit = max(-inset, textView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(-inset, y), limit)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls a range to the top of what can be read, below the toolbar.
    private func scrollToTop(of range: NSRange, margin: CGFloat) {
        guard let window = textView.window else { return }
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let local = textView.convert(window.convertFromScreen(screen), from: nil)
        scroll(toY: local.minY - margin - scrollView.contentView.contentInsets.top)
    }

    /// The first character that can be read. The page scrolls under the
    /// toolbar, so that is below the content inset, not at the top of the
    /// visible rect; and a point in the page's margin is in no line and is
    /// answered with the end of the text, so the point is kept in the text.
    private func topVisibleCharacter() -> Int {
        let visible = textView.visibleRect
        let inset = scrollView.contentView.contentInsets.top
        return textView.characterIndexForInsertion(
            at: NSPoint(x: visible.midX, y: max(visible.minY + inset, textView.textContainerInset.height) + 1))
    }

    // MARK: Outline

    private func refreshHeadings() {
        let fresh = isShowingDraft ? MarkdownDocument(textView.string).headings : []
        if fresh != headings {
            headings = fresh
            onHeadingsChange?()
        }
        currentHeading = nil
        updateCurrentHeading(force: true)
    }

    /// The section being worked in: where the cursor is when it is on screen,
    /// else where the reader has scrolled to.
    private func updateCurrentHeading(force: Bool = false) {
        guard !headings.isEmpty else {
            if currentHeading != nil || force {
                currentHeading = nil
                onCurrentHeadingChange?()
            }
            return
        }
        let visible = textView.visibleRect
        let top = topVisibleCharacter()
        let bottom = textView.characterIndexForInsertion(at: NSPoint(x: visible.midX, y: visible.maxY - 1))
        let cursor = textView.selectedRange().location
        let anchor = (top...max(top, bottom)).contains(cursor) ? cursor : top
        let index = headings.lastIndex { $0.range.location <= anchor }
        if index != currentHeading || force {
            currentHeading = index
            onCurrentHeadingChange?()
        }
    }

    /// Moves to a heading, bringing it to the top of the page.
    func goToHeading(_ index: Int) {
        guard headings.indices.contains(index) else { return }
        reveal(headings[index].range, atTop: true, flash: false)
    }

    @objc func nextHeading(_ sender: Any?) {
        let cursor = textView.selectedRange().location
        if let next = headings.firstIndex(where: { $0.range.location > cursor }) { goToHeading(next) }
    }

    @objc func previousHeading(_ sender: Any?) {
        let cursor = textView.selectedRange().location
        if let previous = headings.lastIndex(where: { $0.range.location < cursor }) { goToHeading(previous) }
    }

    /// Puts the cursor at the start of a range and shows it: at the top of
    /// the page when asked, and flashed so the eye finds it.
    func reveal(_ range: NSRange, atTop: Bool, flash: Bool) {
        let length = (textView.string as NSString).length
        guard range.location <= length else { return }
        let range = NSRange(location: range.location, length: min(range.length, length - range.location))
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        if atTop { scrollToTop(of: range, margin: 28) }
        if flash, range.length > 0 { textView.showFindIndicator(for: range) }
        view.window?.makeFirstResponder(textView)
        updateCurrentHeading(force: true)
    }

    /// The range of whole lines, 1-based and inclusive, clamped to the text.
    func rangeOfLines(_ first: Int, _ last: Int) -> NSRange {
        let text = textView.string as NSString
        var line = 1, start = 0, location = 0, end = text.length
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            if line == first { start = lineRange.location }
            if line == last {
                end = NSMaxRange(lineRange)
                break
            }
            line += 1
            location = NSMaxRange(lineRange)
        }
        if first > line { start = text.length }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Writes what is on screen, if it differs from what is on disk.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard textView != nil, isDirty else { return }
        let text = textView.string
        do {
            if let url {
                try store.save(text, to: url)
            } else if isNew {
                // Nothing typed yet is nothing to file.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let filed = try store.create(text: text)
                url = filed
                isNew = false
                onFiled?(filed)
            }
            savedText = text
        } catch {
            presentError(error)
        }
    }

    /// Follows the draft to where it moved.
    func moved(to url: URL) {
        self.url = url.standardizedFileURL
        onTitleChange?()
    }

    /// Takes up changes made on disk by someone else — a pull, another
    /// editor — unless there is writing here that has not been saved yet.
    @objc private func draftsDidChange() {
        guard let url, !isDirty else { return }
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else {
            // Gone from under us: a move elsewhere, or a delete.
            if !FileManager.default.fileExists(atPath: url.path) {
                self.url = nil
                load("")
            }
            return
        }
        guard disk != savedText else { return }
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        load(disk)
        select(NSRange(location: min(selection.location, (disk as NSString).length), length: 0))
        scrollView.contentView.scroll(to: visible)
    }

    // MARK: Type size

    @objc func makeTextBigger(_ sender: Any?) { setFontSize(styler.fontSize + 1) }
    @objc func makeTextSmaller(_ sender: Any?) { setFontSize(styler.fontSize - 1) }
    @objc func makeTextStandardSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ size: CGFloat) {
        let size = min(max(size, 11), 36)
        styler.fontSize = size
        UserDefaults.standard.set(size, forKey: Self.fontSizeKey)
        textView.typingAttributes = styler.baseAttributes
        if let storage = textView.textStorage { styler.styleAll(storage) }
    }
}
