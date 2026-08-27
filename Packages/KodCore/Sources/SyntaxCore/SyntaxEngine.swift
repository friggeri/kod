import CTreeSitter
import Foundation
import SourceModel

/// Schedules Tree-sitter parsing and capture computation off the main
/// actor, prioritizing the visible viewport per SPEC 11.6 ("Work is
/// prioritized: visible viewport, active tab, ... then background
/// workspace tasks"). Callers drive this from a cancellable `Task`; letting
/// that task's cancellation propagate here (via `Task.checkCancellation`)
/// is how a closed tab, a new snapshot, or a workspace switch stops
/// obsolete work, per SPEC 11.6.
public actor SyntaxEngine {
    public init() {}

    /// Parses the full snapshot once. This is Kod's only parse per
    /// snapshot version: because Kod is read-only, a changed file always
    /// arrives as a brand-new immutable `SourceSnapshot`, never as an
    /// incremental edit Tree-sitter could apply to a previous tree, so
    /// there is no meaningful "incremental reparse" to perform here.
    ///
    /// The tree is `sending`: this actor keeps no reference to it, so
    /// ownership moves wholesale to the caller's isolation domain rather
    /// than being shared with this one (trees are not thread safe — see
    /// `TSTreeBox`).
    public func parse(snapshot: SourceSnapshot, language: SyntaxLanguage) throws -> sending SyntaxTree {
        try Self.parseTree(snapshot: snapshot, language: language)
    }

    /// The parse itself, which touches no actor state and takes only
    /// `Sendable` inputs. Exposed for callers that are already off the
    /// main thread and want to own the resulting tree in their own
    /// isolation domain directly, without an actor hop and without
    /// transferring a tree between domains at all.
    public nonisolated static func parseTree(
        snapshot: SourceSnapshot,
        language: SyntaxLanguage
    ) throws -> SyntaxTree {
        let treeBox = try TreeSitterParser.parse(utf8: snapshot.utf8Data, language: language)
        let additionalLayers = try Self.additionalLayers(
            primaryTree: treeBox,
            utf8: snapshot.utf8Data,
            language: language
        )
        return SyntaxTree(
            treeBox: treeBox,
            additionalLayers: additionalLayers,
            utf8: snapshot.utf8Data,
            language: language,
            snapshotVersion: snapshot.version
        )
    }

    private static let maximumInjectionRanges = 2_048
    private static let maximumInjectionTraversalNodes = 100_000

    private static func additionalLayers(
        primaryTree: TSTreeBox,
        utf8: Data,
        language: SyntaxLanguage
    ) throws -> [SyntaxTreeLayer] {
        switch language {
        case .markdown:
            return try markdownAdditionalLayers(primaryTree: primaryTree, utf8: utf8)
        case .html:
            return try htmlAdditionalLayers(primaryTree: primaryTree, utf8: utf8)
        default:
            return []
        }
    }

    private static func markdownAdditionalLayers(
        primaryTree: TSTreeBox,
        utf8: Data
    ) throws -> [SyntaxTreeLayer] {
        let root = ts_tree_root_node(primaryTree.pointer)
        var layers: [SyntaxTreeLayer] = []

        let inlineRanges = ranges(
            ofNodesNamed: "inline",
            below: root,
            limit: maximumInjectionRanges
        )
        if !inlineRanges.isEmpty {
            let tree = try TreeSitterParser.parse(
                utf8: utf8,
                language: .markdownInline,
                includedRanges: inlineRanges
            )
            layers.append(SyntaxTreeLayer(treeBox: tree, language: .markdownInline))
        }

        let fencedBlocks = nodes(
            named: "fenced_code_block",
            below: root,
            limit: maximumInjectionRanges
        )
        var injectedRanges: [SyntaxLanguage: [TSRange]] = [:]
        for block in fencedBlocks {
            guard let languageNode = firstDescendant(named: "language", below: block),
                  let contentNode = firstDescendant(named: "code_fence_content", below: block),
                  let injectedLanguage = markdownFenceLanguage(node: languageNode, utf8: utf8) else {
                continue
            }
            injectedRanges[injectedLanguage, default: []].append(range(for: contentNode))
        }
        for injectedLanguage in injectedRanges.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ranges = injectedRanges[injectedLanguage], !ranges.isEmpty else {
                continue
            }
            let tree = try TreeSitterParser.parse(
                utf8: utf8,
                language: injectedLanguage,
                includedRanges: ranges
            )
            layers.append(SyntaxTreeLayer(treeBox: tree, language: injectedLanguage))
        }
        return layers
    }

    private static func htmlAdditionalLayers(
        primaryTree: TSTreeBox,
        utf8: Data
    ) throws -> [SyntaxTreeLayer] {
        let root = ts_tree_root_node(primaryTree.pointer)
        let injectionContainers: [(nodeName: String, language: SyntaxLanguage)] = [
            ("script_element", .javascript),
            ("style_element", .css)
        ]
        var layers: [SyntaxTreeLayer] = []

        for injection in injectionContainers {
            let containers = nodes(
                named: injection.nodeName,
                below: root,
                limit: maximumInjectionRanges
            )
            let ranges = containers.compactMap {
                firstDescendant(named: "raw_text", below: $0).map(range(for:))
            }
            guard !ranges.isEmpty else {
                continue
            }
            let tree = try TreeSitterParser.parse(
                utf8: utf8,
                language: injection.language,
                includedRanges: ranges
            )
            layers.append(
                SyntaxTreeLayer(treeBox: tree, language: injection.language)
            )
        }
        return layers
    }

    private static func markdownFenceLanguage(node: TSNode, utf8: Data) -> SyntaxLanguage? {
        let start = Int(ts_node_start_byte(node))
        let end = Int(ts_node_end_byte(node))
        guard start >= 0, end > start, end <= utf8.count else {
            return nil
        }
        let name = String(decoding: utf8[start..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return switch name {
        case "swift": .swift
        case "ts", "typescript": .typescript
        case "tsx": .tsx
        case "js", "javascript", "jsx": .javascript
        case "html": .html
        case "css": .css
        case "py", "python": .python
        case "rs", "rust": .rust
        case "bash", "sh", "shell": .shell
        case "json": .json
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "c", "h": .c
        case "go": .go
        case "java": .java
        case "ruby", "rb": .ruby
        case "lua": .lua
        case "graphql", "gql": .graphql
        case "xml", "svg", "xsd", "xsl", "xslt": .xml
        default: nil
        }
    }

    private static func ranges(
        ofNodesNamed name: String,
        below root: TSNode,
        limit: Int
    ) -> [TSRange] {
        nodes(named: name, below: root, limit: limit).map(range(for:))
    }

    private static func nodes(named name: String, below root: TSNode, limit: Int) -> [TSNode] {
        var results: [TSNode] = []
        var stack = [root]
        var visited = 0
        while let node = stack.popLast(),
              visited < maximumInjectionTraversalNodes,
              results.count < limit {
            visited += 1
            if nodeType(node) == name {
                results.append(node)
            }
            let childCount = ts_node_named_child_count(node)
            for index in (0..<childCount).reversed() {
                stack.append(ts_node_named_child(node, index))
            }
        }
        return results
    }

    private static func firstDescendant(named name: String, below root: TSNode) -> TSNode? {
        var stack = [root]
        var visited = 0
        while let node = stack.popLast(), visited < maximumInjectionTraversalNodes {
            visited += 1
            if nodeType(node) == name {
                return node
            }
            let childCount = ts_node_named_child_count(node)
            for index in (0..<childCount).reversed() {
                stack.append(ts_node_named_child(node, index))
            }
        }
        return nil
    }

    private static func nodeType(_ node: TSNode) -> String {
        guard let type = ts_node_type(node) else {
            return ""
        }
        return String(cString: type)
    }

    private static func range(for node: TSNode) -> TSRange {
        TSRange(
            start_point: ts_node_start_point(node),
            end_point: ts_node_end_point(node),
            start_byte: ts_node_start_byte(node),
            end_byte: ts_node_end_byte(node)
        )
    }

    /// Computes highlight captures for `viewportByteRange` first, then for
    /// the rest of `fullByteRange`, yielding between the two so a caller
    /// can apply and paint the viewport pass immediately instead of
    /// waiting for the whole file. Throws `CancellationError` (propagated
    /// from the enclosing `Task`) if superseded before either pass
    /// completes.
    ///
    /// `tree` is `sending`: this actor reads it on its own executor while
    /// the caller keeps running, so the caller must hand over a tree it
    /// will not touch again — typically `tree.copy()` of the one it
    /// retains for folding and scope headers. A shared tree read from two
    /// isolation domains at once is exactly what tree-sitter forbids.
    public func highlight(
        tree: sending SyntaxTree,
        viewportByteRange: Range<Int>,
        fullByteRange: Range<Int>
    ) async throws -> (viewport: [SyntaxCapture], full: [SyntaxCapture]) {
        try Task.checkCancellation()
        let viewportCaptures = tree.captures(inByteRange: viewportByteRange)

        try Task.checkCancellation()
        await Task.yield()

        try Task.checkCancellation()
        let fullCaptures = tree.captures(inByteRange: fullByteRange)
        return (viewportCaptures, fullCaptures)
    }
}
