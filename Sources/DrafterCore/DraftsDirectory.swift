import Foundation

public enum Folder: Int, Sendable, CaseIterable {
    case inbox, archive

    public var name: String { self == .inbox ? "Inbox" : "Archive" }
}

/// One Markdown file in the directory, as read.
public struct Draft: Identifiable, Hashable, Sendable {
    public var url: URL
    public var folder: Folder
    public var title: String
    public var snippet: String
    public var text: String
    public var modified: Date
    /// Named relative to the drafts directory: `foo.md`, `archive/foo.md`.
    public var name: String

    public init(url: URL, folder: Folder, title: String, snippet: String, text: String, modified: Date, name: String) {
        self.url = url
        self.folder = folder
        self.title = title
        self.snippet = snippet
        self.text = text
        self.modified = modified
        self.name = name
    }

    public var id: URL { url }
    public var notesURL: URL { DraftsDirectory.notes(for: url) }
}

/// A flat directory of Markdown drafts, and `archive/` beneath it.
///
/// There is no index and no database: a draft is a file, its title is the
/// first thing in it that reads like one, and its age is its last change in
/// history, or the file's own time when it is unrecorded.
public struct DraftsDirectory: Sendable {
    public static let archiveSubdir = "archive"
    public static let notesSuffix = "-notes.md"
    static let readme = "README.md"

    public let root: URL
    public var archiveRoot: URL { root.appendingPathComponent(Self.archiveSubdir, isDirectory: true) }

    public init(root: URL) { self.root = root }

    /// Where drafts live when nothing says otherwise: $DRAFTS_DIR, else ~/drafts.
    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["DRAFTS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("drafts", isDirectory: true)
    }

    public func folderRoot(_ folder: Folder) -> URL { folder == .inbox ? root : archiveRoot }

    public func folder(of url: URL) -> Folder? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if parent == root.standardizedFileURL.path { return .inbox }
        if parent == archiveRoot.standardizedFileURL.path { return .archive }
        return nil
    }

    // MARK: Reading

    /// Every draft of both folders. Times come from `recorded` where a file is
    /// clean and has history, and from the filesystem otherwise.
    public func list(recorded: [String: Date] = [:], dirty: Set<String> = []) -> [Draft] {
        Folder.allCases.flatMap { read(folder: $0, recorded: recorded, dirty: dirty) }
    }

    func read(folder: Folder, recorded: [String: Date], dirty: Set<String>) -> [Draft] {
        let dir = folderRoot(folder)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let markdown = urls.filter { $0.pathExtension == "md" && $0.lastPathComponent != Self.readme }
        let present = Set(markdown.map { $0.lastPathComponent })
        var drafts: [Draft] = []
        for url in markdown {
            let file = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // A companion belongs to its draft and is not listed beside it —
            // but only where that draft is there. Orphaned notes are the only
            // copy of what is written in them, and are not hidden.
            if Self.isNotesName(file), present.contains(Self.draftName(ofNotes: file)) { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let name = folder == .inbox ? file : "\(Self.archiveSubdir)/\(file)"
            var modified = values.contentModificationDate ?? .distantPast
            if !dirty.contains(name), let when = recorded[name] { modified = when }
            drafts.append(Draft(
                url: url.standardizedFileURL, folder: folder,
                title: DraftText.title(of: text, fileName: file),
                snippet: DraftText.snippet(of: text), text: text,
                modified: modified, name: name))
        }
        return drafts.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name < $1.name }
    }

    // MARK: Notes

    public static func isNotesName(_ name: String) -> Bool {
        name.count > notesSuffix.count && name.hasSuffix(notesSuffix)
    }

    static func draftName(ofNotes name: String) -> String {
        String(name.dropLast(notesSuffix.count)) + ".md"
    }

    public static func notes(for url: URL) -> URL {
        let name = url.lastPathComponent
        if isNotesName(name) { return url }
        return url.deletingLastPathComponent()
            .appendingPathComponent(String(name.dropLast(3)) + notesSuffix)
    }

    static func draft(ofNotes url: URL) -> URL {
        let name = url.lastPathComponent
        guard isNotesName(name) else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(draftName(ofNotes: name))
    }

    // MARK: Writing

    /// Files a draft begun before it was named: what is written in it names
    /// the file. A name already taken takes a numeric suffix, and the name is
    /// held the moment it is chosen.
    public func create(text: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let slug = DraftText.slug(for: DraftText.title(of: text))
        for attempt in 1... {
            let name = attempt == 1 ? slug : "\(slug)-\(attempt)"
            let url = root.appendingPathComponent(name + ".md")
            // "Meeting Notes" is where the notes of "Meeting" live, when
            // "Meeting" exists.
            if Self.isNotesName(name + ".md"), exists(Self.draft(ofNotes: url)) { continue }
            if try hold(url) {
                try Data(text.utf8).write(to: url)
                return url.standardizedFileURL
            }
        }
        fatalError("unreachable")
    }

    /// Puts a draft away in `archive/`, taking its notes with it. The filename
    /// goes along unchanged.
    public func archive(_ url: URL) throws -> URL {
        guard folder(of: url) == .inbox else { return url }
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        return try move(url, into: archiveRoot, slug: String(url.lastPathComponent.dropLast(3)))
    }

    /// Brings an archived draft back to the inbox.
    public func unarchive(_ url: URL) throws -> URL {
        guard folder(of: url) == .archive else { return url }
        return try move(url, into: root, slug: String(url.lastPathComponent.dropLast(3)))
    }

    /// Files a draft under the title it now carries, in whatever folder it is.
    public func rename(_ url: URL) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8)
        let slug = DraftText.slug(for: DraftText.title(of: text))
        if url.lastPathComponent == slug + ".md" { return url }
        return try move(url, into: url.deletingLastPathComponent(), slug: slug)
    }

    /// Files a draft as `<into>/<slug>.md`, taking its notes along. Nothing is
    /// overwritten, and the two files never come apart.
    func move(_ url: URL, into: URL, slug: String) throws -> URL {
        let fm = FileManager.default
        let notes = Self.notes(for: url)
        let carried = notes != url && exists(notes)
        for attempt in 1... {
            let name = attempt == 1 ? slug : "\(slug)-\(attempt)"
            let target = into.appendingPathComponent(name + ".md")
            if target.standardizedFileURL == url.standardizedFileURL { return url }
            let owner = Self.draft(ofNotes: target)
            if Self.isNotesName(name + ".md"), exists(owner), owner.standardizedFileURL != url.standardizedFileURL { continue }
            guard try hold(target) else { continue }
            if carried, exists(Self.notes(for: target)) {
                try? fm.removeItem(at: target)
                continue
            }
            // rename(2) replaces the held placeholder with the draft itself.
            if Darwin.rename(url.path, target.path) != 0 {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? fm.removeItem(at: target)
                throw error
            }
            if carried {
                do {
                    try fm.moveItem(at: notes, to: Self.notes(for: target))
                } catch {
                    try? fm.moveItem(at: target, to: url)
                    throw error
                }
            }
            return target.standardizedFileURL
        }
        fatalError("unreachable")
    }

    /// Creates an empty file exclusively, reporting false when the name is taken.
    private func hold(_ url: URL) throws -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Darwin.close(fd)
        return true
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
