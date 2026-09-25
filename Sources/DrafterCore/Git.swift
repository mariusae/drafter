import Foundation

/// What a sync did, for whoever asked. Empty when nothing moved.
public struct SyncReport: Sendable, CustomStringConvertible {
    public var parts: [String] = []
    public var pulled = false
    public var quiet: Bool { parts.isEmpty }
    public var description: String { parts.joined(separator: ", ") }
}

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

/// The drafts directory under git.
///
/// Every operation takes its turn on one serial queue, so a commit never runs
/// into a merge, and none of them ever runs on the main thread: writing is the
/// only thing asked of the writer, and a remote having a bad day costs nothing
/// at the keyboard.
public final class Git: @unchecked Sendable {
    public let root: URL
    private let queue = DispatchQueue(label: "drafter.git", qos: .utility)

    /// The repository the directory sits in, or nil when it sits in none.
    public static func open(_ root: URL) -> Git? {
        let git = Git(root: root)
        guard (try? git.run(["rev-parse", "--show-toplevel"])) != nil else { return nil }
        return git
    }

    init(root: URL) { self.root = root }

    // MARK: Operations

    /// Records everything written in the directory. Returns how many files
    /// that was; nothing written is no commit and no error.
    @discardableResult
    public func commit() async throws -> Int {
        try await turn { try self.commitNow() }
    }

    /// Commits and pushes: what happens after every save.
    public func commitAndPush() async throws {
        try await turn {
            let committed = try self.commitNow()
            if committed > 0 || (try? self.divergence())?.ahead ?? 0 > 0 {
                try self.pushNow()
            }
        }
    }

    /// Commit what is written here, fetch, take what was written elsewhere,
    /// push the result. A merge that conflicts is undone rather than left
    /// behind, and reported.
    public func sync() async throws -> SyncReport {
        try await turn { try self.syncNow() }
    }

