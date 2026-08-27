import FontCore
import Foundation
import SettingsCore
import XCTest
@testable import Kod

@MainActor
final class SoftwareUpdateControllerTests: XCTestCase {
    func testCheckForUpdatesForwardsToInjectedController() throws {
        let fixture = try KodAppTestEnvironment.make(in: self)
        let updater = TestSoftwareUpdateController()
        let delegate = AppDelegate(
            environment: fixture.environment,
            softwareUpdater: updater
        )

        delegate.checkForUpdates()

        XCTAssertEqual(updater.checkCount, 1)
    }

    func testSettingsModelReadsAndWritesAutomaticCheckPreference() throws {
        let repository = CodableSettingsRepository(
            store: InMemorySettingsKeyValueStore()
        )
        let updater = TestSoftwareUpdateController()
        updater.automaticallyChecksForUpdates = false
        let model = try SettingsModel(
            fontSettingsStore: FontSettingsStore(repository: repository),
            softwareUpdater: updater
        )

        XCTAssertFalse(model.automaticallyChecksForUpdates)
        model.automaticallyChecksForUpdates = true

        XCTAssertTrue(updater.automaticallyChecksForUpdates)
    }

    func testFactoryStartsOnlyWithAValidKeyOutsideTests() {
        let validPublicKey = Data(repeating: 1, count: 32)
            .base64EncodedString()
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: "REPLACE_WITH_SPARKLE_PUBLIC_KEY",
                environment: [:],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: validPublicKey,
                environment: ["KOD_DISABLE_UPDATER": "1"],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: validPublicKey,
                environment: ["XCTestConfigurationFilePath": "tests.xctestconfiguration"],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: validPublicKey,
                environment: [:],
                isRunningTests: true
            )
        )
        XCTAssertTrue(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: validPublicKey,
                environment: [:],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: "not-base64",
                environment: [:],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: Data(repeating: 1, count: 31).base64EncodedString(),
                environment: [:],
                isRunningTests: false
            )
        )
        XCTAssertFalse(
            SoftwareUpdateControllerFactory.shouldStartUpdater(
                publicKey: nil,
                environment: [:],
                isRunningTests: false
            )
        )
    }

    func testFactoryNeverConstructsSparkleForTheTestHost() {
        let validPublicKey = Data(repeating: 1, count: 32)
            .base64EncodedString()
        var didConstructSparkleController = false

        let updater = SoftwareUpdateControllerFactory.production(
            bundle: .main,
            publicKey: validPublicKey,
            environment: [:],
            isRunningTests: true,
            makeSparkleController: {
                didConstructSparkleController = true
                return TestSoftwareUpdateController()
            }
        )

        XCTAssertTrue(SoftwareUpdateControllerFactory.isRunningUnderXCTest)
        XCTAssertFalse(didConstructSparkleController)
        XCTAssertTrue(updater is DisabledSoftwareUpdateController)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.canCheckForUpdates)
    }

    func testFactoryConstructsUpdaterWithAValidDeveloperBuildKey() {
        let validPublicKey = Data(repeating: 1, count: 32)
            .base64EncodedString()
        var didConstructSparkleController = false

        let updater = SoftwareUpdateControllerFactory.production(
            publicKey: validPublicKey,
            environment: [:],
            isRunningTests: false,
            makeSparkleController: {
                didConstructSparkleController = true
                return TestSoftwareUpdateController()
            }
        )

        XCTAssertTrue(didConstructSparkleController)
        XCTAssertTrue(updater is TestSoftwareUpdateController)
    }
}

@MainActor
private final class TestSoftwareUpdateController:
    SoftwareUpdateControlling
{
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}
