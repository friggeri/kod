import Foundation
import SettingsCore
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
        state.minimapEnabled = false
        state.sidebarSurface = .problems
        _ = state.split(orientation: .vertical)
        state.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(
                x: 120,
                y: 80,
                width: 1_280,
                height: 800
            ),
            sidebarWidth: 286,
            isSidebarCollapsed: true
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testLegacySymbolsSidebarDecodesAsExplorer() throws {
        let decoded = try JSONDecoder().decode(
            WorkspaceSidebarSurface.self,
            from: Data(#""symbols""#.utf8)
        )
        XCTAssertEqual(decoded, .explorer)
        XCTAssertEqual(decoded, .explorer)
    }

    func testWorkspaceLayoutStateDecodesLegacyJSONWithoutGeometry() throws {
        struct LegacyWorkspaceLayoutState: Encodable {
            var root: SplitLayoutNode
            var groups: [EditorGroupID: EditorGroupState]
            var activeGroupID: EditorGroupID
            var wordWrapEnabled: Bool
        }

        let state = WorkspaceLayoutState.singleGroup()
        let legacyState = LegacyWorkspaceLayoutState(
            root: state.root,
            groups: state.groups,
            activeGroupID: state.activeGroupID,
            wordWrapEnabled: state.wordWrapEnabled
        )

        let data = try JSONEncoder().encode(legacyState)
        let decoded = try JSONDecoder().decode(WorkspaceLayoutState.self, from: data)

        XCTAssertEqual(decoded.root, state.root)
        XCTAssertEqual(decoded.groups, state.groups)
        XCTAssertEqual(decoded.activeGroupID, state.activeGroupID)
        XCTAssertNil(decoded.geometry)
        XCTAssertTrue(decoded.minimapEnabled)
        XCTAssertEqual(decoded.sidebarSurface, .explorer)
        XCTAssertNoThrow(try decoded.validate(), "a legacy blob missing only optional fields must remain valid")
    }
}

/// Exercises every case of `WorkspaceLayoutValidationError` that
/// `WorkspaceLayoutState.validate()` can throw. Each test builds an
/// otherwise-valid two-group split state (`makeValidSplitState`) and then
/// corrupts exactly the one invariant under test, so a failure here
/// localizes to a single broken check rather than an interaction between
/// several.
final class WorkspaceLayoutStateValidationTests: XCTestCase {
    /// A minimal, valid two-group horizontal split: `groupA` (root's first
    /// leaf, also `activeGroupID`) has one pinned tab and a matching
    /// navigation entry; `groupB` (root's second leaf) is empty.
    private func makeValidSplitState() -> (
        state: WorkspaceLayoutState,
        groupAID: EditorGroupID,
        groupBID: EditorGroupID,
        tabID: EditorTabID
    ) {
        var groupA = EditorGroupState()
        let tabID = groupA.openTab(relativePath: "Sources/A.swift", pinned: true)
        groupA.recordNavigation(EditorNavigationEntry(relativePath: "Sources/A.swift", viewportAnchorLine: 3))
        let groupB = EditorGroupState()

        let state = WorkspaceLayoutState(
            root: .split(orientation: .horizontal, ratio: 0.5, first: .leaf(groupA.id), second: .leaf(groupB.id)),
            groups: [groupA.id: groupA, groupB.id: groupB],
            activeGroupID: groupA.id
        )
        return (state, groupA.id, groupB.id, tabID)
    }

    func testValidSplitStatePassesValidation() throws {
        let (state, _, _, _) = makeValidSplitState()
        XCTAssertNoThrow(try state.validate())
    }

    func testSingleGroupStatePassesValidation() throws {
        XCTAssertNoThrow(try WorkspaceLayoutState.singleGroup().validate())
    }

    func testDuplicateSplitLeafIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        // Both leaves now name the same group: the tree claims one group
        // occupies two panes simultaneously.
        state.root = .split(orientation: .horizontal, ratio: 0.5, first: .leaf(groupAID), second: .leaf(groupAID))

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.duplicateSplitLeaf(let id) = error else {
                return XCTFail("expected .duplicateSplitLeaf, got \(error)")
            }
            XCTAssertEqual(id, groupAID)
        }
    }

    func testLeafWithoutBackingGroupIsRejected() {
        let (validState, groupAID, groupBID, _) = makeValidSplitState()
        var state = validState
        // Remove groupB's own entry while root still has a leaf for it.
        state.groups.removeValue(forKey: groupBID)

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.splitLeavesGroupsMismatch(let leaves, let groups) = error else {
                return XCTFail("expected .splitLeavesGroupsMismatch, got \(error)")
            }
            XCTAssertEqual(leaves, [groupAID, groupBID])
            XCTAssertEqual(groups, [groupAID])
        }
    }

    func testOrphanedGroupWithNoMatchingLeafIsRejected() {
        let (validState, groupAID, groupBID, _) = makeValidSplitState()
        var state = validState
        // Collapse the tree to a single leaf without removing groupB's
        // dictionary entry, leaving it orphaned.
        state.root = .leaf(groupAID)

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.splitLeavesGroupsMismatch(let leaves, let groups) = error else {
                return XCTFail("expected .splitLeavesGroupsMismatch, got \(error)")
            }
            XCTAssertEqual(leaves, [groupAID])
            XCTAssertEqual(groups, [groupAID, groupBID])
        }
    }

    func testActiveGroupNotFoundIsRejected() {
        let (validState, _, _, _) = makeValidSplitState()
        var state = validState
        let danglingID = EditorGroupID()
        state.activeGroupID = danglingID

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.activeGroupNotFound(let id) = error else {
                return XCTFail("expected .activeGroupNotFound, got \(error)")
            }
            XCTAssertEqual(id, danglingID)
        }
    }

    func testGroupDictionaryKeyMismatchWithItsOwnIDIsRejected() {
        let (validState, groupAID, groupBID, _) = makeValidSplitState()
        var state = validState
        let wrongKey = EditorGroupID()
        // Move groupA's state to a dictionary key that differs from its
        // own `id`, and repoint the tree's leaf/activeGroupID at that same
        // wrong key — so the leaf-set/groups-keys invariant is still
        // satisfied and only the key-vs-id mismatch is exercised.
        guard let groupAState = state.groups.removeValue(forKey: groupAID) else {
            return XCTFail("expected groupA's state to be present")
        }
        state.groups[wrongKey] = groupAState
        state.root = .split(orientation: .horizontal, ratio: 0.5, first: .leaf(wrongKey), second: .leaf(groupBID))
        state.activeGroupID = wrongKey

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.groupKeyMismatch(let key, let actualID) = error else {
                return XCTFail("expected .groupKeyMismatch, got \(error)")
            }
            XCTAssertEqual(key, wrongKey)
            XCTAssertEqual(actualID, groupAID)
        }
    }

    func testNonFiniteSplitRatioIsRejected() {
        for ratio: Double in [.nan, .infinity, -.infinity] {
            let (validState, groupAID, groupBID, _) = makeValidSplitState()
            var state = validState
            state.root = .split(orientation: .horizontal, ratio: ratio, first: .leaf(groupAID), second: .leaf(groupBID))

            XCTAssertThrowsError(try state.validate()) { error in
                guard case WorkspaceLayoutValidationError.invalidSplitRatio(let rejected) = error else {
                    return XCTFail("expected .invalidSplitRatio, got \(error)")
                }
                if !rejected.isNaN {
                    XCTAssertEqual(rejected, ratio)
                }
            }
        }
    }

    func testOutOfRangeSplitRatioIsRejected() {
        for ratio: Double in [0, 1, -0.1, 1.1] {
            let (validState, groupAID, groupBID, _) = makeValidSplitState()
            var state = validState
            state.root = .split(orientation: .horizontal, ratio: ratio, first: .leaf(groupAID), second: .leaf(groupBID))

            XCTAssertThrowsError(try state.validate()) { error in
                guard case WorkspaceLayoutValidationError.invalidSplitRatio(let rejected) = error else {
                    return XCTFail("expected .invalidSplitRatio, got \(error)")
                }
                XCTAssertEqual(rejected, ratio)
            }
        }
    }

    func testDuplicateTabIDWithinGroupIsRejected() {
        let (validState, groupAID, _, tabID) = makeValidSplitState()
        var state = validState
        // Append a second tab reusing the same identity as the first.
        state.groups[groupAID]?.tabs.append(
            EditorTab(id: tabID, relativePath: "Sources/Other.swift", isPinned: true)
        )

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.duplicateTabID(let group, let tab) = error else {
                return XCTFail("expected .duplicateTabID, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
            XCTAssertEqual(tab, tabID)
        }
    }

    func testDuplicateTabRelativePathWithinGroupIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        // A distinct tab identity, but the same `relativePath` as the
        // group's existing tab. `EditorGroupState.openTab` and
        // `insertTransferredTab` explicitly reuse/select the existing tab
        // instead of ever creating this, so it can only arise from state
        // built or corrupted outside those APIs.
        state.groups[groupAID]?.tabs.append(
            EditorTab(relativePath: "Sources/A.swift", isPinned: true)
        )

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.duplicateTabRelativePath(let group, let relativePath) = error else {
                return XCTFail("expected .duplicateTabRelativePath, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
            XCTAssertEqual(relativePath, "Sources/A.swift")
        }
    }

    func testMissingSelectedTabForNonEmptyGroupIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        // groupA has one tab (from makeValidSplitState) but no selection.
        state.groups[groupAID]?.selectedTabID = nil

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.missingSelectedTabForNonEmptyGroup(let group) = error else {
                return XCTFail("expected .missingSelectedTabForNonEmptyGroup, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
        }
    }

    func testEmptyGroupWithNilSelectedTabIsValid() throws {
        // groupB in makeValidSplitState is empty with a `nil`
        // `selectedTabID`; unlike a non-empty group, that is legitimate
        // and must not be rejected.
        let (validState, _, groupBID, _) = makeValidSplitState()
        XCTAssertTrue(validState.groups[groupBID]?.tabs.isEmpty ?? false)
        XCTAssertNil(validState.groups[groupBID]?.selectedTabID)
        XCTAssertNoThrow(try validState.validate())
    }

    func testSelectedTabNotInGroupIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        let danglingTabID = EditorTabID()
        state.groups[groupAID]?.selectedTabID = danglingTabID

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.selectedTabNotInGroup(let group, let tab) = error else {
                return XCTFail("expected .selectedTabNotInGroup, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
            XCTAssertEqual(tab, danglingTabID)
        }
    }

    func testInvertedNavigationSelectionIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        state.groups[groupAID]?.current = EditorNavigationEntry(
            relativePath: "Sources/A.swift",
            selection: EditorSelection(lowerBound: 10, upperBound: 4),
            viewportAnchorLine: 0
        )

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.invalidNavigationSelection(let group) = error else {
                return XCTFail("expected .invalidNavigationSelection, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
        }
    }

    func testNegativeNavigationSelectionBoundIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        state.groups[groupAID]?.backStack = [
            EditorNavigationEntry(
                relativePath: "Sources/A.swift",
                selection: EditorSelection(lowerBound: -1, upperBound: 2),
                viewportAnchorLine: 0
            )
        ]

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.invalidNavigationSelection(let group) = error else {
                return XCTFail("expected .invalidNavigationSelection, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
        }
    }

    func testNegativeViewportAnchorLineIsRejected() {
        let (validState, groupAID, _, _) = makeValidSplitState()
        var state = validState
        state.groups[groupAID]?.forwardStack = [
            EditorNavigationEntry(relativePath: "Sources/A.swift", viewportAnchorLine: -5)
        ]

        XCTAssertThrowsError(try state.validate()) { error in
            guard case WorkspaceLayoutValidationError.invalidViewportAnchorLine(let group) = error else {
                return XCTFail("expected .invalidViewportAnchorLine, got \(error)")
            }
            XCTAssertEqual(group, groupAID)
        }
    }

    func testNonFiniteOrNonPositiveWindowFrameIsRejected() {
        let frames: [WorkspaceWindowFrame] = [
            WorkspaceWindowFrame(x: .nan, y: 0, width: 100, height: 100),
            WorkspaceWindowFrame(x: 0, y: .infinity, width: 100, height: 100),
            WorkspaceWindowFrame(x: 0, y: 0, width: 0, height: 100),
            WorkspaceWindowFrame(x: 0, y: 0, width: 100, height: -1),
        ]
        for frame in frames {
            let (validState, _, _, _) = makeValidSplitState()
            var state = validState
            state.geometry = WorkspaceGeometryState(windowFrame: frame, sidebarWidth: 200, isSidebarCollapsed: false)

            XCTAssertThrowsError(try state.validate()) { error in
                guard case WorkspaceLayoutValidationError.invalidWindowFrame = error else {
                    return XCTFail("expected .invalidWindowFrame for \(frame), got \(error)")
                }
            }
        }
    }

    func testNonFiniteOrNegativeSidebarWidthIsRejected() {
        for sidebarWidth: Double in [.nan, .infinity, -1] {
            let (validState, _, _, _) = makeValidSplitState()
            var state = validState
            state.geometry = WorkspaceGeometryState(
                windowFrame: WorkspaceWindowFrame(x: 0, y: 0, width: 800, height: 600),
                sidebarWidth: sidebarWidth,
                isSidebarCollapsed: false
            )

            XCTAssertThrowsError(try state.validate()) { error in
                guard case WorkspaceLayoutValidationError.invalidSidebarWidth = error else {
                    return XCTFail("expected .invalidSidebarWidth for \(sidebarWidth), got \(error)")
                }
            }
        }
    }

    func testZeroSidebarWidthIsValid() throws {
        let (validState, _, _, _) = makeValidSplitState()
        var state = validState
        state.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 0, y: 0, width: 800, height: 600),
            sidebarWidth: 0,
            isSidebarCollapsed: true
        )
        XCTAssertNoThrow(try state.validate(), "a fully collapsed sidebar is a legitimate zero width")
    }
}

