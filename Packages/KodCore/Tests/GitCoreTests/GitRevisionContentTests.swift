import Foundation
import WorkspaceCore
import XCTest
@testable import GitCore

final class GitRevisionContentTests: XCTestCase {
    func testIndexAndHeadReturnExactBytesIncludingWeirdPath() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        let path = "odd name-[x].bin"
        let headBytes = Data([0, 1, 2, 255, 10])
        let indexBytes = Data([255, 0, 9, 10])
        try fixture.write(path, data: headBytes)
        try fixture.add(path)
        _ = try fixture.commit(message: "initial", date: "2024-01-01T10:00:00 -0500")
        try fixture.write(path, data: indexBytes)
        try fixture.add(path)

        let context = try await GitContext.open(at: fixture.rootURL)
        let head = try await context.revisionContent(source: .head, path: path)
        let index = try await context.revisionContent(source: .index, path: path)
        let worktree = try await context.revisionContent(source: .workingTree, path: path)

        XCTAssertEqual(head.bytes, headBytes)
        XCTAssertEqual(index.bytes, indexBytes)
        XCTAssertEqual(worktree.path, path)
        guard case .workingTree(let url, _) = worktree else {
            return XCTFail("working-tree source should be a filesystem selector")
        }
        XCTAssertEqual(
            url.resolvingSymlinksInPath(),
            fixture.rootURL.appendingPathComponent(path).resolvingSymlinksInPath()
        )
    }

    func testUnbornHeadIsTypedErrorForStagedAddedFile() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("new.swift", text: "let x = 1\n")
        try fixture.add("new.swift")
        let context = try await GitContext.open(at: fixture.rootURL)

        let unbornHeadExists = try await context.headExists()
        XCTAssertFalse(unbornHeadExists)
        do {
            _ = try await context.revisionContent(source: .head, path: "new.swift")
            XCTFail("expected unborn HEAD")
        } catch let error as GitRevisionContentError {
            XCTAssertEqual(error, .unbornHead)
        }

        let stagedDiff = try await context.diff(path: "new.swift", target: .indexVsHead)
        XCTAssertEqual(stagedDiff.change.kind, .added)
        XCTAssertFalse(stagedDiff.hunks.isEmpty)

        let workingTreeDiff = try await context.diff(
            path: "new.swift",
            target: .workingTreeVsIndex,
            isUntracked: true
        )
        XCTAssertEqual(workingTreeDiff.change.kind, .added)
        XCTAssertFalse(workingTreeDiff.hunks.isEmpty)

        _ = try fixture.commit(message: "initial", date: "2024-01-01T10:00:00 -0500")
        await context.invalidate(for: WorkspaceChangeBatch(paths: [
            WorkspaceChangePath(
                path: fixture.rootURL.appendingPathComponent(".git/HEAD").path,
                flags: .modified
            )
        ]))
        let committedHeadExists = try await context.headExists()
        XCTAssertTrue(committedHeadExists)
    }

    func testDiffMetadataSelectsRenameAndDeletionBaselinePaths() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("old name.txt", text: "original\n")
        try fixture.add("old name.txt")
        _ = try fixture.commit(message: "initial", date: "2024-01-01T10:00:00 -0500")
        try fixture.move("old name.txt", "new name.txt")

        let context = try await GitContext.open(at: fixture.rootURL)
        let renameDiff = try await context.diff(
            path: "new name.txt",
            target: .indexVsHead,
            knownOldPath: "old name.txt"
        )
        let index = try await context.revisionContent(source: .index, target: .indexVsHead, diff: renameDiff)
        let head = try await context.revisionContent(source: .head, target: .indexVsHead, diff: renameDiff)
        XCTAssertEqual(index.path, "new name.txt")
        XCTAssertEqual(head.path, "old name.txt")
        XCTAssertEqual(index.bytes, Data("original\n".utf8))
        XCTAssertEqual(head.bytes, Data("original\n".utf8))

        _ = try fixture.commit(message: "rename", date: "2024-01-02T10:00:00 -0500")
        try fixture.write("gone.txt", text: "gone\n")
        try fixture.add("gone.txt")
        _ = try fixture.commit(message: "add gone", date: "2024-01-03T10:00:00 -0500")
        try fixture.remove("gone.txt")
        try fixture.addAll()
        let deletionDiff = try await context.diff(path: "gone.txt", target: .indexVsHead, useCache: false)
        let deletionProjection = GitQuickDiffProjection.project(deletionDiff, provider: .staged)
        XCTAssertEqual(deletionDiff.hunks.first?.newStart, 0)
        XCTAssertEqual(deletionProjection.deletionAnchors.first?.afterCurrentLineNumber, 0)
        let deletedHead = try await context.revisionContent(
            source: .head,
            target: .indexVsHead,
            diff: deletionDiff
        )
        XCTAssertEqual(deletedHead.path, "gone.txt")
        XCTAssertEqual(deletedHead.bytes, Data("gone\n".utf8))
    }

    func testMissingRevisionPathAndBoundedOutputAreExplicit() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("large.bin", data: Data(repeating: 0x41, count: 64))
        try fixture.add("large.bin")
        _ = try fixture.commit(message: "initial", date: "2024-01-01T10:00:00 -0500")

        let executable = try GitExecutableLocator.resolve()
        let environment = GitInvocationHardening.environment(home: ProcessInfo.processInfo.environment["HOME"])
        let service = GitRevisionContentService(
            executableURL: executable,
            repositoryRoot: fixture.rootURL,
            environment: environment,
            maximumOutputByteCount: 8
        )

        do {
            _ = try await service.revisionContent(source: .head, path: "large.bin")
            XCTFail("expected bounded output error")
        } catch let error as GitRevisionContentError {
            XCTAssertEqual(error, .outputTruncated(source: .head, path: "large.bin"))
        }

        let uncapped = GitRevisionContentService(
            executableURL: executable,
            repositoryRoot: fixture.rootURL,
            environment: environment
        )
        do {
            _ = try await uncapped.revisionContent(source: .index, path: "missing.txt")
            XCTFail("expected missing index path")
        } catch let error as GitRevisionContentError {
            XCTAssertEqual(error, .fileNotFound(source: .index, path: "missing.txt"))
        }
    }

    func testRevisionContentRefreshesAfterInvalidation() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "one\n")
        try fixture.add("a.txt")
        _ = try fixture.commit(message: "initial", date: "2024-01-01T10:00:00 -0500")
        let context = try await GitContext.open(at: fixture.rootURL)
        let committedHeadExists = try await context.headExists()
        XCTAssertTrue(committedHeadExists)
        let initial = try await context.revisionContent(source: .index, path: "a.txt")
        XCTAssertEqual(initial.bytes, Data("one\n".utf8))

        try fixture.write("a.txt", text: "two\n")
        try fixture.add("a.txt")
        await context.invalidate(for: WorkspaceChangeBatch(paths: [
            WorkspaceChangePath(path: fixture.rootURL.appendingPathComponent("a.txt").path, flags: .modified)
        ]))

        let refreshed = try await context.revisionContent(source: .index, path: "a.txt")
        XCTAssertEqual(refreshed.bytes, Data("two\n".utf8))
    }
}
