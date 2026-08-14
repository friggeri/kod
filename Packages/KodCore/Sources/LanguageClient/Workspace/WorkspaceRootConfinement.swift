import Foundation

/// The workspace boundary every server-reported file path is checked
/// against (SPEC 6/13's read-only, workspace-confined surface). A
/// language server is an external process: nothing it reports — a
/// published diagnostic's URI, a workspace symbol's location — is
/// trusted to be inside the workspace until this type says so.
///
/// Pure and platform-neutral: it holds a root URL and answers path
/// questions about it, with no knowledge of workspace identity,
/// persistence, or trust.
public struct WorkspaceRootConfinement: Equatable, Sendable {
    /// The standardized workspace root.
    public let root: URL
    private let rootPath: String
    private let containedPrefix: String

    public init(root: URL) {
        let standardized = root.standardizedFileURL
        self.root = standardized
        let path = standardized.path
        rootPath = path
        containedPrefix = path.hasSuffix("/") ? path : path + "/"
    }

    /// Whether `url` is the root itself or a descendant of it. Compared
    /// on a full path component boundary, so a sibling directory that
    /// merely shares a textual prefix (`/workspace-backup`) is outside.
    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(containedPrefix)
    }

    /// The standardized file URL for `uri` when it denotes a real file
    /// inside this workspace, or `nil` when it is not a file URI or
    /// falls outside the workspace.
    public func confinedFileURL(for uri: DocumentURI) -> URL? {
        guard let rawURL = uri.fileURL else {
            return nil
        }
        return confinedFileURL(for: rawURL)
    }

    public func confinedFileURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard contains(standardized) else {
            return nil
        }
        return standardized
    }
}
