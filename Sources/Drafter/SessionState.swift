import AppKit

/// Where the writer was: in every draft, the cursor and the scroll; in the
/// window, which draft, which list, which timeline entry, and which pane had
/// the keyboard. Kept in Application Support, so that quitting and coming
/// back is coming back to exactly where you were.
@MainActor
final class SessionState {
    static let shared = SessionState()

    struct Position: Codable, Equatable {
        var selection: Int
        var selectionLength: Int
        /// The scroll offset, good while the page is laid out as it was:
        /// the same column width and type size.
        var scrollY: Double
        var width: Double
        var fontSize: Double
        /// The first character on screen, for when it is not.
        var topCharacter: Int
        var used: Date
    }

    enum Focus: String, Codable { case list, editor, outline }

    private struct Stored: Codable {
        var positions: [String: Position] = [:]
        var openDraft: String?
        var listMode: Int?
        var timelineEntry: String?
        var focus: Focus?
    }

    private var stored = Stored()
    private var saveTimer: Timer?
    private let url: URL

    /// Positions of drafts not opened in a long while are let go, oldest
    /// first, past this many.
    static let keep = 1000

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafter", isDirectory: true)
        url = ProcessInfo.processInfo.environment["DRAFTER_STATE_FILE"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("State.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode(Stored.self, from: data) {
            stored = decoded
        }
        // Before there was a state file, the open draft was a default.
        let legacy = "LastDraftPath"
        if let path = UserDefaults.standard.string(forKey: legacy) {
            if stored.openDraft == nil { stored.openDraft = URL(fileURLWithPath: path).standardizedFileURL.path }
            UserDefaults.standard.removeObject(forKey: legacy)
        }
    }

    // MARK: Drafts

    func position(for draft: URL) -> Position? { stored.positions[Self.key(draft)] }

    func setPosition(_ position: Position, for draft: URL) {
        guard stored.positions[Self.key(draft)] != position else { return }
        stored.positions[Self.key(draft)] = position
        scheduleSave()
    }

    /// A draft that moved takes its place with it, and its notes theirs.
    func move(from old: URL, to new: URL) {
        guard old.standardizedFileURL != new.standardizedFileURL else { return }
        for (from, to) in [(old, new), (old.notesCompanion, new.notesCompanion)] {
            if let position = stored.positions.removeValue(forKey: Self.key(from)) {
                stored.positions[Self.key(to)] = position
            }
        }
        if stored.openDraft == Self.key(old) { stored.openDraft = Self.key(new) }
        scheduleSave()
    }

    // MARK: The window

    var openDraft: URL? {
        get { stored.openDraft.map { URL(fileURLWithPath: $0) } }
        set { stored.openDraft = newValue.map(Self.key); scheduleSave() }
    }

    var listMode: ListMode {
        get { stored.listMode.flatMap(ListMode.init(rawValue:)) ?? .inbox }
        set { stored.listMode = newValue.rawValue; scheduleSave() }
    }

    var timelineEntry: String? {
        get { stored.timelineEntry }
        set { stored.timelineEntry = newValue; scheduleSave() }
    }

    var focus: Focus {
        get { stored.focus ?? .editor }
        set { stored.focus = newValue; scheduleSave() }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        if stored.positions.count > Self.keep {
            let oldest = stored.positions.sorted { $0.value.used < $1.value.used }
                .prefix(stored.positions.count - Self.keep).map(\.key)
            oldest.forEach { stored.positions.removeValue(forKey: $0) }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            NSLog("Drafter: could not save state: \(error)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}

private extension URL {
    var notesCompanion: URL {
        deletingLastPathComponent().appendingPathComponent(deletingPathExtension().lastPathComponent + "-notes.md")
    }
}
