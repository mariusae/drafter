import XCTest
@testable import DrafterCore

final class MarkdownDocumentTests: XCTestCase {
    let draft = """
    # Title

    A paragraph
    that wraps.

    ## Section

    Under the section.

    - top
      - nested one
      - nested two
    - another

    | a | b |
    |---|---|
    | 1 | 2 |
    """

    func context(_ line: Int) -> String? { MarkdownDocument(draft).context(at: line)?.text }

    func testContexts() {
        XCTAssertEqual(context(0), "# Title")  // the title is only its line
        XCTAssertEqual(context(3), "A paragraph\nthat wraps.")
        XCTAssertEqual(context(5), "## Section\n\nUnder the section.\n\n- top\n  - nested one\n  - nested two\n- another\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(context(9), "- top\n  - nested one\n  - nested two")
        XCTAssertEqual(context(11), "- top\n  - nested two")  // parent's line, and its own branch
        XCTAssertEqual(context(12), "- another")
        XCTAssertEqual(context(15), "| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertNil(context(1))
    }

    func testHeadings() {
        let text = "---\ntitle: T\n---\n# One\n\n```\n# not\n```\n\nTwo\n===\n\n### Three **bold** ##\n"
        let headings = MarkdownDocument(text).headings
        XCTAssertEqual(headings.map(\.title), ["One", "Two", "Three bold"])
        XCTAssertEqual(headings.map(\.level), [1, 1, 3])
        XCTAssertEqual((text as NSString).substring(with: headings[1].range), "Two\n===")
        // With a frontmatter title, an H1 is an ordinary section.
        XCTAssertEqual(MarkdownDocument(text).context(at: 3)?.text.hasPrefix("# One\n\n```"), true)
    }
}

final class TimelineTests: XCTestCase {
    var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("git init -q -b main && git config user.email t@example.com && git config user.name T")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func sh(_ command: String, env: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = repo
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }

    func commit(_ name: String, _ text: String, at seconds: Int) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(name))
        let date = "@\(seconds) +0000"
        try sh("git add -A && git commit -q -m x", env: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
    }

    func testBurstsAndBlocks() throws {
        let base = 1_700_000_000
        let first = "# Airport\n\nThe first paragraph.\n\nThe second paragraph.\n\nThe third paragraph.\n"
        try commit("airport.md", first, at: base)
        // A day later: two saves a minute apart to one paragraph are one burst.
        let day = base + 86_400
        try commit("airport.md", first.replacingOccurrences(of: "third paragraph", with: "third paragraph, edited"), at: day)
        try commit("airport.md", first.replacingOccurrences(of: "third paragraph", with: "third paragraph, edited twice"), at: day + 60)
        try commit("other.md", "# Other\n\nhello\n", at: day + 120)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("archive"), withIntermediateDirectories: true)
        try commit("archive/old.md", "# Old\n", at: day + 180)

        let reader = TimelineReader(directory: DraftsDirectory(root: repo), git: Git.open(repo))
        let changes = reader.read()
        XCTAssertEqual(changes.map(\.name), ["other.md", "airport.md", "airport.md"])

        let burst = changes[1]
        XCTAssertEqual(burst.blocks.map(\.text), ["The third paragraph, edited twice."])
        XCTAssertEqual(burst.blocks.first?.line, 7)
        XCTAssertEqual(burst.since, Date(timeIntervalSince1970: TimeInterval(day)))
        XCTAssertEqual(burst.when, Date(timeIntervalSince1970: TimeInterval(day + 60)))

        // The first commit shows the draft whole, its neighbouring blocks joined.
        XCTAssertEqual(changes[2].blocks.map(\.text), [first.trimmingCharacters(in: .whitespacesAndNewlines)])

        // Written but not committed comes first.
        try Data("# Other\n\nhello, again\n".utf8).write(to: repo.appendingPathComponent("other.md"))
        let fresh = reader.read()
        XCTAssertEqual(fresh.first?.uncommitted, true)
        XCTAssertEqual(fresh.first?.blocks.map(\.text), ["hello, again"])
    }
}
