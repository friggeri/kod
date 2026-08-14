import Foundation
import GitCore
import XCTest
@testable import GitUI

/// Pure coverage for GitUI's immutable status-presentation index.
final class GitStatusPresentationTests: XCTestCase {
    func testExplorerClassificationCoversEveryLetterAndColorRole() {
        var index = GitStatusPresentationIndex.empty

        let cases: [(GitStatusEntry, GitPresentedStatus, GitDecorationColorRole, String?)] = [
            (
                GitStatusEntry(
                    path: "modified.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                ),
                .modified,
                .modified,
                "M"
            ),
            (
                GitStatusEntry(
                    path: "added.txt",
                    shape: .ordinary(indexStatus: .added, worktreeStatus: .unmodified)
                ),
                .added,
                .added,
                "A"
            ),
            (
                GitStatusEntry(
                    path: "deleted.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
                ),
                .deleted,
                .deleted,
                "D"
            ),
            (
                GitStatusEntry(
                    path: "renamed.txt",
                    shape: .renameOrCopy(
                        indexStatus: .renamed,
                        worktreeStatus: .unmodified,
                        similarityPercentage: 100,
                        originalPath: "old.txt"
                    )
                ),
                .renamed,
                .renamed,
                "R"
            ),
            (
                GitStatusEntry(
                    path: "copied.txt",
                    shape: .renameOrCopy(
                        indexStatus: .copied,
                        worktreeStatus: .unmodified,
                        similarityPercentage: 100,
                        originalPath: "source.txt"
                    )
                ),
                .copied,
                .renamed,
                "C"
            ),
            (
                GitStatusEntry(
                    path: "type.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .typeChanged)
                ),
                .typeChanged,
                .modified,
                "T"
            ),
            (
                GitStatusEntry(path: "untracked.txt", shape: .untracked),
                .untracked,
                .untracked,
                "U"
            ),
            (
                GitStatusEntry(path: "ignored.log", shape: .ignored),
                .ignored,
                .ignored,
                nil
            ),
            (
                GitStatusEntry(
                    path: "conflicted.txt",
                    shape: .unmerged(
                        code: "UU",
                        base: nil,
                        ours: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "a", count: 40)
                        ),
                        theirs: GitUnmergedStage(
                            mode: "100644",
                            objectID: String(repeating: "b", count: 40)
                        )
                    )
                ),
                .conflicted,
                .conflict,
                "!"
            )
        ]

        index = GitStatusPresentationIndex(snapshot: GitStatusSnapshot(entries: cases.map { $0.0 }))

