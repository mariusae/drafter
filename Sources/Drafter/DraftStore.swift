import AppKit
import DrafterCore

extension Notification.Name {
    static let draftsDidChange = Notification.Name("DrafterDraftsDidChange")
    static let syncStatusDidChange = Notification.Name("DrafterSyncStatusDidChange")
    static let timelineDidChange = Notification.Name("DrafterTimelineDidChange")
}

enum SyncStatus: Equatable {
    case idle(last: Date?)
    case syncing
    case failed(String)
    case unversioned
}

/// The drafts, as the app knows them, and the one place that writes to disk
/// and asks git to keep what was written.
///
/// Writes happen at once and on the main thread, because a disk is fast and a
/// draft that is not on disk is not kept. Git never happens here: every save
/// is committed and pushed on the repository's own queue, and the directory is
/// brought into step with its remote on a timer of its own.
@MainActor
final class DraftStore {
    private(set) var directory: DraftsDirectory
    private(set) var git: Git?
    private(set) var drafts: [Draft] = []
    private(set) var status: SyncStatus = .unversioned {
        didSet { NotificationCenter.default.post(name: .syncStatusDidChange, object: self) }
    }

    /// Asked before anything reads the directory for git, so what is typed
    /// but not yet saved is part of what is committed.
    var flushPendingEdits: (() -> Void)?

    private var watcher: DirectoryWatcher?
    private var syncTimer: Timer?
    private var pushing = false
    private var pushAgain = false
    private var reloadGeneration = 0

    /// The timeline is read only while something is showing it: it walks
    /// history, which is more than a hidden view deserves on every save.
    private(set) var timeline: [TimelineChange] = []
    private(set) var timelineLoaded = false
    var wantsTimeline = false {
        didSet { if wantsTimeline && !oldValue { reloadTimeline() } }
    }
    private var timelineReader: TimelineReader?
    private let timelineQueue = DispatchQueue(label: "drafter.timeline", qos: .userInitiated)
    private var timelineTimer: Timer?

    static let syncInterval: TimeInterval = 5 * 60

    init(root: URL) {
        directory = DraftsDirectory(root: root)
        open(root)
    }

    func open(_ root: URL) {
        directory = DraftsDirectory(root: root)
        git = Git.open(root)
        status = git == nil ? .unversioned : .idle(last: nil)
        drafts = []
        timeline = []
        timelineLoaded = false
        timelineReader = TimelineReader(directory: directory, git: git)
        watcher = DirectoryWatcher(url: root) { [weak self] in self?.reload() }
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        reload()
        sync()
    }

    func drafts(in folder: Folder) -> [Draft] { drafts.filter { $0.folder == folder } }

    func draft(at url: URL) -> Draft? {
        let url = url.standardizedFileURL
        return drafts.first { $0.url == url }
    }

    // MARK: Reading

    /// Re-reads the directory off the main thread. Times come from history
    /// where there is some, so a checkout does not make everything new.
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = directory, git = git
        Task.detached(priority: .userInitiated) {
            let (times, dirty) = await git?.recordedTimes() ?? ([:], [])
            let drafts = directory.list(recorded: times, dirty: dirty)
            await MainActor.run {
                guard generation == self.reloadGeneration, directory.root == self.directory.root else { return }
                self.drafts = drafts
                NotificationCenter.default.post(name: .draftsDidChange, object: self)
                self.reloadTimeline()
            }
        }
    }

    /// Re-reads the timeline in the background, a moment after the last
    /// change asked for it: saves come in runs.
    func reloadTimeline() {
        guard wantsTimeline, let reader = timelineReader else { return }
        timelineTimer?.invalidate()
        timelineTimer = Timer.scheduledTimer(withTimeInterval: timelineLoaded ? 0.6 : 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timelineQueue.async {
                    let changes = reader.read()
                    DispatchQueue.main.async {
                        guard let self, reader === self.timelineReader else { return }
                        self.timelineLoaded = true
                        if changes != self.timeline {
                            self.timeline = changes
                        }
                        NotificationCenter.default.post(name: .timelineDidChange, object: self)
                    }
                }
            }
        }
    }

    // MARK: Writing

    /// Writes a draft to disk, then commits and pushes it in the background.
    func save(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        updateInPlace(url: url, text: text)
        commitAndPush()
    }

    /// Files a new draft under the name its text gives it.
    func create(text: String) throws -> URL {
        let url = try directory.create(text: text)
        updateInPlace(url: url, text: text)
        commitAndPush()
        return url
    }

    func archive(_ url: URL) throws -> URL { try moved { try directory.archive(url) } }
    func unarchive(_ url: URL) throws -> URL { try moved { try directory.unarchive(url) } }
    func rename(_ url: URL) throws -> URL { try moved { try directory.rename(url) } }

    /// Creates the notes file beside a draft if it is not there yet.
    func notes(for draft: Draft) throws -> URL {
        let notes = draft.notesURL
        if !FileManager.default.fileExists(atPath: notes.path) {
            let heading = draft.title.replacingOccurrences(of: "\n", with: " ")
            try Data("# Notes on \(heading)\n\n".utf8).write(to: notes, options: .withoutOverwriting)
            commitAndPush()
        }
        return notes
    }

    private func moved(_ move: () throws -> URL) throws -> URL {
        flushPendingEdits?()
        let url = try move()
        reload()
        commitAndPush()
        return url
    }

    /// Keeps the list current the moment a save lands, rather than waiting
    /// for the watcher to notice.
    private func updateInPlace(url: URL, text: String) {
        let url = url.standardizedFileURL
        guard let folder = directory.folder(of: url) else { return }
        let file = url.lastPathComponent
        let draft = Draft(
            url: url, folder: folder,
            title: DraftText.title(of: text, fileName: file),
            snippet: DraftText.snippet(of: text), text: text, modified: Date(),
            name: folder == .inbox ? file : "\(DraftsDirectory.archiveSubdir)/\(file)")
        drafts.removeAll { $0.url == url }
        if !DraftsDirectory.isNotesName(file) || !drafts.contains(where: { $0.notesURL == url }) {
            drafts.insert(draft, at: 0)
        }
        NotificationCenter.default.post(name: .draftsDidChange, object: self)
    }

    // MARK: Git

    /// Commit and push, coalesced: saves that land while a push is in flight
    /// are carried by one more push after it.
    private func commitAndPush() {
        guard let git else { return }
        if pushing {
            pushAgain = true
            return
        }
        pushing = true
        Task {
            do {
                try await git.commitAndPush()
                if case .failed = status { status = .idle(last: Date()) }
                reloadTimeline()
            } catch {
                status = .failed(error.localizedDescription)
            }
            pushing = false
            if pushAgain {
                pushAgain = false
                commitAndPush()
            }
        }
    }

    /// Brings the directory and its remote into step.
    func sync() {
        guard let git else {
            status = .unversioned
            return
        }
        if status == .syncing { return }
        flushPendingEdits?()
        status = .syncing
        Task {
            do {
                let report = try await git.sync()
                status = .idle(last: Date())
                if report.pulled { reload() }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

/// Calls back when anything under a directory changes, other than git's own
/// bookkeeping.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard paths.prefix(count).contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) else { return }
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
