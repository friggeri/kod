import Foundation
import XCTest
@testable import Kod

/// A pragmatic, regex/line-scanning static-analysis test (deliberately
/// *not* a full Swift parser — see the task's own framing) that fails
/// the build if a new hard-coded, user-facing string literal is
/// introduced into `App/KodApp/*.swift` without going through this
/// project's localization mechanism (`Localized.string(_:comment:)`,
/// or a SwiftUI `Text`/`Label`/etc. literal, which auto-localizes
/// against the String Catalog via its `LocalizedStringKey` initializer
/// overload — confirmed against the SDK's real overload behavior while
/// migrating `SettingsView.swift`, the first file migrated in this
/// pass).
///
/// ## What counts as a "sink" (a place user-facing text reaches the UI)
///
/// Only APIs/patterns that do **not** have a `LocalizedStringKey`-typed
/// overload are treated as sinks — i.e. exactly the call sites this
/// migration had to wrap in `Localized.string(_:comment:)`:
///
/// 1. SwiftUI accessibility modifiers with a bare string literal:
///    `.accessibilityLabel("...")`, `.accessibilityHint("...")`,
///    `.accessibilityValue("...")`. (Their `Text`/`LocalizedStringKey`
///    overloads, or a `String(localized:)`/`Localized.string(...)`
///    argument, are compliant and simply don't match this pattern,
///    since the check only matches when a literal quote directly
///    follows the sink token.)
/// 2. AppKit accessibility setters with a bare literal argument:
///    `setAccessibilityLabel("...")`, `setAccessibilityHelp("...")`,
///    `setAccessibilityValue("...")`, `setAccessibilityRoleDescription("...")`.
/// 3. AppKit control construction with a bare literal `title:` argument:
///    `NSButton(title: "...", ...)`, `NSMenuItem(title: "...", ...)`.
/// 4. Bare literal assignment to a `.title`, `.messageText`, or
///    `.informativeText` property (panel/menu-item/alert titles and
///    alert body text).
/// 5. `accessibilityLabel()`/`accessibilityHelp()`/
///    `accessibilityRoleDescription()` **override** bodies that
///    `return` a bare string literal directly (none exist in the
///    current tree, but the pattern is still checked so a future
///    override can't slip a hard-coded string past this test).
///
/// `Text("...")`, `Label("...", systemImage:)`, `Picker`, `Toggle`,
/// `Button`, `TextField`, and `Section` with a bare string literal are
/// **intentionally not sinks**: per Apple's `Text` documentation (and
/// confirmed empirically while migrating this codebase), a plain
/// string literal handed to these SwiftUI initializers resolves to the
/// `LocalizedStringKey`-typed overload — not the verbatim
/// `StringProtocol` one — so it already round-trips through the
/// bundle's String Catalog automatically. Flagging it would be a false
/// positive.
///
/// ## Allow-list (what's exempt, and why)
///
/// - `.accessibilityIdentifier(...)` — a11y/UI-automation identifier,
///   never shown to the user (explicitly out of scope per this task).
/// - Any line containing `// audit-exempt` — a small, explicit,
///   hand-maintained per-line escape hatch for the rare legitimately
///   non-linguistic case (e.g. the image-preview zoom buttons' "+"/"−"
///   glyph titles in `ImagePreviewViewController.swift`, whose real
///   accessible names are separately localized).
/// - String literals whose static (non-interpolated) content has no
///   letters at all — e.g. `alert.informativeText = "\(error)"` (100%
///   dynamic, nothing to translate) or `NSButton(title: "", ...)`
///   (an empty placeholder later set dynamically). Interpolation
///   segments (`\(...)`) are stripped before this check so a mixed
///   literal like `"Error: \(error)"` (which *does* have static prose)
///   still counts as a violation if left unwrapped.
/// - Files outside `App/KodApp/` (this test only scans that directory;
///   `App/KodAppTests/`/`App/KodAppUITests/` fixtures and identifiers
///   are explicitly out of scope per the task).
///
/// ## Proving this is a real, working check
///
/// `testScannerDetectsADeliberatelyReintroducedViolation` writes a
/// synthetic fixture file (containing one deliberate, unwrapped
/// `.accessibilityLabel("...")` literal) to a scratch directory under
/// `FileManager.default.temporaryDirectory` — the same idiom already
/// used elsewhere in this test target (see `GitWorkspaceCoordinatorTests`,
/// `ManagedInstallCoordinatorTests`) — runs the exact same scanner
/// against it, and asserts the violation is caught. This is in addition
/// to (not a replacement for) actually reintroducing a violation into
/// real `App/KodApp` source, confirming this test fails, then removing
/// it and confirming the test passes again, which was done by hand
/// before this test suite was finalized.
final class UserFacingStringAuditTests: XCTestCase {
    struct Violation: CustomStringConvertible, Equatable {
        let file: String
        let line: Int
        let sink: String
        let snippet: String

        var description: String { "\(file):\(line): [\(sink)] \(snippet)" }
    }

