import Foundation
import XCTest
@testable import WorkspaceCore

final class EditorLayoutTests: XCTestCase {
    func testOpenTabReusesUnpinnedPreviewTabUntilPinned() {
        var group = EditorGroupState()

        let firstID = group.openTab(relativePath: "Sources/A.swift", pinned: false)
        XCTAssertEqual(group.tabs.count, 1)
        XCTAssertEqual(group.selectedTabID, firstID)
        XCTAssertFalse(group.tabs[0].isPinned)

        let secondID = group.openTab(relativePath: "Sources/B.swift", pinned: false)
        XCTAssertEqual(group.tabs.count, 1, "A second preview replaces the first tab in place")
        XCTAssertEqual(secondID, firstID, "the preview tab keeps its identity across replacement")
        XCTAssertEqual(group.tabs[0].relativePath, "Sources/B.swift")

        group.pin(secondID)
        let thirdID = group.openTab(relativePath: "Sources/C.swift", pinned: false)
        XCTAssertEqual(group.tabs.count, 2, "a pinned tab is never replaced by a new preview")
        XCTAssertNotEqual(thirdID, secondID)
    }

    func testOpenTabSelectsExistingTabInsteadOfDuplicating() {
        var group = EditorGroupState()
        let firstID = group.openTab(relativePath: "Sources/A.swift", pinned: true)
        group.openTab(relativePath: "Sources/B.swift", pinned: true)

        let reopened = group.openTab(relativePath: "Sources/A.swift", pinned: false)

        XCTAssertEqual(reopened, firstID)
        XCTAssertEqual(group.tabs.count, 2)
        XCTAssertEqual(group.selectedTabID, firstID)
    }

    func testCloseTabSelectsNeighborAndReportsRemainingTabs() {
        var group = EditorGroupState()
        let a = group.openTab(relativePath: "A.swift", pinned: true)
        let b = group.openTab(relativePath: "B.swift", pinned: true)
        let c = group.openTab(relativePath: "C.swift", pinned: true)
        group.selectedTabID = b

        let hasRemaining = group.closeTab(b)

        XCTAssertTrue(hasRemaining)
        XCTAssertEqual(group.tabs.map(\.id), [a, c])
        XCTAssertEqual(group.selectedTabID, c, "closing the selected tab selects the next neighbor")

        XCTAssertTrue(group.closeTab(c))
        XCTAssertEqual(group.selectedTabID, a, "closing the last tab falls back to the previous one")

        XCTAssertFalse(group.closeTab(a))
        XCTAssertNil(group.selectedTabID)
    }

    func testMoveTabReorders() {
        var group = EditorGroupState()
        let a = group.openTab(relativePath: "A.swift", pinned: true)
        let b = group.openTab(relativePath: "B.swift", pinned: true)
        let c = group.openTab(relativePath: "C.swift", pinned: true)

        group.moveTab(a, toIndex: 2)

        XCTAssertEqual(group.tabs.map(\.id), [b, c, a])
    }

    func testTransferredTabMovesBetweenGroupsWithoutDuplicatingPaths() throws {
        var source = EditorGroupState()
        let movedID = source.openTab(relativePath: "Moved.swift", pinned: true)
        var destination = EditorGroupState()
        _ = destination.openTab(relativePath: "Existing.swift", pinned: true)

        let movedTab = try XCTUnwrap(source.removeTabForTransfer(movedID))
        let insertedID = destination.insertTransferredTab(movedTab, at: 1)

        XCTAssertTrue(source.tabs.isEmpty)
        XCTAssertEqual(insertedID, movedID)
        XCTAssertEqual(destination.tabs.map(\.relativePath), ["Existing.swift", "Moved.swift"])
        XCTAssertEqual(destination.selectedTabID, movedID)

        let duplicate = EditorTab(relativePath: "Existing.swift", isPinned: true)
        let existingID = try XCTUnwrap(destination.tabs.first?.id)
        XCTAssertEqual(destination.insertTransferredTab(duplicate, at: 0), existingID)
        XCTAssertEqual(destination.tabs.count, 2)
    }

