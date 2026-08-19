import Foundation

public struct EditorTabID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

public struct EditorGroupID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

/// Why an open tab became a tombstone: SPEC 5.6 requires a deleted or
/// moved open file to remain visible as an explicit tombstone tab "until
/// closed or relocated" rather than silently disappearing.
public enum TabTombstoneReason: Equatable, Codable, Sendable {
    /// The file no longer exists at its tab's `relativePath` — either it
    /// was deleted, or moved/renamed to a path Kod has not been told about.
    case missing
}

public struct EditorTab: Equatable, Codable, Sendable {
    public let id: EditorTabID
    public var relativePath: String
    public var isPinned: Bool
    public var tombstoneReason: TabTombstoneReason?

    public init(
        id: EditorTabID = EditorTabID(),
        relativePath: String,
        isPinned: Bool = false,
        tombstoneReason: TabTombstoneReason? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.isPinned = isPinned
        self.tombstoneReason = tombstoneReason
    }

    public var isTombstoned: Bool {
        tombstoneReason != nil
    }
}

/// A UTF-8 byte range within a `SourceSnapshot`, stored as plain bounds so it
/// survives JSON round-tripping independent of `Range`'s Codable support.
public struct EditorSelection: Equatable, Codable, Sendable {
    public var lowerBound: Int
    public var upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public init(_ range: Range<Int>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }

    public var range: Range<Int> {
        lowerBound..<upperBound
    }
}

/// A single Back/Forward navigation waypoint: the file, its selection, and
/// the topmost visible source line at the time of navigation.
public struct EditorNavigationEntry: Equatable, Codable, Sendable {
    public var relativePath: String
    public var selection: EditorSelection?
    public var viewportAnchorLine: Int

    public init(
        relativePath: String,
        selection: EditorSelection? = nil,
        viewportAnchorLine: Int = 0
    ) {
        self.relativePath = relativePath
        self.selection = selection
        self.viewportAnchorLine = viewportAnchorLine
    }
}

/// The state owned by one editor group: its tabs (at most one of which is an
/// unpinned "preview" tab), the selected tab, and independent Back/Forward
/// navigation history.
public struct EditorGroupState: Equatable, Codable, Sendable {
    public var id: EditorGroupID
    public var tabs: [EditorTab]
    public var selectedTabID: EditorTabID?
    public var backStack: [EditorNavigationEntry]
    public var forwardStack: [EditorNavigationEntry]
    public var current: EditorNavigationEntry?

    public init(
        id: EditorGroupID = EditorGroupID(),
        tabs: [EditorTab] = [],
        selectedTabID: EditorTabID? = nil,
        backStack: [EditorNavigationEntry] = [],
        forwardStack: [EditorNavigationEntry] = [],
        current: EditorNavigationEntry? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.backStack = backStack
        self.forwardStack = forwardStack
        self.current = current
    }

    public var selectedTab: EditorTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Opens `relativePath`, reusing and re-pointing the existing unpinned
    /// preview tab unless `pinned` is requested or a tab for the path already
    /// exists (matching single-click preview vs. double-click/pin semantics).
    @discardableResult
    public mutating func openTab(relativePath: String, pinned: Bool) -> EditorTabID {
        if let existing = tabs.first(where: { $0.relativePath == relativePath }) {
            selectedTabID = existing.id
            if pinned {
                pin(existing.id)
            }
            return existing.id
        }

        if !pinned, let previewIndex = tabs.firstIndex(where: { !$0.isPinned }) {
            let existingID = tabs[previewIndex].id
            tabs[previewIndex] = EditorTab(id: existingID, relativePath: relativePath, isPinned: false)
            selectedTabID = existingID
            return existingID
        }

        let tab = EditorTab(relativePath: relativePath, isPinned: pinned)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    public mutating func pin(_ id: EditorTabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        tabs[index].isPinned = true
    }

    /// Marks every open tab for `relativePath` as a tombstone. Called when
    /// an FSEvents-observed delete/move means the file backing that tab no
    /// longer resolves (SPEC 5.6): the tab stays visible and selectable,
    /// but its content is understood to be stale/unavailable until the
    /// user closes it or the path becomes valid again.
    public mutating func markTombstoned(relativePath: String, reason: TabTombstoneReason) {
        for index in tabs.indices where tabs[index].relativePath == relativePath {
            tabs[index].tombstoneReason = reason
        }
    }

    /// Clears a previously set tombstone for `relativePath` (e.g. a file
    /// reappearing at the same path, or the user relocating it there).
    public mutating func clearTombstone(relativePath: String) {
        for index in tabs.indices where tabs[index].relativePath == relativePath {
            tabs[index].tombstoneReason = nil
        }
    }

    /// Closes `id`, selecting the nearest remaining tab. Returns `true` if
    /// the group still has at least one tab afterward.
    @discardableResult
    public mutating func closeTab(_ id: EditorTabID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return !tabs.isEmpty
        }
        tabs.remove(at: index)

        if selectedTabID == id {
            if tabs.indices.contains(index) {
                selectedTabID = tabs[index].id
            } else {
                selectedTabID = tabs.last?.id
            }
        }
        return !tabs.isEmpty
    }

