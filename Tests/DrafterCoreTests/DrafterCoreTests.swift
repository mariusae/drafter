import XCTest
@testable import DrafterCore

final class DraftTextTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(DraftText.title(of: "---\ntitle: \"Front\"\n---\n# Heading\n"), "Front")
        XCTAssertEqual(DraftText.title(of: "intro\n\n# Heading\n"), "Heading")
        XCTAssertEqual(DraftText.title(of: "```\n# not\n```\nfirst line\n"), "```")
        XCTAssertEqual(DraftText.title(of: "\n\n  just words  \n"), "just words")
        XCTAssertEqual(DraftText.title(of: "# [Link](http://x) and [[a|b]]"), "Link and b")
        XCTAssertEqual(DraftText.title(of: "", fileName: "foo.md"), "foo")
        XCTAssertEqual(DraftText.title(of: "# Closed ##"), "Closed")
    }

    func testSlug() {
        XCTAssertEqual(DraftText.slug(for: "Why We Should Start with APIs!"), "why-we-should-start-with-apis")
        XCTAssertEqual(DraftText.slug(for: "  --  "), "untitled")
        XCTAssertEqual(DraftText.slug(for: "CON"), "con-draft")
        XCTAssertEqual(DraftText.slug(for: "日本語 の title"), "日本語-の-title")
    }

    func testSnippet() {
        XCTAssertEqual(DraftText.snippet(of: "# Title\n\nSome **bold** text.\n\n- item\n"), "Some bold text. item")
    }

    func testFuzzy() {
        let title = "Why We Should Start with APIs"
        XCTAssertNotNil(Fuzzy.match("wwsa", in: title))
        XCTAssertNil(Fuzzy.match("zz", in: title))
        let exact = Fuzzy.match("api", in: "APIs")!.score
        let scattered = Fuzzy.match("api", in: "a pretty idea")!.score
        XCTAssertGreaterThan(exact, scattered)
    }
}

final class DraftsDirectoryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateArchiveAndNotes() throws {
        let dir = DraftsDirectory(root: root)
        let first = try dir.create(text: "# Meeting\n\nhello")
        XCTAssertEqual(first.lastPathComponent, "meeting.md")
        let second = try dir.create(text: "# Meeting")
        XCTAssertEqual(second.lastPathComponent, "meeting-2.md")
        // "Meeting Notes" steps aside from Meeting's notes.
        let notesTitled = try dir.create(text: "# Meeting Notes")
        XCTAssertEqual(notesTitled.lastPathComponent, "meeting-notes-2.md")

        try Data("notes".utf8).write(to: DraftsDirectory.notes(for: first))
        XCTAssertEqual(dir.list().filter { $0.folder == .inbox }.count, 3)

        let archived = try dir.archive(first)
        XCTAssertEqual(archived.path, dir.archiveRoot.appendingPathComponent("meeting.md").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.archiveRoot.appendingPathComponent("meeting-notes.md").path))
        XCTAssertEqual(dir.list().filter { $0.folder == .archive }.map(\.title), ["Meeting"])

        let back = try dir.unarchive(archived)
        XCTAssertEqual(back.lastPathComponent, "meeting.md")
    }

    func testRename() throws {
        let dir = DraftsDirectory(root: root)
        let url = try dir.create(text: "# Old")
        try Data("# New Title\n".utf8).write(to: url)
        XCTAssertEqual(try dir.rename(url).lastPathComponent, "new-title.md")
    }
}

final class GitTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func sh(_ command: String, in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Two clones of one remote: what one writes, the other syncs down, and a
    /// conflicting merge is undone rather than left behind.
    func testCommitPushAndSync() async throws {
        try sh("git init -q --bare -b main remote.git", in: base)
        let identity = "git config user.email t@example.com && git config user.name T"
        try sh("git clone -q remote.git a && cd a && \(identity) && git commit -q --allow-empty -m init && git push -q -u origin main", in: base)
        try sh("git clone -q remote.git b && cd b && \(identity)", in: base)
        let a = base.appendingPathComponent("a"), b = base.appendingPathComponent("b")
        let gitA = try XCTUnwrap(Git.open(a)), gitB = try XCTUnwrap(Git.open(b))

        try Data("# One\n".utf8).write(to: a.appendingPathComponent("one.md"))
        try await gitA.commitAndPush()
        let report = try await gitB.sync()
        XCTAssertTrue(report.pulled)
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("one.md"), encoding: .utf8), "# One\n")

        let (times, dirty) = await gitB.recordedTimes()
        XCTAssertNotNil(times["one.md"])
        XCTAssertTrue(dirty.isEmpty)

        try Data("# One from A\n".utf8).write(to: a.appendingPathComponent("one.md"))
        try await gitA.commitAndPush()
        try Data("# One from B\n".utf8).write(to: b.appendingPathComponent("one.md"))
        do {
            _ = try await gitB.sync()
            XCTFail("expected a conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("conflicts"))
        }
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("one.md"), encoding: .utf8), "# One from B\n")
        XCTAssertEqual(try sh("git status --porcelain", in: b), "")
    }
}

final class DraftLinkTests: XCTestCase {
    func testLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = DraftsDirectory(root: root)
        let url = try dir.create(text: "# Café au lait")
        let link = DraftLink.url(for: url)
        XCTAssertEqual(link.absoluteString, "drafter://draft/caf%C3%A9-au-lait")
        XCTAssertEqual(DraftLink.resolve(link, in: dir), url)

        // Archived, the same link still finds it.
        let archived = try dir.archive(url)
        XCTAssertEqual(DraftLink.resolve(link, in: dir), archived)

        XCTAssertNil(DraftLink.resolve(URL(string: "drafter://draft/nothing")!, in: dir))
        XCTAssertNil(DraftLink.resolve(URL(string: "drafter://draft/..%2Fetc")!, in: dir))
        XCTAssertNil(DraftLink.resolve(URL(string: "https://draft/caf%C3%A9-au-lait")!, in: dir))
    }
}
