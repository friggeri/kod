import Foundation
import XCTest
@testable import GitCore

/// SPEC 9.2's central safety guarantee: every Git workflow Kod runs is
/// truly read-only. These tests take a full SHA-256 (content + mtime +
/// type) manifest of both the working tree and the entire `.git`
/// directory before and after running status/diff/blame/repository-
/// location, and require byte-for-byte equality — including files Git
/// would normally opportunistically rewrite (the index refresh a plain
/// `git status` performs). Any metadata Git might normally update is
/// handled by hardening the invocation (`--no-optional-locks` +
/// `GIT_OPTIONAL_LOCKS=0`; see `GitInvocationHardening`), never by
/// relaxing this assertion.
final class GitImmutabilityTests: XCTestCase {
    private func assertManifestUnchanged(
        _ before: WorktreeManifest,
        _ after: WorktreeManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let differences = WorktreeManifest.describeDifferences(before: before, after: after)
        XCTAssertTrue(
            differences.isEmpty,
            "worktree/.git manifest changed:\n\(differences.joined(separator: "\n"))",
            file: file,
            line: line
        )
    }

    /// Backdates `.git/index`'s modification time, the specific
    /// condition under which a plain (unhardened) `git status` performs
    /// its opportunistic "racily clean" index-refresh write-back — so
    /// this test would catch a regression to that hardening even if the
    /// index otherwise looked already up to date.
    private func makeIndexAppearStale(gitDirectory: URL) throws {
        let indexURL = gitDirectory.appendingPathComponent("index")
        let staleDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: indexURL.path)
    }

    func testFullWorkflowAcrossStatusDiffBlameAndLocateLeavesWorktreeAndGitDirByteIdentical() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("keep.txt", text: "line1\nline2\nline3\n")
        try fixture.write("oldname.txt", text: "old content\nsecond line\n")
        try fixture.write("todelete.txt", text: "to be deleted\n")
        try fixture.write("torename.txt", text: "rename me\n")
        try fixture.write("image.bin", data: Data([0x00, 0x01, 0x02, 0xFF]))
        try fixture.addAll()
        let firstCommit = try fixture.commit(message: "initial commit", date: "2024-01-01T10:00:00 -0500")

        try fixture.move("oldname.txt", "newname.txt")
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\n")
        try fixture.removeFromIndex("todelete.txt")
        try fixture.write("image.bin", data: Data([0x00, 0x01, 0x02, 0xFF, 0xAB]))
        try fixture.addAll()
        try fixture.run(["commit", "-q", "-m", "second commit"], extraEnvironment: [
            "GIT_AUTHOR_NAME": "Bob Fixture",
            "GIT_AUTHOR_EMAIL": "bob@example.com",
            "GIT_AUTHOR_DATE": "2024-02-01T10:00:00 -0500",
            "GIT_COMMITTER_NAME": "Bob Fixture",
            "GIT_COMMITTER_EMAIL": "bob@example.com",
            "GIT_COMMITTER_DATE": "2024-02-01T10:00:00 -0500"
        ])

        // Staged edit, then a further unstaged edit on top.
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\nstaged\n")
        try fixture.add("keep.txt")
        try fixture.write("keep.txt", text: "line1\nline2\nline3\nline4\nstaged\nunstaged\n")

        try fixture.write("untracked.txt", text: "untracked\n")
        try fixture.write(".gitignore", text: "*.log\n")
        try fixture.add(".gitignore")
        try fixture.write("debug.log", text: "secret\n")

        // A freshly staged rename and a freshly staged binary edit,
        // still to be exercised for immutability alongside everything
        // above.
        try fixture.move("torename.txt", "renamed.txt")
        try fixture.write("image.bin", data: Data([0x00, 0x01, 0x02, 0xFF, 0xAB, 0xCD, 0xEF]))
        try fixture.add("image.bin")

        let executableURL = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])

        let locator = GitRepositoryLocator(executableURL: executableURL)
        let location = try await locator.locate(startingAt: fixture.rootURL)

        // Make the index look stale (as if some external tool had
        // touched a tracked file's mtime forward) immediately before
        // capturing "before", so a status call that *would* perform an
        // unhardened refresh has every opportunity to do so.
        try makeIndexAppearStale(gitDirectory: location.gitDirectory)

        let before = try WorktreeManifest.capture(root: fixture.rootURL)

        let statusService = GitStatusService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let snapshot = try await statusService.status()
        XCTAssertFalse(snapshot.entries.isEmpty)

        let diffService = GitDiffService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        _ = try await diffService.diff(path: "keep.txt", target: .workingTreeVsIndex)
        _ = try await diffService.diff(path: "keep.txt", target: .indexVsHead)
        _ = try await diffService.diff(path: "keep.txt", target: .workingTreeVsHead)
        _ = try await diffService.diff(path: "image.bin", target: .indexVsHead)
        _ = try await diffService.diff(path: "renamed.txt", target: .indexVsHead, knownOldPath: "torename.txt")
        _ = try await diffService.diff(path: "untracked.txt", target: .workingTreeVsIndex, isUntracked: true)

        let blameService = GitBlameService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        _ = try await blameService.blame(path: "keep.txt")
        _ = try await blameService.blame(path: "keep.txt", revision: firstCommit)

        _ = try await locator.locate(startingAt: fixture.rootURL)

        let after = try WorktreeManifest.capture(root: fixture.rootURL)
        assertManifestUnchanged(before, after)
    }

    func testStatusDuringAnUnresolvedMergeConflictLeavesWorktreeAndGitDirByteIdentical() async throws {
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
        let locator = GitRepositoryLocator(executableURL: executableURL)
        let location = try await locator.locate(startingAt: fixture.rootURL)
        try makeIndexAppearStale(gitDirectory: location.gitDirectory)

        let before = try WorktreeManifest.capture(root: fixture.rootURL)

        let statusService = GitStatusService(executableURL: executableURL, repositoryRoot: fixture.rootURL, environment: environment)
        let snapshot = try await statusService.status()
        XCTAssertEqual(snapshot.conflicted.map(\.path), ["shared.txt"])

        let after = try WorktreeManifest.capture(root: fixture.rootURL)
        assertManifestUnchanged(before, after)
    }

    /// A regression guard for the specific hardening this whole suite
    /// depends on: without `--no-optional-locks`/`GIT_OPTIONAL_LOCKS=0`,
    /// a plain `git status` against a stale index *does* rewrite
    /// `.git/index`. This test intentionally invokes the real Git binary
    /// unhardened (bypassing `GitCore` entirely) to prove the premise
    /// itself is real, not just assumed.
    func testPlainUnhardenedStatusWouldHaveMutatedIndexProvingHardeningIsLoadBearing() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.write("a.txt", text: "hi\nchanged\n")
        try fixture.add("a.txt")

        let indexURL = fixture.rootURL.appendingPathComponent(".git/index")
        try makeIndexAppearStale(gitDirectory: fixture.rootURL.appendingPathComponent(".git"))
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        let beforeDate = try XCTUnwrap(beforeAttributes[.modificationDate] as? Date)

        // Deliberately unhardened: no `--no-optional-locks`, no
        // `GIT_OPTIONAL_LOCKS=0`.
        _ = try fixture.run(["status", "--porcelain=v2", "-z"])

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        let afterDate = try XCTUnwrap(afterAttributes[.modificationDate] as? Date)
        XCTAssertNotEqual(beforeDate, afterDate, "expected the unhardened status to refresh the stale index's mtime")
    }
}
