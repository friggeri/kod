import AppKit
import CodeViewport
import GitCore
import LanguageClient
import SourceModel
import WorkspaceCore
import XCTest
@testable import Kod

@MainActor
final class WorkspaceStatusBarViewTests: XCTestCase {
    func testGitPresentationDistinguishesNoRepositoryLoadingCleanDirtyAndUnavailable() {
        let location = repositoryLocation(head: .branch(name: "feature/status-bar"))

        let noRepository = WorkspaceStatusBarView.gitItems(for: .noRepository)
        XCTAssertNil(noRepository.branch)
        XCTAssertNil(noRepository.git)

        let loading = WorkspaceStatusBarView.gitItems(for: .loading)
        XCTAssertNil(loading.branch)
        XCTAssertEqual(loading.git?.text, "Git loading")

        let clean = WorkspaceStatusBarView.gitItems(
            for: .available(
                location: location,
                status: GitStatusSnapshot(entries: [])
            )
        )
        XCTAssertEqual(clean.branch?.text, "feature/status-bar")
        XCTAssertEqual(clean.git?.text, "0 changes")

        let dirty = WorkspaceStatusBarView.gitItems(
            for: .available(
                location: location,
                status: GitStatusSnapshot(entries: [
                    GitStatusEntry(
                        path: "a.swift",
                        shape: .ordinary(
                            indexStatus: .modified,
                            worktreeStatus: .modified
                        )
                    ),
                    GitStatusEntry(path: "b.swift", shape: .untracked),
                    GitStatusEntry(
                        path: "c.swift",
                        shape: .unmerged(
                            code: "UU",
                            base: nil,
                            ours: GitUnmergedStage(mode: "100644", objectID: "1"),
                            theirs: GitUnmergedStage(mode: "100644", objectID: "2")
                        )
                    )
                ])
            )
        )
        XCTAssertEqual(dirty.git?.text, "3 changes")
        XCTAssertTrue(dirty.git?.accessibilityValue.contains("1 staged") == true)
        XCTAssertTrue(dirty.git?.accessibilityValue.contains("1 conflicted") == true)

        let unavailable = WorkspaceStatusBarView.gitItems(
            for: .unavailable(location: location, reason: "status failed")
        )
        XCTAssertEqual(unavailable.branch?.text, "feature/status-bar")
        XCTAssertEqual(unavailable.git?.text, "Git unavailable")
        XCTAssertEqual(unavailable.git?.toolTip, "status failed")
    }

    func testDetachedHeadUsesShortVisibleAndFullAccessibleIdentifiers() {
        let commitID = "0123456789abcdef0123456789abcdef01234567"
        let items = WorkspaceStatusBarView.gitItems(
            for: .available(
                location: repositoryLocation(
                    head: .detached(commitID: commitID)
                ),
                status: GitStatusSnapshot(entries: [])
            )
        )

        XCTAssertEqual(items.branch?.text, "Detached 01234567")
        XCTAssertTrue(
            items.branch?.accessibilityValue.contains(commitID) == true
        )
        XCTAssertTrue(items.branch?.toolTip?.contains(commitID) == true)
    }

    func testEveryLanguageServerStateHasDistinctTextAndExplicitRestartPolicy() {
        let states: [LanguageServerState] = [
            .missing(reason: "missing"),
            .starting,
            .indexing,
            .ready,
            .busy,
            .stopping,
            .stopped,
            .crashed(reason: "crashed"),
            .disabled(reason: "disabled")
        ]
        let texts = states.map {
            WorkspaceStatusBarView.languageServerItem(
                profileName: "Swift",
                state: $0
            ).text
        }
        XCTAssertEqual(Set(texts).count, states.count)

        for state in states {
            let availability = WorkspaceStatusBarView.restartAvailability(
                profileName: "Swift",
                state: state,
                isTrusted: true
            )
            switch state {
            case .missing, .stopped, .crashed, .disabled:
                XCTAssertTrue(availability.visible)
                XCTAssertTrue(availability.enabled)
            case .starting, .indexing, .ready, .busy, .stopping:
                XCTAssertFalse(availability.visible)
                XCTAssertFalse(availability.enabled)
            }
        }
        let untrusted = WorkspaceStatusBarView.restartAvailability(
            profileName: "Swift",
            state: .crashed(reason: "boom"),
            isTrusted: false
        )
        XCTAssertTrue(untrusted.visible)
        XCTAssertFalse(untrusted.enabled)
    }

    func testCursorUsesOneBasedUTF16PositionAndEmojiSelectionLength() throws {
        let snapshot = SourceSnapshot(text: "a😀b\nsecond")
        let item = try XCTUnwrap(
            WorkspaceStatusBarView.cursorItem(
                snapshot: snapshot,
                selectionState: CodeViewportSelectionState(
                    selectedUTF8Range: 1..<5,
                    focusedUTF8Offset: 0
                )
            )
        )

        XCTAssertEqual(item.text, "Ln 1, Col 2, 2 selected")
        XCTAssertEqual(
            item.accessibilityValue,
            "Line 1, Column 2, 2 UTF-16 code units selected"
        )
    }

    func testMinimumWidthPlanKeepsRequiredItemsAndHidesOptionalItemsInOrder() {
        let model = longModel()
        let minimumPlan = WorkspaceStatusBarView.layoutPlan(
            for: model,
            availableWidth: 640
        )

        XCTAssertLessThanOrEqual(minimumPlan.estimatedRequiredWidth, 640)
        XCTAssertTrue(minimumPlan.truncatesBranch)
        XCTAssertFalse(minimumPlan.showsLineEnding)
        XCTAssertFalse(minimumPlan.showsEncoding)
        XCTAssertFalse(minimumPlan.showsLanguage)

        for width in stride(from: CGFloat(1_000), through: 480, by: -20) {
            let plan = WorkspaceStatusBarView.layoutPlan(
                for: model,
                availableWidth: width
            )
            if !plan.showsEncoding {
                XCTAssertFalse(plan.showsLineEnding)
            }
            if !plan.showsLanguage {
                XCTAssertFalse(plan.showsEncoding)
                XCTAssertFalse(plan.showsLineEnding)
            }
        }
    }

