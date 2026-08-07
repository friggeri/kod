import XCTest
@testable import KodCore

final class KodBuildInfoTests: XCTestCase {
    func testDisplayDescriptionIncludesEveryBuildField() {
        let info = KodBuildInfo(
            version: "1.2.3",
            build: "42",
            architecture: "Test architecture"
        )

        XCTAssertEqual(
            info.displayDescription,
            "Version 1.2.3 (42) - Test architecture"
        )
    }

    func testDescriptionFormattingPerformance() {
        let info = KodBuildInfo(
            version: "1.2.3",
            build: "42",
            architecture: "Test architecture"
        )

        measure {
            for _ in 0..<10_000 {
                _ = info.displayDescription
            }
        }
    }
}