    public mutating func moveTab(_ id: EditorTabID, toIndex destination: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let tab = tabs.remove(at: index)
        let clamped = max(0, min(destination, tabs.count))
        tabs.insert(tab, at: clamped)
    }

    /// Removes a tab while preserving its complete model so another editor
    /// group can insert the same tab identity without reopening it as a new
    /// preview.
    @discardableResult
    public mutating func removeTabForTransfer(_ id: EditorTabID) -> EditorTab? {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return nil
        }
        _ = closeTab(id)
        return tab
    }

    /// Inserts a tab moved from another editor group and selects it. A group
    /// never contains the same path twice; dropping onto a group that already
    /// has the file simply selects that existing tab.
    @discardableResult
    public mutating func insertTransferredTab(
        _ transferredTab: EditorTab,
        at destination: Int
    ) -> EditorTabID {
        if let existing = tabs.first(where: { $0.relativePath == transferredTab.relativePath }) {
            selectedTabID = existing.id
            if transferredTab.isPinned {
                pin(existing.id)
            }
            return existing.id
        }

        var tab = transferredTab
        if !tab.isPinned, tabs.contains(where: { !$0.isPinned }) {
            tab.isPinned = true
        }
        let clamped = max(0, min(destination, tabs.count))
        tabs.insert(tab, at: clamped)
        selectedTabID = tab.id
        return tab.id
    }

    public mutating func recordNavigation(_ entry: EditorNavigationEntry) {
        if let current, current != entry {
            backStack.append(current)
        }
        forwardStack.removeAll()
        current = entry
    }

    /// Refreshes the selection/viewport anchor of the current navigation
    /// entry in place (e.g. right before persisting), without disturbing the
    /// Back/Forward stacks the way `recordNavigation` would.
    public mutating func updateCurrentAnchor(selection: EditorSelection?, viewportAnchorLine: Int) {
        guard current != nil else {
            return
        }
        current?.selection = selection
        current?.viewportAnchorLine = viewportAnchorLine
    }

    public mutating func goBack() -> EditorNavigationEntry? {
        guard let previous = backStack.popLast() else {
            return nil
        }
        if let current {
            forwardStack.append(current)
        }
        current = previous
        return previous
    }

    public mutating func goForward() -> EditorNavigationEntry? {
        guard let next = forwardStack.popLast() else {
            return nil
        }
        if let current {
            backStack.append(current)
        }
        current = next
        return next
    }

    public var canGoBack: Bool {
        !backStack.isEmpty
    }

    public var canGoForward: Bool {
        !forwardStack.isEmpty
    }
}

public enum SplitOrientation: String, Equatable, Codable, Sendable {
    case horizontal
    case vertical
}

public enum WorkspaceSidebarSurface: String, CaseIterable, Hashable, Sendable {
    case explorer
    case search
    case sourceControl
    case problems
}