    func testNavigationBackForwardRestoresSelectionAndAnchor() {
        var group = EditorGroupState()

        group.recordNavigation(
            EditorNavigationEntry(relativePath: "A.swift", selection: EditorSelection(0..<3), viewportAnchorLine: 0)
        )
        group.recordNavigation(
            EditorNavigationEntry(relativePath: "B.swift", selection: EditorSelection(4..<9), viewportAnchorLine: 12)
        )
        XCTAssertFalse(group.canGoForward)
        XCTAssertTrue(group.canGoBack)

        let back = group.goBack()
        XCTAssertEqual(back?.relativePath, "A.swift")
        XCTAssertEqual(back?.selection, EditorSelection(0..<3))
        XCTAssertTrue(group.canGoForward)

        let forward = group.goForward()
        XCTAssertEqual(forward?.relativePath, "B.swift")
        XCTAssertEqual(forward?.viewportAnchorLine, 12)
        XCTAssertFalse(group.canGoForward)

        XCTAssertNil(group.goForward())
    }

    func testRecordNavigationClearsForwardStack() {
        var group = EditorGroupState()
        group.recordNavigation(EditorNavigationEntry(relativePath: "A.swift"))
        group.recordNavigation(EditorNavigationEntry(relativePath: "B.swift"))
        _ = group.goBack()
        XCTAssertTrue(group.canGoForward)

        group.recordNavigation(EditorNavigationEntry(relativePath: "C.swift"))

        XCTAssertFalse(group.canGoForward, "navigating to a new location prunes stale forward history")
    }

    func testUpdateCurrentAnchorRefreshesInPlaceWithoutTouchingHistory() {
        var group = EditorGroupState()
        group.recordNavigation(
            EditorNavigationEntry(relativePath: "A.swift", selection: EditorSelection(0..<1), viewportAnchorLine: 0)
        )
        group.recordNavigation(
            EditorNavigationEntry(relativePath: "B.swift", selection: EditorSelection(0..<1), viewportAnchorLine: 0)
        )
        XCTAssertTrue(group.canGoBack)
        let backStackCountBefore = group.backStack.count

        group.updateCurrentAnchor(selection: EditorSelection(5..<9), viewportAnchorLine: 20)

        XCTAssertEqual(group.current?.relativePath, "B.swift")
        XCTAssertEqual(group.current?.selection, EditorSelection(5..<9))
        XCTAssertEqual(group.current?.viewportAnchorLine, 20)
        XCTAssertEqual(
            group.backStack.count,
            backStackCountBefore,
            "refreshing the live anchor must not push a new Back entry"
        )
    }

    func testSplitCreatesNestedTreeAndActivatesNewGroup() {
        var state = WorkspaceLayoutState.singleGroup()
        let rootGroupID = state.activeGroupID

        let rightGroupID = state.split(orientation: .horizontal)
        XCTAssertEqual(state.activeGroupID, rightGroupID)
        XCTAssertEqual(state.groups.count, 2)
        XCTAssertEqual(
            state.root,
            .split(orientation: .horizontal, ratio: 0.5, first: .leaf(rootGroupID), second: .leaf(rightGroupID))
        )

        let bottomGroupID = state.split(rightGroupID, orientation: .vertical)
        XCTAssertEqual(state.groups.count, 3)
        XCTAssertTrue(state.root.contains(bottomGroupID))
        XCTAssertEqual(Set(state.root.groupIDs), [rootGroupID, rightGroupID, bottomGroupID])
    }

    func testSplitCopiesSelectedFileIntoNewGroupWithIndependentTabIdentity() throws {
        var state = WorkspaceLayoutState.singleGroup()
        let sourceGroupID = state.activeGroupID
        let sourceTabID = state.activeGroup?.openTab(
            relativePath: "Sources/Current.swift",
            pinned: false
        )
        state.activeGroup?.recordNavigation(
            EditorNavigationEntry(
                relativePath: "Sources/Current.swift",
                selection: EditorSelection(4..<8),
                viewportAnchorLine: 12
            )
        )

        let newGroupID = state.split(orientation: .horizontal)
        let copiedTab = try XCTUnwrap(state.groups[newGroupID]?.selectedTab)

        XCTAssertEqual(copiedTab.relativePath, "Sources/Current.swift")
        XCTAssertTrue(copiedTab.isPinned)
        XCTAssertNotEqual(copiedTab.id, sourceTabID)
        XCTAssertEqual(state.groups[newGroupID]?.current?.selection, EditorSelection(4..<8))
        XCTAssertEqual(state.groups[sourceGroupID]?.tabs.count, 1)
    }

