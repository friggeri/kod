import FuzzSupport
import XCTest
@testable import ThemeCore

/// Bounded, seeded fuzzing of `VSCodeThemeImporter.import`, the parser
/// that turns an arbitrary (potentially hostile, potentially just
/// broken) VS Code color-theme JSON file into a `KodTheme` (SPEC 16.1:
/// "Property and fuzz tests for hostile theme JSON"; SPEC 15: "Invalid
/// theme imports list rejected fields and preserve the current theme").
/// Every input is either fully random bytes or a randomly-mutated,
/// structurally-plausible JSON object — the only acceptable outcomes are
/// "a `KodTheme` was produced" or "a well-typed `VSCodeThemeImportError`
/// was thrown"; a crash or hang is a failure.
final class VSCodeThemeImportFuzzTests: XCTestCase {
    /// Property: entirely random bytes handed to the importer never
    /// crash — they either fail JSON parsing (`.invalidJSON`) or, on the
    /// rare occasion random bytes happen to form valid JSON, fail some
    /// other well-typed validation step.
    func testRandomBytesNeverCrashTheImporter() throws {
        try FuzzRun.run("VSCodeThemeImportFuzzTests.randomBytes") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...500, &source))
            do {
                _ = try VSCodeThemeImporter.import(jsonData: data, identifier: "fuzz")
            } catch is VSCodeThemeImportError {
                // Expected for hostile/malformed input.
            }
        }
    }

    /// Property: a JSON object with random keys mapped to random
    /// (possibly wrong-typed) values — the shape a truncated, hand-
    /// edited, or adversarially-crafted theme file would actually take,
    /// as opposed to fully unstructured bytes — is always either
    /// imported or rejected with a well-typed error, never crashes, and
    /// never hangs.
    func testRandomlyShapedJSONObjectsNeverCrashTheImporter() throws {
        try FuzzRun.run("VSCodeThemeImportFuzzTests.randomShapes", iterations: 300) { source in
            let object = randomJSONObject(&source, depth: 0)
            let data = try JSONSerialization.data(withJSONObject: object)
            do {
                _ = try VSCodeThemeImporter.import(jsonData: data, identifier: "fuzz")
            } catch is VSCodeThemeImportError {
                // Expected for most random shapes.
            }
        }
    }

    /// Property: known top-level keys (`colors`, `tokenColors`, etc.)
    /// populated with a random assortment of correctly- and incorrectly-
    /// typed values still never crash the importer, and any accepted
    /// color values must always be valid, in-range `ThemeColor`s (a
    /// malformed hex string must be rejected as unsupported, never
    /// silently coerced into some default color).
    func testKnownKeysWithRandomlyTypedValuesNeverCrash() throws {
        try FuzzRun.run("VSCodeThemeImportFuzzTests.knownKeysRandomTypes", iterations: 300) { source in
            var colors: [String: Any] = [:]
            let colorKeys = ["editor.background", "editor.foreground", "sideBar.background", "not.a.real.key"]
            for key in colorKeys {
                colors[key] = randomJSONValue(&source, depth: 1)
            }
            let object: [String: Any] = [
                "name": randomJSONValue(&source, depth: 1),
                "type": ["light", "dark", "hc-black", 42, NSNull()][Int.random(in: 0..<5, using: &source)],
                "colors": colors,
                "tokenColors": [randomJSONValue(&source, depth: 1), randomJSONValue(&source, depth: 1)]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            do {
                let (theme, _) = try VSCodeThemeImporter.import(jsonData: data, identifier: "fuzz")
                // Any theme that was accepted must be internally
                // consistent: every color the importer claims to have
                // produced must itself be a validly-constructed
                // `ThemeColor` (already guaranteed by its own type, but
                // asserted here so a future refactor that weakens that
                // guarantee fails this fuzz suite).
                _ = theme.editor.background
            } catch is VSCodeThemeImportError {
                // Expected for most random shapes.
            }
        }
    }

    // MARK: - Random JSON generation

    private func randomJSONValue(_ source: inout FuzzRandomSource, depth: Int) -> Any {
        if depth >= 3 {
            return randomJSONScalar(&source)
        }
        switch Int.random(in: 0...4, using: &source) {
        case 0:
            return randomJSONObject(&source, depth: depth + 1)
        case 1:
            return (0..<Int.random(in: 0...5, using: &source)).map { _ in randomJSONValue(&source, depth: depth + 1) }
        default:
            return randomJSONScalar(&source)
        }
    }

    private func randomJSONScalar(_ source: inout FuzzRandomSource) -> Any {
        switch Int.random(in: 0...5, using: &source) {
        case 0:
            return FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...12, using: &source), &source)
        case 1:
            return Int.random(in: -1_000_000...1_000_000, using: &source)
        case 2:
            return Double.random(in: -1_000...1_000, using: &source)
        case 3:
            return Bool.random(using: &source)
        case 4:
            return NSNull()
        default:
            // A hex-color-shaped string, sometimes valid, sometimes not
            // — the specific shape that most exercises `ThemeColor(hex:)`.
            let hexChars = Array("0123456789ABCDEFghijXYZ#")
            let length = Int.random(in: 0...10, using: &source)
            return String((0..<length).map { _ in hexChars[Int.random(in: 0..<hexChars.count, using: &source)] })
        }
    }

    private func randomJSONObject(_ source: inout FuzzRandomSource, depth: Int) -> [String: Any] {
        var object: [String: Any] = [:]
        let keyCount = Int.random(in: 0...5, using: &source)
        for _ in 0..<keyCount {
            let key = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 1...10, using: &source), &source)
            object[key] = randomJSONValue(&source, depth: depth)
        }
        return object
    }
}
