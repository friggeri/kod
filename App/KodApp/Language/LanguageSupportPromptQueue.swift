import Foundation

/// The plain, view-free state machine behind the workspace's unknown-file-type
/// prompt.
///
/// It owns queueing, de-duplication, per-session suppression ("Not Now"),
/// and which prompt is currently presented. It performs no I/O, touches no
/// views, and never calls the language-support service.
@MainActor
final class LanguageSupportPromptQueue {
    private(set) var currentUnknownFileTypeURL: URL?
    private(set) var isPreparing = false
    private(set) var queuedUnknownFileTypeURLs: [URL] = []
    private(set) var suppressedKeys: Set<String> = []

    /// Deliberately `nonisolated`: the key is a pure function of the file's
    /// extension.
    nonisolated static func unknownLanguageKey(for url: URL) -> String {
        "unknown:\(url.pathExtension.lowercased())"
    }

    // MARK: - Enqueueing

    /// Queues an unknown-file-type prompt. Extension-less files never
    /// prompt: there is nothing a profile could be keyed on.
    @discardableResult
    func enqueueUnknownFileType(url: URL) -> Bool {
        let key = Self.unknownLanguageKey(for: url)
        guard !url.pathExtension.isEmpty,
              !suppressedKeys.contains(key),
              currentUnknownFileTypeURL.map({
                  Self.unknownLanguageKey(for: $0)
              }) != key,
              !queuedUnknownFileTypeURLs.contains(where: {
                  Self.unknownLanguageKey(for: $0) == key
              }) else {
            return false
        }
        queuedUnknownFileTypeURLs.append(url)
        return true
    }

    // MARK: - Presentation lifecycle

    /// Claims the right to present the next prompt. Returns `false` when a
    /// prompt is already showing or another pass is already running, so
    /// two concurrent callers can never race a prompt onto the screen.
    func beginPreparing() -> Bool {
        guard currentUnknownFileTypeURL == nil, !isPreparing else {
            return false
        }
        isPreparing = true
        return true
    }

    func endPreparing() {
        isPreparing = false
    }

    func dequeueUnknownFileTypeCandidate() -> URL? {
        while !queuedUnknownFileTypeURLs.isEmpty {
            let url = queuedUnknownFileTypeURLs.removeFirst()
            if suppressedKeys.contains(Self.unknownLanguageKey(for: url)) {
                continue
            }
            return url
        }
        return nil
    }

    func activateUnknownFileType(_ url: URL) {
        currentUnknownFileTypeURL = url
    }

    /// Resolves the presented prompt, optionally suppressing its key for
    /// the rest of the session ("Not Now").
    func finishCurrent(suppressForSession: Bool) {
        if suppressForSession, let currentUnknownFileTypeURL {
            suppressedKeys.insert(
                Self.unknownLanguageKey(for: currentUnknownFileTypeURL)
            )
        }
        currentUnknownFileTypeURL = nil
    }

    // MARK: - Invalidation

    /// Drops queued and presented prompts when trust is revoked. Session
    /// suppression is intentionally kept.
    func cancelAll() {
        queuedUnknownFileTypeURLs.removeAll()
        currentUnknownFileTypeURL = nil
        isPreparing = false
    }
}
