import Foundation

/// A typed source from which Quick Diff can obtain a file baseline.
public enum GitRevisionSource: String, Hashable, Sendable {
    case workingTree
    case index
    case head
}

/// Exact revision content. Working-tree content remains a URL selector so
/// callers can use their normal filesystem/snapshot loading path instead of
/// having Git re-read the file.
public enum GitRevisionContent: Sendable {
    case workingTree(url: URL, path: String)
    case data(source: GitRevisionSource, path: String, bytes: Data)

    public var source: GitRevisionSource {
        switch self {
        case .workingTree:
            .workingTree
        case .data(let source, _, _):
            source
        }
    }

    public var path: String {
        switch self {
        case .workingTree(_, let path), .data(_, let path, _):
            path
        }
    }

    public var bytes: Data? {
        guard case .data(_, _, let bytes) = self else { return nil }
        return bytes
    }
}

public enum GitRevisionContentError: Error, Equatable, Sendable {
    /// `HEAD` does not name a commit yet. This is expected for an added file
    /// staged in a newly initialized repository.
    case unbornHead
    case fileNotFound(source: GitRevisionSource, path: String)
    case contentUnavailable(source: GitRevisionSource, path: String)
    case outputTruncated(source: GitRevisionSource, path: String)
    case processFailed(source: GitRevisionSource, exitCode: Int32, message: String)
}

/// Selects the source-side path from parsed rename/deletion metadata. Clients
/// that already know the exact path can call `revisionContent(source:path:)`
/// directly; this helper prevents accidentally asking Git for a new path
/// which does not exist in an old revision.
public enum GitRevisionPathSelector {
    public static func path(
        for source: GitRevisionSource,
        target: GitDiffTarget,
        change: GitDiffFileChange
    ) -> String? {
        switch source {
        case .workingTree:
            return change.newPath
        case .index:
            switch target {
            case .workingTreeVsIndex:
                switch change.kind {
                case .renamed, .deleted:
                    return change.oldPath
                case .added, .modified, .copied:
                    return change.newPath
                }
            case .indexVsHead, .workingTreeVsHead:
                return change.kind == .deleted ? nil : change.newPath
            }
        case .head:
            switch target {
            case .workingTreeVsIndex:
                return nil
            case .indexVsHead, .workingTreeVsHead:
                switch change.kind {
                case .added:
                    return nil
                case .deleted, .renamed, .modified, .copied:
                    return change.oldPath ?? change.newPath
                }
            }
        }
    }
}

/// Reads index and HEAD blobs via hardened `git cat-file` invocations.
/// Output is bounded, cancellation propagates through `GitProcessRunner`,
/// and nonzero/truncated results are always explicit errors.
public struct GitRevisionContentService: Sendable {
    private let executableURL: URL
    private let repositoryRoot: URL
    private let environment: [String: String]
    private let runner: GitProcessRunner
    private let maximumOutputByteCount: Int

    public init(
        executableURL: URL,
        repositoryRoot: URL,
        environment: [String: String],
        runner: GitProcessRunner = GitProcessRunner(),
        maximumOutputByteCount: Int = 128 * 1_024 * 1_024
    ) {
        self.executableURL = executableURL
        self.repositoryRoot = repositoryRoot
        self.environment = environment
        self.runner = runner
        self.maximumOutputByteCount = maximumOutputByteCount
    }

    public func revisionContent(
        source: GitRevisionSource,
        path: String
    ) async throws -> GitRevisionContent {
        switch source {
        case .workingTree:
            return .workingTree(
                url: repositoryRoot.appendingPathComponent(path),
                path: path
            )
        case .index:
            return .data(
                source: source,
                path: path,
                bytes: try await loadBlob(source: source, path: path, object: ":\(path)")
            )
        case .head:
            try await verifyHeadExists()
            return .data(
                source: source,
                path: path,
                bytes: try await loadBlob(source: source, path: path, object: "HEAD:\(path)")
            )
        }
    }

    public func revisionContent(
        source: GitRevisionSource,
        target: GitDiffTarget,
        diff: GitFileDiff
    ) async throws -> GitRevisionContent {
        guard let path = GitRevisionPathSelector.path(
            for: source,
            target: target,
            change: diff.change
        ) else {
            if source == .head, diff.change.kind == .added, !(try await hasHead()) {
                throw GitRevisionContentError.unbornHead
            }
            throw GitRevisionContentError.contentUnavailable(source: source, path: diff.change.newPath)
        }
        return try await revisionContent(source: source, path: path)
    }

    /// Returns whether `HEAD` currently resolves to a commit.
    public func headExists() async throws -> Bool {
        try await hasHead()
    }

    private func verifyHeadExists() async throws {
        guard try await hasHead() else {
            throw GitRevisionContentError.unbornHead
        }
    }

    private func hasHead() async throws -> Bool {
        let result = try await run(
            .revParse,
            ["--verify", "--quiet", "HEAD^{commit}"],
            maximumOutputByteCount: 256
        )
        if result.standardOutputTruncated {
            throw GitRevisionContentError.outputTruncated(source: .head, path: "HEAD")
        }
        if result.exitCode == 1 {
            return false
        }
        guard result.exitCode == 0 else {
            throw GitRevisionContentError.processFailed(
                source: .head,
                exitCode: result.exitCode,
                message: result.standardErrorMessage
            )
        }
        return true
    }

    private func loadBlob(
        source: GitRevisionSource,
        path: String,
        object: String
    ) async throws -> Data {
        let result = try await run(.catFile, ["blob", object])
        if result.standardOutputTruncated {
            throw GitRevisionContentError.outputTruncated(source: source, path: path)
        }
        guard result.exitCode == 0 else {
            if isMissingObjectError(result.standardErrorMessage) {
                throw GitRevisionContentError.fileNotFound(source: source, path: path)
            }
            throw GitRevisionContentError.processFailed(
                source: source,
                exitCode: result.exitCode,
                message: result.standardErrorMessage
            )
        }
        return result.standardOutput
    }

    private func run(
        _ command: GitReadOnlyCommand,
        _ subcommandArguments: [String],
        maximumOutputByteCount: Int? = nil
    ) async throws -> GitProcessResult {
        let invocation = GitInvocation(
            executableURL: executableURL,
            arguments: GitInvocationHardening.arguments(for: command, arguments: subcommandArguments),
            currentDirectoryURL: repositoryRoot,
            environment: environment,
            maximumOutputByteCount: maximumOutputByteCount ?? self.maximumOutputByteCount
        )
        return try await runner.run(invocation)
    }

    private func isMissingObjectError(_ message: String) -> Bool {
        message.contains("does not exist") || message.contains("not a valid object")
    }
}
