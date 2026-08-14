import Foundation
import SettingsCore
import XCTest
@testable import LanguageAdapters

final class LanguageServerOverrideStorePersistenceTests: XCTestCase {
    private struct LegacyStoredOverride: Codable {
        let path: String
        let arguments: [String]
    }

    func testLegacyUnenvelopedOverrideMigrates() throws {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        let store = LanguageServerOverrideStore(repository: repository)
        let key = "language-server-override.global.swift"
        try keyValueStore.setValue(
            .data(
                try JSONEncoder().encode(
                    LegacyStoredOverride(
                        path: "/usr/bin/env",
                        arguments: ["swift"]
                    )
                )
            ),
            forKey: key
        )

        guard case .value(let restored, let provenance) =
                try store.globalOverride(languageKey: "swift") else {
            return XCTFail("Expected migrated override")
        }
        XCTAssertEqual(restored.url.path, "/usr/bin/env")
        XCTAssertEqual(restored.arguments, ["swift"])
        XCTAssertEqual(
            provenance,
            .migrated(from: .unversioned, toVersion: 1)
        )
        guard let migrated = try keyValueStore.value(forKey: key),
              case .data(let data) = migrated else {
            return XCTFail("Expected migrated override envelope")
        }
        struct Header: Decodable {
            let version: Int
        }
        XCTAssertEqual(
            try JSONDecoder().decode(Header.self, from: data).version,
            1
        )
    }

    func testCorruptOverrideIsQuarantinedAndCanBeReplaced() throws {
        let keyValueStore = InMemorySettingsKeyValueStore()
        let repository = CodableSettingsRepository(store: keyValueStore)
        let store = LanguageServerOverrideStore(repository: repository)
        let key = "language-server-override.global.swift"
        try keyValueStore.setValue(
            .data(Data("not-json".utf8)),
            forKey: key
        )

        guard case .quarantined(let record) =
                try store.globalOverride(languageKey: "swift") else {
            return XCTFail("Expected corrupt override quarantine")
        }
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(
            try repository.quarantine.records().map(\.key),
            [key]
        )

        try store.setGlobalOverride(
            url: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            languageKey: "swift"
        )
        guard case .value(let replacement, _) =
                try store.globalOverride(languageKey: "swift") else {
            return XCTFail("Expected replacement override")
        }
        XCTAssertEqual(replacement.url.path, "/bin/echo")
    }
}
