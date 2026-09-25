import Foundation

/// The timeline: recent modifications, newest first, shown as the blocks that
/// moved — a port of `drafts -t`.
///
/// Where the directory is a repository the answer comes out of its history,
/// which, since every save is committed, is the record of the writing itself.
/// Changed lines are carried up to the Markdown blocks they sit in; blocks
/// that overlap or stand one blank line apart are joined; and saves to nearby
/// blocks of one draft within five minutes are one entry, showing the text as
/// it stood after that burst rather than a stack of its intermediate versions.
public struct TimelineChange: Sendable, Identifiable, Equatable {
    public struct Block: Sendable, Equatable {
        public var text: String
        /// 1-based, inclusive lines of `source`.
        public var line: Int
        public var endLine: Int
    }

    /// Relative to the drafts directory.
    public var name: String
    public var title: String
    /// The newest edit of the burst, and the oldest.
    public var when: Date
    public var since: Date
    public var blocks: [Block]
    /// The draft as it stood after the burst.
    public var source: String
    /// Written but not yet committed.
    public var uncommitted = false

    public var id: String { "\(name)@\(since.timeIntervalSince1970)" }
}

public enum TimelineRules {
    /// Bounds one change's blocks, so a wholesale rewrite does not bury the
    /// changes around it.
    public static let blockLimit = 20
    static let timeGap: TimeInterval = 5 * 60
    static let blockGap = 1
    static let blockSpan = 20
}

/// Reads the timeline, remembering the answer while the directory stands
/// still. Not thread-safe: use it from one queue.
public final class TimelineReader: @unchecked Sendable {
    public let directory: DraftsDirectory
    let git: Git?
    private var cacheKey = ""
    private var cached: [TimelineChange] = []

    /// How far back history is read: every save is a commit, so this is
    /// counted in saves, not in sittings.
    public var historyScan = 1500

    public init(directory: DraftsDirectory, git: Git?) {
        self.directory = directory
        self.git = git
    }

    public func read(limit: Int = 100) -> [TimelineChange] {
        let key = self.key()
        if key == cacheKey, !cached.isEmpty { return cached }
        let changes: [TimelineChange]
        if let git {
            changes = recorded(git, written: written(git), limit: limit)
        } else {
            changes = recent(limit: limit)
        }
        cacheKey = key
        cached = changes
        return changes
    }

    /// What the timeline was read from: the revision, and the time of every
    /// draft on disk.
    private func key() -> String {
        var parts: [String] = []
        if let head = try? git?.run(["rev-parse", "HEAD"]) { parts.append(head) }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "md" {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            parts.append("\(file.lastPathComponent)@\(date?.timeIntervalSince1970 ?? 0)")
        }
        return parts.sorted().joined(separator: "\0")
    }

    /// Whether a file of the directory is one the timeline is about: a draft
    /// of the inbox. What is archived is put away, history and all.
    static func shows(_ name: String) -> Bool {
        !name.contains("/") && name.hasSuffix(".md") && name != DraftsDirectory.readme && !name.hasPrefix(".")
    }

    // MARK: Unversioned

    /// With no history, each draft stands for itself, by what it opens with.
    private func recent(limit: Int) -> [TimelineChange] {
        let drafts = directory.read(folder: .inbox, recorded: [:], dirty: [])
        return drafts.prefix(limit).compactMap { draft in
            let document = MarkdownDocument(draft.text)
            guard let opening = document.lines.indices.first(where: {
                $0 >= document.bodyStart && !document.lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }), let context = document.context(at: opening) else { return nil }
            return TimelineChange(
                name: draft.name, title: draft.title, when: draft.modified, since: draft.modified,
                blocks: [.init(text: context.text, line: context.first + 1, endLine: context.last + 1)],
                source: draft.text)
        }
    }

    // MARK: Versioned

