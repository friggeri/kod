import XCTest
@testable import PreviewCore

/// Direct coverage for the pre-tokenizer stripper: the exact removal
/// semantics the sanitizers depend on, plus the large hostile input that
/// used to make the scan quadratic (every removal restarted the search at
/// the start of the document, so a document full of small `<script>`
/// elements cost O(n²)).
final class DangerousElementStripperTests: XCTestCase {
    func testRemovesElementWithItsEntireBodyAndCloseTag() {
        let result = DangerousElementStripper.strip(
            "before <script>alert(1)</script> after",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "before  after")
        XCTAssertEqual(result.removedConstructs, ["removed <script> element"])
    }

    func testMatchesElementNameCaseInsensitively() {
        let result = DangerousElementStripper.strip(
            "a<ScRiPt >x</SCRIPT>b",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "ab")
        XCTAssertEqual(result.removedConstructs, ["removed <script> element"])
    }

    func testDoesNotMatchALongerElementNameWithTheSamePrefix() {
        let result = DangerousElementStripper.strip(
            "<scriptx>kept</scriptx>",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "<scriptx>kept</scriptx>")
        XCTAssertTrue(result.removedConstructs.isEmpty)
    }

    func testUnterminatedElementDropsEverythingToTheEndOfTheDocument() {
        let result = DangerousElementStripper.strip(
            "keep <script>alert(1)",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "keep ")
        XCTAssertEqual(
            result.removedConstructs,
            ["removed unterminated <script> element and trailing content"]
        )
    }

    func testUnterminatedOpeningTagDropsEverythingToTheEndOfTheDocument() {
        let result = DangerousElementStripper.strip(
            "keep <script foo=\"bar\"",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "keep ")
        XCTAssertEqual(
            result.removedConstructs,
            ["removed unterminated <script> element and trailing content"]
        )
    }

    /// Removing the inner element splices `<scr` onto `ipt>`, forming a
    /// brand-new opening tag that was never present in the input. The
    /// scan matches opening tags against the *output* — which already is
    /// the spliced document — so it catches it with no rescan at all.
    func testTagCreatedBySplicingAfterARemovalIsAlsoRemoved() {
        let result = DangerousElementStripper.strip(
            "<scr<script>bad</script>ipt>alert(1)</script>tail",
            elementNames: ["script"]
        )
        XCTAssertEqual(result.text, "tail")
        XCTAssertEqual(result.removedConstructs.count, 2)
        XCTAssertFalse(result.text.lowercased().contains("script"))
        XCTAssertFalse(result.text.contains("alert"))
    }

    func testRepeatedSpliceChainIsFullyUnwound() {
        // Each removal re-forms the next `<script` from the surrounding
        // fragments, three levels deep.
        let result = DangerousElementStripper.strip(
            "<s<s<script>a</script>cr<script>b</script>ipt>c</script>cript>d</script>keep",
            elementNames: ["script"]
        )
        XCTAssertFalse(result.text.lowercased().contains("script"))
        XCTAssertTrue(result.text.hasSuffix("keep"))
    }

    func testStripsEveryRequestedElementNameInDocumentOrder() {
        let result = DangerousElementStripper.strip(
            "<style>body{}</style>mid<script>x</script>",
            elementNames: ["script", "style"]
        )
        XCTAssertEqual(result.text, "mid")
        // Document order, not the order the names were listed in: every
        // name is matched in the same single pass, so no removal can
        // depend on which name happens to be checked first.
        XCTAssertEqual(
            result.removedConstructs,
            ["removed <style> element", "removed <script> element"]
        )
    }

    /// Removing one element name can splice a *different* dangerous name
    /// together. Handling each name in its own pass (as the original did)
    /// let this through whenever the spliced name had already been
    /// processed.
    func testRemovalOfOneElementNameCannotSpliceAnother() {
        let result = DangerousElementStripper.strip(
            "<scr<style>x</style>ipt>alert(1)</script>tail",
            elementNames: ["script", "style"]
        )
        XCTAssertEqual(result.text, "tail")
        XCTAssertFalse(result.text.contains("alert"))
    }

    /// Truncating an unterminated element can leave a `<script` that was
    /// harmless only because something followed it, and is now the last
    /// thing in the document.
    func testTruncationDoesNotLeaveADanglingOpeningTagAtTheEnd() {
        let result = DangerousElementStripper.strip(
            "keep <script<script<style>alert(1)",
            elementNames: ["script", "style"]
        )
        XCTAssertEqual(result.text, "keep ")
    }

