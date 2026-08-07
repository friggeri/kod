import Foundation

/// One step into a `StructuredNode` tree: either an object member by key or
/// an array element by index. A full `StructuredPath` (root-to-node list of
/// these) is what "copy key path" (SPEC 10.3) copies to the pasteboard.
public enum StructuredPathComponent: Equatable, Hashable, Sendable {
    case key(String)
    case index(Int)
}

public typealias StructuredPath = [StructuredPathComponent]

extension StructuredPath {
    /// Renders as a JavaScript/JSON-like accessor path, e.g.
    /// `root.items[2].name`, which is what most developers expect to paste
    /// into code. Keys that are not valid bare identifiers fall back to
    /// bracketed string-literal form (`root["odd key"]`).
    public var displayString: String {
        var result = "root"
        for component in self {
            switch component {
            case .key(let key):
                if Self.isValidBareIdentifier(key) {
                    result += ".\(key)"
                } else {
                    let escaped = key
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    result += "[\"\(escaped)\"]"
                }
            case .index(let index):
                result += "[\(index)]"
            }
        }
        return result
    }

    private static func isValidBareIdentifier(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else {
            return false
        }
        return key.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// A single search hit inside a `StructuredNode` tree: the path to the
/// matching node and whether the match was found in its key or its value
/// text.
public struct StructuredSearchMatch: Equatable, Sendable {
    public enum MatchLocation: Equatable, Sendable {
        case key
        case value
    }

    public let path: StructuredPath
    public let location: MatchLocation
    public let node: StructuredNode

    public init(path: StructuredPath, location: MatchLocation, node: StructuredNode) {
        self.path = path
        self.location = location
        self.node = node
    }
}

public enum StructuredSearch {
    /// Maximum matches returned, independent of how large the tree is —
    /// bounding this keeps a pathological "every node matches" search
    /// query from building an unbounded result array (SPEC 11.6: "No
    /// unbounded ... result array").
    public static let maximumMatches = 5_000

    /// Case-insensitive substring search across every object key and every
    /// scalar's `previewText`, walking the tree iteratively (an explicit
    /// stack, not recursion) so a very deep tree cannot overflow the call
    /// stack merely by being searched.
    public static func search(_ root: StructuredNode, query: String) -> [StructuredSearchMatch] {
        guard !query.isEmpty else {
            return []
        }
        let needle = query.lowercased()
        var results: [StructuredSearchMatch] = []
        var stack: [(node: StructuredNode, path: StructuredPath)] = [(root, [])]

        while let (node, path) = stack.popLast() {
            if results.count >= maximumMatches {
                break
            }
            switch node {
            case .object(let members):
                for member in members.reversed() {
                    if member.key.lowercased().contains(needle) {
                        results.append(StructuredSearchMatch(path: path + [.key(member.key)], location: .key, node: member.value))
                    }
                    stack.append((member.value, path + [.key(member.key)]))
                }
            case .array(let elements):
                for (index, element) in elements.enumerated().reversed() {
                    stack.append((element, path + [.index(index)]))
                }
            default:
                if node.previewText.lowercased().contains(needle) {
                    results.append(StructuredSearchMatch(path: path, location: .value, node: node))
                }
            }
        }
        return Array(results.prefix(maximumMatches))
    }
}
