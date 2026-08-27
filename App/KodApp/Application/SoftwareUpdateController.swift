import Foundation
import Sparkle

@MainActor
protocol SoftwareUpdateControlling: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    func checkForUpdates()
}

@MainActor
final class SparkleSoftwareUpdateController: SoftwareUpdateControlling {
    private let controller: SPUStandardUpdaterController

    init(
        controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    ) {
        self.controller = controller
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class DisabledSoftwareUpdateController: SoftwareUpdateControlling {
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = false

    func checkForUpdates() {}
}

@MainActor
enum SoftwareUpdateControllerFactory {
    static let isRunningUnderXCTest: Bool = {
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        return Bundle.allBundles.contains {
            $0.bundleURL.pathExtension == "xctest"
        }
    }()

    static func production(
        bundle: Bundle = .main,
        publicKey: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRunningTests: Bool = SoftwareUpdateControllerFactory
            .isRunningUnderXCTest,
        makeSparkleController: @MainActor () -> any SoftwareUpdateControlling = {
            SparkleSoftwareUpdateController()
        }
    ) -> any SoftwareUpdateControlling {
        let configuredPublicKey = publicKey ?? bundle.object(
            forInfoDictionaryKey: "SUPublicEDKey"
        ) as? String
        guard shouldStartUpdater(
            publicKey: configuredPublicKey,
            environment: environment,
            isRunningTests: isRunningTests
        ) else {
            return DisabledSoftwareUpdateController()
        }
        return makeSparkleController()
    }

    static func shouldStartUpdater(
        publicKey: String?,
        environment: [String: String],
        isRunningTests: Bool = SoftwareUpdateControllerFactory
            .isRunningUnderXCTest
    ) -> Bool {
        guard !isRunningTests,
              environment["KOD_DISABLE_UPDATER"] != "1",
              environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil,
              isValidPublicKey(publicKey) else {
            return false
        }
        return true
    }

    private static func isValidPublicKey(_ publicKey: String?) -> Bool {
        guard let publicKey,
              !publicKey.isEmpty,
              publicKey == publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
              publicKey != "REPLACE_WITH_SPARKLE_PUBLIC_KEY",
              publicKey != "$(SPARKLE_PUBLIC_ED_KEY)",
              let decoded = Data(base64Encoded: publicKey),
              decoded.count == 32,
              decoded.base64EncodedString() == publicKey else {
            return false
        }
        return true
    }
}
