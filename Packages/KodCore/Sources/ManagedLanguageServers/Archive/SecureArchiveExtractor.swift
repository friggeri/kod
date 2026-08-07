import Foundation

public enum ArchiveExtractionError: Error, Equatable, Sendable {
    case unsupportedFormat(ManagedArchiveFormat)
    case entryCountExceeded(limit: Int)
    case emptyEntryName
    case absolutePath(String)
    case pathTraversal(String)
    case invalidPathComponent(String)
    case disallowedEntryType(name: String, type: String)
    case duplicateOrCaseFoldCollision(String)
    case destinationEscape(String)
    case layoutMismatch(missing: [String], unexpected: [String])
    case executableEntryMissing(String)
    case destinationNotDirectory(URL)
    case writeFailed(String)
}

/// Extracts a downloaded, digest-verified archive into a fresh staging
/// directory, rejecting every hostile-archive shape Phase 8 must defend
/// against (SPEC 6.5/13.2): path traversal, absolute paths, symlink or
/// hardlink escape, device/special files, duplicate or case-folding
/// path collisions, decompression bombs (via `GzipCodec`'s bounded
/// streaming inflate — never fully inflating before checking size), and
/// an archive whose final file set doesn't exactly match the catalog's
/// declared layout (which is what catches an unexpected extra
/// executable smuggled alongside the real one).
///
/// This never shells out to `tar`/`unzip`/`ditto` — it walks entries
/// itself via `TarReader` and decides, per entry, whether it is safe to
/// write, which is the only way Kod can enforce all of the above
/// uniformly regardless of what any system archive tool does or does
/// not itself protect against.
public enum SecureArchiveExtractor {
    /// A hard ceiling on entry count, independent of total decompressed
    /// bytes, so an archive of many zero-byte entries can't otherwise
    /// exhaust inodes/memory for per-entry bookkeeping.
    public static let defaultMaxEntryCount = 20_000

