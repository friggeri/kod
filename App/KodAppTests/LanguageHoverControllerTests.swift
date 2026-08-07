import AppKit
import CodeViewport
import Foundation
import LanguageClient
import SourceModel
import XCTest
@testable import Kod

private actor HoverTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@MainActor
final class LanguageHoverControllerTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

    private func makeController(
        text: String = "alpha beta gamma",
        url: URL = URL(fileURLWithPath: "/tmp/LanguageHoverControllerTests.ts"),
        version: Int = 1
    ) -> CodeDocumentViewController {
        CodeDocumentViewController(
            snapshot: SourceSnapshot(text: text, url: url, version: version)
        )
    }

    private func makeHover(_ value: String) throws -> Hover {
        let data = try JSONSerialization.data(withJSONObject: [
            "contents": [
                "kind": "plaintext",
                "value": value
            ]
        ])
        return try JSONDecoder().decode(Hover.self, from: data)
    }

    private func makeTarget(url: URL) -> NavigationTarget {
        NavigationTarget(
            url: url,
            range: LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: LSPPosition(line: 0, character: 5)
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testRequestsDispatchImmediatelyAndMovementWithinTokenIsCoalesced() async throws {
        let controller = makeController()
        let range = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let hover = try makeHover("alpha hover")
        var hoverCalls = 0
        var definitionCalls = 0
        let subject = LanguageHoverController(
            dwellDuration: .seconds(5),
            hoverRequest: { _, _ in
                hoverCalls += 1
                return hover
            },
            definitionRequest: { _, _ in
                definitionCalls += 1
                return []
            }
        )

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.lowerBound,
            targetRange: range,
            anchorRect: .zero
        )
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.upperBound - 1,
            targetRange: range,
            anchorRect: NSRect(x: 10, y: 10, width: 1, height: 1)
        )

        await waitUntil { hoverCalls == 1 && definitionCalls == 1 }
        subject.cancel()
    }

    func testDefinitionConfirmationAlsoSupportsOperatorTokens() async throws {
        let controller = makeController(text: "+")
        let range = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let target = makeTarget(url: controller.snapshot.url)
        var definitionApplications = 0
        let subject = LanguageHoverController(
            dwellDuration: .zero,
            hoverRequest: { _, _ in nil },
            definitionRequest: { _, _ in [target] }
        )
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: 0,
            targetRange: range,
            anchorRect: .zero
        )

        await waitUntil { definitionApplications == 1 }
        XCTAssertEqual(controller.viewport.hoveredLinkUTF8Range, range)
        subject.cancel()
    }

    func testHoverHonorsDwellWithoutWaitingForDefinition() async throws {
        let controller = makeController()
        let range = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let hover = try makeHover("alpha hover")
        let definitionGate = HoverTestGate()
        var hoverApplications = 0
        var definitionApplications = 0
        let subject = LanguageHoverController(
            hoverRequest: { _, _ in hover },
            definitionRequest: { _, _ in
                await definitionGate.wait()
                return []
            }
        )
        subject.onHoverApplied = { _, _ in hoverApplications += 1 }
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.lowerBound,
            targetRange: range,
            anchorRect: .zero
        )

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(hoverApplications, 0, "The 75 ms presentation dwell must prevent flicker")
        await waitUntil { hoverApplications == 1 }
        XCTAssertEqual(definitionApplications, 0, "Definition latency must not block hover content")

        await definitionGate.open()
        await waitUntil { definitionApplications == 1 }
        subject.cancel()
    }

    func testDefinitionAppliesWithoutWaitingForHover() async throws {
        let controller = makeController()
        let range = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let hover = try makeHover("alpha hover")
        let hoverGate = HoverTestGate()
        let target = makeTarget(url: controller.snapshot.url)
        var hoverApplications = 0
        var definitionApplications = 0
        let subject = LanguageHoverController(
            hoverRequest: { _, _ in
                await hoverGate.wait()
                return hover
            },
            definitionRequest: { _, _ in [target] }
        )
        subject.onHoverApplied = { _, _ in hoverApplications += 1 }
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.lowerBound,
            targetRange: range,
            anchorRect: .zero
        )

        await waitUntil { definitionApplications == 1 }
        XCTAssertEqual(hoverApplications, 0)
        XCTAssertEqual(controller.viewport.hoveredLinkUTF8Range, range)

        await hoverGate.open()
        await waitUntil { hoverApplications == 1 }
        subject.cancel()
    }

    func testLateResultFromPreviousTokenCannotMutateCurrentHover() async throws {
        let controller = makeController()
        let alphaRange = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let betaRange = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 6))
        let alphaHover = try makeHover("alpha hover")
        let betaHover = try makeHover("beta hover")
        let alphaGate = HoverTestGate()
        var hoverCalls = 0
        var appliedValues: [String] = []
        let subject = LanguageHoverController(
            dwellDuration: .zero,
            hoverRequest: { _, offset in
                hoverCalls += 1
                if offset == alphaRange.lowerBound {
                    await alphaGate.wait()
                    return alphaHover
                }
                return betaHover
            },
            definitionRequest: { _, _ in [] }
        )
        subject.onHoverApplied = { _, hover in
            if let hover {
                appliedValues.append(hover.contents.value)
            }
        }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: alphaRange.lowerBound,
            targetRange: alphaRange,
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 1 }
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: betaRange.lowerBound,
            targetRange: betaRange,
            anchorRect: .zero
        )
        await waitUntil { appliedValues == ["beta hover"] }

        await alphaGate.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(appliedValues, ["beta hover"])
        subject.cancel()
    }

    func testPositiveAndNegativeResultsAreCachedForNavigation() async throws {
        let controller = makeController()
        let alphaRange = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let betaRange = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 6))
        let hover = try makeHover("alpha hover")
        let target = makeTarget(url: controller.snapshot.url)
        var hoverCalls = 0
        var definitionCalls = 0
        var hoverApplications = 0
        var definitionApplications = 0
        let subject = LanguageHoverController(
            dwellDuration: .zero,
            hoverRequest: { _, offset in
                hoverCalls += 1
                return offset == alphaRange.lowerBound ? hover : nil
            },
            definitionRequest: { _, offset in
                definitionCalls += 1
                return offset == alphaRange.lowerBound ? [target] : []
            }
        )
        subject.onHoverApplied = { _, _ in hoverApplications += 1 }
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: alphaRange.lowerBound,
            targetRange: alphaRange,
            anchorRect: .zero
        )
        await waitUntil { hoverApplications == 1 && definitionApplications == 1 }
        subject.cancel()
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: alphaRange.lowerBound,
            targetRange: alphaRange,
            anchorRect: .zero
        )
        XCTAssertEqual(hoverCalls, 1)
        XCTAssertEqual(definitionCalls, 1)
        guard case .resolved(let cachedTargets) = subject.cachedDefinitions(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: alphaRange.lowerBound
        ) else {
            return XCTFail("Expected cached definition targets")
        }
        XCTAssertEqual(cachedTargets, [target])

        subject.cancel()
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: betaRange.lowerBound,
            targetRange: betaRange,
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 2 && definitionCalls == 2 }
        subject.cancel()
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: betaRange.lowerBound,
            targetRange: betaRange,
            anchorRect: .zero
        )
        XCTAssertEqual(hoverCalls, 2, "A legitimate nil hover must be cached")
        XCTAssertEqual(definitionCalls, 2, "A legitimate empty definition must be cached")
        guard case .resolved(let cachedNegative) = subject.cachedDefinitions(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: betaRange.lowerBound
        ) else {
            return XCTFail("Expected cached negative definition result")
        }
        XCTAssertTrue(cachedNegative.isEmpty)
        subject.cancel()
    }

    func testCacheIsBoundedVersionedAndProviderInvalidationIsScoped() async throws {
        let url = URL(fileURLWithPath: "/tmp/LanguageHoverControllerCacheTests.ts")
        let controller = makeController(url: url)
        let offsets = [0, 6, 11]
        let ranges = try offsets.map {
            try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: $0))
        }
        let hover = try makeHover("hover")
        var hoverCalls = 0
        var definitionCalls = 0
        var hoverApplications = 0
        var definitionApplications = 0
        let subject = LanguageHoverController(
            dwellDuration: .zero,
            cacheCapacity: 2,
            hoverRequest: { _, _ in
                hoverCalls += 1
                return hover
            },
            definitionRequest: { _, _ in
                definitionCalls += 1
                return []
            }
        )
        subject.onHoverApplied = { _, _ in hoverApplications += 1 }
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        for (index, range) in ranges.enumerated() {
            subject.update(
                controller: controller,
                providerIdentifier: "typescript",
                utf8Offset: range.lowerBound,
                targetRange: range,
                anchorRect: .zero
            )
            await waitUntil {
                hoverApplications == index + 1 && definitionApplications == index + 1
            }
            subject.cancel()
        }
        XCTAssertEqual(subject.cachedEntryCount, 2)

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: ranges[0].lowerBound,
            targetRange: ranges[0],
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 4 && definitionCalls == 4 }
        subject.cancel()

        subject.update(
            controller: controller,
            providerIdentifier: "swift",
            utf8Offset: ranges[0].lowerBound,
            targetRange: ranges[0],
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 5 && definitionCalls == 5 }
        let swiftHoverApplications = hoverApplications
        subject.invalidateCache(forProvider: "typescript")
        subject.update(
            controller: controller,
            providerIdentifier: "swift",
            utf8Offset: ranges[0].lowerBound,
            targetRange: ranges[0],
            anchorRect: .zero
        )
        XCTAssertEqual(hoverCalls, 5, "Invalidating TypeScript must retain Swift cache entries")
        XCTAssertEqual(
            hoverApplications,
            swiftHoverApplications,
            "Invalidating TypeScript must not restart an active Swift interaction"
        )
        subject.cancel()

        let versionTwoController = makeController(url: url, version: 2)
        let versionTwoRange = try XCTUnwrap(
            versionTwoController.viewport.hoverTargetUTF8Range(at: ranges[0].lowerBound)
        )
        subject.update(
            controller: versionTwoController,
            providerIdentifier: "swift",
            utf8Offset: versionTwoRange.lowerBound,
            targetRange: versionTwoRange,
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 6 && definitionCalls == 6 }
        subject.cancel()
    }

    func testRequestFailuresAreNotCached() async throws {
        let controller = makeController()
        let range = try XCTUnwrap(controller.viewport.hoverTargetUTF8Range(at: 0))
        let hover = try makeHover("recovered")
        var hoverCalls = 0
        var definitionCalls = 0
        var hoverApplications = 0
        var definitionApplications = 0
        let subject = LanguageHoverController(
            dwellDuration: .zero,
            hoverRequest: { _, _ in
                hoverCalls += 1
                if hoverCalls == 1 {
                    throw TestError.failed
                }
                return hover
            },
            definitionRequest: { _, _ in
                definitionCalls += 1
                if definitionCalls == 1 {
                    throw TestError.failed
                }
                return []
            }
        )
        subject.onHoverApplied = { _, _ in hoverApplications += 1 }
        subject.onDefinitionsApplied = { _, _ in definitionApplications += 1 }

        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.lowerBound,
            targetRange: range,
            anchorRect: .zero
        )
        await waitUntil { hoverCalls == 1 && definitionCalls == 1 }
        try await Task.sleep(for: .milliseconds(20))
        subject.cancel()
        subject.update(
            controller: controller,
            providerIdentifier: "typescript",
            utf8Offset: range.lowerBound,
            targetRange: range,
            anchorRect: .zero
        )
        await waitUntil {
            hoverCalls == 2 && definitionCalls == 2
                && hoverApplications == 1 && definitionApplications == 1
        }
        subject.cancel()
    }
}