    func testStatusBarIsNativeGroupedAndLaysOutAtMinimumWindowWidth() throws {
        let trust = NSButton()
        let statusBar = WorkspaceStatusBarView(trustControl: trust)
        statusBar.frame = NSRect(x: 0, y: 0, width: 640, height: 30)
        statusBar.update(longModel())
        statusBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(statusBar.accessibilityLabel(), "Workspace status")
        XCTAssertEqual(statusBar.material, .contentBackground)
        XCTAssertNotNil(findView(identifier: "workspace.status.branch", in: statusBar))
        XCTAssertFalse(
            try XCTUnwrap(
                findView(
                    identifier: "workspace.languageServerState",
                    in: statusBar
                )
            ).isHidden
        )
        XCTAssertFalse(
            try XCTUnwrap(
                findView(identifier: "workspace.status.cursor", in: statusBar)
            ).isHidden
        )
        XCTAssertFalse(trust.isHidden)
    }

    func testActiveSplitDocumentAndSelectionDriveLiveMetadata() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let controller = WorkspaceViewController(
            identity: try WorkspaceIdentity(root: root),
            dependencies: fixture.environment.makeWorkspaceDependencies()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()

        let firstGroup = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        let firstSnapshot = SourceSnapshot(
            text: "a😀b\r\n",
            url: root.appendingPathComponent("emoji.swift")
        )
        firstGroup.openTab(
            relativePath: "emoji.swift",
            pinned: true,
            snapshot: firstSnapshot
        )
        try firstGroup.currentStatusDocument?
            .cursorDocument?
            .viewport
            .selectUTF8Range(1..<5)
        window.layoutIfNeeded()

        XCTAssertEqual(
            text(identifier: "workspace.status.language", in: controller.view),
            "Swift"
        )
        XCTAssertEqual(
            text(identifier: "workspace.status.encoding", in: controller.view),
            "UTF-8"
        )
        XCTAssertEqual(
            text(identifier: "workspace.status.lineEnding", in: controller.view),
            "CRLF"
        )
        XCTAssertEqual(
            text(identifier: "workspace.status.cursor", in: controller.view),
            "Ln 1, Col 2, 2 selected"
        )

        let firstViewport = try XCTUnwrap(
            firstGroup.currentStatusDocument?.cursorDocument?.viewport
        )
        controller.splitActiveGroupRight(nil)
        let secondGroup = try XCTUnwrap(
            controller.splitContainer.controller(
                for: controller.layoutState.activeGroupID
            )
        )
        secondGroup.openTab(
            relativePath: "second.py",
            pinned: true,
            snapshot: SourceSnapshot(
                text: "print('ok')\n",
                url: root.appendingPathComponent("second.py")
            )
        )
        window.layoutIfNeeded()

        XCTAssertEqual(
            text(identifier: "workspace.status.language", in: controller.view),
            "Python"
        )
        try firstViewport.selectUTF8Range(0..<firstSnapshot.utf8Count)
        XCTAssertEqual(
            text(identifier: "workspace.status.language", in: controller.view),
            "Python",
            "inactive split callbacks must not replace active status"
        )

        controller.closeActiveGroup(nil)
        window.layoutIfNeeded()
        XCTAssertEqual(
            text(identifier: "workspace.status.language", in: controller.view),
            "Swift",
            "closing the active split must rebind status to the surviving split"
        )
    }

    private func longModel() -> WorkspaceStatusBarView.Model {
        WorkspaceStatusBarView.Model(
            branch: WorkspaceStatusBarView.Item(
                text: "[feeaaturee/veery-loong-pseeudooloocaaliizeed-braanch !!!]",
                accessibilityLabel: "Git branch"
            ),
            git: WorkspaceStatusBarView.Item(
                text: "[12 chaangees !!!]",
                accessibilityLabel: "Git changes"
            ),
            languageServer: WorkspaceStatusBarView.Item(
                text: "[TypeeScript/JaavaaScript: Indeexing !!!]",
                accessibilityLabel: "Language server status"
            ),
            showsLanguageServerRestart: true,
            enablesLanguageServerRestart: true,
            language: WorkspaceStatusBarView.Item(
                text: "[TypeeScript/JaavaaScript !!!]",
                accessibilityLabel: "File language"
            ),
            encoding: WorkspaceStatusBarView.Item(
                text: "[UTF-8 !!!]",
                accessibilityLabel: "File encoding"
            ),
            lineEnding: WorkspaceStatusBarView.Item(
                text: "[CRLF !!!]",
                accessibilityLabel: "Line endings"
            ),
            cursor: WorkspaceStatusBarView.Item(
                text: "[Ln 120, Col 84, 12 selected !!!]",
                accessibilityLabel: "Cursor position"
            )
        )
    }

    private func repositoryLocation(
        head: GitHeadState
    ) -> GitRepositoryLocation {
        GitRepositoryLocation(
            workingTreeRoot: URL(fileURLWithPath: "/workspace"),
            gitDirectory: URL(fileURLWithPath: "/workspace/.git"),
            commonDirectory: URL(fileURLWithPath: "/workspace/.git"),
            isBareRepository: false,
            head: head
        )
    }

    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findView(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func text(identifier: String, in view: NSView) -> String? {
        (findView(identifier: identifier, in: view) as? NSTextField)?
            .stringValue
    }
}
