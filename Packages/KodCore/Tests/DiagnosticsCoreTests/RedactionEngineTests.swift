import Foundation
import XCTest
@testable import DiagnosticsCore

final class RedactionEngineTests: XCTestCase {
    func testSourceTextCategoryIsAlwaysReplacedRegardlessOfContent() {
        let field = DiagnosticContextField(
            name: "sample",
            category: .sourceText,
            value: "func login(password: String) { print(password) }"
        )

        let redacted = RedactionEngine.redactedValue(for: field)

        XCTAssertEqual(redacted, "<source text redacted>")
        XCTAssertFalse(redacted.contains("password"))
        XCTAssertFalse(redacted.contains("login"))
    }

    func testEachCategoryProducesItsOwnFixedPlaceholder() {
        let categories: [DiagnosticContextField.Category] = [
            .sourceText, .searchTerm, .username, .homePath,
            .fullPath, .repositoryRemote, .symbol, .diagnosticMessage, .environmentSecret
        ]

        var placeholders = Set<String>()
        for category in categories {
            let field = DiagnosticContextField(name: "x", category: category, value: "secret-\(category)")
            let redacted = RedactionEngine.redactedValue(for: field)
            XCTAssertFalse(redacted.contains("secret-"), "\(category) leaked its raw value")
            placeholders.insert(redacted)
        }

        XCTAssertEqual(placeholders.count, categories.count, "each category must have a distinct placeholder")
    }

    func testRedactionIsDeterministicAcrossRepeatedCalls() {
        let field = DiagnosticContextField(name: "q", category: .searchTerm, value: "findThisPassword123")
        let first = RedactionEngine.redactedValue(for: field)
        let second = RedactionEngine.redactedValue(for: field)
        XCTAssertEqual(first, second)
    }

    func testRedactsHomeDirectoryPrefixInFreeformText() {
        let home = NSHomeDirectory()
        let message = "Failed to watch \(home)/Projects/secret-app/config.json"
        let redacted = RedactionEngine.redactFreeformText(message)

        XCTAssertFalse(redacted.contains(home))
        XCTAssertTrue(redacted.contains("<home>") || redacted.contains("<path>"))
    }

    func testRedactsGenericAbsolutePaths() {
        let message = "Could not read /Users/someoneelse/Documents/notes.txt: permission denied"
        let redacted = RedactionEngine.redactFreeformText(message)

        XCTAssertFalse(redacted.contains("someoneelse"))
        XCTAssertFalse(redacted.contains("notes.txt"))
        XCTAssertTrue(redacted.contains("permission denied"), "surrounding prose must be preserved")
    }

    func testRedactsCurrentUsernameToken() throws {
        let user = NSUserName()
        guard !user.isEmpty else {
            throw XCTSkip("no current username available in this environment")
        }
        let message = "Login as \(user) failed"
        let redacted = RedactionEngine.redactCurrentUsername(in: message)
        XCTAssertFalse(redacted.contains(user))
        XCTAssertTrue(redacted.contains("<user>"))
    }

    func testRedactsSSHStyleGitRemote() {
        let message = "Cannot inspect remote git@github.com:acme-corp/private-repo.git"
        let redacted = RedactionEngine.redactFreeformText(message)

        XCTAssertFalse(redacted.contains("acme-corp"))
        XCTAssertFalse(redacted.contains("private-repo"))
        XCTAssertTrue(redacted.contains("<repository remote redacted>"))
    }

    func testRedactsHTTPSGitRemoteWithEmbeddedCredentials() {
        let message = "Push to https://user:ghp_abcdEFGH12345@github.com/acme/app.git failed"
        let redacted = RedactionEngine.redactFreeformText(message)

        XCTAssertFalse(redacted.contains("ghp_abcdEFGH12345"))
        XCTAssertFalse(redacted.contains("acme/app"))
    }

    func testRedactsEnvironmentSecretAssignments() {
        let message = "Spawned process with API_KEY=sk-abc123XYZ and other args"
        let redacted = RedactionEngine.redactFreeformText(message)

        XCTAssertFalse(redacted.contains("sk-abc123XYZ"))
        XCTAssertTrue(redacted.contains("<secret redacted>"))
        XCTAssertTrue(redacted.contains("other args"))
    }

    func testRedactsBareGitHubTokenShapes() {
        let message = "token ghp_1234567890abcdefghij leaked in log"
        let redacted = RedactionEngine.redactFreeformText(message)
        XCTAssertFalse(redacted.contains("ghp_1234567890abcdefghij"))
    }

    func testRedactEventReplacesContextAndScrubsMessage() {
        let event = DiagnosticEvent(
            subsystem: .search,
            level: .warning,
            message: "Search in /Users/adrien/proj timed out",
            context: [
                DiagnosticContextField(name: "term", category: .searchTerm, value: "TODO fixme"),
                DiagnosticContextField(name: "note", category: .general, value: "seen near /Users/adrien/proj/file.txt")
            ]
        )

        let redacted = RedactionEngine.redact(event)

        XCTAssertFalse(redacted.message.contains("adrien"))
        XCTAssertEqual(redacted.context[0].value, "<search term redacted>")
        XCTAssertFalse(redacted.context[1].value.contains("adrien"))
        XCTAssertEqual(redacted.id, event.id)
        XCTAssertEqual(redacted.subsystem, event.subsystem)
        XCTAssertEqual(redacted.level, event.level)
    }

    func testGeneralCategoryStillAppliesFreeformScrubbing() {
        let field = DiagnosticContextField(name: "detail", category: .general, value: "path was /Users/adrien/x")
        let redacted = RedactionEngine.redactedValue(for: field)
        XCTAssertFalse(redacted.contains("adrien"))
    }
}
