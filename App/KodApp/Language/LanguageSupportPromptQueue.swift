import Foundation

/// The plain, view-free state machine behind the workspace's
/// missing-language-server / unknown-file-type prompt.
///
/// It owns queueing, de-duplication, per-session suppression ("Not Now"),
/// the generation counter that invalidates in-flight resolution when
/// profiles change, and which prompt is currently presented. It performs
/// no I/O, touches no views, and never calls the language-support
/// service — the presenter awaits discovery and feeds results back in, so
/// every queueing rule here is deterministic and testable on its own.
@MainActor
final class LanguageSupportPromptQueue {
    enum Prompt: Equatable {
        /// A known profile whose server executable could not be found.
        case missingServer(languageKey: String)
        /// A file whose extension matches no profile at all.
        case unknownFileType(url: URL)

        var languageKey: String {
            switch self {
            case .missingServer(let languageKey):
                return languageKey
            case .unknownFileType(let url):
                return LanguageSupportPromptQueue.unknownLanguageKey(for: url)
            }
        }

        var unknownFileTypeURL: URL? {
            switch self {
            case .missingServer:
                return nil
            case .unknownFileType(let url):
                return url
            }
        }
    }

    private(set) var current: Prompt?
    /// Bumped whenever profile configuration changes. Resolution work
    /// started under an older generation is discarded rather than shown.
    private(set) var generation = 0
    private(set) var isPreparing = false
    private(set) var queuedMissingServerKeys: [String] = []
    private(set) var queuedUnknownFileTypeURLs: [URL] = []
    private(set) var suppressedKeys: Set<String> = []

    var currentMissingServerKey: String? {
        guard case .missingServer(let languageKey) = current else {
            return nil
        }
        return languageKey
    }

    var currentUnknownFileTypeURL: URL? {
        current?.unknownFileTypeURL
    }

    /// Deliberately `nonisolated`: the key is a pure function of the
    /// file's extension, and `Prompt` (a nested type, which does not
    /// inherit this class's isolation) derives its key from it.
    nonisolated static func unknownLanguageKey(for url: URL) -> String {
        "unknown:\(url.pathExtension.lowercased())"
    }

    // MARK: - Enqueueing

    /// Queues a missing-server prompt. Returns `false` when the key is
    /// suppressed for this session, already presented, or already queued.
    @discardableResult
    func enqueueMissingServer(languageKey: String) -> Bool {
        guard !suppressedKeys.contains(languageKey),
              current?.languageKey != languageKey,
              !queuedMissingServerKeys.contains(languageKey) else {
            return false
        }
        queuedMissingServerKeys.append(languageKey)
        return true
    }

    /// Queues an unknown-file-type prompt. Extension-less files never
    /// prompt: there is nothing a profile could be keyed on.
    @discardableResult
    func enqueueUnknownFileType(url: URL) -> Bool {
        let key = Self.unknownLanguageKey(for: url)
        guard !url.pathExtension.isEmpty,
              !suppressedKeys.contains(key),
              current?.languageKey != key,
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
    /// two concurrent callers can never race a banner onto the screen.
    func beginPreparing() -> Bool {
        guard current == nil, !isPreparing else {
            return false
        }
        isPreparing = true
        return true
    }

    func endPreparing() {
        isPreparing = false
    }

    /// Pops the next candidate missing-server key, skipping any suppressed
    /// while it sat in the queue.
    func dequeueMissingServerCandidate() -> String? {
        while !queuedMissingServerKeys.isEmpty {
            let languageKey = queuedMissingServerKeys.removeFirst()
            if suppressedKeys.contains(languageKey) {
                continue
            }
            return languageKey
        }
        return nil
    }

    /// Returns a candidate to the front of the queue when the generation it
    /// was resolved under went stale.
    func requeueMissingServerCandidate(_ languageKey: String) {
        guard !queuedMissingServerKeys.contains(languageKey) else {
            return
        }
        queuedMissingServerKeys.insert(languageKey, at: 0)
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

    func activate(_ prompt: Prompt) {
        current = prompt
    }

    /// Resolves the presented prompt, optionally suppressing its key for
    /// the rest of the session ("Not Now").
    func finishCurrent(suppressForSession: Bool) {
        if suppressForSession, let key = current?.languageKey {
            suppressedKeys.insert(key)
        }
        current = nil
    }

    // MARK: - Invalidation

    func bumpGeneration() {
        generation &+= 1
    }

    func removeQueuedMissingServer(languageKey: String) {
        queuedMissingServerKeys.removeAll { $0 == languageKey }
    }

    /// Drops everything (queues, current prompt) and invalidates in-flight
    /// resolution — used when trust is revoked, which must never leave a
    /// stale prompt behind. Session suppression is intentionally kept.
    func cancelAll() {
        bumpGeneration()
        queuedMissingServerKeys.removeAll()
        queuedUnknownFileTypeURLs.removeAll()
        current = nil
        isPreparing = false
    }
}
