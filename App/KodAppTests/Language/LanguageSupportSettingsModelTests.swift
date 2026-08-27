import AppKit
import Foundation
import KodUIComponents
import LanguageAdapters
import XCTest
@testable import Kod

@MainActor
final class SettingsNavigationModelTests: XCTestCase {
    func testSelectionKeepsExistingLanguageAndFallsBackForMissingOne() {
        let items = makeItems()
        let model = SettingsNavigationModel(
            selectedDestination: .language("typescript")
        )

        model.reconcileSelection(in: items)
        XCTAssertEqual(
            model.selectedDestination,
            .language("typescript")
        )

        model.selectedDestination = .language("retired")
        model.reconcileSelection(in: items)
        XCTAssertEqual(model.selectedDestination, .updates)
    }

    func testExternalLanguageSelectionUpdatesDestination() {
        let model = SettingsNavigationModel()

        model.selectLanguage("typescript")
        XCTAssertEqual(
            model.selectedDestination,
            .language("typescript")
        )
    }

    func testRepresentativeFilesResolveMaterialLanguageIcons() {
        XCTAssertEqual(
            SettingsLanguageIcon.fileName(for: "swift"),
            "Example.swift"
        )
        XCTAssertEqual(
            SettingsLanguageIcon.fileName(for: "typescript"),
            "Example.ts"
        )
        XCTAssertEqual(
            SettingsLanguageIcon.fileName(for: "python"),
            "example.py"
        )
        XCTAssertEqual(
            SettingsLanguageIcon.fileName(for: "unknown"),
            "file.txt"
        )
        XCTAssertEqual(SettingsLanguageIcon.pointSize, 12)

        let jsonIcon = MaterialFileIconView()
        jsonIcon.fileName = SettingsLanguageIcon.fileName(for: "json")
        XCTAssertNotNil(jsonIcon.image)
        XCTAssertNotEqual(jsonIcon.image?.size, .zero)
    }

    func testStatusPresentationUsesConciseServerStates() {
        XCTAssertEqual(
            LanguageSupportServerState.syntaxOnly.presentation.title,
            "Syntax Only"
        )
        XCTAssertEqual(
            LanguageSupportServerState.checking.presentation.title,
            "Checking"
        )
        let available = LanguageSupportServerState.available(
            DiscoveredExecutable(
                url: URL(fileURLWithPath: "/usr/bin/clangd"),
                arguments: [],
                version: "clangd version 18.1.8\nApple build",
                source: .loginShellPath
            )
        )
        XCTAssertEqual(available.presentation.title, "Ready")
        XCTAssertEqual(
            available.installedMetadata,
            "clangd version 18.1.8"
        )
        XCTAssertEqual(
            available.installedMetadataHelp,
            "Login shell PATH: /usr/bin/clangd"
        )
        XCTAssertEqual(
            LanguageSupportServerState.available(
                DiscoveredExecutable(
                    url: URL(fileURLWithPath: "/usr/bin/sourcekit-lsp"),
                    arguments: [],
                    version: nil,
                    source: .languageSpecificTool
                )
            ).installedMetadata,
            "sourcekit-lsp"
        )
        XCTAssertEqual(
            LanguageSupportServerState.missing("Not found")
                .presentation.title,
            "Not Installed"
        )
    }

    private func makeItems() -> [LanguageSupportItem] {
        var typeScript = DefaultLanguageProfiles.typeScript
        typeScript.languageServer?.selectedExecutable =
            RegisteredLanguageServerExecutable(
                path: "/opt/tools/typescript-language-server",
                arguments: ["--stdio"]
            )

        return [
            item(
                profile: DefaultLanguageProfiles.swift,
                state: .missing("Not found")
            ),
            item(
                profile: typeScript,
                state: .available(
                    DiscoveredExecutable(
                        url: URL(
                            fileURLWithPath:
                                "/opt/tools/typescript-language-server"
                        ),
                        arguments: ["--stdio"],
                        version: "1.0",
                        source: .registeredProfile
                    )
                )
            )
        ]
    }

    private func item(
        profile: LanguageProfile,
        state: LanguageSupportServerState
    ) -> LanguageSupportItem {
        LanguageSupportItem(
            profile: profile,
            serverState: state
        )
    }
}