    /// Regression for the quadratic rescan: a large document made of many
    /// small dangerous elements must be stripped in time proportional to
    /// its length. The previous implementation restarted the scan from
    /// the start of the document after every one of these removals and
    /// took minutes on this input.
    func testLargeHostileInputWithManySmallElementsStaysLinear() {
        let elementCount = 5_000
        var hostile = ""
        hostile.reserveCapacity(elementCount * 48)
        for index in 0..<elementCount {
            hostile += "text\(index) <script>alert(\(index))</script> "
        }
        hostile += "tail"

        let start = ContinuousClock().now
        let result = DangerousElementStripper.strip(
            hostile,
            elementNames: ["script", "style", "iframe", "object", "embed", "template", "noscript", "form"]
        )
        let elapsed = ContinuousClock().now - start

        XCTAssertEqual(result.removedConstructs.count, elementCount)
        XCTAssertFalse(result.text.lowercased().contains("<script"))
        XCTAssertFalse(result.text.contains("alert("))
        XCTAssertTrue(result.text.hasSuffix("tail"))
        XCTAssertLessThan(
            elapsed,
            .seconds(10),
            "stripping \(elementCount) small elements must not rescan the whole document per removal"
        )
    }

    /// The same shape, but every element is unterminated *after* the
    /// first one is removed — the pathological case for the splice path.
    func testLargeHostileInputOfSpliceBaitStaysBounded() {
        let repeats = 3_000
        let hostile = String(repeating: "<scr<script>x</script>ipt>y</script>", count: repeats)

        let start = ContinuousClock().now
        let result = DangerousElementStripper.strip(hostile, elementNames: ["script"])
        let elapsed = ContinuousClock().now - start

        XCTAssertFalse(result.text.lowercased().contains("<script"))
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    /// The property the whole layer exists for, checked against randomly
    /// assembled adversarial fragments rather than hand-picked strings:
    /// whatever comes out, no recognizable dangerous opening tag survives
    /// in it, and re-running the stripper changes nothing (so no removal
    /// can ever leave behind something a second pass would have caught).
    func testRandomizedFragmentsNeverLeaveADangerousOpeningTag() {
        let fragments = [
            "<", ">", "/", "<s", "scr", "ipt", "<script", "</script", "<script>",
            "</script>", "<scr", "<SCRIPT ", "</SCRIPT>", "<style>", "</style>",
            "text", " ", "\t", "é", "<scriptx>", "<script/", "alert(1)", "\n"
        ]
        var generator = SeededGenerator(seed: 0x5EED_1234_ABCD_0001)

        for _ in 0..<2_000 {
            let pieceCount = Int.random(in: 1...24, using: &generator)
            var input = ""
            for _ in 0..<pieceCount {
                input += fragments[Int.random(in: 0..<fragments.count, using: &generator)]
            }

            let once = DangerousElementStripper.strip(
                input,
                elementNames: ["script", "style"]
            ).text
            XCTAssertFalse(
                Self.containsOpeningTag(once, name: "script"),
                "surviving <script> opening tag for input: \(input.debugDescription)"
            )
            XCTAssertFalse(
                Self.containsOpeningTag(once, name: "style"),
                "surviving <style> opening tag for input: \(input.debugDescription)"
            )

            let twice = DangerousElementStripper.strip(
                once,
                elementNames: ["script", "style"]
            ).text
            XCTAssertEqual(
                twice,
                once,
                "stripping is not a fixed point for input: \(input.debugDescription)"
            )
        }
    }

    /// A deliberately independent reader of the same rule the stripper
    /// applies: `<name` followed by whitespace, `>`, `/`, or end of input.
    private static func containsOpeningTag(_ text: String, name: String) -> Bool {
        let lowered = Array(text.lowercased())
        let tag = Array("<" + name)
        guard lowered.count >= tag.count else {
            return false
        }
        for start in 0...(lowered.count - tag.count) {
            guard Array(lowered[start..<(start + tag.count)]) == tag else {
                continue
            }
            let afterIndex = start + tag.count
            guard afterIndex < lowered.count else {
                return true
            }
            let next = lowered[afterIndex]
            if next.isWhitespace || next == ">" || next == "/" {
                return true
            }
        }
        return false
    }
}

/// Deterministic PRNG so a failing case is always reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
