import Foundation
import XCTest
@testable import LanguageAdapters

/// Focused coverage for the curated, shipped-only installation-guidance
/// catalog (`DefaultLanguageServerInstallationGuides`). This catalog is
/// deliberately separate from the Codable `LanguageProfile`/
/// `LanguageServerConfiguration` model (see that type's doc comment):
/// these tests exist to guard the catalog's *content* invariants (every
/// default LSP-capable profile is covered, every documentation link is
/// HTTPS, every command is display-safe, XML is docs-only, and a
/// spoofed custom profile can never resolve guidance) rather than
/// re-describing the implementation.
final class LanguageServerInstallationGuideTests: XCTestCase {
    func testCatalogCoversEveryDefaultProfileWithALanguageServer() {
        let defaultProfilesWithServers = DefaultLanguageProfiles.all.filter {
            $0.languageServer != nil
        }
        XCTAssertFalse(defaultProfilesWithServers.isEmpty)

        for profile in defaultProfilesWithServers {
            XCTAssertNotNil(
                DefaultLanguageServerInstallationGuides.all[
                    profile.identifier
                ],
                "Expected installation guidance for default profile \(profile.identifier)"
            )
        }

        // The inverse also holds: the catalog shouldn't carry stale
        // entries for profiles that no longer exist or have no server.
        let identifiersWithServers = Set(
            defaultProfilesWithServers.map(\.identifier)
        )
        XCTAssertEqual(
            Set(DefaultLanguageServerInstallationGuides.all.keys),
            identifiersWithServers
        )
    }

    func testAllDocumentationURLsAreHTTPS() {
        for (identifier, guide) in DefaultLanguageServerInstallationGuides.all {
            XCTAssertEqual(
                guide.documentationURL.scheme,
                "https",
                "Documentation URL for \(identifier) must be HTTPS"
            )
            XCTAssertEqual(guide.profileIdentifier, identifier)
        }
    }

    func testCommandsAreNonemptyDisplayOnlyAndNewlineFree() {
        for (identifier, guide) in DefaultLanguageServerInstallationGuides.all {
            for option in guide.commandOptions {
                XCTAssertFalse(
                    option.id.isEmpty,
                    "\(identifier): command option id must not be empty"
                )
                XCTAssertFalse(
                    option.label.isEmpty,
                    "\(identifier): command option label must not be empty"
                )
                XCTAssertFalse(
                    option.commandLines.isEmpty,
                    "\(identifier)/\(option.id): must have at least one command line"
                )
                for line in option.commandLines {
                    XCTAssertFalse(
                        line.isEmpty,
                        "\(identifier)/\(option.id): command line must not be empty"
                    )
                    XCTAssertFalse(
                        line.contains("\n"),
                        "\(identifier)/\(option.id): command line must not embed a newline"
                    )
                }
            }
        }
    }

    func testExpectedNPMAndPNPMGuidanceExists() {
        let expectedPackagesByIdentifier: [String: [String]] = [
            "typescript": ["typescript-language-server", "typescript"],
            "html": ["vscode-langservers-extracted"],
            "css": ["vscode-langservers-extracted"],
            "json": ["vscode-langservers-extracted"],
            "python": ["pyright"],
            "shellscript": ["bash-language-server"],
            "graphql": ["graphql-language-service-cli"]
        ]

        for (identifier, packages) in expectedPackagesByIdentifier {
            guard let guide = DefaultLanguageServerInstallationGuides.all[
                identifier
            ] else {
                XCTFail("Missing guidance for \(identifier)")
                continue
            }
            let byID = Dictionary(
                uniqueKeysWithValues: guide.commandOptions.map {
                    ($0.id, $0)
                }
            )
            guard let npm = byID["npm"], let pnpm = byID["pnpm"] else {
                XCTFail("\(identifier): expected both npm and pnpm options")
                continue
            }
            XCTAssertEqual(
                npm.commandLines,
                ["npm install -g \(packages.joined(separator: " "))"]
            )
            XCTAssertEqual(
                pnpm.commandLines,
                ["pnpm add -g \(packages.joined(separator: ","))"]
            )
        }
    }

    func testYAMLPNPMGuidanceUsesTheHoistedNodeLinker() throws {
        let guide = try XCTUnwrap(
            DefaultLanguageServerInstallationGuides.all["yaml"]
        )
        let byID = Dictionary(
            uniqueKeysWithValues: guide.commandOptions.map {
                ($0.id, $0)
            }
        )

        XCTAssertEqual(
            byID["npm"]?.commandLines,
            ["npm install -g yaml-language-server"]
        )
        XCTAssertEqual(
            byID["pnpm"]?.commandLines,
            [
                "pnpm --config.node-linker=hoisted add -g yaml-language-server"
            ]
        )
    }

    func testXMLHasDocumentationButNoCommand() throws {
        let xml = try XCTUnwrap(
            DefaultLanguageServerInstallationGuides.all["xml"]
        )
        XCTAssertTrue(xml.commandOptions.isEmpty)
        XCTAssertEqual(xml.documentationURL.scheme, "https")
    }

    func testGuideForProfileRequiresDefaultOrigin() {
        let defaultSwift = DefaultLanguageProfiles.swift
        XCTAssertNotNil(
            DefaultLanguageServerInstallationGuides.guide(for: defaultSwift)
        )

        // A custom profile that reuses a default profile's identifier
        // and server configuration must still never resolve guidance:
        // only `origin == .default` unlocks a catalog lookup.
        var spoofedCustomProfile = defaultSwift
        spoofedCustomProfile.origin = .custom
        XCTAssertNil(
            DefaultLanguageServerInstallationGuides.guide(
                for: spoofedCustomProfile
            )
        )

        var unrelatedCustomProfile = defaultSwift
        unrelatedCustomProfile.identifier = "custom-swift-lookalike"
        unrelatedCustomProfile.origin = .custom
        XCTAssertNil(
            DefaultLanguageServerInstallationGuides.guide(
                for: unrelatedCustomProfile
            )
        )
    }

    func testGuideForProfileReturnsNilWhenNoCatalogEntryExists() {
        var profile = DefaultLanguageProfiles.swift
        profile.identifier = "not-in-the-catalog"
        XCTAssertNil(
            DefaultLanguageServerInstallationGuides.guide(for: profile)
        )
    }
}
