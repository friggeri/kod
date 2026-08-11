import Foundation
import XCTest
@testable import GitCore

final class GitRepositoryLocatorTests: XCTestCase {
    func makeLocator() throws -> GitRepositoryLocator {
        let executableURL = try GitExecutableLocator.resolve()
        return GitRepositoryLocator(executableURL: executableURL)
    }

    func testLocatesRootGitDirAndBranchForANonWorktreeRepository() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let locator = try makeLocator()
        let location = try await locator.locate(startingAt: fixture.rootURL)

        XCTAssertEqual(
            location.workingTreeRoot.resolvingSymlinksInPath().path,
            fixture.rootURL.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(location.isBareRepository)
        XCTAssertFalse(location.isLinkedWorktree)
        XCTAssertEqual(location.gitDirectory, location.commonDirectory)
        guard case .branch(let name) = location.head else {
            return XCTFail("expected a branch head")
        }
        XCTAssertEqual(name, "main")
    }

    func testDetectsDetachedHead() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        let commit = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")
        try fixture.checkout("--detach", commit)

        let locator = try makeLocator()
        let location = try await locator.locate(startingAt: fixture.rootURL)

        guard case .detached(let commitID) = location.head else {
            return XCTFail("expected a detached head")
        }
        XCTAssertEqual(commitID, commit)
        XCTAssertTrue(location.head.isDetached)
    }

    func testLocatesFromASubdirectoryOfTheWorkingTree() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }

        try fixture.write("nested/deep/a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let locator = try makeLocator()
        let subdirectory = fixture.rootURL.appendingPathComponent("nested/deep", isDirectory: true)
        let location = try await locator.locate(startingAt: subdirectory)

        XCTAssertEqual(
            location.workingTreeRoot.resolvingSymlinksInPath().path,
            fixture.rootURL.resolvingSymlinksInPath().path
        )
    }

    func testThrowsForANonRepositoryPath() async throws {
        let plainDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAGitRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plainDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plainDirectory) }

        let locator = try makeLocator()
        do {
            _ = try await locator.locate(startingAt: plainDirectory)
            XCTFail("expected notARepository error")
        } catch GitRepositoryLocatorError.notARepository {
            // expected
        }
    }

    func testLocatesALinkedWorktree() async throws {
        let fixture = try GitFixtureBuilder.makeEmptyRepository()
        defer { try? fixture.removeAll() }
        try fixture.write("a.txt", text: "hi\n")
        try fixture.addAll()
        _ = try fixture.commit(message: "c1", date: "2024-01-01T10:00:00 -0500")

        let linkedWorktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCoreLinkedWorktree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linkedWorktree) }
        try fixture.run(["worktree", "add", "-q", "-b", "linked", linkedWorktree.path])

        let locator = try makeLocator()
        let location = try await locator.locate(startingAt: linkedWorktree)

        XCTAssertTrue(location.isLinkedWorktree)
        XCTAssertNotEqual(location.gitDirectory, location.commonDirectory)
        XCTAssertFalse(location.isBareRepository)
    }
}