final class WorkspaceLayoutStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> (
        WorkspaceLayoutStore,
        CodableSettingsRepository,
        InMemorySettingsKeyValueStore
    ) {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        return (
            WorkspaceLayoutStore(repository: repository),
            repository,
            keyValueStore
        )
    }

    @MainActor
    func testStoreSavesAndLoadsPerWorkspaceIdentityWithoutTouchingTheRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, _, _) = makeStore()
        XCTAssertEqual(try store.load(for: identity), .absent)

        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Hello.swift", pinned: false)
        try store.save(state, for: identity)

        guard case .value(let loaded, _) = try store.load(for: identity) else {
            return XCTFail("Expected persisted layout")
        }

        XCTAssertEqual(loaded, state)

        let repositoryContents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(repositoryContents.isEmpty, "layout metadata must never be written into the workspace")

        try store.clear(for: identity)
        XCTAssertEqual(try store.load(for: identity), .absent)
    }

    @MainActor
    func testVersionOneLayoutMigratesToExplorerWithoutChangingContentWidth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, _, keyValueStore) = makeStore()
        var legacy = WorkspaceLayoutState.singleGroup()
        legacy.sidebarSurface = .problems
        legacy.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
            sidebarWidth: 240,
            isSidebarCollapsed: false
        )
        let envelope = CodableSettingsEnvelope(version: 1, payload: legacy)
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(envelope)),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        guard case .value(let migrated, let provenance) = try store.load(for: identity) else {
            return XCTFail("Expected migrated layout")
        }
        XCTAssertEqual(provenance, .migrated(from: .version(1), toVersion: 3))
        XCTAssertEqual(migrated.sidebarSurface, .explorer)
        XCTAssertEqual(migrated.geometry?.sidebarWidth, 240)
    }

    @MainActor
    func testVersionTwoActivityRailLayoutRemovesRailWidthAndPreservesSurface() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, _, keyValueStore) = makeStore()
        var railState = WorkspaceLayoutState.singleGroup()
        railState.sidebarSurface = .problems
        railState.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
            sidebarWidth: 284,
            isSidebarCollapsed: false
        )
        let envelope = CodableSettingsEnvelope(version: 2, payload: railState)
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(envelope)),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        guard case .value(let migrated, let provenance) = try store.load(for: identity) else {
            return XCTFail("Expected migrated layout")
        }
        XCTAssertEqual(provenance, .migrated(from: .version(2), toVersion: 3))
        XCTAssertEqual(migrated.sidebarSurface, .problems)
        XCTAssertEqual(migrated.geometry?.sidebarWidth, 240)
    }

    @MainActor
    func testUnversionedLayoutMigrationClampsContentWidthAndPreservesZero() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, _, keyValueStore) = makeStore()
        var legacy = WorkspaceLayoutState.singleGroup()
        legacy.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
            sidebarWidth: 500,
            isSidebarCollapsed: false
        )
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(legacy)),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        guard case .value(let migrated, let provenance) = try store.load(for: identity) else {
            return XCTFail("Expected migrated layout")
        }
        XCTAssertEqual(provenance, .migrated(from: .unversioned, toVersion: 3))
        XCTAssertEqual(migrated.geometry?.sidebarWidth, 420)

        var zeroWidth = WorkspaceLayoutState.singleGroup()
        zeroWidth.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
            sidebarWidth: 0,
            isSidebarCollapsed: true
        )
        try keyValueStore.setValue(
            .data(try JSONEncoder().encode(zeroWidth)),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )
        guard case .value(let migratedZero, _) = try store.load(for: identity) else {
            return XCTFail("Expected zero-width migration")
        }
        XCTAssertEqual(migratedZero.geometry?.sidebarWidth, 0)
    }

    @MainActor
    func testStoreKeepsWindowGeometryIsolatedPerWorkspaceIdentity() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = parent.appendingPathComponent("First", isDirectory: true)
        let secondRoot = parent.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: parent)
        }

        let (store, _, _) = makeStore()

        let firstIdentity = try WorkspaceIdentity(root: firstRoot)
        let secondIdentity = try WorkspaceIdentity(root: secondRoot)
        var firstState = WorkspaceLayoutState.singleGroup()
        firstState.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 10, y: 20, width: 900, height: 600),
            sidebarWidth: 220,
            isSidebarCollapsed: false
        )
        var secondState = WorkspaceLayoutState.singleGroup()
        secondState.geometry = WorkspaceGeometryState(
            windowFrame: WorkspaceWindowFrame(x: 300, y: 200, width: 1_400, height: 900),
            sidebarWidth: 360,
            isSidebarCollapsed: true
        )

        try store.save(firstState, for: firstIdentity)
        try store.save(secondState, for: secondIdentity)

        guard case .value(let loadedFirst, _) =
                try store.load(for: firstIdentity),
              case .value(let loadedSecond, _) =
                try store.load(for: secondIdentity) else {
            return XCTFail("Expected both persisted layouts")
        }
        XCTAssertEqual(loadedFirst.geometry, firstState.geometry)
        XCTAssertEqual(loadedSecond.geometry, secondState.geometry)
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
        let (store, repository, keyValueStore) = makeStore()
        try keyValueStore.setValue(
            .data(Data("not valid json {{{".utf8)),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        guard case .quarantined(let record) =
                try store.load(for: identity) else {
            return XCTFail("Expected corrupt metadata to be quarantined")
        }
        XCTAssertEqual(
            record.key,
            "workspace-layout.\(identity.persistenceKey)"
        )
        XCTAssertEqual(try repository.quarantine.records(), [record])

        // Rebuild: a fresh save/load cycle must succeed, proving the
        // corrupt bytes were actually removed rather than left to fail
        // again on the next launch.
        var state = WorkspaceLayoutState.singleGroup()
        state.activeGroup?.openTab(relativePath: "Sources/Rebuilt.swift", pinned: false)
        try store.save(state, for: identity)
        guard case .value(let rebuilt, _) = try store.load(for: identity) else {
            return XCTFail("Expected rebuilt layout")
        }
        XCTAssertEqual(rebuilt, state)
    }

    @MainActor
    func testSemanticallyInvalidButDecodableLayoutIsQuarantinedAndRebuiltRatherThanReturned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, repository, keyValueStore) = makeStore()

        // This blob decodes perfectly (every field is the right Swift
        // type) but is semantically invalid: `activeGroupID` names a group
        // absent from `groups`. It must be treated identically to a blob
        // that fails to decode at all, not silently handed back to a
        // caller that assumes `groups[activeGroupID]` always exists.
        var invalidState = WorkspaceLayoutState.singleGroup()
        invalidState.activeGroupID = EditorGroupID()
        let data = try JSONEncoder().encode(invalidState)
        try keyValueStore.setValue(
            .data(data),
            forKey: "workspace-layout.\(identity.persistenceKey)"
        )

        guard case .quarantined(let record) =
                try store.load(for: identity) else {
            return XCTFail("Expected semantic quarantine")
        }
        XCTAssertEqual(
            record.key,
            "workspace-layout.\(identity.persistenceKey)"
        )
        XCTAssertTrue(
            record.reason.contains("activeGroupNotFound"),
            "the quarantine reason should reflect the validation failure, not a decode error"
        )

        // Second load must be stable: the corrupt (semantically invalid)
        // bytes were actually removed, so this does not re-quarantine.
        XCTAssertEqual(try store.load(for: identity), .absent)
        XCTAssertEqual(try repository.quarantine.records().count, 1)

        // Rebuild: as with a decode failure, a fresh save/load cycle must
        // succeed once the invalid blob has been cleared.
        var rebuilt = WorkspaceLayoutState.singleGroup()
        rebuilt.activeGroup?.openTab(relativePath: "Sources/Rebuilt.swift", pinned: false)
        try store.save(rebuilt, for: identity)
        guard case .value(let loaded, _) = try store.load(for: identity) else {
            return XCTFail("Expected rebuilt layout")
        }
        XCTAssertEqual(loaded, rebuilt)
    }

    @MainActor
    func testSaveRejectsSemanticallyInvalidStateWithoutPersistingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let identity = try WorkspaceIdentity(root: root)
        let (store, _, keyValueStore) = makeStore()
        let key = "workspace-layout.\(identity.persistenceKey)"

        // A state that would decode and encode perfectly fine, but is
        // semantically invalid per `WorkspaceLayoutState.validate()`: two
        // tabs in the same group sharing a `relativePath`, which
        // `EditorGroupState.openTab`/`insertTransferredTab` never allow.
        // `save` must call `validate()` before ever touching `defaults`,
        // so a bad in-memory state is rejected instead of persisted for a
        // later `load(for:)` to have to quarantine.
        var state = WorkspaceLayoutState.singleGroup()
        let groupID = state.activeGroupID
        state.groups[groupID]?.tabs = [
            EditorTab(relativePath: "Sources/A.swift", isPinned: true),
            EditorTab(relativePath: "Sources/A.swift", isPinned: true),
        ]

        XCTAssertThrowsError(try store.save(state, for: identity)) { error in
            guard case WorkspaceLayoutValidationError.duplicateTabRelativePath(let erroredGroup, let path) = error else {
                return XCTFail("expected .duplicateTabRelativePath, got \(error)")
            }
            XCTAssertEqual(erroredGroup, groupID)
            XCTAssertEqual(path, "Sources/A.swift")
        }

        // Nothing must have been written for the rejected save.
        XCTAssertNil(try keyValueStore.value(forKey: key))
        XCTAssertEqual(try store.load(for: identity), .absent)
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