    /// What is written but not yet committed is the newest of all; a draft
    /// never committed is shown whole.
    private func written(_ git: Git) -> [TimelineChange] {
        let (changed, added) = git.written()
        var changes: [TimelineChange] = []
        for (name, whole) in added.map({ ($0, true) }) + changed.map({ ($0, false) }) where Self.shows(name) {
            let url = directory.root.appendingPathComponent(name)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let diff = whole ? "" : (try? git.run(["diff", "--relative", "-U0", "HEAD", "--", name])) ?? ""
            if var change = Self.change(name: name, content: content, hunks: Self.hunkHeaders(diff), whole: whole, when: modified) {
                change.uncommitted = true
                changes.append(change)
            }
        }
        return changes.sorted { $0.when > $1.when }
    }

    /// Walks history newest first, folding nearby edits into the changes
    /// already found. Once enough are found, it reads through the coalescing
    /// window of the last one before stopping.
    private func recorded(_ git: Git, written: [TimelineChange], limit: Int) -> [TimelineChange] {
        let revisions = (try? git.history(scan: historyScan)) ?? []
        var changes = written.map { change -> TimelineChange in
            var change = change
            change.blocks = Self.coalesce(change.source, change.blocks)
            return change
        }

        // Contents are read in batches, as the walk reaches them.
        var index = 0
        var cutoff = Self.cutoff(changes, limit: limit)
        while index < revisions.count {
            if let cutoff, revisions[index].when < cutoff { break }
            let batch = Array(revisions[index..<min(index + 50, revisions.count)])
            let wanted = batch.flatMap { revision in
                revision.files.filter { Self.shows($0.name) }.map { (revision.id, $0.path) }
            }
            let contents = git.contents(wanted)
            var next = 0
            for revision in batch {
                if let cutoff, revision.when < cutoff { break }
                for file in revision.files where Self.shows(file.name) {
                    defer { next += 1 }
                    guard let content = contents[next],
                          let change = Self.change(name: file.name, content: content, hunks: file.hunks,
                                                   whole: false, when: revision.when) else { continue }
                    changes = Self.add(change, to: changes)
                }
                cutoff = Self.cutoff(changes, limit: limit)
            }
            index += batch.count
        }
        return Array(changes.prefix(limit))
    }

    // MARK: The algorithm

    static let hunkHeader = try! NSRegularExpression(pattern: #"^@@ -[0-9,]+ \+(\d+)(?:,(\d+))? @@"#)

    static func hunkHeaders(_ diff: String) -> [String] {
        diff.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }
    }

    /// The 0-based lines a diff's hunks added. A hunk that only deletes
    /// anchors at the line it left behind, so a removal shows its block.
    static func changedLines(hunks: [String], lineCount: Int) -> [Int] {
        var lines: [Int] = []
        var seen = Set<Int>()
        for hunk in hunks {
            let ns = hunk as NSString
            guard let match = hunkHeader.firstMatch(in: hunk, range: NSRange(location: 0, length: ns.length)),
                  let first = Int(ns.substring(with: match.range(at: 1))) else { continue }
            var count = 1
            if match.range(at: 2).location != NSNotFound {
                count = Int(ns.substring(with: match.range(at: 2))) ?? 1
            }
            if count == 0 { count = 1 }
            for number in first..<(first + count) {
                let index = number - 1
                if index >= 0, index < lineCount, seen.insert(index).inserted { lines.append(index) }
            }
        }
        return lines
    }

    /// A change from a file's content and the hunks that produced it: every
    /// block holding a changed line, deduplicated and joined.
    static func change(name: String, content: String, hunks: [String], whole: Bool, when: Date) -> TimelineChange? {
        let document = MarkdownDocument(content)
        let lines = whole ? Array(document.lines.indices) : changedLines(hunks: hunks, lineCount: document.lines.count)
        var seen = Set<String>()
        var blocks: [TimelineChange.Block] = []
        for line in lines {
            guard let context = document.context(at: line),
                  !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(context.text).inserted else { continue }
            blocks.append(.init(text: context.text, line: context.first + 1, endLine: context.last + 1))
        }
        blocks = coalesce(content, blocks)
        guard !blocks.isEmpty else { return nil }
        return TimelineChange(
            name: name, title: DraftText.title(of: content, fileName: name), when: when, since: when,
            blocks: Array(blocks.prefix(TimelineRules.blockLimit)), source: content)
    }

