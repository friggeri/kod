import XCTest
@testable import Kod

@MainActor
final class WorkspaceHealthPresenterTests: XCTestCase {
    private final class IntentRecorder {
        var intents: [WorkspaceHealthRecoveryIntent] = []
    }

    private func issue(
        _ subsystem: WorkspaceSubsystem,
        severity: WorkspaceHealthIssue.Severity = .degraded,
        summary: String? = nil,
        actions: [WorkspaceHealthRecoveryActionID] = [.retry]
    ) -> WorkspaceHealthIssue {
        WorkspaceHealthIssue(
            scope: .subsystem(subsystem),
            severity: severity,
            summary: summary ?? subsystem.rawValue,
            reason: "diagnostic reason",
            recoveryActionIDs: actions
        )
    }

    func testOrdersBySeverityThenSubsystemAndNavigatesDeterministically() {
        var health = WorkspaceHealth()
        health.record(issue(.persistence, severity: .degraded))
        health.record(issue(.git, severity: .unavailable))
        health.record(issue(.watcher, severity: .unavailable))
        let presenter = WorkspaceHealthPresenter { _ in }

        presenter.update(health)

        XCTAssertEqual(presenter.presentation?.issue.subsystem, .watcher)
        XCTAssertEqual(presenter.presentation?.positionText, "1 of 3 workspace issues")
        XCTAssertTrue(presenter.presentation?.stateText.hasPrefix("Unavailable") == true)

        presenter.selectNext()
        XCTAssertEqual(presenter.presentation?.issue.subsystem, .git)
        presenter.selectNext()
        XCTAssertEqual(presenter.presentation?.issue.subsystem, .persistence)
        presenter.selectNext()
        XCTAssertEqual(presenter.presentation?.issue.subsystem, .watcher)
    }

    func testRecoveryRoutesTypedIntentForOnlyPresentedFailedIssue() throws {
        var health = WorkspaceHealth()
        health.record(
            issue(
                .watcher,
                severity: .unavailable,
                actions: [.retry, .refresh]
            )
        )
        health.record(issue(.git, severity: .unavailable))
        let recorder = IntentRecorder()
        let presenter = WorkspaceHealthPresenter {
            recorder.intents.append($0)
        }
        presenter.update(health)

        presenter.activate(.retry)
        presenter.activate(.refresh)

        let current = try XCTUnwrap(presenter.presentation?.issue)
        XCTAssertEqual(
            recorder.intents,
            [
                WorkspaceHealthRecoveryIntent(
                    issueID: current.id,
                    actionID: .retry
                ),
                WorkspaceHealthRecoveryIntent(
                    issueID: current.id,
                    actionID: .refresh
                )
            ]
        )
        XCTAssertEqual(current.subsystem, .watcher)
    }

    func testDismissalHidesPresentationWithoutClearingHealth() {
        var health = WorkspaceHealth()
        health.record(issue(.search, severity: .unavailable))
        let presenter = WorkspaceHealthPresenter { _ in }
        presenter.update(health)

        presenter.dismissCurrentIssue()

        XCTAssertNil(presenter.presentation)
        XCTAssertTrue(presenter.view.isHidden)
        XCTAssertEqual(health.degradedSubsystems, [.search])
    }

    func testUpdatedIssueGenerationReappearsAfterDismissal() {
        var health = WorkspaceHealth()
        health.record(issue(.search, severity: .unavailable))
        let presenter = WorkspaceHealthPresenter { _ in }
        presenter.update(health)
        presenter.dismissCurrentIssue()

        health.record(
            issue(
                .search,
                severity: .unavailable,
                summary: "Search failed again"
            )
        )
        presenter.update(health)

        XCTAssertEqual(presenter.presentation?.issue.summary, "Search failed again")
        XCTAssertFalse(presenter.view.isHidden)
    }

    func testLanguageProfileIssuesRemainDistinct() {
        var health = WorkspaceHealth()
        health.record(
            WorkspaceHealthIssue(
                scope: .languageProfile(identifier: "swift"),
                severity: .unavailable,
                summary: "Swift language support is unavailable",
                reason: "missing",
                recoveryActionIDs: [.retry]
            )
        )
        health.record(
            WorkspaceHealthIssue(
                scope: .languageProfile(identifier: "typescript"),
                severity: .degraded,
                summary: "TypeScript language support is unavailable",
                reason: "crashed",
                recoveryActionIDs: [.retry]
            )
        )
        let presenter = WorkspaceHealthPresenter { _ in }

        presenter.update(health)

        XCTAssertEqual(health.issues.count, 2)
        XCTAssertNotEqual(health.issues[0].id, health.issues[1].id)
        XCTAssertEqual(presenter.presentation?.issue.id.rawValue, "language-profile:swift")
        presenter.selectNext()
        XCTAssertEqual(
            presenter.presentation?.issue.id.rawValue,
            "language-profile:typescript"
        )
    }

    func testDiagnosticReasonIsBoundedAndFlattened() {
        let value = WorkspaceHealthIssue(
            scope: .subsystem(.git),
            severity: .degraded,
            summary: "Git failed",
            reason: String(repeating: "x", count: 600) + "\nsecret",
            recoveryActionIDs: [.retry]
        )

        XCTAssertEqual(value.reason.count, WorkspaceHealthIssue.maximumReasonLength)
        XCTAssertFalse(value.reason.contains("\n"))
    }
}
