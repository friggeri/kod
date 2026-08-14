import Foundation
import XCTest
@testable import GitCore

final class GitRepositoryInvalidationTests: XCTestCase {
    func testEmptyInvalidationIsANoOp() async {
        let context = makeContext()
        let initialIdentity = await context.repositoryStateIdentity()

        await context.invalidate(GitRepositoryInvalidation(changedPaths: []))

        let unchangedIdentity = await context.repositoryStateIdentity()
        XCTAssertEqual(unchangedIdentity, initialIdentity)
    }

    func testNonemptyInvalidationAdvancesGenerationOnce() async {
        let context = makeContext()
        let initialIdentity = await context.repositoryStateIdentity()

        await context.invalidate(
            GitRepositoryInvalidation(changedPaths: [
                "/repository/a.swift",
                "/repository/b.swift",
                "/repository/a.swift"
            ])
        )

        let invalidatedIdentity = await context.repositoryStateIdentity()
        XCTAssertEqual(
            invalidatedIdentity.worktreeGeneration,
            initialIdentity.worktreeGeneration + 1
        )
        XCTAssertEqual(invalidatedIdentity.headDescription, initialIdentity.headDescription)
        XCTAssertEqual(invalidatedIdentity.indexFingerprint, initialIdentity.indexFingerprint)
    }

    private func makeContext() -> GitContext {
        let root = URL(fileURLWithPath: "/repository", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        return GitContext(
            location: GitRepositoryLocation(
                workingTreeRoot: root,
                gitDirectory: gitDirectory,
                commonDirectory: gitDirectory,
                isBareRepository: false,
                head: .branch(name: "main")
            ),
            executableURL: URL(fileURLWithPath: "/usr/bin/git")
        )
    }
}