extension WorkspaceSidebarSurface: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "symbols" {
            self = .explorer
            return
        }
        guard let surface = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown workspace sidebar surface: \(rawValue)"
            )
        }
        self = surface
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WorkspaceWindowFrame: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WorkspaceGeometryState: Equatable, Codable, Sendable {
    public var windowFrame: WorkspaceWindowFrame
    public var sidebarWidth: Double
    public var isSidebarCollapsed: Bool

    public init(
        windowFrame: WorkspaceWindowFrame,
        sidebarWidth: Double,
        isSidebarCollapsed: Bool
    ) {
        self.windowFrame = windowFrame
        self.sidebarWidth = sidebarWidth
        self.isSidebarCollapsed = isSidebarCollapsed
    }
}

/// Every way a successfully *decoded* `WorkspaceLayoutState` can still be
/// semantically invalid — i.e. it satisfied `Codable` (every field parsed
/// as the right Swift type) but violates an invariant the rest of
/// `WorkspaceCore`/`WorkspaceViewController` assume always holds. This is
/// deliberately a throwing validation, not a normalizing one: SPEC 15
/// treats corrupt metadata as something to quarantine-and-rebuild from
/// scratch, not to silently patch. A tree with a duplicated leaf, a group
/// referenced by nothing, or a dangling selection could each be "fixed" in
/// several different plausible ways, and guessing wrong would silently
/// discard the user's actual intent (e.g. picking the wrong surviving
/// duplicate group) — so `WorkspaceLayoutState.validate()` only ever
/// distinguishes "structurally sound" from "reject the whole blob," never
/// repairs in place.
public enum WorkspaceLayoutValidationError: Error, Equatable, Sendable {
    /// The same `EditorGroupID` appears at more than one leaf of `root`.
    case duplicateSplitLeaf(EditorGroupID)
    /// The set of leaf group IDs in `root` does not exactly match the set
    /// of keys in `groups` (either a leaf has no backing group state, or
    /// `groups` contains an orphaned entry no leaf references).
    case splitLeavesGroupsMismatch(leaves: Set<EditorGroupID>, groups: Set<EditorGroupID>)
    /// `activeGroupID` has no entry in `groups`.
    case activeGroupNotFound(EditorGroupID)
    /// A `groups` dictionary entry's key does not equal its own
    /// `EditorGroupState.id`. Every normal mutation (`split`, `closeGroup`,
    /// `activeGroup`'s setter) keeps a group's dictionary key and its `id`
    /// in lockstep, so a mismatch here means the entry was tampered with or
    /// corrupted independently of its key.
    case groupKeyMismatch(key: EditorGroupID, actualID: EditorGroupID)
    /// A split node's `ratio` is NaN/infinite, or outside the open interval
    /// (0, 1).
    case invalidSplitRatio(Double)
    /// Two tabs in the same `EditorGroupState` share an `EditorTabID`.
    case duplicateTabID(group: EditorGroupID, tab: EditorTabID)
    /// Two tabs in the same `EditorGroupState` share a `relativePath`.
    /// `EditorGroupState.openTab`/`insertTransferredTab` explicitly prevent
    /// a group from ever holding the same path twice, so a duplicate here
    /// could only come from state built (or corrupted) outside those APIs.
    case duplicateTabRelativePath(group: EditorGroupID, relativePath: String)
    /// A group's `selectedTabID` does not match any of its own tabs.
    case selectedTabNotInGroup(group: EditorGroupID, tab: EditorTabID)
    /// A group has one or more tabs but a `nil` `selectedTabID`. An empty
    /// group (no tabs) legitimately has no selection; every mutation that
    /// adds a tab (`openTab`, `insertTransferredTab`) also selects it, so a
    /// non-empty group with no selection is otherwise unreachable.
    case missingSelectedTabForNonEmptyGroup(EditorGroupID)
    /// A navigation entry (in `backStack`, `forwardStack`, or `current`) has
    /// a selection whose bounds are negative or inverted
    /// (`lowerBound > upperBound`).
    case invalidNavigationSelection(group: EditorGroupID)
    /// A navigation entry has a negative `viewportAnchorLine`.
    case invalidViewportAnchorLine(group: EditorGroupID)
    /// `geometry.windowFrame` has a non-finite coordinate/dimension, or a
    /// non-positive width/height.
    case invalidWindowFrame
    /// `geometry.sidebarWidth` is non-finite or negative.
    case invalidSidebarWidth
}

