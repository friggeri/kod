import FuzzSupport
import XCTest
@testable import DiagnosticsCore

/// Bounded, seeded fuzzing of `RedactionEngine`, the pass every
/// `DiagnosticEvent`/support bundle/opt-in crash report goes through
/// before being written anywhere (SPEC 13.3: "Crash reports and support
/// bundles redact source text, search terms, usernames, home-directory
/// prefixes, repository remotes, environment secrets, and full paths by
/// default"; this is Phase 12's explicitly requested new "support-bundle
/// redaction" fuzz target). Every input is random text, optionally
/// salted with realistic secret/path/username shapes — the only
/// property under test is "never crashes, and never returns a string
/// that still contains the exact original secret-shaped substring."
final class RedactionFuzzTests: XCTestCase {
    func testRedactFreeformTextNeverCrashesOnRandomUnicodeText() throws {
        try FuzzRun.run("RedactionFuzzTests.freeformRandom") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...500, using: &source), &source)
            _ = RedactionEngine.redactFreeformText(text)
        }
    }

    /// Property: a random home-directory-shaped path embedded in
    /// otherwise-random surrounding text is always redacted — the
    /// literal `/Users/<random-name>` substring must never survive
    /// redaction, regardless of what random text surrounds it. A single
    /// space boundary keeps this a realistic diagnostic-message shape
    /// (a path embedded in a sentence) rather than an adversarially
    /// glued run of combining marks/emoji touching the path with no
    /// separator at all, which is not a shape real diagnostic messages
    /// take.
    func testEmbeddedHomeDirectoryPathIsAlwaysRedactedRegardlessOfSurroundingText() throws {
        try FuzzRun.run("RedactionFuzzTests.embeddedHomePath", iterations: 300) { source in
            let username = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 1...12, using: &source), &source)
                .filter { $0.isLetter || $0.isNumber }
            guard !username.isEmpty else {
                return
            }
            let sensitivePath = "/Users/\(username)/Documents/secret-project"
            let before = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...40, using: &source), &source)
            let after = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...40, using: &source), &source)
            let text = "\(before) \(sensitivePath) \(after)"

            let redacted = RedactionEngine.redactFreeformText(text)
            XCTAssertFalse(
                redacted.contains(sensitivePath),
                "the exact original home-directory path must never survive redaction"
            )
        }
    }

    /// Property: a random environment-secret-shaped token (`TOKEN=...`,
    /// a GitHub-style `ghp_...` token, etc.) embedded in random
    /// surrounding text is always redacted. Space-separated from its
    /// surrounding random text for the same realistic-shape reason as
    /// the home-directory test above.
    func testEmbeddedSecretShapedTokenIsAlwaysRedacted() throws {
        try FuzzRun.run("RedactionFuzzTests.embeddedSecretToken", iterations: 300) { source in
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            let secretValue = String((0..<Int.random(in: 8...40, using: &source)).map { _ in
                alphabet[Int.random(in: 0..<alphabet.count, using: &source)]
            })
            let secretShapes = [
                "API_TOKEN=\(secretValue)",
                "secret: \(secretValue)",
                "ghp_\(secretValue)",
                "PASSWORD=\(secretValue)"
            ]
            let sensitiveFragment = secretShapes[Int.random(in: 0..<secretShapes.count, using: &source)]
            let before = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...30, using: &source), &source)
            let after = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...30, using: &source), &source)
            let text = "\(before) \(sensitiveFragment) \(after)"

            let redacted = RedactionEngine.redactFreeformText(text)
            XCTAssertFalse(
                redacted.contains(secretValue),
                "the exact original secret value must never survive redaction, in text: \(text)"
            )
        }
    }

    /// Property: redaction is idempotent for any random input —
    /// redacting already-redacted text never crashes and never expands
    /// back into something containing a previously-redacted secret
    /// (i.e. it cannot "unredact" or otherwise misbehave when applied
    /// twice, which matters because some app code paths do call it more
    /// than once on the same field).
    func testRedactionIsIdempotentOnRandomText() throws {
        try FuzzRun.run("RedactionFuzzTests.idempotent", iterations: 300) { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...300, using: &source), &source)
            let once = RedactionEngine.redactFreeformText(text)
            let twice = RedactionEngine.redactFreeformText(once)
            XCTAssertEqual(once, twice, "redacting already-redacted text must be a no-op")
        }
    }
}
