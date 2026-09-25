import Foundation

/// Markdown block structure, read line by line: enough of CommonMark to say
/// which block a line belongs to, and where a draft's headings are.
///
/// The rules for what a line's block *is* are Reflect's, as `drafts` ports
/// them, because they are the rules that make a quotation read as something
/// someone wrote:
///
///   - a paragraph is the whole paragraph, however it wraps;
///   - a heading carries its section, up to the next heading of any level;
///   - the title heading is only its own line, or it would quote the draft;
///   - a top-level list item keeps everything nested under it;
///   - a nested list item is its parent's own line plus its own branch;
///   - a table, a quote, or a fenced code block is taken whole.
public struct MarkdownDocument {
    public let source: String
    /// The source split on "\n"; line numbers here are 0-based indexes.
    public let lines: [String]
    let bodyStart: Int
    let frontmatterTitled: Bool
    let blocks: [Block]

    public init(_ source: String) {
        self.source = source
        lines = source.components(separatedBy: "\n")
        let split = DraftText.splitFrontmatter(source)
        frontmatterTitled = !(DraftText.frontmatterTitle(split.raw) ?? "").isEmpty
        bodyStart = source.count == split.body.count ? 0 : lines.count - split.body.components(separatedBy: "\n").count
        blocks = Parser(lines: lines, start: bodyStart).parse()
    }

    // MARK: Blocks

    final class Block {
        enum Kind { case heading(Int), paragraph, code, quote, table, listItem, rule }
        let kind: Kind
        let first: Int
        var last: Int
        /// A list item's marker column, and the column its content starts at.
        var indent = 0
        var contentIndent = 0
        /// A list item's own lines: up to its first nested item or blank line.
        var leadLast = 0
        var children: [Block] = []
        weak var parent: Block?

        init(_ kind: Kind, _ first: Int, _ last: Int) {
            self.kind = kind
            self.first = first
            self.last = last
        }

        var headingLevel: Int? {
            if case .heading(let level) = kind { return level }
            return nil
        }
    }

    /// A block's lines as the context for a line inside it: 0-based, inclusive.
    public struct Context: Equatable {
        public var text: String
        public var first: Int
        public var last: Int
    }

    /// The block around a line, by the rules above. Nil between blocks.
    public func context(at line: Int) -> Context? {
        guard line >= bodyStart, line < lines.count else { return nil }
        guard let index = blocks.firstIndex(where: { $0.first <= line && line <= $0.last }) else {
            let bare = lines[line].trimmingCharacters(in: .whitespaces)
            return bare.isEmpty ? nil : Context(text: bare, first: line, last: line)
        }
        let block = blocks[index]
        switch block.kind {
        case .heading(let level):
            if level == 1 && isTitleHeading(block) { return slice(block.first, block.last) }
            var end = block.last
            for next in blocks[(index + 1)...] {
                if next.headingLevel != nil { break }
                end = next.last
            }
            return slice(block.first, end)
        case .listItem:
            var item = block
            while let child = item.children.first(where: { $0.first <= line && line <= $0.last }) {
                item = child
            }
            guard let parent = item.parent else { return slice(item.first, item.last) }
            let lead = lines[parent.first...parent.leadLast].joined(separator: "\n")
            let branch = lines[item.first...item.last].joined(separator: "\n")
            return Context(text: lead + "\n" + branch, first: parent.first, last: item.last)
        default:
            return slice(block.first, block.last)
        }
    }

    private func slice(_ first: Int, _ last: Int) -> Context {
        var last = last
        while last > first, lines[last].trimmingCharacters(in: .whitespaces).isEmpty { last -= 1 }
        return Context(text: lines[first...last].joined(separator: "\n"), first: first, last: last)
    }

    /// The first non-empty top-level H1 is the title, unless frontmatter
    /// names one.
    private func isTitleHeading(_ heading: Block) -> Bool {
        guard !frontmatterTitled else { return false }
        return blocks.first(where: { $0.headingLevel == 1 && !headingText($0).isEmpty }) === heading
    }

    // MARK: Headings

    public struct Heading: Equatable, Sendable {
        public var level: Int
        public var title: String
        /// 0-based line of the heading's text.
        public var line: Int
        /// The heading's line(s) in the source, in UTF-16 units, for NSString.
        public var range: NSRange
    }

    /// Every heading in the draft, in order, fenced code aside.
    public var headings: [Heading] {
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        return blocks.compactMap { block in
            guard let level = block.headingLevel else { return nil }
            let end = starts[block.last] + lines[block.last].utf16.count
            return Heading(level: level, title: headingText(block), line: block.first,
                           range: NSRange(location: starts[block.first], length: end - starts[block.first]))
        }
    }

