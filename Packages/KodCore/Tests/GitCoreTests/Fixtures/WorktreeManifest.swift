import CryptoKit
import Foundation

enum WorktreeManifestError: Error {
    case cannotEnumerate(URL)
}

/// One filesystem entry's identity for immutability comparison: its
/// relative path, POSIX type, size, modification time, and (for regular
/// files) a SHA-256 content hash. Directories and other non-regular
/// entries are still recorded (by type/size/mtime) so an added, removed,
/// or type-changed entry is caught even without a content hash to
/// compare.
struct WorktreeManifestEntry: Equatable {
    let relativePath: String
    let fileType: FileAttributeType
    let size: Int
    let modificationDate: Date?
    /// SHA-256 hex digest of file content for regular files; the
    /// symlink target string for symbolic links; `nil` otherwise
    /// (directories, sockets, etc.).
    let contentHash: String?
}

/// A full, deterministic snapshot of every entry under a root directory
/// — crucially including dotfiles/dot-directories (`.git` itself), since
/// `FileManager.DirectoryEnumerationOptions` defaults never skip hidden
/// entries unless `.skipsHiddenFiles` is explicitly passed (which this
/// intentionally never does).
struct WorktreeManifest: Equatable {
    let entries: [WorktreeManifestEntry]

    static func capture(root: URL) throws -> WorktreeManifest {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw WorktreeManifestError.cannotEnumerate(root)
        }

        let rootPathPrefixCount = root.path.count + 1
        var entries: [WorktreeManifestEntry] = []

        for case let url as URL in enumerator {
            let path = url.path
            let relativePath = path.count > rootPathPrefixCount
                ? String(path.dropFirst(rootPathPrefixCount))
                : url.lastPathComponent

            let attributes = try fileManager.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType ?? .typeUnknown
            let size = attributes[.size] as? Int ?? 0
            let modificationDate = attributes[.modificationDate] as? Date

            var contentHash: String?
            switch type {
            case .typeRegular:
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case .typeSymbolicLink:
                contentHash = try? fileManager.destinationOfSymbolicLink(atPath: path)
            default:
                contentHash = nil
            }

            entries.append(
                WorktreeManifestEntry(
                    relativePath: relativePath,
                    fileType: type,
                    size: size,
                    modificationDate: modificationDate,
                    contentHash: contentHash
                )
            )
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return WorktreeManifest(entries: entries)
    }

    /// Every relative path present in `after` but not `self`, or vice
    /// versa, plus every path present in both whose recorded fields
    /// differ — a human-readable diff for a failing assertion message.
    static func describeDifferences(before: WorktreeManifest, after: WorktreeManifest) -> [String] {
        let beforeByPath = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.relativePath, $0) })
        let afterByPath = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.relativePath, $0) })

        var differences: [String] = []
        for path in Set(beforeByPath.keys).union(afterByPath.keys).sorted() {
            switch (beforeByPath[path], afterByPath[path]) {
            case (nil, .some):
                differences.append("CREATED: \(path)")
            case (.some, nil):
                differences.append("REMOVED: \(path)")
            case (.some(let beforeEntry), .some(let afterEntry)) where beforeEntry != afterEntry:
                if beforeEntry.contentHash != afterEntry.contentHash {
                    differences.append("CONTENT CHANGED: \(path)")
                } else if beforeEntry.modificationDate != afterEntry.modificationDate {
                    differences.append("MTIME CHANGED: \(path) (\(beforeEntry.modificationDate.map(String.init(describing:)) ?? "nil") -> \(afterEntry.modificationDate.map(String.init(describing:)) ?? "nil"))")
                } else {
                    differences.append("CHANGED: \(path)")
                }
            default:
                break
            }
        }
        return differences
    }
}
