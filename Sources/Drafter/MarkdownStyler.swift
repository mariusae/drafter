import AppKit

/// Light Markdown styling for a proportional editor: the text stays the text,
/// but a heading reads as one, markup recedes, and code looks like code.
///
/// Only attributes are touched, never characters, so what is on screen is
/// byte-for-byte what is written to disk.
///
/// The colors are reflect-mac's: the system's semantic ones and nothing of
/// our own, so light and dark are each what the Mac says they are. Text is
/// text color; what is quoted, struck or done is secondary; markup recedes
/// to tertiary; links are link color and tags the accent; code is set in
/// the label color on a quaternary wash.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    var fontSize: CGFloat {
        didSet { rebuildFonts() }
    }

    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var bodyFont = NSFont.systemFont(ofSize: 17)
    private var codeFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private var headingFonts: [NSFont] = []

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init()
        rebuildFonts()
    }

    private func rebuildFonts() {
        bodyFont = NSFont.systemFont(ofSize: fontSize)
        codeFont = NSFont.monospacedSystemFont(ofSize: round(fontSize * 0.9), weight: .regular)
        headingFonts = [
            NSFont.systemFont(ofSize: round(fontSize * 1.6), weight: .bold),
            NSFont.systemFont(ofSize: round(fontSize * 1.3), weight: .bold),
            NSFont.systemFont(ofSize: round(fontSize * 1.12), weight: .semibold),
            NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.paragraphSpacing = round(fontSize * 0.15)
        baseAttributes = [
            .font: bodyFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
            .kern: 0.1,
        ]
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        let text = storage.string as NSString
        // A draft is short, and restyling all of it is the only way a fence
        // opened or closed by an edit is always right. A long one restyles
        // only the paragraphs that were touched.
        let range = text.length < 30_000
            ? NSRange(location: 0, length: text.length)
            : text.paragraphRange(for: edited)
        style(storage, in: range)
    }

    func styleAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: Styling

    /// Inline code's wash. A system color given an alpha is fixed to the
    /// appearance of the moment it was asked for; text styled once must
    /// follow light and dark as they change, so it is resolved as drawn.
    static let codeWash = NSColor(name: "DrafterCodeWash") { appearance in
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).usingColorSpace(.sRGB) ?? .clear
        }
        return color
    }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})([ \t]+|$)"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![*_\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_\w])"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\[\]\n]*)\](\([^)\n]*\))"#)
    private static let url = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
    private static let wikiLink = try! NSRegularExpression(pattern: #"(\[\[)([^\[\]\n]+)(\]\])"#)
    private static let strikethrough = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private static let tag = try! NSRegularExpression(pattern: #"(?<![\w#&/])#[\p{L}\p{N}_][\p{L}\p{N}_/-]*"#)

    private func style(_ storage: NSTextStorage, in range: NSRange) {
        guard range.length > 0 else { return }
        let text = storage.string as NSString
        var inFence = fenceOpen(before: range.location, in: text)
        storage.setAttributes(baseAttributes, range: range)

        text.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosing, _ in
            let line = text.substring(with: lineRange)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if isFence || inFence {
                // Code reads at full strength on its wash; its fences, there
                // only to be edited, recede.
                storage.addAttributes([
                    .font: self.codeFont,
                    .foregroundColor: isFence ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                    .drafterCodeBlock: true,
                ], range: enclosing)
                if isFence { inFence.toggle() }
                return
            }
            self.styleLine(storage, line: line, range: lineRange)
        }
    }

    private func styleLine(_ storage: NSTextStorage, line: String, range: NSRange) {
        let local = NSRange(location: 0, length: (line as NSString).length)
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + range.location, length: r.length) }
        let markup = NSColor.tertiaryLabelColor

        if let match = Self.heading.firstMatch(in: line, range: local) {
            let level = match.range(at: 1).length
            let font = headingFonts[min(level, headingFonts.count) - 1]
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.foregroundColor, value: markup, range: shifted(match.range(at: 1)))
        } else if line.hasPrefix(">") {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        } else if let match = Self.listMarker.firstMatch(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: shifted(match.range(at: 1)))
            let box = match.range(at: 2)
            if box.location != NSNotFound, (line as NSString).substring(with: box).lowercased().contains("x") {
                // A task done: struck through, and let go of.
                let rest = NSRange(location: NSMaxRange(match.range), length: local.length - NSMaxRange(match.range))
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor,
                ], range: shifted(rest))
            }
        }

        let baseFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
        for match in Self.strong.matches(in: line, range: local) {
            storage.addAttribute(.font, value: baseFont.adding(.bold), range: shifted(match.range))
            dim(storage, markers: match.range(at: 1).length, around: shifted(match.range), color: markup)
        }
        for match in Self.emphasis.matches(in: line, range: local) {
            let current = storage.attribute(.font, at: shifted(match.range).location, effectiveRange: nil) as? NSFont ?? baseFont
            storage.addAttribute(.font, value: current.adding(.italic), range: shifted(match.range))
            dim(storage, markers: 1, around: shifted(match.range), color: markup)
        }
        for match in Self.strikethrough.matches(in: line, range: local) {
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor.tertiaryLabelColor,
            ], range: shifted(match.range(at: 2)))
            dim(storage, markers: 2, around: shifted(match.range), color: markup)
        }
        for match in Self.tag.matches(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: shifted(match.range))
        }
        for match in Self.url.matches(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: shifted(match.range))
        }
        for match in Self.wikiLink.matches(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: markup, range: shifted(match.range(at: 1)))
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: shifted(match.range(at: 2)))
            storage.addAttribute(.foregroundColor, value: markup, range: shifted(match.range(at: 3)))
        }
        for match in Self.link.matches(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: shifted(match.range(at: 1)))
            storage.addAttribute(.foregroundColor, value: markup, range: shifted(match.range(at: 2)))
        }
        // Last: code is code, whatever inside it looked like something else.
        for match in Self.codeSpan.matches(in: line, range: local) {
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: Self.codeWash,
            ], range: shifted(match.range))
        }
    }

    private func dim(_ storage: NSTextStorage, markers: Int, around range: NSRange, color: NSColor) {
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location, length: markers))
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: NSMaxRange(range) - markers, length: markers))
    }

    /// Whether a code fence is open at a location, by counting the fences
    /// before it.
    private func fenceOpen(before location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return false }
        var open = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: location), options: .byLines) { line, _, _, _ in
            let trimmed = line?.drop(while: { $0 == " " || $0 == "\t" }) ?? ""
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { open.toggle() }
        }
        return open
    }
}

private extension NSFont {
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

extension NSAttributedString.Key {
    /// The lines of a fenced code block, fences and all: drawn on a wash.
    static let drafterCodeBlock = NSAttributedString.Key("DrafterCodeBlock")
}
