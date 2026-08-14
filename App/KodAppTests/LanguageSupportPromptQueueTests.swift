import Foundation
import XCTest
@testable import Kod

/// Deterministic, view-free coverage for `LanguageSupportPromptQueue` —
/// the state machine behind the missing-server / unknown-file-type
/// banner. Nothing here constructs a workspace controller, a session, or
/// a language-support service: queueing, de-duplication, suppression,
/// generation invalidation and resolution are pure state transitions.
@MainActor
final class LanguageSupportPromptQueueTests: XCTestCase {
    private func makeQueue() -> LanguageSupportPromptQueue {
        LanguageSupportPromptQueue()
    }

    func testQueueStartsEmpty() {
        let queue = makeQueue()
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.dequeueMissingServerCandidate())
        XCTAssertNil(queue.dequeueUnknownFileTypeCandidate())
    }

    func testMissingServerKeysAreQueuedOnceAndDrainedInOrder() {
        let queue = makeQueue()
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "swift"))
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "python"))
        XCTAssertFalse(
            queue.enqueueMissingServer(languageKey: "swift"),
            "An already-queued key must not be queued twice"
        )

        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "swift")
        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "python")
        XCTAssertNil(queue.dequeueMissingServerCandidate())
    }

    func testThePresentedKeyIsNotRequeued() {
        let queue = makeQueue()
        queue.activate(.missingServer(languageKey: "swift"))

        XCTAssertFalse(queue.enqueueMissingServer(languageKey: "swift"))
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "rust"))
    }

    func testSuppressedKeysAreNeitherQueuedNorDequeued() {
        let queue = makeQueue()
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "swift"))
        queue.activate(.missingServer(languageKey: "python"))
        queue.finishCurrent(suppressForSession: true)

        // Suppression applies to future enqueues...
        XCTAssertFalse(queue.enqueueMissingServer(languageKey: "python"))
        // ...and to a key that was already sitting in the queue.
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "rust"))
        queue.activate(.missingServer(languageKey: "rust"))
        queue.finishCurrent(suppressForSession: true)
        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "swift")
        XCTAssertNil(queue.dequeueMissingServerCandidate())
    }

    func testResolvingWithoutSuppressionLetsTheKeyPromptAgain() {
        let queue = makeQueue()
        queue.activate(.missingServer(languageKey: "swift"))
        queue.finishCurrent(suppressForSession: false)

        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.enqueueMissingServer(languageKey: "swift"))
    }

    func testUnknownFileTypesAreKeyedByExtensionAndDeduplicated() {
        let queue = makeQueue()
        let first = URL(fileURLWithPath: "/tmp/a.zzz")
        let second = URL(fileURLWithPath: "/tmp/b.zzz")

        XCTAssertTrue(queue.enqueueUnknownFileType(url: first))
        XCTAssertFalse(
            queue.enqueueUnknownFileType(url: first),
            "The same URL must not queue twice"
        )
        XCTAssertFalse(
            queue.enqueueUnknownFileType(url: second),
            "Unknown file prompts are deduplicated by extension"
        )

        XCTAssertEqual(
            LanguageSupportPromptQueue.unknownLanguageKey(for: first),
            "unknown:zzz"
        )
        XCTAssertEqual(queue.dequeueUnknownFileTypeCandidate(), first)
    }

    func testExtensionLessFilesNeverPrompt() {
        let queue = makeQueue()
        XCTAssertFalse(
            queue.enqueueUnknownFileType(url: URL(fileURLWithPath: "/tmp/Makefile"))
        )
        XCTAssertNil(queue.dequeueUnknownFileTypeCandidate())
    }

    func testSuppressingAnUnknownFileTypePromptSuppressesItsWholeExtension() {
        let queue = makeQueue()
        let url = URL(fileURLWithPath: "/tmp/a.zzz")
        queue.activate(.unknownFileType(url: url))
        XCTAssertEqual(queue.currentUnknownFileTypeURL, url)
        XCTAssertNil(queue.currentMissingServerKey)

        queue.finishCurrent(suppressForSession: true)

        XCTAssertFalse(
            queue.enqueueUnknownFileType(url: URL(fileURLWithPath: "/tmp/other.zzz"))
        )
    }

    func testOnlyOnePreparationPassRunsAtATime() {
        let queue = makeQueue()
        XCTAssertTrue(queue.beginPreparing())
        XCTAssertFalse(queue.beginPreparing(), "A second pass must not start")

        queue.endPreparing()
        XCTAssertTrue(queue.beginPreparing())
    }

    func testPreparationIsRefusedWhileAPromptIsAlreadyPresented() {
        let queue = makeQueue()
        queue.activate(.missingServer(languageKey: "swift"))

        XCTAssertFalse(queue.beginPreparing())
    }

    func testStaleGenerationCandidatesGoBackToTheFrontOfTheQueue() {
        let queue = makeQueue()
        queue.enqueueMissingServer(languageKey: "swift")
        queue.enqueueMissingServer(languageKey: "python")
        let candidate = queue.dequeueMissingServerCandidate()
        XCTAssertEqual(candidate, "swift")

        let generationBefore = queue.generation
        queue.bumpGeneration()
        XCTAssertNotEqual(queue.generation, generationBefore)
        queue.requeueMissingServerCandidate("swift")
        queue.requeueMissingServerCandidate("swift")

        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "swift")
        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "python")
        XCTAssertNil(queue.dequeueMissingServerCandidate())
    }

    func testProfileConfigurationChangeCanDropASingleQueuedKey() {
        let queue = makeQueue()
        queue.enqueueMissingServer(languageKey: "swift")
        queue.enqueueMissingServer(languageKey: "python")

        queue.removeQueuedMissingServer(languageKey: "swift")

        XCTAssertEqual(queue.dequeueMissingServerCandidate(), "python")
        XCTAssertNil(queue.dequeueMissingServerCandidate())
    }

    /// Revoking trust must not leave a stale prompt or queue behind, but
    /// "Not Now" suppression is a session decision and survives.
    func testCancelAllClearsEverythingExceptSessionSuppression() {
        let queue = makeQueue()
        queue.activate(.missingServer(languageKey: "swift"))
        queue.finishCurrent(suppressForSession: true)
        queue.enqueueMissingServer(languageKey: "python")
        queue.enqueueUnknownFileType(url: URL(fileURLWithPath: "/tmp/a.zzz"))
        queue.activate(.missingServer(languageKey: "rust"))
        let generationBefore = queue.generation

        queue.cancelAll()

        XCTAssertNil(queue.current)
        XCTAssertNil(queue.dequeueMissingServerCandidate())
        XCTAssertNil(queue.dequeueUnknownFileTypeCandidate())
        XCTAssertNotEqual(queue.generation, generationBefore)
        XCTAssertFalse(queue.enqueueMissingServer(languageKey: "swift"))
    }

    func testPromptExposesItsKeyForBothKinds() {
        XCTAssertEqual(
            LanguageSupportPromptQueue.Prompt
                .missingServer(languageKey: "swift").languageKey,
            "swift"
        )
        XCTAssertEqual(
            LanguageSupportPromptQueue.Prompt
                .unknownFileType(url: URL(fileURLWithPath: "/tmp/a.ZZZ")).languageKey,
            "unknown:zzz"
        )
    }
}
