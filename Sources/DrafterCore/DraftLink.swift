import Foundation

/// Links to drafts: `drafter://draft/<name>`, the name being the draft's
/// filename without `.md`.
///
/// A link names a draft the way the directory does, by its file, so it says
/// nothing about where the draft is filed: it is looked for in the inbox and
/// then in the archive, and a draft put away is still found by the links
/// that point at it. The one thing that breaks a link is renaming the draft,
/// which is why nothing renames a draft unasked.
public enum DraftLink {
    public static let scheme = "drafter"
    static let host = "draft"

    public static func url(for draft: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        // Composed, as a name is typed and written elsewhere; the file system
        // hands names back decomposed, and finds them either way.
        components.path = "/" + draft.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        return components.url!
    }

    /// The draft a link names, if the directory has it.
    public static func resolve(_ link: URL, in directory: DraftsDirectory) -> URL? {
        guard link.scheme?.lowercased() == scheme, link.host?.lowercased() == host else { return nil }
        var name = link.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if name.hasPrefix(DraftsDirectory.archiveSubdir + "/") {
            name.removeFirst(DraftsDirectory.archiveSubdir.count + 1)
        }
        if name.hasSuffix(".md") { name.removeLast(3) }
        // One name, no way out of the directory.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        for folder in Folder.allCases {
            let candidate = directory.folderRoot(folder).appendingPathComponent(name + ".md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }
}