    func testCloseGroupCollapsesSplitAndKeepsAtLeastOneGroup() {
        var state = WorkspaceLayoutState.singleGroup()
        let rootGroupID = state.activeGroupID
        let rightGroupID = state.split(orientation: .horizontal)

        state.closeGroup(rightGroupID)

        XCTAssertEqual(state.root, .leaf(rootGroupID))
        XCTAssertEqual(state.groups.count, 1)
        XCTAssertEqual(state.activeGroupID, rootGroupID)

        state.closeGroup(rootGroupID)
        XCTAssertEqual(state.groups.count, 1, "the last remaining group can never be closed")
    }

    func testWorkspaceLayoutStateRoundTripsThroughJSON() throws {
        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/A.swift", pinned: true)
        state.wordWrapEnabled = true
        _ = state.split(orientation: .vertical)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutState.self, from: data)

        XCTAssertEqual(decoded, state)
    }
}

final class WorkspaceLayoutStoreTests: XCTestCase {
    @MainActor
    func testStoreSavesAndLoadsPerWorkspaceIdentityWithoutTouchingTheRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "WorkspaceLayoutStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let store = WorkspaceLayoutStore(defaults: defaults)
        XCTAssertNil(store.load(for: identity))

        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Hello.swift", pinned: false)
        store.save(state, for: identity)

        let loaded = try XCTUnwrap(store.load(for: identity))
        XCTAssertEqual(loaded, state)

        let repositoryContents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(repositoryContents.isEmpty, "layout metadata must never be written into the workspace")

        store.clear(for: identity)
        XCTAssertNil(store.load(for: identity))
    }

    @MainActor
    func testCorruptLayoutMetadataIsQuarantinedAndRebuiltRatherThanIndistinguishableFromAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let suiteName = "WorkspaceLayoutStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let store = WorkspaceLayoutStore(defaults: defaults)
        defaults.set(
            Data("not valid json {{{".utf8),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        XCTAssertNil(store.load(for: identity), "corrupt metadata must fail safe, same as no saved layout")
        XCTAssertEqual(store.quarantine.ledger().count, 1)
        XCTAssertEqual(store.quarantine.ledger()[0].key, "workspace-layout.\(identity.persistenceKey)")

        // Rebuild: a fresh save/load cycle must succeed, proving the
        // corrupt bytes were actually removed rather than left to fail
        // again on the next launch.
        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Rebuilt.swift", pinned: false)
        store.save(state, for: identity)
        XCTAssertEqual(try XCTUnwrap(store.load(for: identity)), state)
    }

    // MARK: - Tombstones

    func testMarkTombstonedFlagsMatchingTabsAcrossAllGroups() {
        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Deleted.swift", pinned: true)
        state.split(orientation: .vertical)
        state.activeGroup?.openTab(relativePath: "Sources/Deleted.swift", pinned: true)
        state.activeGroup?.openTab(relativePath: "Sources/Other.swift", pinned: true)

        state.markTombstoned(relativePath: "Sources/Deleted.swift", reason: .missing)

        for group in state.groups.values {
            for tab in group.tabs where tab.relativePath == "Sources/Deleted.swift" {
                XCTAssertTrue(tab.isTombstoned)
                XCTAssertEqual(tab.tombstoneReason, .missing)
            }
            for tab in group.tabs where tab.relativePath == "Sources/Other.swift" {
                XCTAssertFalse(tab.isTombstoned)
            }
        }
    }

    func testClearTombstoneRestoresNormalTabState() {
        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Flaky.swift", pinned: true)
        state.markTombstoned(relativePath: "Sources/Flaky.swift", reason: .missing)
        XCTAssertTrue(state.activeGroup?.tabs.first?.isTombstoned ?? false)

        state.clearTombstone(relativePath: "Sources/Flaky.swift")

        XCTAssertFalse(state.activeGroup?.tabs.first?.isTombstoned ?? true)
        XCTAssertNil(state.activeGroup?.tabs.first?.tombstoneReason)
    }

    func testTombstoneStateRoundTripsThroughJSON() throws {
        var group = EditorGroupState()
        group.openTab(relativePath: "Sources/Gone.swift", pinned: true)
        group.markTombstoned(relativePath: "Sources/Gone.swift", reason: .missing)

        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(EditorGroupState.self, from: data)

        XCTAssertEqual(decoded, group)
        XCTAssertTrue(decoded.tabs[0].isTombstoned)
    }
}