        for (entry, status, colorRole, letter) in cases {
            let decoration = index.explorerDecoration(
                forRelativePath: entry.path,
                isDirectory: false
            )
            XCTAssertEqual(decoration?.presentation.status, status, entry.path)
            XCTAssertEqual(decoration?.presentation.colorRole, colorRole, entry.path)
            XCTAssertEqual(decoration?.badgeText, letter, entry.path)
            XCTAssertEqual(
                decoration?.indicator,
                status == .ignored ? nil : .statusLetter,
                entry.path
            )
            XCTAssertFalse(
                decoration?.accessibilityDescription.isEmpty ?? true,
                "\(entry.path) must expose a full-word accessibility status"
            )
        }
    }

    func testExplorerStatusUsesVSCodePriorityAndWorktreeWinsTies() {
        var index = GitStatusPresentationIndex.empty
        let renamedThenModified = GitStatusEntry(
            path: "renamed.txt",
            shape: .renameOrCopy(
                indexStatus: .renamed,
                worktreeStatus: .modified,
                similarityPercentage: 90,
                originalPath: "old.txt"
            )
        )
        let addedThenTypeChanged = GitStatusEntry(
            path: "typed.txt",
            shape: .ordinary(indexStatus: .added, worktreeStatus: .typeChanged)
        )
        let deletedThenAdded = GitStatusEntry(
            path: "tie.txt",
            shape: .ordinary(indexStatus: .deleted, worktreeStatus: .added)
        )
        index = GitStatusPresentationIndex(
            snapshot: GitStatusSnapshot(
                entries: [renamedThenModified, addedThenTypeChanged, deletedThenAdded]
            )
        )

        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "renamed.txt",
                isDirectory: false
            )?.presentation.status,
            .modified
        )
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "typed.txt",
                isDirectory: false
            )?.presentation.status,
            .typeChanged
        )
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "tie.txt",
                isDirectory: false
            )?.presentation.status,
            .added
        )
    }

    func testNonDeletedChangesPropagateToParentFoldersInConstantTimeIndex() {
        var index = GitStatusPresentationIndex.empty
        index = GitStatusPresentationIndex(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "Sources/Feature/File.swift",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .modified)
                ),
                GitStatusEntry(path: "Sources/Other/New.swift", shape: .untracked)
            ])
        )

        let feature = index.explorerDecoration(
            forRelativePath: "Sources/Feature",
            isDirectory: true
        )
        XCTAssertEqual(feature?.presentation.status, .modified)
        XCTAssertEqual(feature?.indicator, .descendant)
        XCTAssertEqual(feature?.badgeText, "\u{2022}")
        XCTAssertTrue(feature?.accessibilityDescription.contains("Modified") == true)

        let sources = index.explorerDecoration(
            forRelativePath: "Sources",
            isDirectory: true
        )
        XCTAssertEqual(sources?.presentation.status, .modified)
        XCTAssertEqual(sources?.indicator, .descendant)
    }

    func testDeletedAndIgnoredEntriesDoNotPropagateToParents() {
        var index = GitStatusPresentationIndex.empty
        index = GitStatusPresentationIndex(
            snapshot: GitStatusSnapshot(entries: [
                GitStatusEntry(
                    path: "Deleted/old.txt",
                    shape: .ordinary(indexStatus: .unmodified, worktreeStatus: .deleted)
                ),
                GitStatusEntry(
                    path: "Mixed/removed.txt",
                    shape: .ordinary(indexStatus: .modified, worktreeStatus: .deleted)
                ),
                GitStatusEntry(path: "Ignored/debug.log", shape: .ignored),
                GitStatusEntry(path: "Build/", shape: .ignored)
            ])
        )

        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "Deleted/old.txt",
                isDirectory: false
            )?.presentation.status,
            .deleted
        )
        XCTAssertNil(
            index.explorerDecoration(
                forRelativePath: "Deleted",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "Mixed/removed.txt",
                isDirectory: false
            )?.presentation,
            GitStatusPresentation(status: .modified, colorRole: .stagedModified)
        )
        XCTAssertNil(
            index.explorerDecoration(
                forRelativePath: "Mixed",
                isDirectory: true
            ),
            "any entry with a deleted side must not create a ghost parent decoration"
        )

        let ignored = index.explorerDecoration(
            forRelativePath: "Ignored/debug.log",
            isDirectory: false
        )
        XCTAssertEqual(ignored?.presentation.status, .ignored)
        XCTAssertNil(ignored?.badgeText)
        XCTAssertNil(
            index.explorerDecoration(
                forRelativePath: "Ignored",
                isDirectory: true
            )
        )
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "Build",
                isDirectory: true
            ),
            .ignored
        )
    }

    func testIndexUsesStagedColorsForExplorerEntries() {
        let changedOnBothSides = GitStatusEntry(
            path: "both.txt",
            shape: .ordinary(indexStatus: .modified, worktreeStatus: .deleted)
        )

        let stagedDeletion = GitStatusEntry(
            path: "gone.txt",
            shape: .ordinary(indexStatus: .deleted, worktreeStatus: .unmodified)
        )

        var index = GitStatusPresentationIndex.empty
        index = GitStatusPresentationIndex(
            snapshot: GitStatusSnapshot(
                entries: [changedOnBothSides, stagedDeletion]
            )
        )
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "gone.txt",
                isDirectory: false
            )?.presentation.colorRole,
            .stagedDeleted
        )

        let stagedOnlyModification = GitStatusEntry(
            path: "staged-modified.txt",
            shape: .ordinary(indexStatus: .modified, worktreeStatus: .unmodified)
        )
        index = GitStatusPresentationIndex(snapshot: GitStatusSnapshot(entries: [stagedOnlyModification]))
        XCTAssertEqual(
            index.explorerDecoration(
                forRelativePath: "staged-modified.txt",
                isDirectory: false
            )?.presentation.colorRole,
            .stagedModified
        )
    }

    func testRenameLookupIndexesBothCurrentAndOriginalPaths() throws {
        var index = GitStatusPresentationIndex.empty
        let renamed = GitStatusEntry(
            path: "new/name.swift",
            shape: .renameOrCopy(
                indexStatus: .renamed,
                worktreeStatus: .unmodified,
                similarityPercentage: 100,
                originalPath: "old/name.swift"
            )
        )
        index = GitStatusPresentationIndex(snapshot: GitStatusSnapshot(entries: [renamed]))

        XCTAssertEqual(
            try XCTUnwrap(index.entry(forRelativePath: "new/name.swift")),
            renamed
        )
        XCTAssertEqual(
            try XCTUnwrap(index.entry(forRelativePath: "old/name.swift")),
            renamed
        )
    }
}