    private func headingText(_ block: Block) -> String {
        var text = lines[block.first].trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text = String(text.drop(while: { $0 == "#" }))
            text = text.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
        }
        return DraftText.stripInline(text.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Parsing

private struct Parser {
    typealias Block = MarkdownDocument.Block
    let lines: [String]
    let start: Int

    func parse() -> [Block] {
        var blocks: [Block] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            if let fence = fenceOpening(line) {
                var j = i + 1
                while j < lines.count, !closesFence(lines[j], fence) { j += 1 }
                let last = min(j, lines.count - 1)
                blocks.append(Block(.code, i, last))
                i = last + 1
            } else if let level = atxLevel(line) {
                blocks.append(Block(.heading(level), i, i))
                i += 1
            } else if isRule(line) {
                blocks.append(Block(.rule, i, i))
                i += 1
            } else if isQuote(line) {
                var j = i
                while j + 1 < lines.count, !isBlank(lines[j + 1]) { j += 1 }
                blocks.append(Block(.quote, i, j))
                i = j + 1
            } else if listMarker(line) != nil, indent(of: line) < 4 {
                let (items, next) = parseList(from: i)
                blocks.append(contentsOf: items)
                i = next
            } else if line.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                var j = i + 1
                while j + 1 < lines.count, !isBlank(lines[j + 1]), lines[j + 1].contains("|") { j += 1 }
                blocks.append(Block(.table, i, j))
                i = j + 1
            } else {
                var j = i
                var setext: Int?
                while j + 1 < lines.count {
                    let next = lines[j + 1]
                    if let level = setextLevel(next) {
                        setext = level
                        j += 1
                        break
                    }
                    if isBlank(next) || interruptsParagraph(next) { break }
                    j += 1
                }
                blocks.append(Block(setext.map { .heading($0) } ?? .paragraph, i, j))
                i = j + 1
            }
        }
        return blocks
    }

    /// A run of list items and their continuation lines. Items nest by where
    /// their markers stand relative to the content of the item above.
    private func parseList(from begin: Int) -> ([Block], Int) {
        var top: [Block] = []
        var open: [Block] = []
        var j = begin
        while j < lines.count {
            let line = lines[j]
            if isBlank(line) {
                // A blank line continues the list only when what follows is
                // an item, or is indented under one.
                guard let next = lines[(j + 1)...].firstIndex(where: { !isBlank($0) }) else { break }
                let following = lines[next]
                if listMarker(following) != nil || indent(of: following) >= (open.first?.contentIndent ?? 2) {
                    j = next
                    continue
                }
                break
            }
            if let marker = listMarker(line) {
                let column = indent(of: line)
                while let last = open.last, column < last.contentIndent { open.removeLast() }
                let item = Block(.listItem, j, j)
                item.indent = column
                item.contentIndent = column + marker
                item.leadLast = j
                if let parent = open.last {
                    item.parent = parent
                    parent.children.append(item)
                } else {
                    top.append(item)
                }
                open.append(item)
            } else if open.isEmpty || (indent(of: line) < 2 && (atxLevel(line) != nil || fenceOpening(line) != nil)) {
                break
            } else if let current = open.last, current.leadLast == j - 1, current.children.isEmpty {
                current.leadLast = j  // the item's own text, wrapped
            }
            for item in open { item.last = j }
            j += 1
        }
        return (top, j)
    }

    // MARK: Line kinds

    private func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private func indent(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 - width % 4 } else { break }
        }
        return width
    }

    private func trimmed(_ line: String) -> Substring {
        line.drop(while: { $0 == " " || $0 == "\t" })
    }

    private func atxLevel(_ line: String) -> Int? {
        guard indent(of: line) < 4 else { return nil }
        let text = trimmed(line)
        let hashes = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = text.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "\r" else { return nil }
        return hashes
    }

    private func setextLevel(_ line: String) -> Int? {
        guard indent(of: line) < 4 else { return nil }
        let text = trimmed(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0 == "=" }) { return 1 }
        if text.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private func isRule(_ line: String) -> Bool {
        guard indent(of: line) < 4 else { return false }
        let text = line.filter { $0 != " " && $0 != "\t" && $0 != "\r" }
        guard text.count >= 3, let first = text.first, "-*_".contains(first) else { return false }
        return text.allSatisfy { $0 == first }
    }

    private func isQuote(_ line: String) -> Bool {
        indent(of: line) < 4 && trimmed(line).hasPrefix(">")
    }

    /// The width of a list marker and the space after it, or nil.
    private func listMarker(_ line: String) -> Int? {
        let text = trimmed(line)
        if let first = text.first, "-*+".contains(first) {
            let rest = text.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            if isRule(line) { return nil }
            return 1 + min(max(rest.prefix(while: { $0 == " " }).count, 1), 4)
        }
        let digits = text.prefix(while: \.isNumber)
        guard (1...9).contains(digits.count) else { return nil }
        let rest = text.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return digits.count + 1 + min(max(after.prefix(while: { $0 == " " }).count, 1), 4)
    }

    private func fenceOpening(_ line: String) -> String? {
        guard indent(of: line) < 4 else { return nil }
        let text = trimmed(line)
        for mark in ["`", "~"] {
            let run = text.prefix(while: { String($0) == mark }).count
            if run >= 3 { return String(repeating: mark, count: run) }
        }
        return nil
    }

    private func closesFence(_ line: String, _ fence: String) -> Bool {
        let text = trimmed(line).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(fence) && text.allSatisfy { $0 == fence.first }
    }

    private func isTableDelimiter(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("-") && text.allSatisfy { "|-: \t".contains($0) }
    }

    private func interruptsParagraph(_ line: String) -> Bool {
        atxLevel(line) != nil || fenceOpening(line) != nil || isQuote(line) || isRule(line)
            || (listMarker(line) != nil && indent(of: line) < 4)
    }
}
