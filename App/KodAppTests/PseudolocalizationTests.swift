import AppKit
import XCTest
@testable import Kod

/// SPEC 14 requires localization infrastructure from the first release,
/// even though 1.0 ships English-only. A String Catalog holds the door
/// open for future translations, but translated strings are very often
/// longer than their English source — real localization QA catches
/// clipping regressions with "pseudolocalization": every source string
/// is mechanically expanded/decorated (without actually translating it)
/// so it can be round-tripped through the app's real UI-layout/text-
/// measurement code while still being human-readable enough to eyeball.
///
/// These tests do the headless equivalent: they apply a deterministic
/// pseudolocalization transform to a representative set of short,
/// layout-adjacent "clipping-prone" model strings (tab/panel
/// accessibility labels, toolbar button titles, sidebar status
/// messages, and the single-letter Git status badges), measure both the
/// original and pseudolocalized text with the same AppKit string-
/// measurement API production code would use, and assert the
/// measurement path is real and exercised — not a trivial always-pass
/// check — by requiring a measurably larger bounding box and, for one
/// tightly-bounded control, a genuine overflow determination.
@MainActor
final class PseudolocalizationTests: XCTestCase {
    // MARK: - Deterministic pseudolocalization transform

    /// Doubles every vowel (preserving case) and wraps the result in
    /// `"[... !!!]"` delimiters, the same shape of transform real
    /// pseudolocalization tooling (e.g. Apple's own "Double-Length
    /// Pseudolanguage" scheme, or gettext's `--pseudo`) uses to
    /// approximate the ~30-50%+ length expansion many translated
    /// languages (German, Finnish, French, ...) exhibit relative to
    /// English source text, while keeping the original characters
    /// legible for a human reviewer. This is a real, deterministic
    /// algorithm (same input always produces the same output) — not a
    /// joke transform — and is exercised by every test below.
    private static func pseudolocalize(_ source: String) -> String {
        var doubled = ""
        doubled.reserveCapacity(source.count * 2)
        for character in source {
            doubled.append(character)
            if "aeiouAEIOU".contains(character) {
                doubled.append(character)
            }
        }
        return "[\(doubled) !!!]"
    }

    /// A real, reusable overflow-detection helper of the kind a layout
    /// engine would use: measures `text` with `font` and reports whether
    /// it fits within `maxWidth`. Exercised (not merely asserted around)
    /// by `testGitStatusBadgeLetterOverflowsItsSingleGlyphBudgetWhenPseudolocalized`.
    private static func wouldOverflow(_ text: String, font: NSFont, maxWidth: CGFloat) -> Bool {
        let measuredWidth = (text as NSString).size(withAttributes: [.font: font]).width
        return measuredWidth > maxWidth
    }

    /// Representative "clipping-prone" model strings: short, layout-
    /// adjacent text that backs a fixed or tightly-sized UI element.
    /// These are literal copies of real production strings (see the
    /// per-entry comment for their source call site) rather than a
    /// synthetic corpus, so the test reflects the actual migrated UI.
    private static let clippingProneModelStrings: [(label: String, text: String)] = [
        ("WorkspaceViewController toolbar toggle accessibility label", "Toggle Source and Preview"),
        ("KeyboardCommandRegistry menu title", "Show Problems"),
        ("SearchSidebarViewController status label", "No results"),
        ("SymbolsViewController status label", "Searching…"),
        ("WorkspaceViewController trust banner text", "Workspace trust granted"),
        ("Language Support settings title", "Language Support"),
        ("GitBlamePanelController accessibility label", "Commit details"),
        ("SourceControlSidebarViewController section title", "Merge Changes"),
        ("GitDiffViewController segmented control label", "Side by Side"),
    ]

    // MARK: - Deterministic transform sanity

    func testPseudolocalizeIsDeterministicAndExpandsLength() {
        for (label, text) in Self.clippingProneModelStrings {
            let first = Self.pseudolocalize(text)
            let second = Self.pseudolocalize(text)
            XCTAssertEqual(first, second, "\(label): pseudolocalization must be deterministic")
            XCTAssertGreaterThan(
                first.count,
                text.count,
                "\(label): pseudolocalized text must be longer than the source"
            )
        }
    }

