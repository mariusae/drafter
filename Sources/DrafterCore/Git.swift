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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = Git.environment
        process.standardInput = FileHandle.nullDevice
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
        return String(decoding: output, as: UTF8.self)
    }
}