    /// The last recorded change of each file, by name relative to the
    /// directory, and the names written since the last commit. A checkout
    /// writes many files at once, so a clean file's age is its history's.
    public func recordedTimes() async -> (times: [String: Date], dirty: Set<String>) {
        (try? await turn {
            var times: [String: Date] = [:]
            let log = try self.run(["log", "--relative", "--format=%x1e%ct", "--name-only", "--", "."])
            for record in log.split(separator: "\u{1e}") {
                let lines = record.split(separator: "\n")
                guard let first = lines.first, let seconds = TimeInterval(first) else { continue }
                let when = Date(timeIntervalSince1970: seconds)
                for name in lines.dropFirst() where times[String(name)] == nil {
                    times[String(name)] = when
                }
            }
            var dirty = Set<String>()
            let status = try self.run(["status", "--porcelain", "-z", "--untracked-files=all", "--", "."])
            // Porcelain names paths from the repository root; relative names
            // are what the rest of the program speaks.
            let prefix = (try? self.run(["rev-parse", "--show-prefix"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for entry in status.split(separator: "\0") where entry.count > 3 {
                var path = String(entry.dropFirst(3))
                if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
                dirty.insert(path)
            }
            return (times, dirty)
        }) ?? ([:], [])
    }

    // MARK: Reading history
    //
    // These only read, and run on the caller's thread rather than taking a
    // turn on the queue: a timeline walking history should not hold up a
    // commit, and git's reads are safe beside its writes.

    /// One recorded change: when, and the drafts it touched.
    public struct Revision: Sendable {
        public var id: String
        public var when: Date
        public var files: [RevisionFile]
    }

    /// `path` is the file at that revision; `name` follows later renames to
    /// what the draft is called now. `hunks` are the diff's hunk headers.
    public struct RevisionFile: Sendable {
        public var path: String
        public var name: String
        public var hunks: [String]
    }

    /// Files changed since the last commit, and files never committed.
    public func written() -> (changed: [String], added: [String]) {
        let tracked = (try? run(["diff", "--relative", "-z", "--name-only", "--diff-filter=AM", "HEAD", "--", "."])) ?? ""
        let others = (try? run(["ls-files", "-z", "--others", "--exclude-standard", "--", "."])) ?? ""
        let split = { (text: String) in text.split(separator: "\0").map(String.init) }
        return (split(tracked), split(others))
    }

    /// The most recent revisions, newest first, with their hunk headers:
    /// one `git log -p` rather than a process per revision.
    public func history(scan: Int) throws -> [Revision] {
        let log = try run(["log", "--relative", "--find-renames", "--diff-filter=AMR", "-n", String(scan),
                           "-p", "-U0", "--no-color", "--no-ext-diff", "--format=%x1e%H %ct", "--", "."],
                          timeout: 120)
        return Git.parseHistory(log)
    }

    static func parseHistory(_ log: String) -> [Revision] {
        var revisions: [Revision] = []
        // Read newest first, aliases carry a historical path through every
        // later rename to the name the draft has now.
        var aliases: [String: String] = [:]
        for record in log.split(separator: "\u{1e}") {
            var lines = record.split(separator: "\n", omittingEmptySubsequences: false)[...]
            guard let header = lines.popFirst() else { continue }
            let fields = header.split(separator: " ")
            guard fields.count == 2, let seconds = TimeInterval(fields[1]) else { continue }
            var revision = Revision(id: String(fields[0]), when: Date(timeIntervalSince1970: seconds), files: [])

            var path: String?, from: String?, hunks: [String] = []
            var inHunks = false
            func finish() {
                guard let current = path else { return }
                let name = aliases[current] ?? current
                if let from { aliases[from] = name }
                revision.files.append(RevisionFile(path: current, name: name, hunks: hunks))
            }
            for line in lines {
                if line.hasPrefix("diff --git ") {
                    finish()
                    path = nil; from = nil; hunks = []; inHunks = false
                    // A rename with no edit has no +++ line to name it by.
                    continue
                }
                if line.hasPrefix("@@") {
                    inHunks = true
                    hunks.append(String(line))
                    continue
                }
                if inHunks { continue }
                if line.hasPrefix("+++ ") { path = Git.diffPath(line.dropFirst(4), side: "b/") }
                else if line.hasPrefix("rename from ") { from = Git.unquote(line.dropFirst("rename from ".count)) }
                else if line.hasPrefix("rename to ") { path = Git.unquote(line.dropFirst("rename to ".count)) }
            }
            finish()
            if !revision.files.isEmpty { revisions.append(revision) }
        }
        return revisions
    }

    private static func diffPath(_ text: Substring, side: String) -> String? {
        let path = unquote(text)
        guard path != "/dev/null", path.hasPrefix(side) else { return nil }
        return String(path.dropFirst(side.count))
    }

    private static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        return String(text.dropFirst().dropLast())
    }

    /// Files as they stood at revisions, through one `git cat-file --batch`.
    /// A file that cannot be read is nil.
    public func contents(_ requests: [(revision: String, path: String)]) -> [String?] {
        guard !requests.isEmpty else { return [] }
        let prefix = (try? run(["rev-parse", "--show-prefix"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let input = requests.map { "\($0.revision):\(prefix)\($0.path)\n" }.joined()
        guard let output = try? runData(["cat-file", "--batch"], input: Data(input.utf8), timeout: 120) else {
            return requests.map { _ in nil }
        }
        var results: [String?] = []
        var index = output.startIndex
        for _ in requests {
            guard let newline = output[index...].firstIndex(of: 0x0a) else { results.append(nil); continue }
            let header = String(decoding: output[index..<newline], as: UTF8.self).split(separator: " ")
            index = output.index(after: newline)
            guard header.count == 3, header[1] != "missing", let size = Int(header[2]) else {
                results.append(nil)
                continue
            }
            let end = output.index(index, offsetBy: size)
            results.append(String(decoding: output[index..<end], as: UTF8.self))
            index = output.index(after: end)  // the newline after the object
        }
        return results
    }

    // MARK: On the queue

    private func turn<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func commitNow() throws -> Int {
        // `-- .` holds the add to the drafts directory: a directory nested in
        // a larger repository must not sweep up the rest of it.
        try run(["add", "-A", "--", "."])
        let staged = try run(["diff", "--cached", "--relative", "-z", "--name-only", "--", "."])
        let changed = staged.split(separator: "\0").map(String.init)
        if changed.isEmpty { return 0 }
        let message: String
        switch changed.count {
        case 1: message = "Update \(changed[0])"
        default: message = "Update \(changed.count) drafts"
        }
        try run(["commit", "--quiet", "--only", "-m", message, "--", "."])
        return changed.count
    }

    private func upstream() -> String? {
        (try? run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pushNow() throws {
        guard let upstream = upstream() else { return }  // nowhere to send it
        do {
            try run(["push", "--quiet"], timeout: 60)
        } catch {
            throw GitError(message: "Pushing to \(upstream) failed: \(error.localizedDescription)")
        }
    }

    private func divergence() throws -> (behind: Int, ahead: Int) {
        let counts = try run(["rev-list", "--left-right", "--count", "@{u}...HEAD"])
        let fields = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 2 else { throw GitError(message: "git rev-list said \(counts)") }
        return (fields[0], fields[1])
    }

    private func syncNow() throws -> SyncReport {
        var report = SyncReport()
        let committed = try commitNow()
        if committed > 0 { report.parts.append("\(committed) \(committed == 1 ? "draft" : "drafts") committed") }
        guard let upstream = upstream() else { return report }  // the commit was the whole job
        do {
            try run(["fetch", "--quiet"], timeout: 60)
        } catch {
            throw GitError(message: "Fetching \(upstream) failed: \(error.localizedDescription)")
        }
        var (behind, ahead) = try divergence()
        if behind > 0 {
            do {
                try run(["merge", "--no-edit", "@{u}"])
            } catch {
                _ = try? run(["merge", "--abort"])
                throw GitError(message: "Merging \(upstream) conflicts; resolve it by hand.")
            }
            report.pulled = true
            report.parts.append("\(behind) \(behind == 1 ? "commit" : "commits") pulled")
            ahead = try divergence().ahead
        }
        if ahead > 0 {
            try pushNow()
            report.parts.append("\(ahead) \(ahead == 1 ? "commit" : "commits") pushed")
        }
        return report
    }

    // MARK: Running git

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // An app launched from the Finder has launchd's PATH, which knows
        // nothing of Homebrew — where credential helpers and git-lfs live.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [path]).joined(separator: ":")
        // Nobody is at a terminal to answer a prompt; fail instead of hanging.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }()

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        String(decoding: try runData(arguments, timeout: timeout), as: UTF8.self)
    }

    func runData(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 30) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = Git.environment
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes as they fill, so a chatty command cannot block on
        // a full pipe while we wait for it to exit.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            output = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errors = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let deadline = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        group.wait()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = process.terminationReason == .uncaughtSignal ? "timed out" : detail
            throw GitError(message: "git \(arguments.joined(separator: " ")): \(reason)")
        }
        return output
    }
}
