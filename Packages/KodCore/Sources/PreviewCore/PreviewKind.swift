import Foundation
import UniformTypeIdentifiers

/// The built-in preview Kod can offer for a file, or `.none` if it must
/// fall back to the plain-text/code viewer. Always derived from validated
/// content (magic bytes / a real parse attempt), never from a path
/// extension alone (SPEC 10: "dispatch by validated content/UTType rather
/// than extension alone") — a `.png` file that is not actually a valid PNG
/// must not be forced into the image preview, and a `.json` file that is
/// not actually valid JSON still gets `.structuredData` here (so the
/// structured-data preview can show its own explicit parse diagnostic)
/// rather than silently downgrading to `.none`.
public enum PreviewKind: Equatable, Sendable {
    case markdown
    case html
    case image(ImageFormat)
    case structuredData
    case none
}

/// Detects which built-in preview (if any) applies to a file, from its
/// actual bytes. A path extension is accepted only as a cheap pre-filter
/// hint — resolved through `UniformTypeIdentifiers.UTType` where a stable
/// system type exists (`public.json`, `com.apple.property-list`) rather
/// than a hand-rolled string comparison — for which detector to try
/// first; every branch still validates against real content before
/// committing to a preview kind.
public enum PreviewContentDetector {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    public static func detect(pathExtension: String, contentPrefix: Data) -> PreviewKind {
        if let imageFormat = ImageFormat.detect(fromPrefixBytes: contentPrefix) {
            return .image(imageFormat)
        }

        let lowercasedExtension = pathExtension.lowercased()
        let hintedType = UTType(filenameExtension: lowercasedExtension)

        if hintedType?.conforms(to: .json) == true || hintedType?.conforms(to: .propertyList) == true {
            return .structuredData
        }
        // Content not matching the extension's hint still gets a chance:
        // a `bplist00` prologue is enough to route to the structured-data
        // preview (with its own diagnostic if the rest of the content
        // turns out invalid) even without a recognized extension, since
        // SPEC 10 requires content, not extension, to drive dispatch.
        if contentPrefix.starts(with: Array("bplist00".utf8)) {
            return .structuredData
        }

        if hintedType?.conforms(to: .html) == true,
           HTMLPreviewDocument.looksLikeHTML(contentPrefix) {
            return .html
        }

        if markdownExtensions.contains(lowercasedExtension) {
            return .markdown
        }

        return .none
    }
}
