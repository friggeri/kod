/// Composites versioned decoration layers into disjoint, styled runs for a
/// requested byte range, applying the SPEC 7.1 precedence order and
/// discarding any layer that was computed for a snapshot other than the
/// currently active one.
///
/// `CodeViewport` drives this from the main actor already (all drawing is
/// `@MainActor`), so the compositor itself is main-actor-bound rather than
/// an independent actor: applying a freshly computed layer and painting
/// with the composed result must never interleave with a snapshot change.
@MainActor
public final class DecorationCompositor {
    public private(set) var activeSnapshotVersion: Int
    private var layers: [DecorationLayerKind: DecorationLayerSnapshot] = [:]

    public init(activeSnapshotVersion: Int) {
        self.activeSnapshotVersion = activeSnapshotVersion
    }

    /// Switches to a new active snapshot, discarding every previously
    /// applied layer. Any in-flight computation still targeting the old
    /// version will be rejected by `apply(_:)` once it completes.
    public func activate(snapshotVersion: Int) {
        guard snapshotVersion != activeSnapshotVersion else {
            return
        }
        activeSnapshotVersion = snapshotVersion
        layers.removeAll()
    }

    /// Applies a freshly computed layer snapshot. Returns `false` (and
    /// leaves state unchanged) when `layer` targets a stale snapshot
    /// version or is itself an out-of-order delivery of an
    /// already-superseded `layerVersion` for its kind.
    @discardableResult
    public func apply(_ layer: DecorationLayerSnapshot) -> Bool {
        guard layer.snapshotVersion == activeSnapshotVersion else {
            return false
        }
        if let existing = layers[layer.kind], existing.layerVersion > layer.layerVersion {
            return false
        }
        layers[layer.kind] = layer
        return true
    }

    public func layerVersion(for kind: DecorationLayerKind) -> Int? {
        layers[kind]?.layerVersion
    }

    public func removeLayer(_ kind: DecorationLayerKind) {
        layers.removeValue(forKey: kind)
    }

    /// Composes every applied layer's contribution to `range` into
    /// minimal, disjoint, fully-merged runs ordered by ascending byte
    /// offset. Ranges with no attributes from any layer are omitted.
    public func composedRuns(inUTF8Range range: Range<Int>) -> [DecorationRun] {
        guard !range.isEmpty else {
            return []
        }

        var boundaries: Set<Int> = [range.lowerBound, range.upperBound]
        var clippedRunsByKind: [(DecorationLayerKind, [DecorationRun])] = []

        for kind in DecorationLayerKind.allCases {
            guard let layer = layers[kind] else {
                continue
            }
            var clipped: [DecorationRun] = []
            clipped.reserveCapacity(layer.runs.count)
            for run in layer.runs {
                let lower = max(run.utf8Range.lowerBound, range.lowerBound)
                let upper = min(run.utf8Range.upperBound, range.upperBound)
                guard lower < upper else {
                    continue
                }
                boundaries.insert(lower)
                boundaries.insert(upper)
                clipped.append(DecorationRun(utf8Range: lower..<upper, attributes: run.attributes))
            }
            if !clipped.isEmpty {
                clippedRunsByKind.append((kind, clipped))
            }
        }

        let sortedBoundaries = boundaries.sorted()
        guard sortedBoundaries.count > 1 else {
            return []
        }

        var results: [DecorationRun] = []
        for index in 0..<(sortedBoundaries.count - 1) {
            let segmentStart = sortedBoundaries[index]
            let segmentEnd = sortedBoundaries[index + 1]
            guard segmentStart < segmentEnd else {
                continue
            }

            var attributes = DecorationAttributes.none
            for (_, runs) in clippedRunsByKind {
                for run in runs
                where run.utf8Range.lowerBound <= segmentStart && run.utf8Range.upperBound >= segmentEnd {
                    attributes = attributes.overlaying(run.attributes)
                }
            }

            guard attributes != .none else {
                continue
            }
            if let last = results.last,
               last.utf8Range.upperBound == segmentStart,
               last.attributes == attributes {
                results[results.count - 1] = DecorationRun(
                    utf8Range: last.utf8Range.lowerBound..<segmentEnd,
                    attributes: attributes
                )
            } else {
                results.append(DecorationRun(utf8Range: segmentStart..<segmentEnd, attributes: attributes))
            }
        }
        return results
    }
}
