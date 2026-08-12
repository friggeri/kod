import Foundation
import XCTest
@testable import LanguageClient

@MainActor
final class WorkspaceDiagnosticsStoreTests: XCTestCase {
    func testOwnerIsolationResourceCleanupAndPresentationDeduplication() {
        let store = WorkspaceDiagnosticsStore()
        let firstURL = URL(fileURLWithPath: "/workspace/First.swift")
        let secondURL = URL(fileURLWithPath: "/workspace/Second.swift")
        let shared = diagnostic(message: "Shared")
        let ownerOnly = diagnostic(message: "Owner only")

        store.replace(
            owner: "swift",
            resource: firstURL,
            diagnostics: [shared, shared]
        )
        store.replace(
            owner: "typescript",
            resource: firstURL,
            diagnostics: [shared, ownerOnly]
        )
        store.replace(
            owner: "typescript",
            resource: secondURL,
            diagnostics: [ownerOnly]
        )

        XCTAssertEqual(store.diagnostics(owner: "swift", resource: firstURL), [shared, shared])
        XCTAssertEqual(
            store.snapshot.presentationDiagnosticsByFile[firstURL],
            [shared, shared, ownerOnly],
            "Duplicates from one owner remain raw/presented; only cross-owner duplicates collapse"
        )
        XCTAssertEqual(
            store.snapshot.presentationDiagnosticsByFile[secondURL],
            [ownerOnly]
        )

        store.clear(owner: "swift")
        XCTAssertTrue(store.diagnostics(owner: "swift", resource: firstURL).isEmpty)
        XCTAssertEqual(
            store.snapshot.presentationDiagnosticsByFile[firstURL],
            [shared, ownerOnly]
        )

        store.clear(resource: firstURL)
        XCTAssertNil(store.snapshot.presentationDiagnosticsByFile[firstURL])
        XCTAssertEqual(
            store.snapshot.presentationDiagnosticsByFile[secondURL],
            [ownerOnly]
        )
    }

    func testObserversReceiveReplacementAndClearSnapshots() {
        let store = WorkspaceDiagnosticsStore()
        let url = URL(fileURLWithPath: "/workspace/File.swift")
        var counts: [Int] = []
        let observer = store.observeChanges { snapshot in
            counts.append(
                snapshot.presentationDiagnosticsByFile.values
                    .reduce(0) { $0 + $1.count }
            )
        }

        store.replace(owner: "swift", resource: url, diagnostics: [diagnostic(message: "One")])
        store.replace(owner: "swift", resource: url, diagnostics: [])
        store.removeObserver(observer)
        store.replace(owner: "swift", resource: url, diagnostics: [diagnostic(message: "Ignored")])

        XCTAssertEqual(counts, [0, 1, 0])
    }

    private func diagnostic(message: String) -> Diagnostic {
        Diagnostic(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 1)
            ),
            severity: .warning,
            code: nil,
            source: "test",
            message: message
        )
    }
}