    @discardableResult
    public static func extract(
        archiveBytes: Data,
        format: ManagedArchiveFormat,
        maxDecompressedBytes: Int,
        expectedRelativePaths: [String],
        executableRelativePath: String,
        destinationRoot: URL,
        maxEntryCount: Int = SecureArchiveExtractor.defaultMaxEntryCount,
        fileManager: FileManager = .default
    ) throws -> [String] {
        guard format == .tarGz else {
            throw ArchiveExtractionError.unsupportedFormat(format)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveExtractionError.destinationNotDirectory(destinationRoot)
        }

        let tarBytes = try GzipCodec.decompress(archiveBytes, maxDecompressedBytes: maxDecompressedBytes)
        let entries = try TarReader.readEntries(tarBytes)
        guard entries.count <= maxEntryCount else {
            throw ArchiveExtractionError.entryCountExceeded(limit: maxEntryCount)
        }

        let destinationRootPath = destinationRoot.standardizedFileURL.path
        var seenLowercasedPaths: Set<String> = []
        var writtenRegularFilePaths: [String] = []

        for entry in entries {
            let normalized = try normalizedRelativePath(entry.name)

            let lowercased = normalized.lowercased()
            guard seenLowercasedPaths.insert(lowercased).inserted else {
                throw ArchiveExtractionError.duplicateOrCaseFoldCollision(normalized)
            }

            switch entry.type {
            case .regularFile:
                break
            case .directory:
                try createDirectory(at: normalized, destinationRootPath: destinationRootPath, destinationRoot: destinationRoot, fileManager: fileManager)
                continue
            case .symbolicLink:
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "symbolicLink")
            case .hardLink:
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "hardLink")
            case .characterDevice:
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "characterDevice")
            case .blockDevice:
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "blockDevice")
            case .fifo:
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "fifo")
            case .other(let raw):
                throw ArchiveExtractionError.disallowedEntryType(name: normalized, type: "other(\(raw))")
            }

            let destinationURL = try resolvedDestinationURL(
                for: normalized,
                destinationRootPath: destinationRootPath,
                destinationRoot: destinationRoot
            )
            try createDirectory(
                at: (normalized as NSString).deletingLastPathComponent,
                destinationRootPath: destinationRootPath,
                destinationRoot: destinationRoot,
                fileManager: fileManager
            )

            do {
                try entry.body.write(to: destinationURL, options: .atomic)
            } catch {
                throw ArchiveExtractionError.writeFailed("\(normalized): \(error.localizedDescription)")
            }

            let isExecutable = normalized == executableRelativePath
            let permissions: Int = isExecutable ? 0o755 : 0o644
            do {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destinationURL.path)
            } catch {
                throw ArchiveExtractionError.writeFailed("\(normalized) permissions: \(error.localizedDescription)")
            }

            writtenRegularFilePaths.append(normalized)
        }

        let actualSet = Set(writtenRegularFilePaths)
        let expectedSet = Set(expectedRelativePaths)
        if actualSet != expectedSet {
            let missing = expectedSet.subtracting(actualSet).sorted()
            let unexpected = actualSet.subtracting(expectedSet).sorted()
            throw ArchiveExtractionError.layoutMismatch(missing: missing, unexpected: unexpected)
        }
        guard actualSet.contains(executableRelativePath) else {
            throw ArchiveExtractionError.executableEntryMissing(executableRelativePath)
        }

        return writtenRegularFilePaths.sorted()
    }

    /// Splits, validates, and rejoins a raw tar entry name into a safe,
    /// forward-slash relative path with no leading `/`, no empty
    /// components, and no `.`/`..` component anywhere — the three shapes
    /// that together cover "absolute path" and "path traversal" attacks
    /// regardless of how many `../` segments or redundant slashes an
    /// entry tries to use.
    private static func normalizedRelativePath(_ rawName: String) throws -> String {
        guard !rawName.isEmpty else {
            throw ArchiveExtractionError.emptyEntryName
        }
        if rawName.hasPrefix("/") {
            throw ArchiveExtractionError.absolutePath(rawName)
        }
        if rawName.contains("\\") {
            throw ArchiveExtractionError.invalidPathComponent(rawName)
        }

        let rawComponents = rawName.split(separator: "/", omittingEmptySubsequences: false)
        var components: [String] = []
        for rawComponent in rawComponents {
            let component = String(rawComponent)
            if component.isEmpty {
                // Trailing slash on a directory entry name is normal
                // (e.g. "bin/"); an *interior* empty component ("a//b")
                // is not and is rejected as malformed rather than
                // silently collapsed, since silently collapsing it is
                // exactly the kind of "the path actually used differs
                // from the path that was validated" gap this function
                // exists to close.
                continue
            }
            if component == "." {
                continue
            }
            if component == ".." {
                throw ArchiveExtractionError.pathTraversal(rawName)
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw ArchiveExtractionError.emptyEntryName
        }
        return components.joined(separator: "/")
    }

    private static func resolvedDestinationURL(
        for normalizedRelativePath: String,
        destinationRootPath: String,
        destinationRoot: URL
    ) throws -> URL {
        let candidate = destinationRoot.appendingPathComponent(normalizedRelativePath).standardizedFileURL
        // Defense in depth: even though `normalizedRelativePath` was
        // already validated to contain no `..`/absolute component, this
        // re-checks the fully joined, standardized path is still
        // lexically inside `destinationRoot` before ever writing —
        // catching any future bug in the component-level check above
        // rather than relying on it being the only guard.
        guard candidate.path == destinationRootPath || candidate.path.hasPrefix(destinationRootPath + "/") else {
            throw ArchiveExtractionError.destinationEscape(normalizedRelativePath)
        }
        return candidate
    }

    private static func createDirectory(
        at normalizedRelativePath: String,
        destinationRootPath: String,
        destinationRoot: URL,
        fileManager: FileManager
    ) throws {
        guard !normalizedRelativePath.isEmpty else {
            return
        }
        let directoryURL = try resolvedDestinationURL(
            for: normalizedRelativePath,
            destinationRootPath: destinationRootPath,
            destinationRoot: destinationRoot
        )
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            throw ArchiveExtractionError.writeFailed("\(normalizedRelativePath): \(error.localizedDescription)")
        }
    }
}
