import Foundation
import XCTest
@testable import LanguageClient

/// Asserts Kod's process-launch discipline (SPEC 13.2): every executable
/// is launched via an absolute, pre-resolved `URL` with a fixed argument
/// array — never a shell string, never a `PATH` lookup, never string
/// interpolation that could be reinterpreted. Also asserts the allow-list
/// design that makes sending a mutating JSON-RPC method structurally
/// impossible from Kod's own code, independent of any given server's
/// behavior.
final class ProcessInvocationAssertionTests: XCTestCase {
    func testArgumentArrayIsPassedThroughVerbatimWithoutShellEvaluation() async throws {
        // Deliberately shell-metacharacter-laden arguments: if these were
        // ever passed through `/bin/sh -c` instead of `Process.arguments`,
        // they would be split/glob-expanded/substituted. Verifying they
        // arrive back byte-for-byte proves no shell evaluation occurred.
        let hostileArguments = ["normal", "; rm -rf / #", "$(whoami)", "`id`", "a b\"c'd"]
        let executableURL = try FakeLanguageServerLocator.executableURL()
        let configuration = LanguageServerConnection.Configuration(
            executableURL: executableURL,
            arguments: hostileArguments,
            rootURL: FileManager.default.temporaryDirectory
        )
        let logMessages = LockedArray<String>()
        let connection = LanguageServerConnection(configuration: configuration, onNotification: { notification in
            if case .logMessage(let text) = notification, text.hasPrefix("argv:") {
                logMessages.append(text)
            }
        })
        try await connection.start()
        defer { Task { await connection.shutdown() } }

        let deadline = Date().addingTimeInterval(3)
        while logMessages.count() == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let message = try XCTUnwrap(logMessages.snapshot().first)
        let echoedArguments = message
            .dropFirst("argv:".count)
            .components(separatedBy: "\u{1}")
        // `hostileArguments[0]` ("normal") selects the scenario and is
        // consumed by the fixture's own dispatch, not echoed as an extra
        // argument beyond argv itself — the echo reflects the process's
        // full `CommandLine.arguments` tail, i.e. every argument Kod
        // passed, unmangled.
        XCTAssertEqual(echoedArguments, hostileArguments)
    }

    func testLaunchingANonExecutablePathFailsRatherThanFallingBackToAShellOrPath() async throws {
        let configuration = LanguageServerConnection.Configuration(
            executableURL: URL(fileURLWithPath: "/definitely/does/not/exist/on/this/machine"),
            arguments: [],
            rootURL: FileManager.default.temporaryDirectory
        )
        let connection = LanguageServerConnection(configuration: configuration)
        do {
            try await connection.start()
            XCTFail("Expected start() to throw for a non-existent executable")
        } catch LanguageClientError.executableNotFound {
            // expected
        }
        let state = await connection.state
        guard case .missing = state else {
            return XCTFail("Expected .missing state, got \(state)")
        }
    }

    func testSourceKitLSPDiscoveryNeverUsesARelativeOrBarePathXcrunLookup() {
        XCTAssertTrue(SourceKitLSPDiscovery.xcrunURL.path.hasPrefix("/"))
    }
}

final class MutationGuardTests: XCTestCase {
    private static let knownMutatingMethodNames: Set<String> = [
        "textDocument/rename",
        "textDocument/codeAction",
        "textDocument/formatting",
        "textDocument/rangeFormatting",
        "textDocument/onTypeFormatting",
        "workspace/applyEdit",
        "workspace/executeCommand",
        "workspace/willCreateFiles",
        "workspace/didCreateFiles",
        "workspace/willRenameFiles",
        "workspace/didRenameFiles",
        "workspace/willDeleteFiles",
        "workspace/didDeleteFiles"
    ]

    func testNoOutboundMethodInTheAllowListIsAMutatingOperation() {
        for method in LanguageClientOutboundMethod.allCases {
            XCTAssertFalse(
                Self.knownMutatingMethodNames.contains(method.rawValue),
                "\(method.rawValue) is a mutating LSP method and must never be in the outbound allow-list"
            )
        }
    }

    func testApplyEditIsAlwaysRejected() {
        XCTAssertTrue(LanguageClientInboundMethod.applyEdit.isAlwaysRejected)
    }

    /// `registerCapability`/`unregisterCapability` are no longer a blanket
    /// "always rejected" — `LanguageServerConnection` now inspects a
    /// `registerCapability` batch's methods and accepts it only if every
    /// one is read-only (see `LanguageServerConnectionFixtureTests`'s
    /// dynamic-registration tests for the actual accept/reject behavior),
    /// and always accepts `unregisterCapability` since removing a
    /// registration can never grant a new capability.
    func testRegisterAndUnregisterCapabilityAreNotBlanketRejected() {
        XCTAssertFalse(LanguageClientInboundMethod.registerCapability.isAlwaysRejected)
        XCTAssertFalse(LanguageClientInboundMethod.unregisterCapability.isAlwaysRejected)
    }

    func testNonMutatingInboundMethodsAreNotRejected() {
        XCTAssertFalse(LanguageClientInboundMethod.workspaceConfiguration.isAlwaysRejected)
        XCTAssertFalse(LanguageClientInboundMethod.workspaceFolders.isAlwaysRejected)
        XCTAssertFalse(LanguageClientInboundMethod.createWorkDoneProgress.isAlwaysRejected)
        XCTAssertFalse(LanguageClientInboundMethod.showMessageRequest.isAlwaysRejected)
    }

    func testOperationNotPermittedUsesADistinctNonStandardErrorCode() {
        // -32001 is outside the reserved JSON-RPC (-32700...-32600) and
        // LSP (-32800, -32801, -32002) ranges, so it is unambiguous in
        // logs and never confusable with a spec-defined error.
        XCTAssertEqual(JSONRPCErrorCode.operationNotPermitted, -32001)
        let error = JSONRPCResponseError.operationNotPermitted("workspace/applyEdit")
        XCTAssertEqual(error.code, -32001)
    }
}
