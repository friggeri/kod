import Foundation
import XCTest
@testable import SearchCore

final class RipgrepArgumentsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/workspace/root")

    func testDefaultOptionsAreCaseInsensitiveFixedStringsRespectingIgnoreFiles() {
        let query = SearchQuery(pattern: "needle", root: root)
        let arguments = RipgrepArguments.build(for: query)

        XCTAssertTrue(arguments.contains("--ignore-case"))
        XCTAssertTrue(arguments.contains("--fixed-strings"))
        XCTAssertFalse(arguments.contains("--word-regexp"))
        XCTAssertFalse(arguments.contains("--hidden"))
        XCTAssertFalse(arguments.contains("--no-ignore"))
        XCTAssertEqual(arguments.last, ".")
        XCTAssertTrue(arguments.contains("needle"))
    }

    func testMatchCaseOmitsIgnoreCaseFlag() {
        var options = SearchOptions()
        options.matchCase = true
        let query = SearchQuery(pattern: "Needle", root: root, options: options)

        let arguments = RipgrepArguments.build(for: query)

        XCTAssertFalse(arguments.contains("--ignore-case"))
    }

    func testWholeWordAddsWordRegexpFlag() {
        var options = SearchOptions()
        options.wholeWord = true
        let query = SearchQuery(pattern: "cat", root: root, options: options)

        XCTAssertTrue(RipgrepArguments.build(for: query).contains("--word-regexp"))
    }

    func testRegexModeOmitsFixedStringsFlag() {
        var options = SearchOptions()
        options.useRegex = true
        let query = SearchQuery(pattern: "cat.*dog", root: root, options: options)

        XCTAssertFalse(RipgrepArguments.build(for: query).contains("--fixed-strings"))
    }

    func testHiddenAndIgnoredOptionsAddExplicitFlags() {
        var options = SearchOptions()
        options.includeHidden = true
        options.includeIgnored = true
        let query = SearchQuery(pattern: "needle", root: root, options: options)

        let arguments = RipgrepArguments.build(for: query)
        XCTAssertTrue(arguments.contains("--hidden"))
        XCTAssertTrue(arguments.contains("--no-ignore"))
    }

    func testIncludeAndExcludeGlobsArePassedAndGitIsAlwaysForceExcludedLast() {
        var options = SearchOptions()
        options.includeGlobs = ["*.swift"]
        options.excludeGlobs = ["Generated/**"]
        let query = SearchQuery(pattern: "needle", root: root, options: options)

        let arguments = RipgrepArguments.build(for: query)
        XCTAssertTrue(arguments.contains("*.swift"))
        XCTAssertTrue(arguments.contains("!Generated/**"))

        // The forced `.git` exclusion must be the very last `--glob` pair so
        // it always wins over any user-provided include glob.
        guard let lastGlobFlagIndex = arguments.lastIndex(of: "--glob") else {
            return XCTFail("expected at least one --glob argument")
        }
        XCTAssertEqual(arguments[lastGlobFlagIndex + 1], RipgrepArguments.forcedExcludeGlob)
    }

    func testPatternIsPassedViaDashEToSurviveLeadingDashes() {
        let query = SearchQuery(pattern: "-not-a-flag", root: root)
        let arguments = RipgrepArguments.build(for: query)

        guard let flagIndex = arguments.firstIndex(of: "-e") else {
            return XCTFail("expected -e pattern flag")
        }
        XCTAssertEqual(arguments[flagIndex + 1], "-not-a-flag")
    }

    func testEndOfOptionsMarkerSeparatesPatternFromPath() {
        let query = SearchQuery(pattern: "needle", root: root)
        let arguments = RipgrepArguments.build(for: query)

        guard let separatorIndex = arguments.firstIndex(of: "--") else {
            return XCTFail("expected -- separator before the search root")
        }
        XCTAssertEqual(arguments[separatorIndex + 1], ".")
    }
}