    /// Merges an older change into a newer burst when both its time and its
    /// place in the draft are near. The newer source wins.
    static func add(_ older: TimelineChange, to changes: [TimelineChange]) -> [TimelineChange] {
        var changes = changes
        var older = older
        older.blocks = coalesce(older.source, older.blocks)
        for index in changes.indices.reversed() {
            var newer = changes[index]
            guard newer.name == older.name, newer.since.timeIntervalSince(older.when) <= TimelineRules.timeGap else { continue }
            let aligned = align(newer.source, older.blocks)
            guard nearby(newer.blocks, aligned) else { continue }
            newer.blocks = Array(coalesce(newer.source, newer.blocks + aligned).prefix(TimelineRules.blockLimit))
            if older.since < newer.since { newer.since = older.since }
            changes[index] = newer
            return changes
        }
        changes.append(older)
        return changes
    }

    static func cutoff(_ changes: [TimelineChange], limit: Int) -> Date? {
        guard limit > 0, changes.count >= limit else { return nil }
        return changes.prefix(limit).map { $0.since.addingTimeInterval(-TimelineRules.timeGap) }.min()
    }

    static func nearby(_ left: [TimelineChange.Block], _ right: [TimelineChange.Block]) -> Bool {
        left.contains { one in right.contains { other in coalesces(one.line, one.endLine, other.line, other.endLine) } }
    }

    static func coalesces(_ left: Int, _ leftEnd: Int, _ right: Int, _ rightEnd: Int) -> Bool {
        var (left, leftEnd, right, rightEnd) = (left, leftEnd, right, rightEnd)
        if left > right { swap(&left, &right); swap(&leftEnd, &rightEnd) }
        if right <= leftEnd { return true }
        return right - leftEnd - 1 <= TimelineRules.blockGap && max(leftEnd, rightEnd) - left + 1 <= TimelineRules.blockSpan
    }

    /// Relocates an older block whose text still occurs in the newer source,
    /// accounting for lines inserted above it in the same burst. A block
    /// whose text changed keeps its old place, which the newer text overlaps.
    static func align(_ source: String, _ blocks: [TimelineChange.Block]) -> [TimelineChange.Block] {
        blocks.map { block in
            guard let found = source.range(of: block.text) else { return block }
            var moved = block
            moved.line = source[..<found.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            moved.endLine = moved.line + block.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            return moved
        }
    }

    /// Unions overlapping blocks and blocks one blank line apart, re-slicing
    /// the union from the source so it begins and ends on whole blocks.
    static func coalesce(_ source: String, _ blocks: [TimelineChange.Block]) -> [TimelineChange.Block] {
        guard blocks.count >= 2 else { return blocks }
        let sorted = blocks.sorted { $0.line != $1.line ? $0.line < $1.line : $0.endLine > $1.endLine }
        var ranges: [(first: Int, last: Int)] = []
        for block in sorted {
            if let current = ranges.last, coalesces(current.first, current.last, block.line, block.endLine) {
                ranges[ranges.count - 1].last = max(current.last, block.endLine)
            } else {
                ranges.append((block.line, block.endLine))
            }
        }
        let lines = source.components(separatedBy: "\n")
        return ranges.compactMap { span in
            let first = max(span.first, 1), last = min(span.last, lines.count)
            guard last >= first else { return nil }
            let text = lines[(first - 1)...(last - 1)].joined(separator: "\n")
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .init(text: text, line: first, endLine: last)
        }
    }
}