    private struct SinkPattern {
        let name: String
        let regex: NSRegularExpression
    }

    /// One `NSRegularExpression` per documented sink category. Every
    /// pattern requires a literal `"` to appear immediately (modulo
    /// whitespace) after the sink token — enforced with a lookahead
    /// `(?=")` so the match itself stops right before the quote — so
    /// wrapped calls like `.accessibilityLabel(Localized.string(...))`
    /// or `.accessibilityLabel(Text("..."))` never match — only a
    /// *bare* string literal argument does.
    private static let sinkPatterns: [SinkPattern] = [
        ("SwiftUI .accessibilityLabel(\"literal\")", #"\.accessibilityLabel\(\s*(?=")"#),
        ("SwiftUI .accessibilityHint(\"literal\")", #"\.accessibilityHint\(\s*(?=")"#),
        ("SwiftUI .accessibilityValue(\"literal\")", #"\.accessibilityValue\(\s*(?=")"#),
        ("AppKit setAccessibilityLabel(\"literal\")", #"\.setAccessibilityLabel\(\s*(?=")"#),
        ("AppKit setAccessibilityHelp(\"literal\")", #"\.setAccessibilityHelp\(\s*(?=")"#),
        ("AppKit setAccessibilityValue(\"literal\")", #"\.setAccessibilityValue\(\s*(?=")"#),
        ("AppKit setAccessibilityRoleDescription(\"literal\")", #"\.setAccessibilityRoleDescription\(\s*(?=")"#),
        ("NSButton(title: \"literal\")", #"NSButton\(\s*title:\s*(?=")"#),
        ("NSMenuItem(title: \"literal\")", #"NSMenuItem\(\s*title:\s*(?=")"#),
        (".title = \"literal\"", #"\.title\s*=\s*(?=")"#),
        (".messageText = \"literal\"", #"\.messageText\s*=\s*(?=")"#),
        (".informativeText = \"literal\"", #"\.informativeText\s*=\s*(?=")"#),
    ].map { SinkPattern(name: $0.0, regex: try! NSRegularExpression(pattern: $0.1)) }

    /// Matches the three AppKit accessibility-override function
    /// signatures named in the task. Tracked across a short lookahead
    /// window (see `scanForViolations`) rather than a single-line
    /// regex, since the `return` statement is typically on its own
    /// line inside the function body.
    private static let accessibilityOverrideSignature = try! NSRegularExpression(
        pattern: #"override func (accessibilityLabel|accessibilityHelp|accessibilityRoleDescription)\(\s*\)\s*->\s*String\??\s*\{"#
    )
    private static let bareReturnLiteral = try! NSRegularExpression(pattern: #"^\s*return\s+""#)

    private static let interpolationRun = try! NSRegularExpression(pattern: #"\\\([^)]*\)"#)
    private static let hasLetter = try! NSRegularExpression(pattern: #"\p{L}"#)

    /// Extracts the text between the first unescaped `"..."` literal
    /// starting at `startIndex` in `line`, honoring `\"` escapes.
    private static func literalContent(in line: String, afterMatchEnd startIndex: String.Index) -> String? {
        var chars = Array(line[startIndex...])
        guard chars.first == "\"" else { return nil }
        chars.removeFirst()
        var content = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                content.append(c)
                content.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "\"" {
                return content
            }
            content.append(c)
            i += 1
        }
        return nil // unterminated on this line; not something we can safely judge
    }

    /// Returns true if `literalText` (the raw content between the
    /// quotes, escapes intact) has no translatable static prose once
    /// `\(...)` interpolation runs are stripped — i.e. it's either
    /// empty, purely dynamic, or made up only of punctuation/digits.
    private static func isNonTranslatable(_ literalText: String) -> Bool {
        let range = NSRange(literalText.startIndex..., in: literalText)
        let stripped = Self.interpolationRun.stringByReplacingMatches(in: literalText, range: range, withTemplate: "")
        let strippedRange = NSRange(stripped.startIndex..., in: stripped)
        return Self.hasLetter.firstMatch(in: stripped, range: strippedRange) == nil
    }

    /// Scans every `.swift` file directly under `rootDirectory` (non-
    /// recursive is sufficient for `App/KodApp`, which is a flat
    /// directory) for sink-pattern violations.
    static func scanForViolations(rootDirectory: URL) throws -> [Violation] {
        let fileManager = FileManager.default
        let swiftFiles = try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var violations: [Violation] = []

        for fileURL in swiftFiles {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            var insideAccessibilityOverride = false
            var overrideLinesRemaining = 0

            for (index, rawLine) in lines.enumerated() {
                let lineNumber = index + 1
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

                // A whole-line comment can't be a live sink call.
                if trimmed.hasPrefix("//") { continue }
                // Explicit, narrow, hand-maintained per-line escape hatch.
                if rawLine.contains("// audit-exempt") { continue }

                // Track override-body lookahead window for the
                // accessibility-override sink.
                if Self.accessibilityOverrideSignature.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)) != nil {
                    insideAccessibilityOverride = true
                    overrideLinesRemaining = 5 // small window; these overrides are short one-liners in practice
                } else if insideAccessibilityOverride {
                    if Self.bareReturnLiteral.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)) != nil,
                       let quoteIndex = rawLine.firstIndex(of: "\""),
                       let content = literalContent(in: rawLine, afterMatchEnd: quoteIndex),
                       !isNonTranslatable(content) {
                        violations.append(Violation(
                            file: fileURL.lastPathComponent,
                            line: lineNumber,
                            sink: "accessibility override return \"literal\"",
                            snippet: trimmed
                        ))
                    }
                    overrideLinesRemaining -= 1
                    if overrideLinesRemaining <= 0 || trimmed == "}" {
                        insideAccessibilityOverride = false
                    }
                }

                // Explicit sink-pattern scan.
                for sink in Self.sinkPatterns {
                    let nsRange = NSRange(rawLine.startIndex..., in: rawLine)
                    guard let match = sink.regex.firstMatch(in: rawLine, range: nsRange),
                          let matchRange = Range(match.range, in: rawLine) else { continue }
                    guard let content = literalContent(in: rawLine, afterMatchEnd: matchRange.upperBound) else { continue }
                    if isNonTranslatable(content) { continue }
                    violations.append(Violation(
                        file: fileURL.lastPathComponent,
                        line: lineNumber,
                        sink: sink.name,
                        snippet: trimmed
                    ))
                }
            }
        }

        return violations
    }

    private func kodAppSourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UserFacingStringAuditTests.swift -> App/KodAppTests
            .deletingLastPathComponent() // App/KodAppTests -> App
            .appendingPathComponent("KodApp")
    }

    // MARK: - The actual regression guard

    func testAppSourceTreeHasNoUnlocalizedUserFacingStringLiterals() throws {
        let root = kodAppSourceDirectory()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "expected to find App/KodApp at \(root.path)"
        )

        let violations = try Self.scanForViolations(rootDirectory: root)
        XCTAssertTrue(
            violations.isEmpty,
            "Found \(violations.count) unlocalized user-facing string literal(s) in App/KodApp:\n"
                + violations.map(\.description).joined(separator: "\n")
        )
    }

    // MARK: - Proof the scanner is real (not a vacuous always-pass check)

    func testScannerDetectsADeliberatelyReintroducedViolation() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserFacingStringAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let fixtureSource = """
        import SwiftUI

        struct FixtureView: View {
            var body: some View {
                Text("This is fine, it auto-localizes")
                    .accessibilityLabel("This is a reintroduced violation")
            }
        }
        """
        try fixtureSource.write(
            to: scratchDir.appendingPathComponent("FixtureView.swift"),
            atomically: true,
            encoding: .utf8
        )

        let violations = try Self.scanForViolations(rootDirectory: scratchDir)
        XCTAssertEqual(violations.count, 1, "expected the scanner to catch exactly the one deliberately-reintroduced violation")
        XCTAssertEqual(violations.first?.sink, "SwiftUI .accessibilityLabel(\"literal\")")
        XCTAssertTrue(violations.first?.snippet.contains("This is a reintroduced violation") ?? false)
    }

    func testScannerDoesNotFlagCompliantPatternsOrAllowlistedExemptions() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserFacingStringAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let fixtureSource = #"""
        import SwiftUI

        struct FixtureView: View {
            var body: some View {
                Text("Bare SwiftUI literal auto-localizes")
                    .accessibilityIdentifier("fixture.identifier")
                    .accessibilityLabel(Localized.string("Properly wrapped label", comment: "test fixture"))
            }
        }

        final class FixtureButton {
            let button = NSButton(title: "+", target: nil, action: nil) // audit-exempt: symbolic glyph, not prose
            func setUp() {
                button.setAccessibilityLabel(Localized.string("Properly wrapped AppKit label", comment: "test fixture"))
            }
        }
        """#
        try fixtureSource.write(
            to: scratchDir.appendingPathComponent("FixtureCompliant.swift"),
            atomically: true,
            encoding: .utf8
        )

        let violations = try Self.scanForViolations(rootDirectory: scratchDir)
        XCTAssertTrue(violations.isEmpty, "expected zero violations for fully-compliant/allowlisted patterns, found: \(violations)")
    }

    func testNonTranslatableLiteralsAreNotFlagged() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserFacingStringAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let fixtureSource = #"""
        import AppKit

        final class FixtureAlert {
            let alert = NSAlert()
            func present(_ error: Error) {
                alert.informativeText = "\(error)"
            }
        }

        final class FixturePlaceholder {
            let button = NSButton(title: "", target: nil, action: nil)
        }
        """#
        try fixtureSource.write(
            to: scratchDir.appendingPathComponent("FixtureNonTranslatable.swift"),
            atomically: true,
            encoding: .utf8
        )

        let violations = try Self.scanForViolations(rootDirectory: scratchDir)
        XCTAssertTrue(violations.isEmpty, "purely dynamic/empty literals should not be flagged, found: \(violations)")
    }
}