/// A binary tree of split editor groups. Leaves are group identifiers;
/// internal nodes describe an orientation, the divider ratio, and the two
/// child subtrees, allowing arbitrarily nested horizontal/vertical splits.
public indirect enum SplitLayoutNode: Equatable, Codable, Sendable {
    case leaf(EditorGroupID)
    case split(orientation: SplitOrientation, ratio: Double, first: SplitLayoutNode, second: SplitLayoutNode)

    public func contains(_ id: EditorGroupID) -> Bool {
        switch self {
        case .leaf(let leafID):
            return leafID == id
        case .split(_, _, let first, let second):
            return first.contains(id) || second.contains(id)
        }
    }

    public var groupIDs: [EditorGroupID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.groupIDs + second.groupIDs
        }
    }

    /// Replaces the leaf for `id` with `node`, used to turn a single group
    /// into a split pane (or nest a split further).
    public func replacingLeaf(_ id: EditorGroupID, with node: SplitLayoutNode) -> SplitLayoutNode {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? node : self
        case .split(let orientation, let ratio, let first, let second):
            return .split(
                orientation: orientation,
                ratio: ratio,
                first: first.replacingLeaf(id, with: node),
                second: second.replacingLeaf(id, with: node)
            )
        }
    }

    /// Removes the leaf for `id`, collapsing its parent split into the
    /// surviving sibling. Returns `nil` when `self` itself is the leaf being
    /// removed (the caller decides how to handle removing the last group).
    public func collapsingLeaf(_ id: EditorGroupID) -> SplitLayoutNode? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case .split(let orientation, let ratio, let first, let second):
            if case .leaf(id) = first {
                return second
            }
            if case .leaf(id) = second {
                return first
            }
            let newFirst = first.collapsingLeaf(id)
            let newSecond = second.collapsingLeaf(id)
            return .split(
                orientation: orientation,
                ratio: ratio,
                first: newFirst ?? first,
                second: newSecond ?? second
            )
        }
    }

    /// Walks every leaf, inserting its group ID into `seen`. Throws the
    /// first duplicate encountered — a group ID appearing at more than one
    /// leaf is structural corruption (the same pane occupying two places in
    /// the split tree simultaneously), not something a validator can guess
    /// how to repair.
    fileprivate func validateUniqueLeaves(seen: inout Set<EditorGroupID>) throws(WorkspaceLayoutValidationError) {
        switch self {
        case .leaf(let id):
            guard seen.insert(id).inserted else {
                throw .duplicateSplitLeaf(id)
            }
        case .split(_, _, let first, let second):
            try first.validateUniqueLeaves(seen: &seen)
            try second.validateUniqueLeaves(seen: &seen)
        }
    }

    /// Validates every divider ratio in the tree: it must be finite (never
    /// NaN/infinite from a bad arithmetic step) and strictly between 0 and
    /// 1, since a ratio at or beyond either edge would collapse one side of
    /// the split to nothing.
    fileprivate func validateRatios() throws(WorkspaceLayoutValidationError) {
        switch self {
        case .leaf:
            return
        case .split(_, let ratio, let first, let second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw .invalidSplitRatio(ratio)
            }
            try first.validateRatios()
            try second.validateRatios()
        }
    }
}

/// The full restorable layout of one workspace window: its split tree, the
/// state of every group in that tree, the currently active group, and the
/// global word-wrap and minimap preferences. Window/sidebar geometry is optional so layout
/// blobs written before geometry persistence was introduced remain decodable.
public struct WorkspaceLayoutState: Equatable, Codable, Sendable {
    public var root: SplitLayoutNode
    public var groups: [EditorGroupID: EditorGroupState]
    public var activeGroupID: EditorGroupID
    public var wordWrapEnabled: Bool
    public var minimapEnabled: Bool
    public var sidebarSurface: WorkspaceSidebarSurface
    public var geometry: WorkspaceGeometryState?

