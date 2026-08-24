import SourceModel
import XCTest
@testable import SyntaxCore

final class SyntaxEngineTests: XCTestCase {
    func testParsesSwiftAndProducesKeywordCapture() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func greet() {\n    let name = \"world\"\n    print(name)\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        XCTAssertEqual(tree.snapshotVersion, snapshot.version)

        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
        XCTAssertFalse(captures.isEmpty)
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("keyword") })
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("string") })
        XCTAssertTrue(captures.contains { $0.name.hasPrefix("function") })
    }

    func testAllLaunchLanguagesProduceAtLeastOneCapture() async throws {
        let engine = SyntaxEngine()
        let samples: [SyntaxLanguage: String] = [
            .swift: "func f() -> Int { return 1 }\n",
            .typescript: "function f(x: number): number { return x + 1; }\n",
            .tsx: "const View = () => <button title=\"Save\" />;\n",
            .javascript: "function f(x) { return x + 1; }\n",
            .html: "<html><body><p>hi</p></body></html>\n",
            .css: "body { color: red; }\n",
            .python: "def f(x):\n    return x + 1\n",
            .rust: "fn f(x: i32) -> i32 { x + 1 }\n",
            .shell: "if true; then echo \"ready\"; fi\n",
            .markdown: "# Heading\n",
            .markdownInline: "**strong** and `code`\n",
            .json: "{\"ready\": true}\n",
            .yaml: "ready: true\n",
            .toml: "ready = true\n",
            .c: "int main(void) { return 0; }\n",
            .go: "package main\nfunc main() {}\n",
            .java: "class Main { static void main(String[] args) {} }\n",
            .ruby: "def greet(name)\n  \"Hello, #{name}\"\nend\n",
            .lua: "local function greet(name) return name end\n",
            .graphql: "query Greeting { greeting { message } }\n",
            .xml: "<greeting language=\"en\">Hello</greeting>\n"
        ]

        for language in SyntaxLanguage.allCases {
            guard let source = samples[language] else {
                XCTFail("missing sample for \(language)")
                continue
            }

            let snapshot = SourceSnapshot(text: source)
            let tree = try await engine.parse(snapshot: snapshot, language: language)
            let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)
            XCTAssertFalse(captures.isEmpty, "\(language) produced no captures")
        }
    }

    func testDetectsShellAliasesAndShebangs() {
        XCTAssertEqual(
            SyntaxLanguage.detect(forURL: URL(fileURLWithPath: "/tmp/script.sh")),
            .shell
        )
        XCTAssertEqual(
            SyntaxLanguage.detect(forURL: URL(fileURLWithPath: "/tmp/.bashrc")),
            .shell
        )
        let snapshot = SourceSnapshot(
            text: "#!/usr/bin/env bash\necho ready\n",
            url: URL(fileURLWithPath: "/tmp/script")
        )
        XCTAssertEqual(SyntaxLanguage.detect(for: snapshot), .shell)
    }

    func testMarkdownCombinesBlockInlineAndFencedCodeCaptures() async throws {
        let engine = SyntaxEngine()
        let source = """
        # Heading

        **strong**

        ```swift
        let answer = 42
        ```
        """
        let snapshot = SourceSnapshot(
            text: source,
            url: URL(fileURLWithPath: "/tmp/README.md")
        )
        let tree = try await engine.parse(snapshot: snapshot, language: .markdown)
        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)

        XCTAssertTrue(captures.contains { $0.name == "text.title" })
        XCTAssertTrue(captures.contains { $0.name == "text.strong" })
        XCTAssertTrue(
            captures.contains {
                $0.name.hasPrefix("keyword") && capturedText($0, in: snapshot) == "let"
            }
        )
    }

    func testHTMLCombinesMarkupCSSAndJavaScriptCaptures() async throws {
        let source = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                .card { color: rebeccapurple; }
            </style>
        </head>
        <body>
            <script>
                const greeting = "Hello, Kod!";
            </script>
        </body>
        </html>
        """
        let snapshot = SourceSnapshot(
            text: source,
            url: URL(fileURLWithPath: "/tmp/index.html")
        )
        let tree = try await SyntaxEngine().parse(
            snapshot: snapshot,
            language: .html
        )
        let captures = tree.captures(
            inByteRange: 0..<snapshot.utf8Count
        )

        XCTAssertTrue(
            captures.contains {
                $0.name == "tag" && capturedText($0, in: snapshot) == "html"
            }
        )
        XCTAssertTrue(
            captures.contains {
                $0.name == "property" && capturedText($0, in: snapshot) == "color"
            }
        )
        XCTAssertTrue(
            captures.contains {
                $0.name == "keyword" && capturedText($0, in: snapshot) == "const"
            }
        )
    }

    func testDetectsXMLAliasesAndExactFileNames() {
        for ext in ["xml", "svg", "xsd", "xsl", "xslt", "plist"] {
            XCTAssertEqual(SyntaxLanguage.detect(forPathExtension: ext), .xml)
        }
        for name in ["Info.plist", "Contents.xml", "AndroidManifest.xml", "web.config"] {
            XCTAssertEqual(
                SyntaxLanguage.detect(forURL: URL(fileURLWithPath: "/project/\(name)")),
                .xml
            )
        }
    }

    func testMalformedExpandedLanguageInputsRemainParseable() async throws {
        let engine = SyntaxEngine()
        let malformed: [SyntaxLanguage: String] = [
            .c: "int main( { return ;",
            .go: "package main\nfunc ( {",
            .java: "class { void main(",
            .ruby: "def greet(\n  puts \"hi\"",
            .lua: "local function greet(",
            .graphql: "query { greeting(",
            .xml: "<root><child></root>"
        ]
        for (language, source) in malformed {
            let snapshot = SourceSnapshot(text: source)
            let tree = try await engine.parse(snapshot: snapshot, language: language)
            XCTAssertEqual(tree.snapshotVersion, snapshot.version, "\(language) did not return a tree")
        }
    }

    func testTypeScriptIncludesJavaScriptBaseCaptures() async throws {
        if case .failure(let error) = TSQueryStore.shared.highlightsQuery(for: .typescript) {
            XCTFail("TypeScript highlight query failed to compile: \(error)")
        }
        let engine = SyntaxEngine()
        let source = #"import type { AppType } from "@adx/server"; const client = makeClient<AppType>("ready");"#
        let snapshot = SourceSnapshot(text: source)
        let tree = try await engine.parse(snapshot: snapshot, language: .typescript)
        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)

        XCTAssertTrue(captures.contains { $0.name == "keyword" && capturedText($0, in: snapshot) == "import" })
        XCTAssertTrue(captures.contains { $0.name == "keyword" && capturedText($0, in: snapshot) == "const" })
        XCTAssertTrue(captures.contains { $0.name == "string" && capturedText($0, in: snapshot) == #""@adx/server""# })
        XCTAssertTrue(captures.contains { $0.name == "type" && capturedText($0, in: snapshot) == "AppType" })
    }

    func testTSXExtensionUsesTypeScriptGrammarAndHighlightsJSX() async throws {
        XCTAssertEqual(SyntaxLanguage.detect(forPathExtension: "tsx"), .tsx)

        let engine = SyntaxEngine()
        let source = "export const View = () => <button title=\"Save\" />;\n"
        let snapshot = SourceSnapshot(text: source, url: URL(fileURLWithPath: "/tmp/View.tsx"))
        let tree = try await engine.parse(snapshot: snapshot, language: .tsx)
        let captures = tree.captures(inByteRange: 0..<snapshot.utf8Count)

        XCTAssertTrue(captures.contains { $0.name == "keyword" && capturedText($0, in: snapshot) == "export" })
        XCTAssertTrue(captures.contains { $0.name == "tag" && capturedText($0, in: snapshot) == "button" })
        XCTAssertTrue(captures.contains { $0.name == "attribute" && capturedText($0, in: snapshot) == "title" })
    }

    func testHighlightPrioritizesViewportThenFull() async throws {
        let engine = SyntaxEngine()
        let source = String(repeating: "let x = 1\n", count: 200)
        let snapshot = SourceSnapshot(text: source)
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)

        let viewportRange = 0..<50
        let (viewport, full) = try await engine.highlight(
            tree: tree,
            viewportByteRange: viewportRange,
            fullByteRange: 0..<snapshot.utf8Count
        )
        XCTAssertFalse(viewport.isEmpty)
        XCTAssertTrue(full.count >= viewport.count)
        XCTAssertTrue(full.allSatisfy { $0.utf8Range.lowerBound >= 0 && $0.utf8Range.upperBound <= snapshot.utf8Count })
    }

    func testFoldRangesSpanMultipleLines() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func f() {\n    let x = 1\n    print(x)\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        let folds = tree.foldRanges()
        XCTAssertTrue(folds.contains { $0.headerLine == 0 && $0.endLine == 3 })
    }

    func testEnclosingScopesReturnsOutermostFirst() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(text: "func outer() {\n    func inner() {\n        let x = 1\n    }\n}\n")
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        // Byte offset inside "let x = 1"
        guard let offset = snapshot.text.range(of: "let x") else {
            return XCTFail("fixture text changed")
        }
        let utf8Offset = snapshot.text.utf8.distance(from: snapshot.text.utf8.startIndex, to: offset.lowerBound.samePosition(in: snapshot.text.utf8)!)
        let scopes = tree.enclosingScopes(atByteOffset: utf8Offset)
        XCTAssertFalse(scopes.isEmpty)
        XCTAssertEqual(scopes.first?.startLine, 0)
    }

    func testEnclosingScopesDoNotTreatDocumentRootAsAStickyScope() async throws {
        let engine = SyntaxEngine()
        let snapshot = SourceSnapshot(
            text: "import Foundation\n\nfunc greet() {\n    print(\"hi\")\n}\n"
        )
        let tree = try await engine.parse(snapshot: snapshot, language: .swift)
        guard let offset = snapshot.text.range(of: "print") else {
            return XCTFail("fixture text changed")
        }
        let utf8Offset = snapshot.text.utf8.distance(
            from: snapshot.text.utf8.startIndex,
            to: offset.lowerBound.samePosition(in: snapshot.text.utf8)!
        )

        let scopes = tree.enclosingScopes(atByteOffset: utf8Offset)

        XCTAssertFalse(scopes.isEmpty)
        XCTAssertEqual(scopes.first?.startLine, 2)
        XCTAssertFalse(scopes.contains { $0.startLine == 0 })
    }

    private func capturedText(_ capture: SyntaxCapture, in snapshot: SourceSnapshot) -> String? {
        try? snapshot.text(inUTF8Range: capture.utf8Range)
    }
}
