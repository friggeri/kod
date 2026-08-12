import XCTest
@testable import GitCore

final class GitQuickDiffProjectionTests: XCTestCase {
    func testAddedMarksKeepHunkOwnershipAndNavigationOrder() {
        let projection = GitQuickDiffProjection.project(
            hunks: [
                hunk(newStart: 2, lines: [.added(2), .added(3)]),
                hunk(newStart: 8, lines: [.added(8)])
            ],
            provider: .workingTree
        )

        XCTAssertEqual(projection.navigationHunkIDs.map(\.index), [0, 1])
        XCTAssertEqual(projection.marks.map(\.kind), [.added, .added])
        XCTAssertEqual(projection.marks.map(\.currentLineRange), [2..<4, 8..<9])
        XCTAssertEqual(projection.marks.map(\.hunkID.index), [0, 1])
        XCTAssertEqual(projection.provider.source, .index)
    }

    func testReplacementProducesModifiedCurrentRange() {
        let projection = GitQuickDiffProjection.project(
            hunks: [hunk(newStart: 4, lines: [.removed(4), .removed(5), .added(4), .added(5)])],
            provider: .workingTree
        )

        XCTAssertEqual(projection.marks, [
            GitQuickDiffMark(
                hunkID: GitQuickDiffHunkID(provider: .workingTree, index: 0),
                kind: .modified,
                currentLineRange: 4..<6
            )
        ])
        XCTAssertTrue(projection.deletionAnchors.isEmpty)
    }

    func testDeletionAnchorsIncludesBeforeFirstLine() {
        let projection = GitQuickDiffProjection.project(
            hunks: [
                hunk(newStart: 2, lines: [.context(1), .removed(2)]),
                hunk(newStart: 1, lines: [.removed(1)]),
                hunk(newStart: 0, lines: [.removed(1)])
            ],
            provider: .workingTree
        )

        XCTAssertEqual(
            projection.deletionAnchors.map(\.afterCurrentLineNumber),
            [1, 0, 0]
        )
        XCTAssertEqual(projection.deletionAnchors.map(\.hunkID.index), [0, 1, 2])
    }

    func testSecondaryMarksOverlappingPrimaryAreSuppressed() {
        let primary = GitQuickDiffProjection.project(
            hunks: [hunk(newStart: 3, lines: [.added(3), .added(4)])],
            provider: .workingTree
        )
        let secondary = GitQuickDiffProjection.project(
            hunks: [hunk(newStart: 4, lines: [.added(4), .added(5)])],
            provider: .staged
        )

        let result = GitQuickDiffProjection.withPrimaryPrecedence(primary: primary, secondary: secondary)
        XCTAssertEqual(result.primary.marks.count, 1)
        XCTAssertTrue(result.secondary.marks.isEmpty)
        XCTAssertEqual(result.secondary.navigationHunkIDs, [GitQuickDiffHunkID(provider: .staged, index: 0)])
    }

    func testPathSelectorUsesOldPathsForBaselines() {
        let renamed = GitDiffFileChange(kind: .renamed, oldPath: "old name.swift", newPath: "new name.swift")
        let deleted = GitDiffFileChange(kind: .deleted, oldPath: "gone.swift", newPath: "gone.swift")

        XCTAssertEqual(
            GitRevisionPathSelector.path(for: .index, target: .workingTreeVsIndex, change: renamed),
            "old name.swift"
        )
        XCTAssertEqual(
            GitRevisionPathSelector.path(for: .head, target: .indexVsHead, change: renamed),
            "old name.swift"
        )
        XCTAssertEqual(
            GitRevisionPathSelector.path(for: .head, target: .indexVsHead, change: deleted),
            "gone.swift"
        )
    }

    private func hunk(newStart: Int, lines: [Line]) -> GitDiffHunk {
        GitDiffHunk(
            oldStart: newStart,
            oldCount: lines.count,
            newStart: newStart,
            newCount: lines.count,
            sectionHeading: nil,
            lines: lines.map(\.diffLine)
        )
    }

    private enum Line {
        case context(Int)
        case added(Int)
        case removed(Int)

        var diffLine: GitDiffLine {
            switch self {
            case .context(let number):
                GitDiffLine(kind: .context, oldLineNumber: number, newLineNumber: number, text: "context")
            case .added(let number):
                GitDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: number, text: "added")
            case .removed(let number):
                GitDiffLine(kind: .removed, oldLineNumber: number, newLineNumber: nil, text: "removed")
            }
        }
    }
}
