import CoreGraphics

struct GutterLaneLayout: Equatable {
    let lineNumbers: CGRect
    let gitStatus: CGRect
    let folding: CGRect
}

/// Validates and indexes gutter markers independently from drawing and hit
/// testing. Equal layer versions remain replaceable, matching decoration layers.
struct GutterModel {
    static let minimumWidth: CGFloat = 64
    static let leadingPadding: CGFloat = 8
    static let laneSpacing: CGFloat = 4
    static let diffLaneWidth: CGFloat = 6
    static let foldLaneWidth: CGFloat = 16
    static let trailingPadding: CGFloat = 4
    static let primaryMarkerWidth: CGFloat = 4
    static let secondaryMarkerWidth: CGFloat = 3

    private(set) var changes: [CodeGutterChange] = []
    private var lineChanges: [CodeGutterChange] = []
    private var deletionChangesByAnchor: [Int: [CodeGutterChange]] = [:]
    private var layerVersion = -1

    @discardableResult
    mutating func apply(
        _ changes: [CodeGutterChange],
        snapshotVersion: Int,
        activeSnapshotVersion: Int,
        layerVersion: Int,
        lineCount: Int
    ) -> Bool {
        guard snapshotVersion == activeSnapshotVersion, layerVersion >= self.layerVersion else {
            return false
        }
        let valid = changes.allSatisfy { change in
            switch change.location {
            case .lines(let range):
                return !range.isEmpty
                    && range.lowerBound >= 0
                    && range.upperBound <= lineCount
                    && change.kind != .deleted
            case .deletion(let afterLine):
                return change.kind == .deleted
                    && afterLine >= -1
                    && afterLine < lineCount
            }
        }
        guard valid else {
            return false
        }

        self.changes = changes
        lineChanges = changes.filter {
            if case .lines = $0.location { return true }
            return false
        }.sorted(by: Self.sort)
        let deletions = changes.filter {
            if case .deletion = $0.location { return true }
            return false
        }.sorted(by: Self.sort)
        deletionChangesByAnchor = Dictionary(grouping: deletions) { change in
            if case .deletion(let afterLine) = change.location {
                return afterLine
            }
            return -1
        }
        self.layerVersion = layerVersion
        return true
    }

    mutating func clear() {
        changes = []
        lineChanges = []
        deletionChangesByAnchor = [:]
        layerVersion = -1
    }

    func lineChange(at line: Int) -> CodeGutterChange? {
        guard !lineChanges.isEmpty else {
            return nil
        }
        var lowerBound = 0
        var upperBound = lineChanges.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if Self.position(lineChanges[midpoint]) <= line {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        var index = lowerBound - 1
        var secondaryMatch: CodeGutterChange?
        while index >= 0 {
            let change = lineChanges[index]
            guard case .lines(let range) = change.location else {
                index -= 1
                continue
            }
            if range.upperBound <= line {
                break
            }
            if range.contains(line) {
                if change.layer == .primary {
                    return change
                }
                secondaryMatch = secondaryMatch ?? change
            }
            index -= 1
        }
        return secondaryMatch
    }

    func deletion(afterLine: Int) -> CodeGutterChange? {
        let matches = deletionChangesByAnchor[afterLine] ?? []
        return matches.first(where: { $0.layer == .primary }) ?? matches.first
    }

    static func requiredWidth(lineNumberWidth: CGFloat) -> CGFloat {
        let fixedWidth = leadingPadding + laneSpacing + diffLaneWidth
            + laneSpacing + foldLaneWidth + trailingPadding
        return max(minimumWidth, lineNumberWidth + fixedWidth)
    }

    static func laneLayout(width: CGFloat, height: CGFloat) -> GutterLaneLayout {
        let folding = CGRect(
            x: width - trailingPadding - foldLaneWidth,
            y: 0,
            width: foldLaneWidth,
            height: height
        )
        let gitStatus = CGRect(
            x: folding.minX - laneSpacing - diffLaneWidth,
            y: 0,
            width: diffLaneWidth,
            height: height
        )
        return GutterLaneLayout(
            lineNumbers: CGRect(
                x: leadingPadding,
                y: 0,
                width: max(0, gitStatus.minX - laneSpacing - leadingPadding),
                height: height
            ),
            gitStatus: gitStatus,
            folding: folding
        )
    }

    static func markerRect(
        in lane: CGRect,
        layer: CodeGutterChange.Layer,
        y: CGFloat,
        height: CGFloat
    ) -> CGRect {
        switch layer {
        case .primary:
            CGRect(x: lane.minX + 1, y: y, width: primaryMarkerWidth, height: height)
        case .secondary:
            CGRect(x: lane.minX + 2, y: y, width: secondaryMarkerWidth, height: height)
        }
    }

    private static func sort(_ lhs: CodeGutterChange, _ rhs: CodeGutterChange) -> Bool {
        let lhsPosition = position(lhs)
        let rhsPosition = position(rhs)
        if lhsPosition != rhsPosition {
            return lhsPosition < rhsPosition
        }
        if lhs.layer != rhs.layer {
            return lhs.layer == .primary
        }
        return lhs.id < rhs.id
    }

    private static func position(_ change: CodeGutterChange) -> Int {
        switch change.location {
        case .lines(let range): range.lowerBound
        case .deletion(let afterLine): afterLine
        }
    }
}
