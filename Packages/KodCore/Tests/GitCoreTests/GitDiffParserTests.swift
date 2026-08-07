import Foundation
import XCTest
@testable import GitCore

final class GitDiffParserTests: XCTestCase {
    // MARK: Hand-crafted unit tests for `GitDiffParser` against golden
    // text captured from real `git diff` output.

    func testParsesSimpleModificationHunk() throws {
        let text = """
        diff --git a/f.txt b/f.txt
        index 1f25f40..f0f2307 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1,3 @@
         l1
        +l2
        +l3

        """
        let content = try GitDiffParser.parseContent(text)
        guard case .text(let hunks) = content else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(hunks.count, 1)
        let hunk = try XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newCount, 3)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .added, .added])
        XCTAssertEqual(hunk.addedLineNumbers, [2, 3])
    }

    func testDetectsBinaryMarker() throws {
        let text = """
        diff --git a/image.bin b/image.bin
        index f445fed..46861b3 100644
        Binary files a/image.bin and b/image.bin differ

        """
        let content = try GitDiffParser.parseContent(text)
        XCTAssertEqual(content, .binary)
    }

    func testParsesNoNewlineMarker() throws {
        let text = """
        diff --git a/f.txt b/f.txt
        index abc..def 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file

        """
        let content = try GitDiffParser.parseContent(text)
        guard case .text(let hunks) = content else {
            return XCTFail("expected text content")
        }
        let hunk = try XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.lines.map(\.kind), [.removed, .noNewlineAtEndOfFile, .added, .noNewlineAtEndOfFile])
    }

    func testParsesRawIdentityForAddDeleteRenameCopy() throws {
        var data = Data()
        data.append(Data(":000000 100755 0000000000000000000000000000000000000000 aa39060000000000000000000000000000000000 A\u{0}added.txt\u{0}".utf8))
        data.append(Data(":100644 100644 b8cb0000000000000000000000000000000000000 0970e470000000000000000000000000000000000 R083\u{0}oldname.txt\u{0}newname.txt\u{0}".utf8))
        data.append(Data(":100644 100644 aaaa0000000000000000000000000000000000 bbbb0000000000000000000000000000000000 D\u{0}todelete.txt\u{0}".utf8))
        data.append(Data(":100644 100644 cccc0000000000000000000000000000000000 dddd0000000000000000000000000000000000 C100\u{0}source.txt\u{0}copy.txt\u{0}".utf8))

        let changes = try GitDiffParser.parseRawIdentity(data)
        XCTAssertEqual(changes.count, 4)

        XCTAssertEqual(changes[0].kind, .added)
        XCTAssertEqual(changes[0].newPath, "added.txt")
        XCTAssertEqual(changes[0].newMode, "100755")

        XCTAssertEqual(changes[1].kind, .renamed)
        XCTAssertEqual(changes[1].oldPath, "oldname.txt")
        XCTAssertEqual(changes[1].newPath, "newname.txt")
        XCTAssertEqual(changes[1].similarityPercentage, 83)

        XCTAssertEqual(changes[2].kind, .deleted)
        XCTAssertEqual(changes[2].newPath, "todelete.txt")

        XCTAssertEqual(changes[3].kind, .copied)
        XCTAssertEqual(changes[3].oldPath, "source.txt")
        XCTAssertEqual(changes[3].newPath, "copy.txt")
        XCTAssertEqual(changes[3].similarityPercentage, 100)
    }

    func testSideBySideProjectionPairsRemovedAndAddedRuns() {
        let hunk = GitDiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
            sectionHeading: nil,
            lines: [
                GitDiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "same"),
                GitDiffLine(kind: .removed, oldLineNumber: 2, newLineNumber: nil, text: "old2"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "new2"),
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "new3")
            ]
        )
        let rows = GitSideBySideProjection.rows(for: hunk)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].left?.text, "same")
        XCTAssertEqual(rows[0].right?.text, "same")
        XCTAssertEqual(rows[1].left?.text, "old2")
        XCTAssertEqual(rows[1].right?.text, "new2")
        XCTAssertNil(rows[2].left)
        XCTAssertEqual(rows[2].right?.text, "new3")
    }

    // MARK: End-to-end against a real fixture repository.

    func makeService(rootURL: URL) throws -> GitDiffService {
        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        return GitDiffService(executableURL: executableURL, repositoryRoot: rootURL, environment: environment)
    }

    func testEndToEndDiffOfStagedRenameWithModification() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("oldname.txt", text: "l1\nl2\nl3\nl4\nl5\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        try fixture.move("oldname.txt", "newname.txt")
        try fixture.write("newname.txt", text: "l1\nl2\nl3\nl4\nl5\nl6\n")
        try fixture.addAll()

        let service = try makeService(rootURL: fixture.rootURL)
        let diff = try await service.diff(path: "newname.txt", target: .indexVsHead, knownOldPath: "oldname.txt")

        XCTAssertEqual(diff.change.kind, .renamed)
        XCTAssertEqual(diff.change.oldPath, "oldname.txt")
        XCTAssertEqual(diff.change.newPath, "newname.txt")
        XCTAssertNotNil(diff.change.similarityPercentage)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].addedLineNumbers, [6])
    }

    func testEndToEndDiffOfBinaryFile() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("image.bin", data: Data([0x00, 0x01, 0x02, 0xFF]))
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        try fixture.write("image.bin", data: Data([0x00, 0x01, 0x02, 0xFF, 0xAB, 0xCD]))
        try fixture.addAll()

        let service = try makeService(rootURL: fixture.rootURL)
        let diff = try await service.diff(path: "image.bin", target: .indexVsHead)

        XCTAssertEqual(diff.change.kind, .modified)
        XCTAssertEqual(diff.content, .binary)
    }

    func testEndToEndDiffOfUntrackedFile() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("tracked.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        try fixture.write("new.txt", text: "untracked line1\nline2\n")

        let service = try makeService(rootURL: fixture.rootURL)
        let diff = try await service.diff(path: "new.txt", target: .workingTreeVsIndex, isUntracked: true)

        XCTAssertEqual(diff.change.kind, .added)
        XCTAssertEqual(diff.change.newPath, "new.txt")
        XCTAssertEqual(diff.hunks.first?.addedLineNumbers, [1, 2])
    }

    func testEndToEndDiffOfDeletedFile() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("todelete.txt", text: "a\nb\nc\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        try fixture.removeFromIndex("todelete.txt")

        let service = try makeService(rootURL: fixture.rootURL)
        let diff = try await service.diff(path: "todelete.txt", target: .indexVsHead)

        XCTAssertEqual(diff.change.kind, .deleted)
        XCTAssertEqual(diff.hunks.first?.removedLineNumbers, [1, 2, 3])
    }

    func testEndToEndDiffAgainstRealGitPatchOutput() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("f.txt", text: "l1\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.write("f.txt", text: "l1\nl2\nl3\n")

        let service = try makeService(rootURL: fixture.rootURL)
        let diff = try await service.diff(path: "f.txt", target: .workingTreeVsIndex)

        let groundTruth = try fixture.run(["diff", "--no-ext-diff", "--no-textconv", "--", "f.txt"])
        let addedGroundTruth = groundTruth
            .split(separator: "\n")
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .map { String($0.dropFirst()) }

        XCTAssertEqual(diff.hunks.flatMap { $0.lines.filter { $0.kind == .added }.map(\.text) }, addedGroundTruth)
    }
}
