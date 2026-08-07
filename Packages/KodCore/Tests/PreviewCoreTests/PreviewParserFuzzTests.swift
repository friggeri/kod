import FuzzSupport
import XCTest
@testable import PreviewCore

/// Bounded, seeded fuzzing of every built-in preview parser (SPEC 16.1:
/// "Property and fuzz tests for ... hostile theme JSON" and SPEC 10's
/// Markdown/image/JSON/plist previews' own "hostile-input and network-
/// blocking tests" acceptance criterion, SPEC 16.2 #11): `MarkdownParser`,
/// `SVGDocumentLoader`, `ImageDecoder`, `JSONParser`, `XMLPlistParser`,
/// and `BinaryPlistParser`. Every input is random bytes/text — the only
/// acceptable outcomes are a successfully parsed (possibly-empty or
/// degenerate) result, or an explicit `.invalid`/`.rejected` diagnostic;
/// a crash, hang, or unbounded allocation is a failure.
final class PreviewParserFuzzTests: XCTestCase {
    func testMarkdownParserNeverCrashesOnRandomText() throws {
        try FuzzRun.run("PreviewParserFuzzTests.markdown") { source in
            let text = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...400, using: &source), &source)
            _ = MarkdownParser.parse(text)
        }
    }

    /// Markdown-shaped random text (random mixes of the syntax
    /// characters Markdown actually uses) explores the format's edges
    /// far more than fully unstructured Unicode does.
    func testMarkdownParserNeverCrashesOnMarkdownShapedRandomText() throws {
        try FuzzRun.run("PreviewParserFuzzTests.markdownShaped", iterations: 300) { source in
            let alphabet = Array("#*_`[]()!->|~\\\n \t0123456789abcXYZ".utf8)
            let length = Int.random(in: 0...300, using: &source)
            let bytes = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &source)] }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = MarkdownParser.parse(text)
        }
    }

    func testSVGDocumentLoaderNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.svg") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))
            _ = SVGDocumentLoader.load(data)
        }
    }

    /// Bytes prefixed with a real `<svg` opening tag (so the loader
    /// commits to sanitizing rather than bailing out on format
    /// detection) followed by random bytes, including embedded
    /// `<script>`/`<!ENTITY` fragments — the exact hostile constructs
    /// `SVGSanitizer` must strip — never crash the sanitizer.
    func testSVGShapedRandomBytesNeverCrashTheSanitizer() throws {
        try FuzzRun.run("PreviewParserFuzzTests.svgShaped", iterations: 200) { source in
            let hostileFragments = [
                "<script>alert(1)</script>", "<!ENTITY xxe SYSTEM \"file:///etc/passwd\">",
                "onload=\"evil()\"", "<image href=\"javascript:evil()\"/>", ""
            ]
            let fragment = hostileFragments[Int.random(in: 0..<hostileFragments.count, using: &source)]
            let randomTail = FuzzGenerators.randomUnicodeString(scalarCount: Int.random(in: 0...100, using: &source), &source)
            let xml = "<svg xmlns=\"http://www.w3.org/2000/svg\">\(fragment)\(randomTail)</svg>"
            _ = SVGDocumentLoader.load(Data(xml.utf8))
        }
    }

    func testImageDecoderNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.image", iterations: 300) { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...1_024, &source))
            _ = ImageDecoder.decode(data)
        }
    }

    /// Bytes prefixed with real PNG/JPEG magic numbers, followed by
    /// random content, exercise ImageIO's own decoding path (rather
    /// than being rejected purely on `ImageFormat.detect` before ever
    /// reaching it) while still never crashing this process.
    func testImageDecoderNeverCrashesOnFormatPrefixedRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.imageFormatShaped", iterations: 200) { source in
            let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            let jpegMagic: [UInt8] = [0xFF, 0xD8, 0xFF]
            var bytes = Bool.random(using: &source) ? pngMagic : jpegMagic
            bytes.append(contentsOf: FuzzGenerators.randomBytes(lengthIn: 0...512, &source))
            _ = ImageDecoder.decode(Data(bytes))
        }
    }

    func testJSONParserNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.json") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))
            _ = JSONParser.parse(data)
        }
    }

    /// JSON-syntax-shaped random text (braces, brackets, quotes, colons,
    /// commas, digits) explores nesting/malformed-structure edges much
    /// more effectively than fully unstructured bytes.
    func testJSONParserNeverCrashesOnJSONShapedRandomText() throws {
        try FuzzRun.run("PreviewParserFuzzTests.jsonShaped", iterations: 300) { source in
            let alphabet = Array("{}[]\":,0123456789truefalsenull -\n".utf8)
            let length = Int.random(in: 0...300, using: &source)
            let bytes = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &source)] }
            _ = JSONParser.parse(Data(bytes))
        }
    }

    func testXMLPlistParserNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.xmlPlist") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))
            _ = XMLPlistParser.parse(data, limits: .default)
        }
    }

    func testBinaryPlistParserNeverCrashesOnRandomBytes() throws {
        try FuzzRun.run("PreviewParserFuzzTests.binaryPlist") { source in
            let data = Data(FuzzGenerators.randomBytes(lengthIn: 0...2_048, &source))
            _ = BinaryPlistParser.parse(data, limits: .default)
        }
    }

    /// Bytes prefixed with the real `bplist00` magic (so the parser
    /// commits to the offset-table walk instead of bailing out
    /// immediately) followed by random trailer/offset-table-shaped
    /// bytes never crash the parser — this is specifically the
    /// decompression-bomb-style attack surface `BinaryPlistParser`'s own
    /// doc comment calls out (a tiny file whose offset table points
    /// billions of entries at the same string).
    func testBinaryPlistMagicPrefixedRandomBytesNeverCrash() throws {
        try FuzzRun.run("PreviewParserFuzzTests.binaryPlistMagicShaped", iterations: 300) { source in
            var bytes = Array("bplist00".utf8)
            bytes.append(contentsOf: FuzzGenerators.randomBytes(lengthIn: 32...200, &source))
            _ = BinaryPlistParser.parse(Data(bytes), limits: .default)
        }
    }
}
