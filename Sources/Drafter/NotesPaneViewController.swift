import AppKit

/// The notes beside a draft, as a pane under it: a slim header saying what
/// it is, with a button to put it away, over the notes themselves.
@MainActor
final class NotesPaneViewController: NSViewController {
    let editor: EditorViewController
    var onClose: (() -> Void)?

    init(editor: EditorViewController) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        let header = NSView()
        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "Notes")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Notes")!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Hide Notes (⌘J)"

        let separator = NSBox()
        separator.boxType = .separator

        for view in [icon, label, close, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let body = editor.view
        body.translatesAutoresizingMaskIntoConstraints = false
        addChild(editor)
        container.addSubview(header)
        container.addSubview(body)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    @objc private func closeClicked() { onClose?() }
}
