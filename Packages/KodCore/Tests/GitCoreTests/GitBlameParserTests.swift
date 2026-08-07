import Foundation
import XCTest
@testable import GitCore

final class GitBlameParserTests: XCTestCase {
    func testParsesBoundaryCommitAndSubsequentCommitWithPrevious() throws {
        let text = """
        fff059ecb5202467eb89d49b61ad5823289f4f53 1 1 1
        author Ada
        author-mail <ada@example.com>
        author-time 1704121200
        author-tz -0500
        committer Ada
        committer-mail <ada@example.com>
        committer-time 1704121200
        committer-tz -0500
        summary first commit
        boundary
        filename f.txt
        \tline1
        4751539870f6d4d531ab3137b67ba2bb37fa0cf4 2 2 1
        author Bob
        author-mail <bob@example.com>
        author-time 1706783400
        author-tz +0200
        committer Bob
        committer-mail <bob@example.com>
        committer-time 1706783400
        committer-tz +0200
        summary second commit
        previous fff059ecb5202467eb89d49b61ad5823289f4f53 f.txt
        filename f.txt
        \tline2 modified
        fff059ecb5202467eb89d49b61ad5823289f4f53 3 3 1
        \tline3
        0000000000000000000000000000000000000000 4 4 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1786063852
        author-tz -0600
        committer Not Committed Yet
        committer-mail <not.committed.yet>
        committer-time 1786063852
        committer-tz -0600
        summary Version of f.txt from f.txt
        previous 4751539870f6d4d531ab3137b67ba2bb37fa0cf4 f.txt
        filename f.txt
        \tline4 uncommitted

        """
        let result = try GitBlameParser.parse(text)
        XCTAssertEqual(result.lines.count, 4)

        let firstLine = result.lines[0]
        XCTAssertEqual(firstLine.commit.authorName, "Ada")
        XCTAssertEqual(firstLine.commit.authorEmail, "ada@example.com")
        XCTAssertEqual(firstLine.commit.authorTimeZone, "-0500")
        XCTAssertTrue(firstLine.commit.isBoundary)
        XCTAssertFalse(firstLine.commit.isUncommitted)
        XCTAssertEqual(firstLine.text, "line1")
        XCTAssertNil(firstLine.previousCommitID)

        let secondLine = result.lines[1]
        XCTAssertEqual(secondLine.commit.authorName, "Bob")
        XCTAssertEqual(secondLine.previousCommitID, "fff059ecb5202467eb89d49b61ad5823289f4f53")
        XCTAssertEqual(secondLine.previousFilename, "f.txt")

        // Third line reuses commit 1's full cached metadata even though
        // it is not adjacent to the first occurrence.
        let thirdLine = result.lines[2]
        XCTAssertEqual(thirdLine.commit, firstLine.commit)
        XCTAssertEqual(thirdLine.filename, "f.txt")
        XCTAssertEqual(thirdLine.text, "line3")

        let fourthLine = result.lines[3]
        XCTAssertTrue(fourthLine.commit.isUncommitted)
        XCTAssertEqual(fourthLine.commit.authorName, "Not Committed Yet")
        XCTAssertEqual(fourthLine.text, "line4 uncommitted")
        XCTAssertEqual(fourthLine.commit.authorTime, Date(timeIntervalSince1970: 1_786_063_852))

        XCTAssertEqual(result.commits.count, 3)
    }

    func testLineLookupByFinalLineNumber() throws {
        let text = """
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1
        author A
        author-mail <a@example.com>
        author-time 1704121200
        author-tz +0000
        committer A
        committer-mail <a@example.com>
        committer-time 1704121200
        committer-tz +0000
        summary s
        filename f.txt
        \tonly line

        """
        let result = try GitBlameParser.parse(text)
        let line = try XCTUnwrap(result.line(atFinalLineNumber: 1))
        XCTAssertEqual(line.text, "only line")
        XCTAssertNil(result.line(atFinalLineNumber: 2))
    }

    func testThrowsOnMissingContentLine() {
        let text = """
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1
        author A
        """
        XCTAssertThrowsError(try GitBlameParser.parse(text))
    }

    // MARK: End-to-end against a real fixture repository.

    func testEndToEndBlameAcrossCommitsAndUncommittedLine() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("f.txt", text: "line1\nline2\nline3\n")
        try fixture.addAll()
        let firstCommit = try fixture.commit(
            message: "first commit",
            authorName: "Ada Fixture",
            authorEmail: "ada@example.com",
            date: "2024-01-01T10:00:00 -0500"
        )

        try fixture.write("f.txt", text: "line1\nline2 modified\nline3\n")
        try fixture.addAll()
        try fixture.run(["commit", "-q", "-m", "second commit"], extraEnvironment: [
            "GIT_AUTHOR_NAME": "Bob Fixture",
            "GIT_AUTHOR_EMAIL": "bob@example.com",
            "GIT_AUTHOR_DATE": "2024-02-01T12:30:00 +0200",
            "GIT_COMMITTER_NAME": "Bob Fixture",
            "GIT_COMMITTER_EMAIL": "bob@example.com",
            "GIT_COMMITTER_DATE": "2024-02-01T12:30:00 +0200"
        ])

        try fixture.write("f.txt", text: "line1\nline2 modified\nline3\nline4 uncommitted\n")

        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        let service = GitBlameService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let result = try await service.blame(path: "f.txt")

        XCTAssertEqual(result.lines.count, 4)
        XCTAssertEqual(result.lines[0].commit.commitID, firstCommit)
        XCTAssertEqual(result.lines[0].commit.authorName, "Ada Fixture")
        XCTAssertTrue(result.lines[0].commit.isBoundary)
        XCTAssertEqual(result.lines[1].commit.authorName, "Bob Fixture")
        XCTAssertEqual(result.lines[1].commit.authorTimeZone, "+0200")
        XCTAssertEqual(result.lines[2].commit.commitID, firstCommit)
        XCTAssertTrue(result.lines[3].commit.isUncommitted)
        XCTAssertEqual(result.lines[3].text, "line4 uncommitted")

        // Ground truth: the real, separately-invoked `git blame` (without
        // `--porcelain`, a distinct human-readable format Kod's parser
        // does not consume) reports the same commit-author pairing per
        // line.
        let groundTruth = try fixture.run(["blame", "--", "f.txt"])
        let groundTruthAuthors = groundTruth
            .split(separator: "\n")
            .map { line -> String in
                let afterParen = line.drop { $0 != "(" }
                return String(afterParen.dropFirst().prefix { $0 != " " })
            }
        XCTAssertEqual(groundTruthAuthors.count, 4)
        XCTAssertEqual(groundTruthAuthors[0], "Ada")
        XCTAssertEqual(groundTruthAuthors[1], "Bob")
        XCTAssertEqual(groundTruthAuthors[2], "Ada")
        XCTAssertEqual(groundTruthAuthors[3], "Not")
    }

    func testEndToEndBlameOfSpecificRevision() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("f.txt", text: "line1\n")
        try fixture.addAll()
        let firstCommit = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        try fixture.write("f.txt", text: "line1\nline2\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c2", date: "2024-01-02T10:00:00 -0500")

        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        let service = GitBlameService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let result = try await service.blame(path: "f.txt", revision: firstCommit)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].commit.commitID, firstCommit)
    }
}
