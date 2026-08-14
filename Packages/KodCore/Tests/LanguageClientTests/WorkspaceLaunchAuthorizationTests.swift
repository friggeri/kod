import Foundation
import XCTest
@testable import LanguageClient

/// Trust-before-launch and workspace path confinement, expressed as
/// injected, platform-neutral capabilities: no `WorkspaceCore` types, no
/// `UserDefaults` suite, no persistence of any kind.
final class WorkspaceLaunchAuthorizationTests: XCTestCase {
    func testAllowAndDenyAreEvaluatedWithoutAnyPersistence() async {
        let allowed = await WorkspaceLaunchAuthorization.authorized.isAuthorized()
        let denied = await WorkspaceLaunchAuthorization.denied.isAuthorized()

        XCTAssertTrue(allowed)
        XCTAssertFalse(denied)
    }

    /// The gate is evaluated on every attempt rather than cached, so
    /// granting or revoking trust takes effect on the next launch.
    func testAuthorizationIsReevaluatedOnEveryQuery() async {
        let isAuthorized = LockedBox(false)
        let authorization = WorkspaceLaunchAuthorization { isAuthorized.get() }

        let before = await authorization.isAuthorized()
        isAuthorized.set(true)
        let after = await authorization.isAuthorized()
        isAuthorized.set(false)
        let revoked = await authorization.isAuthorized()

        XCTAssertFalse(before)
        XCTAssertTrue(after)
        XCTAssertFalse(revoked)
    }

    func testMainActorAuthorizationHopsToTheMainActor() async {
        let sawMainThread = LockedBox(false)
        let authorization = WorkspaceLaunchAuthorization.mainActor {
            sawMainThread.set(Thread.isMainThread)
            return true
        }

        let authorized = await authorization.isAuthorized()
        XCTAssertTrue(authorized)
        XCTAssertTrue(sawMainThread.get())
    }

    /// A host trust store adapts to the capability through
    /// `WorkspaceTrustAuthorizing`, which is how the app's real
    /// `WorkspaceIdentity`/`WorkspaceTrustStore` pair enters this module
    /// without being imported by it.
    func testHostTrustStoresAdaptThroughTheAuthorizingProtocol() async {
        let root = URL(fileURLWithPath: "/tmp/kod-authorization", isDirectory: true)
        let store = StubTrustStore(trustedRoots: [root])

        let trusted = await WorkspaceLaunchAuthorization
            .trustStore(store, workspace: StubWorkspace(root: root))
            .isAuthorized()
        let untrusted = await WorkspaceLaunchAuthorization
            .trustStore(
                store,
                workspace: StubWorkspace(root: URL(fileURLWithPath: "/tmp/elsewhere"))
            )
            .isAuthorized()

        XCTAssertTrue(trusted)
        XCTAssertFalse(untrusted)
        XCTAssertEqual(store.workspaceRoot(of: StubWorkspace(root: root)), root)
    }
}

private struct StubWorkspace: Sendable {
    let root: URL
}

private final class StubTrustStore: WorkspaceTrustAuthorizing, @unchecked Sendable {
    private let trustedRoots: Set<URL>

    init(trustedRoots: Set<URL>) {
        self.trustedRoots = trustedRoots
    }

    @MainActor func isTrusted(_ workspace: StubWorkspace) -> Bool {
        trustedRoots.contains(workspace.root)
    }

    nonisolated func workspaceRoot(of workspace: StubWorkspace) -> URL {
        workspace.root
    }
}

/// Path confinement for everything an external server process reports.
final class WorkspaceRootConfinementTests: XCTestCase {
    private let confinement = WorkspaceRootConfinement(
        root: URL(fileURLWithPath: "/tmp/kod-workspace", isDirectory: true)
    )

    func testTheRootItselfAndItsDescendantsAreInside() {
        XCTAssertTrue(
            confinement.contains(URL(fileURLWithPath: "/tmp/kod-workspace"))
        )
        XCTAssertTrue(
            confinement.contains(URL(fileURLWithPath: "/tmp/kod-workspace/Sources/A.ts"))
        )
    }

    /// A sibling directory that merely shares a textual prefix is outside:
    /// confinement is compared on path component boundaries.
    func testASiblingSharingATextualPrefixIsOutside() {
        XCTAssertFalse(
            confinement.contains(URL(fileURLWithPath: "/tmp/kod-workspace-backup/A.ts"))
        )
        XCTAssertFalse(
            confinement.contains(URL(fileURLWithPath: "/tmp/elsewhere/A.ts"))
        )
    }

    func testTraversalIsStandardizedBeforeComparison() {
        XCTAssertNil(
            confinement.confinedFileURL(
                for: URL(fileURLWithPath: "/tmp/kod-workspace/../secrets.txt")
            ),
            "A traversal that escapes the root must be rejected"
        )
        XCTAssertEqual(
            confinement.confinedFileURL(
                for: URL(fileURLWithPath: "/tmp/kod-workspace/./Sources/A.ts")
            )?.path,
            "/tmp/kod-workspace/Sources/A.ts"
        )
    }

    func testNonFileURIsAreRejected() {
        XCTAssertNil(
            confinement.confinedFileURL(
                for: DocumentURI(stringValue: "https://example.com/A.ts")
            )
        )
        XCTAssertNil(
            confinement.confinedFileURL(
                for: DocumentURI(stringValue: "untitled:Untitled-1")
            )
        )
    }

    func testAFileURIInsideTheWorkspaceIsStandardizedAndAccepted() {
        let uri = DocumentURI(
            fileURL: URL(fileURLWithPath: "/tmp/kod-workspace/Sources/A.ts")
        )
        XCTAssertEqual(
            confinement.confinedFileURL(for: uri)?.path,
            "/tmp/kod-workspace/Sources/A.ts"
        )
    }

    func testARootWithATrailingSlashBehavesIdentically() {
        let slashed = WorkspaceRootConfinement(
            root: URL(fileURLWithPath: "/tmp/kod-workspace/", isDirectory: true)
        )
        XCTAssertTrue(
            slashed.contains(URL(fileURLWithPath: "/tmp/kod-workspace/A.ts"))
        )
        XCTAssertFalse(
            slashed.contains(URL(fileURLWithPath: "/tmp/kod-workspace-backup/A.ts"))
        )
    }
}
