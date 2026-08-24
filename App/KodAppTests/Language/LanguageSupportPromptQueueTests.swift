import Foundation
import XCTest
@testable import Kod

@MainActor
final class LanguageSupportPromptQueueTests: XCTestCase {
    func testUnknownFileTypesAreKeyedByExtensionAndDeduplicated() {
        let queue = LanguageSupportPromptQueue()
        let first = URL(fileURLWithPath: "/tmp/a.zzz")
        let second = URL(fileURLWithPath: "/tmp/b.zzz")

        XCTAssertTrue(queue.enqueueUnknownFileType(url: first))
        XCTAssertFalse(queue.enqueueUnknownFileType(url: first))
        XCTAssertFalse(queue.enqueueUnknownFileType(url: second))
        XCTAssertEqual(
            LanguageSupportPromptQueue.unknownLanguageKey(for: first),
            "unknown:zzz"
        )
        XCTAssertEqual(queue.dequeueUnknownFileTypeCandidate(), first)
    }

    func testExtensionlessFilesNeverPrompt() {
        let queue = LanguageSupportPromptQueue()

        XCTAssertFalse(
            queue.enqueueUnknownFileType(
                url: URL(fileURLWithPath: "/tmp/Makefile")
            )
        )
        XCTAssertNil(queue.dequeueUnknownFileTypeCandidate())
    }

    func testSuppressingAPromptSuppressesItsWholeExtension() {
        let queue = LanguageSupportPromptQueue()
        let url = URL(fileURLWithPath: "/tmp/a.zzz")
        queue.activateUnknownFileType(url)

        queue.finishCurrent(suppressForSession: true)

        XCTAssertFalse(
            queue.enqueueUnknownFileType(
                url: URL(fileURLWithPath: "/tmp/other.zzz")
            )
        )
    }

    func testOnlyOnePreparationPassRunsAtATime() {
        let queue = LanguageSupportPromptQueue()

        XCTAssertTrue(queue.beginPreparing())
        XCTAssertFalse(queue.beginPreparing())
        queue.endPreparing()
        XCTAssertTrue(queue.beginPreparing())
    }

    func testPreparationIsRefusedWhileAPromptIsPresented() {
        let queue = LanguageSupportPromptQueue()
        queue.activateUnknownFileType(URL(fileURLWithPath: "/tmp/a.zzz"))

        XCTAssertFalse(queue.beginPreparing())
    }

    func testCancelAllClearsQueueAndPresentationButKeepsSuppression() {
        let queue = LanguageSupportPromptQueue()
        let suppressed = URL(fileURLWithPath: "/tmp/a.zzz")
        queue.activateUnknownFileType(suppressed)
        queue.finishCurrent(suppressForSession: true)
        queue.enqueueUnknownFileType(url: URL(fileURLWithPath: "/tmp/a.abc"))
        queue.activateUnknownFileType(URL(fileURLWithPath: "/tmp/a.def"))

        queue.cancelAll()

        XCTAssertNil(queue.currentUnknownFileTypeURL)
        XCTAssertNil(queue.dequeueUnknownFileTypeCandidate())
        XCTAssertFalse(queue.enqueueUnknownFileType(url: suppressed))
    }
}
