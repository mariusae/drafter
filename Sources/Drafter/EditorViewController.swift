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
    func show(_ url: URL?, selecting range: NSRange? = nil) {
        if url?.standardizedFileURL == self.url, url != nil {
            if let range { select(range) }
            return
        }
        saveNow()
        self.url = url?.standardizedFileURL
        isNew = false
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        load(text)
        if let range { select(range) }
    }

    /// Begins a draft that is not yet a file.
    func beginNew() {
        saveNow()
        url = nil
        isNew = true
        load("")
        view.window?.makeFirstResponder(textView)
    }

    private func load(_ text: String) {
        savedText = text
        textView.string = text
        if let storage = textView.textStorage { styler.styleAll(storage) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
        updatePlaceholder()
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
