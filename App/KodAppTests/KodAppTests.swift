import KodCore
import XCTest

final class KodAppTests: XCTestCase {
    func testBuildInformationHasStablePresentation() {
        let info = KodBuildInfo(
            version: "0.1.0",
            build: "1",
            architecture: "Test"
        )

        XCTAssertEqual(info.displayDescription, "Version 0.1.0 (1) - Test")
    }
}