    public init(
        root: SplitLayoutNode,
        groups: [EditorGroupID: EditorGroupState],
        activeGroupID: EditorGroupID,
        wordWrapEnabled: Bool = false,
        minimapEnabled: Bool = true,
        sidebarSurface: WorkspaceSidebarSurface = .explorer,
        geometry: WorkspaceGeometryState? = nil
    ) {
        self.root = root
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.wordWrapEnabled = wordWrapEnabled
        self.minimapEnabled = minimapEnabled
        self.sidebarSurface = sidebarSurface
        self.geometry = geometry
    }

    public static func singleGroup() -> WorkspaceLayoutState {
        let group = EditorGroupState()
        return WorkspaceLayoutState(
            root: .leaf(group.id),
            groups: [group.id: group],
            activeGroupID: group.id,
            wordWrapEnabled: false,
            minimapEnabled: true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case groups
        case activeGroupID
        case wordWrapEnabled
        case minimapEnabled
        case sidebarSurface
        case geometry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(SplitLayoutNode.self, forKey: .root)
        groups = try container.decode([EditorGroupID: EditorGroupState].self, forKey: .groups)
        activeGroupID = try container.decode(EditorGroupID.self, forKey: .activeGroupID)
        wordWrapEnabled = try container.decodeIfPresent(Bool.self, forKey: .wordWrapEnabled) ?? false
        minimapEnabled = try container.decodeIfPresent(Bool.self, forKey: .minimapEnabled) ?? true
        sidebarSurface = try container.decodeIfPresent(
            WorkspaceSidebarSurface.self,
            forKey: .sidebarSurface
        ) ?? .explorer
        geometry = try container.decodeIfPresent(WorkspaceGeometryState.self, forKey: .geometry)
    }

    public var activeGroup: EditorGroupState? {
        get { groups[activeGroupID] }
        set {
            guard let newValue else {
                return
            }
            groups[activeGroupID] = newValue
        }
    }

    /// Splits `groupID` (defaulting to the active group), inserting a new
    /// sibling and making it active. When the source has a selected file, the
    /// new group starts with an independently identified copy of that file.
    @discardableResult
    public mutating func split(
        _ groupID: EditorGroupID? = nil,
        orientation: SplitOrientation,
        ratio: Double = 0.5
    ) -> EditorGroupID {
        let source = groupID ?? activeGroupID
        let sourceGroup = groups[source]
        var newGroup = EditorGroupState()
        if let selectedTab = sourceGroup?.selectedTab {
            let copiedTab = EditorTab(
                relativePath: selectedTab.relativePath,
                isPinned: true,
                tombstoneReason: selectedTab.tombstoneReason
            )
            newGroup.tabs = [copiedTab]
            newGroup.selectedTabID = copiedTab.id
            newGroup.current = sourceGroup?.current?.relativePath == selectedTab.relativePath
                ? sourceGroup?.current
                : EditorNavigationEntry(relativePath: selectedTab.relativePath)
        }
        let newNode = SplitLayoutNode.split(
            orientation: orientation,
            ratio: ratio,
            first: .leaf(source),
            second: .leaf(newGroup.id)
        )
        root = root.replacingLeaf(source, with: newNode)
        groups[newGroup.id] = newGroup
        activeGroupID = newGroup.id
        return newGroup.id
    }

    /// Closes `groupID`, collapsing the split it belonged to. Does nothing if
    /// it is the only remaining group, since a workspace always keeps one
    /// group visible.
    public mutating func closeGroup(_ groupID: EditorGroupID) {
        guard groups.count > 1 else {
            return
        }
        guard let collapsed = root.collapsingLeaf(groupID) else {
            return
        }
        root = collapsed
        groups.removeValue(forKey: groupID)
        if activeGroupID == groupID {
            activeGroupID = root.groupIDs.first ?? groupID
        }
    }

    /// Marks every open tab for `relativePath`, across every split group, as
    /// a tombstone (SPEC 5.6: deleted/moved open files become explicit
    /// tombstone tabs rather than silently disappearing).
    public mutating func markTombstoned(relativePath: String, reason: TabTombstoneReason) {
        for id in groups.keys {
            groups[id]?.markTombstoned(relativePath: relativePath, reason: reason)
        }
    }

    /// Clears a previously set tombstone for `relativePath`, across every
    /// split group.
    public mutating func clearTombstone(relativePath: String) {
        for id in groups.keys {
            groups[id]?.clearTombstone(relativePath: relativePath)
        }
    }

    /// Checks every semantic invariant a decoded `WorkspaceLayoutState`
    /// must hold beyond what `Codable` alone enforces, throwing the first
    /// `WorkspaceLayoutValidationError` found. This never mutates or
    /// normalizes `self` — see the doc comment on
    /// `WorkspaceLayoutValidationError` for why ambiguous structural
    /// corruption is rejected wholesale rather than repaired.
    ///
    /// Checked, in order:
    /// - every leaf of `root` names a distinct `EditorGroupID`;
    /// - the set of those leaf IDs is *exactly* `groups.keys` (no leaf
    ///   without a group, no orphaned group no leaf references);
    /// - `activeGroupID` resolves to an entry in `groups`;
    /// - every split's `ratio` is finite and strictly between 0 and 1;
    /// - within each group: its dictionary key equals its own `id`; tab
    ///   IDs are unique; tab `relativePath`s are unique (`openTab`/
    ///   `insertTransferredTab` never allow a group to hold the same path
    ///   twice); `selectedTabID`, if set, names one of that group's own
    ///   tabs, and a group with any tabs always has a `selectedTabID` (only
    ///   an empty group may have `nil`);
    /// - every navigation entry's selection bounds are non-negative and
    ///   non-inverted, and its `viewportAnchorLine` is non-negative;
    /// - `geometry`, if present, has a finite window frame with positive
    ///   width/height and a finite, non-negative `sidebarWidth`.
    public func validate() throws(WorkspaceLayoutValidationError) {
        var leafIDs = Set<EditorGroupID>()
        try root.validateUniqueLeaves(seen: &leafIDs)

        let groupKeys = Set(groups.keys)
        guard leafIDs == groupKeys else {
            throw .splitLeavesGroupsMismatch(leaves: leafIDs, groups: groupKeys)
        }

        guard groups[activeGroupID] != nil else {
            throw .activeGroupNotFound(activeGroupID)
        }

        try root.validateRatios()

        for (groupID, group) in groups {
            guard group.id == groupID else {
                throw .groupKeyMismatch(key: groupID, actualID: group.id)
            }

            var tabIDs = Set<EditorTabID>()
            var relativePaths = Set<String>()
            for tab in group.tabs {
                guard tabIDs.insert(tab.id).inserted else {
                    throw .duplicateTabID(group: groupID, tab: tab.id)
                }
                guard relativePaths.insert(tab.relativePath).inserted else {
                    throw .duplicateTabRelativePath(group: groupID, relativePath: tab.relativePath)
                }
            }

            switch group.selectedTabID {
            case .some(let selectedTabID):
                guard tabIDs.contains(selectedTabID) else {
                    throw .selectedTabNotInGroup(group: groupID, tab: selectedTabID)
                }
            case .none:
                guard group.tabs.isEmpty else {
                    throw .missingSelectedTabForNonEmptyGroup(groupID)
                }
            }

            let navigationEntries = group.backStack + group.forwardStack + [group.current].compactMap { $0 }
            for entry in navigationEntries {
                if let selection = entry.selection,
                   selection.lowerBound < 0 || selection.lowerBound > selection.upperBound {
                    throw .invalidNavigationSelection(group: groupID)
                }
                if entry.viewportAnchorLine < 0 {
                    throw .invalidViewportAnchorLine(group: groupID)
                }
            }
        }

        if let geometry {
            let frame = geometry.windowFrame
            guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else {
                throw .invalidWindowFrame
            }
            guard geometry.sidebarWidth.isFinite, geometry.sidebarWidth >= 0 else {
                throw .invalidSidebarWidth
            }
        }
    }
}
