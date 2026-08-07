import os

/// Non-fatal logging for `CodeViewport`/`CodeDocumentViewController`
/// failures (e.g. syntax highlighting) so they are visible for diagnosis
/// instead of being silently discarded, per SPEC 15.
enum CodeViewportLog {
    static let subsystem = "com.kodapp.CodeViewport"
    static let highlighting = Logger(subsystem: subsystem, category: "highlighting")
}
