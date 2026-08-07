import AppKit
import Foundation
import GitCore
import XCTest
@testable import Kod

/// Headless coverage for the blame gutter/commit-popover text formatting
/// (SPEC 9.1) and the table's public `update(result:)`/selection API.
@MainActor
final class GitBlameViewControllerTests: XCTestCase {
    private func makeCommit(uncommitted: Bool = false) -> GitBlameCommit {
        GitBlameCommit(
            commitID: uncommitted ? String(repeating: "0", count: 40) : "fff059ecb5202467eb89d49b61ad5823289f4f53",
            authorName: uncommitted ? "Not Committed Yet" : "Ada Fixture",
            authorEmail: uncommitted ? "not.committed.yet" : "ada@example.com",
            authorTime: Date(timeIntervalSince1970: 1_704_121_200),
            authorTimeZone: "-0500",
            committerName: uncommitted ? "Not Committed Yet" : "Ada Fixture",
            committerEmail: uncommitted ? "not.committed.yet" : "ada@example.com",
            committerTime: Date(timeIntervalSince1970: 1_704_121_200),
            committerTimeZone: "-0500",
            summary: uncommitted ? "Version of f.txt from f.txt" : "initial commit",
            isBoundary: !uncommitted,
            isUncommitted: uncommitted
        )
    }

    func testGutterTextForACommittedLineIncludesAuthorDateAndSummary() {
        let line = GitBlameLine(
            commit: makeCommit(),
            originalLineNumber: 1,
            finalLineNumber: 1,
            filename: "f.txt",
            text: "line1",
            previousCommitID: nil,
            previousFilename: nil
        )
        let text = GitBlameViewController.gutterText(for: line)
        XCTAssertEqual(text, "Ada Fixture, 2024-01-01 • initial commit")
    }

    func testGutterTextForAnUncommittedLineIsDistinct() {
        let line = GitBlameLine(
            commit: makeCommit(uncommitted: true),
            originalLineNumber: 4,
            finalLineNumber: 4,
            filename: "f.txt",
            text: "line4 uncommitted",
            previousCommitID: "4751539870f6d4d531ab3137b67ba2bb37fa0cf4",
            previousFilename: "f.txt"
        )
        XCTAssertEqual(GitBlameViewController.gutterText(for: line), "Not committed yet")
    }

    func testPopoverTextIncludesEmailShortCommitIDAndTimezone() {
        let line = GitBlameLine(
            commit: makeCommit(),
            originalLineNumber: 1,
            finalLineNumber: 1,
            filename: "f.txt",
            text: "line1",
            previousCommitID: nil,
            previousFilename: nil
        )
        let text = GitBlameViewController.popoverText(for: line)
        XCTAssertTrue(text.contains("ada@example.com"))
        XCTAssertTrue(text.contains("fff059e"))
        XCTAssertTrue(text.contains("-0500"))
        XCTAssertTrue(text.contains("initial commit"))
    }

    func testPopoverTextForUncommittedLineDoesNotReferenceACommitID() {
        let line = GitBlameLine(
            commit: makeCommit(uncommitted: true),
            originalLineNumber: 4,
            finalLineNumber: 4,
            filename: "f.txt",
            text: "line4 uncommitted",
            previousCommitID: nil,
            previousFilename: nil
        )
        let text = GitBlameViewController.popoverText(for: line)
        XCTAssertTrue(text.contains("Uncommitted change"))
        XCTAssertTrue(text.contains("f.txt, line 4"))
    }

    func testUpdateReplacesResultAndSelectionInvokesCallbackWithTheChosenLine() throws {
        var selectedLines: [GitBlameLine] = []
        let controller = GitBlameViewController { line in
            selectedLines.append(line)
        }
        controller.loadView()

        let line = GitBlameLine(
            commit: makeCommit(),
            originalLineNumber: 1,
            finalLineNumber: 1,
            filename: "f.txt",
            text: "line1",
            previousCommitID: nil,
            previousFilename: nil
        )
        controller.update(result: GitBlameResult(lines: [line]))
        XCTAssertEqual(controller.result?.lines.count, 1)

        let tableView = try XCTUnwrap(findTableView(in: controller.view))
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.sendAction(tableView.action, to: tableView.target)

        XCTAssertEqual(selectedLines.count, 1)
        XCTAssertEqual(selectedLines.first?.text, "line1")
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }
        for subview in view.subviews {
            if let found = findTableView(in: subview) {
                return found
            }
        }
        return nil
    }
}