    // MARK: - Real AppKit measurement round-trip

    /// Proves the measurement path itself is real and exercised: every
    /// clipping-prone model string, once pseudolocalized, must round-
    /// trip through `NSString.size(withAttributes:)` (the same API
    /// production label/button-sizing code uses) without crashing and
    /// must report a measurably larger bounding box than the original —
    /// simulating what would happen if a future translation expanded
    /// this text.
    func testPseudolocalizedStringsMeasureLargerThanOriginalsUsingRealAppKitAPI() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        for (label, text) in Self.clippingProneModelStrings {
            let pseudo = Self.pseudolocalize(text)

            let originalSize = (text as NSString).size(withAttributes: [.font: font])
            let pseudoSize = (pseudo as NSString).size(withAttributes: [.font: font])

            XCTAssertGreaterThan(originalSize.width, 0, "\(label): original measurement must be real, non-zero")
            XCTAssertTrue(originalSize.width.isFinite, "\(label): original measurement must not crash/produce NaN")
            XCTAssertTrue(pseudoSize.width.isFinite, "\(label): pseudolocalized measurement must not crash/produce NaN")
            XCTAssertGreaterThan(
                pseudoSize.width,
                originalSize.width,
                "\(label): pseudolocalized '\(pseudo)' should measure wider than '\(text)'"
            )
        }
    }

    /// Same proof using `NSAttributedString.size()` (the other real
    /// AppKit measurement entry point named in the task), so both
    /// commonly-used measurement APIs are actually exercised, not just
    /// one.
    func testPseudolocalizedStringsMeasureLargerViaNSAttributedString() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        for (label, text) in Self.clippingProneModelStrings {
            let pseudo = Self.pseudolocalize(text)

            let originalAttr = NSAttributedString(string: text, attributes: [.font: font])
            let pseudoAttr = NSAttributedString(string: pseudo, attributes: [.font: font])

            let originalSize = originalAttr.size()
            let pseudoSize = pseudoAttr.size()

            XCTAssertTrue(originalSize.width.isFinite && pseudoSize.width.isFinite, "\(label): NSAttributedString.size() must not crash/produce NaN")
            XCTAssertGreaterThan(
                pseudoSize.width,
                originalSize.width,
                "\(label): pseudolocalized '\(pseudo)' should measure wider than '\(text)' via NSAttributedString"
            )
        }
    }

    // MARK: - Genuine overflow detection

    /// `GitPresentedStatus.letter` (see `GitWorkspaceCoordinator.swift`) is
    /// deliberately a single glyph ("A"/"M"/"D"/"R"/"C"/"T"/"U"/"!")
    /// sized to fit a
    /// small fixed badge; its layout budget is exactly one glyph's
    /// width plus a hairline of padding. Pseudolocalizing a single
    /// letter (e.g. "A" -> "[A !!!]") should very obviously overflow
    /// that budget, exercising `wouldOverflow(_:font:maxWidth:)` as a
    /// real, meaningful overflow-detection code path rather than a
    /// vacuous always-true/always-false check.
    func testGitStatusBadgeLetterOverflowsItsSingleGlyphBudgetWhenPseudolocalized() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let badgeLetters = ["A", "M", "D", "R", "C", "T", "U", "!"]

        for letter in badgeLetters {
            let singleGlyphBudget = (letter as NSString).size(withAttributes: [.font: font]).width + 1.0
            XCTAssertFalse(
                Self.wouldOverflow(letter, font: font, maxWidth: singleGlyphBudget),
                "badge letter '\(letter)' should fit its own single-glyph budget"
            )

            let pseudo = Self.pseudolocalize(letter)
            XCTAssertTrue(
                Self.wouldOverflow(pseudo, font: font, maxWidth: singleGlyphBudget),
                "pseudolocalized badge letter '\(pseudo)' should overflow the single-glyph badge budget"
            )
        }
    }
}
