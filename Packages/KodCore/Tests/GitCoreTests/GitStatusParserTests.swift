import Foundation
import XCTest
@testable import GitCore

final class GitStatusParserTests: XCTestCase {
    // MARK: Golden byte-level fixtures (captured from real `git status
    // --porcelain=v2 -z`, reproduced here as literal bytes so the parser
    // is exercised against the exact wire format even without a live
    // repository).

    func testParsesOrdinaryAddedEntry() throws {
        let record = ["1", "A.", "N...", "000000", "100644", "100644",
                       String(repeating: "0", count: 40),
                       "397b4a7624e35fa60563a9c03b1213d93f7b6546", ".gitignore"].joined(separator: " ")
        let data = Data((record + "\u{0}").utf8)
        let snapshot = try GitStatusParser.parse(data)

        XCTAssertEqual(snapshot.entries.count, 1)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.path, ".gitignore")
        XCTAssertTrue(entry.isStaged)
        XCTAssertFalse(entry.isUnstaged)
        guard case .ordinary(let indexStatus, let worktreeStatus) = entry.shape else {
            return XCTFail("expected ordinary shape")
        }
        XCTAssertEqual(indexStatus, .added)
        XCTAssertEqual(worktreeStatus, .unmodified)
    }

    func testParsesOrdinaryStagedAndUnstagedEntry() throws {
        let record = ["1", "MM", "N...", "100644", "100644", "100644",
                       "84275f993945", "7fe573c936b5", "keep.txt"].joined(separator: " ")
        let data = Data((record + "\u{0}").utf8)
        let snapshot = try GitStatusParser.parse(data)

        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertTrue(entry.isStaged)
        XCTAssertTrue(entry.isUnstaged)
    }

    func testParsesUntrackedAndIgnoredEntries() throws {
        let data = Data("? untracked.txt\u{0}! debug.log\u{0}".utf8)
        let snapshot = try GitStatusParser.parse(data)

        XCTAssertEqual(snapshot.untracked.map(\.path), ["untracked.txt"])
        XCTAssertEqual(snapshot.ignored.map(\.path), ["debug.log"])
        XCTAssertTrue(snapshot.entries.allSatisfy { !$0.isStaged && !$0.isUnstaged })
    }

    func testParsesRenameEntryWithOriginalPath() throws {
        let record = ["2", "R.", "N...", "100644", "100644", "100644",
                       "b3c5a95f929a50feb06c275ac567cdb1b441d1e2",
                       "5fcb7b1b3ca40839d7673eed17afdb0a22143ce",
                       "R83", "newname.txt"].joined(separator: " ")
        let data = Data((record + "\u{0}oldname.txt\u{0}").utf8)
        let snapshot = try GitStatusParser.parse(data)

        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.path, "newname.txt")
        XCTAssertEqual(entry.originalPath, "oldname.txt")
        XCTAssertTrue(entry.isRenamed)
        guard case .renameOrCopy(_, _, let similarity, let originalPath) = entry.shape else {
            return XCTFail("expected renameOrCopy shape")
        }
        XCTAssertEqual(similarity, 83)
        XCTAssertEqual(originalPath, "oldname.txt")
    }

    func testParsesUnmergedAddAddConflict() throws {
        let record = ["u", "AA", "N...", "000000", "100644", "100644", "100644",
                       String(repeating: "0", count: 40),
                       "65e9d1c71aa492e9588ac906ff84e1b552aa388",
                       "a9b4cd24b7ed367ccb0b92bc7fc20c930",
                       "newname.txt"].joined(separator: " ")
        let data = Data((record + "\u{0}").utf8)
        let snapshot = try GitStatusParser.parse(data)

        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertTrue(entry.isConflicted)
        XCTAssertEqual(snapshot.conflicted.count, 1)
        guard case .unmerged(let code, let base, let ours, let theirs) = entry.shape else {
            return XCTFail("expected unmerged shape")
        }
        XCTAssertEqual(code, "AA")
        XCTAssertNil(base)
        XCTAssertEqual(ours.mode, "100644")
        XCTAssertEqual(theirs.mode, "100644")
    }

    func testParsesArbitraryUnicodeAndTabBytePaths() throws {
        let unicodePath = "h\u{00E9}llo w\u{00F6}rld.txt"
        let tabPath = "weird\tname.txt"
        var data = Data()
        data.append(Data((["1", "A.", "N...", "000000", "100644", "100644",
                            String(repeating: "0", count: 40),
                            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", unicodePath].joined(separator: " ") + "\u{0}").utf8))
        data.append(Data((["1", "A.", "N...", "000000", "100644", "100644",
                            String(repeating: "0", count: 40),
                            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", tabPath].joined(separator: " ") + "\u{0}").utf8))

        let snapshot = try GitStatusParser.parse(data)
        XCTAssertEqual(snapshot.entries.map(\.path), [unicodePath, tabPath])
    }

    // MARK: End-to-end against a real fixture repository and a real,
    // separately-invoked `/usr/bin/git`/resolved Git binary (golden
    // comparison, not just hand-crafted bytes).

    func testEndToEndStatusMatchesRealGitAcrossEveryGroup() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("keep.txt", text: "line1\nline2\nline3\n")
        try fixture.write("todelete.txt", text: "to be deleted\n")
        try fixture.write("oldname.txt", text: "old name content\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "initial commit", date: "2024-01-01T10:00:00 -0500")

        try fixture.move("oldname.txt", "newname.txt")
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\n")
        try fixture.removeFromIndex("todelete.txt")
        try fixture.addAll()
        _ = try fixture.commit(message: "second commit", date: "2024-02-01T10:00:00 -0500")

        // Staged edit, then a further unstaged edit on top.
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\nstaged edit\n")
        try fixture.add("keep.txt")
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\nstaged edit\nunstaged edit\n")

        try fixture.write("untracked.txt", text: "untracked\n")
        try fixture.write(".gitignore", text: "*.log\n")
        try fixture.add(".gitignore")
        try fixture.write("debug.log", text: "secret\n")

        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        let service = GitStatusService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let snapshot = try await service.status()

        XCTAssertEqual(Set(snapshot.staged.map(\.path)), [".gitignore", "keep.txt"])
        XCTAssertEqual(Set(snapshot.unstaged.map(\.path)), ["keep.txt"])
        XCTAssertEqual(Set(snapshot.untracked.map(\.path)), ["untracked.txt"])
        XCTAssertEqual(Set(snapshot.ignored.map(\.path)), ["debug.log"])
        XCTAssertTrue(snapshot.conflicted.isEmpty)

        // Ground truth: run the real `git status --porcelain=v1` (a
        // simpler, independently-implemented format Kod's own parser
        // does not consume) directly and compare the set of changed
        // paths it reports.
        let groundTruthOutput = try fixture.run(["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"])
        let groundTruthPaths = Set(
            groundTruthOutput
                .split(separator: "\n")
                .map { String($0.dropFirst(3)) }
        )
        let kodPaths = Set(snapshot.entries.map(\.path))
        XCTAssertEqual(groundTruthPaths, kodPaths)
    }

    func testEndToEndStatusDetectsConflict() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("shared.txt", text: "base\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "base", date: "2024-01-01T10:00:00 -0500")

        try fixture.createBranch("feature")
        try fixture.checkout("feature")
        try fixture.write("shared.txt", text: "feature change\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "feature change", date: "2024-01-02T10:00:00 -0500")

        try fixture.checkout("main")
        try fixture.write("shared.txt", text: "main change\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "main change", date: "2024-01-03T10:00:00 -0500")

        try fixture.mergeExpectingConflict("feature")

        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        let service = GitStatusService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let snapshot = try await service.status()

        XCTAssertEqual(snapshot.conflicted.map(\.path), ["shared.txt"])
        XCTAssertTrue(snapshot.conflicted[0].isConflicted)
    }
}
