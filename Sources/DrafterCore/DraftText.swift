import Foundation

// What a draft's text says about it: what it is called, what it opens with,
// and what file it would be filed under. These are ports of the rules in
// ~/src/cmd/drafts, so the app and the command agree on every draft.

public enum DraftText {
    /// A draft's title: a frontmatter `title:`, else the first H1, else the
    /// first line with anything on it, else the file's own name.
    public static func title(of text: String, fileName: String = "") -> String {
        let split = splitFrontmatter(text)
        if let title = frontmatterTitle(split.raw), !title.isEmpty {
            return oneLine(title)
        }
        if let heading = firstHeading(split.body) {
            return oneLine(heading)
        }
        for line in split.body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return oneLine(stripHeadingMarks(trimmed)) }
        }
        if fileName.isEmpty { return "" }
        return (fileName as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    /// What the draft says after its title, flattened to a line or two of
    /// prose for the list.
    public static func snippet(of text: String, maxLength: Int = 240) -> String {
        let body = splitFrontmatter(text).body
        var lines: [Substring] = []
        var skippedTitle = false
        var fenced = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || line.isEmpty { continue }
            if !skippedTitle {
                skippedTitle = true
                continue
            }
            lines.append(Substring(stripInline(stripHeadingMarks(line))))
            if lines.reduce(0, { $0 + $1.count }) > maxLength { break }
        }
        let joined = lines.joined(separator: " ")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) + "…" : joined
    }

    // MARK: Frontmatter

    public struct Frontmatter {
        public var raw: String
        public var body: String
    }

    public static func splitFrontmatter(_ source: String) -> Frontmatter {
        guard let open = source.range(of: #"^---[ \t]*\r?\n"#, options: .regularExpression) else {
            return Frontmatter(raw: "", body: source)
        }
        let rest = source[open.upperBound...]
        guard let close = rest.range(of: #"(?:^|\r?\n)---[ \t]*(?:\r?\n|$)"#, options: .regularExpression) else {
            return Frontmatter(raw: "", body: source)
        }
        return Frontmatter(raw: String(rest[..<close.lowerBound]), body: String(rest[close.upperBound...]))
    }

    /// The `title:` key of frontmatter. This is a tolerant, flat reading
    /// rather than a YAML parser: title is the one key a draft is read for.
    static func frontmatterTitle(_ raw: String) -> String? {
        for line in raw.split(separator: "\n") {
            guard line.hasPrefix("title:") else { continue }
            var value = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Headings

    private static let atxTitle = try! NSRegularExpression(pattern: #"^ {0,3}#(?:[ \t]+(.*?))?[ \t]*$"#)

    /// The first non-empty H1 outside any code fence.
    static func firstHeading(_ body: String) -> String? {
        var fence: String?
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { fence = "```"; continue }
            if trimmed.hasPrefix("~~~") { fence = "~~~"; continue }
            let candidate = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let ns = candidate as NSString
            guard let match = atxTitle.firstMatch(in: candidate, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let group = match.range(at: 1)
            guard group.location != NSNotFound else { continue }
            var text = ns.substring(with: group).trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func stripHeadingMarks(_ line: String) -> String {
        guard line.hasPrefix("#") else { return line }
        return String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
    }

    /// A title as a reader sees it in a list: links flattened to their text.
    static func oneLine(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result = replace(#"\[\[([^\[\]\n|]*)\|([^\[\]\n]*)\]\]"#, in: result, with: "$2")
        result = replace(#"\[\[([^\[\]\n]*)\]\]"#, in: result, with: "$1")
        result = replace(#"\[([^\[\]\n]*)\]\([^)\n]*\)"#, in: result, with: "$1")
        return result
    }

    /// Inline markup dropped for a plain-text preview.
    static func stripInline(_ line: String) -> String {
        var result = oneLine(line)
        result = replace(#"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, in: result, with: "")
        result = replace(#"^>\s?"#, in: result, with: "")
        result = replace(#"(\*\*|__|\*|_|`)"#, in: result, with: "")
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    // MARK: Filenames

    static let maxSlugCharacters = 60
    static let windowsReserved: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ]

    /// A draft's filename, as a projection of its title: lowercase, letters
    /// and numbers kept, separator runs collapsed to one dash.
    public static func slug(for title: String) -> String {
        var slug = title.lowercased()
        slug = replace(#"[^\p{L}\p{N}\s_-]+"#, in: slug, with: "")
        slug = replace(#"[\s_-]+"#, in: slug, with: "-")
        slug = replace(#"^-+|-+$"#, in: slug, with: "")
        if slug.count > maxSlugCharacters {
            slug = replace(#"^-+|-+$"#, in: String(slug.prefix(maxSlugCharacters)), with: "")
        }
        if slug.isEmpty { return "untitled" }
        if windowsReserved.contains(slug) { return slug + "-draft" }
        return slug
    }
}
