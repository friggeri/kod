import Foundation
import XCTest
@testable import GitCore

/// `GitRevisionArgument` is the only place a caller-supplied revision is
/// allowed to become an element of `Process.arguments`, so its accept/
/// reject boundary is tested directly here; `GitProcessInvocationSpyTests`
/// then proves the argument array `GitBlameService` actually builds
/// matches these decisions.
final class GitRevisionArgumentTests: XCTestCase {
    func testAcceptsOrdinaryRevisionForms() throws {
        let accepted = [
            "HEAD",
            "HEAD~1",
            "HEAD^",
            "HEAD@{1}",
            "main",
            "refs/heads/feature/x",
            "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c",
            "v1.0.0",
            "origin/main"
        ]
        for revision in accepted {
            XCTAssertEqual(try GitRevisionArgument.validated(revision), revision)
        }
    }

    func testRejectsLeadingOptionStrings() {
        for revision in ["-", "--", "--reverse", "-L1,5", "--contents=/etc/passwd"] {
            XCTAssertThrowsError(try GitRevisionArgument.validated(revision)) { error in
                XCTAssertEqual(
                    error as? GitRevisionArgumentError,
                    .leadingOption(revision)
                )
            }
        }
    }

    func testRejectsEmptyAndWhitespaceOnlyRevisions() {
        for revision in ["", " ", "\t\n"] {
            XCTAssertThrowsError(try GitRevisionArgument.validated(revision)) { error in
                XCTAssertEqual(error as? GitRevisionArgumentError, .empty)
            }
        }
    }

    func testRejectsEmbeddedWhitespaceControlAndNulCharacters() {
        for revision in ["HEAD --reverse", "HEAD\nmain", "HEAD\u{0}", "HEAD\u{7F}"] {
            XCTAssertThrowsError(try GitRevisionArgument.validated(revision)) { error in
                XCTAssertEqual(
                    error as? GitRevisionArgumentError,
                    .invalidCharacter(revision)
                )
            }
        }
    }

    func testRejectsUnboundedlyLongRevisions() {
        let revision = String(repeating: "a", count: GitRevisionArgument.maximumLength + 1)
        XCTAssertThrowsError(try GitRevisionArgument.validated(revision)) { error in
            XCTAssertEqual(
                error as? GitRevisionArgumentError,
                .tooLong(count: GitRevisionArgument.maximumLength + 1)
            )
        }
        XCTAssertNoThrow(
            try GitRevisionArgument.validated(
                String(repeating: "a", count: GitRevisionArgument.maximumLength)
            )
        )
    }
}
