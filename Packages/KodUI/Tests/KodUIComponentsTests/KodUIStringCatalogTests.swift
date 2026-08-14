import Foundation
import XCTest
@testable import KodUIComponents

final class KodUIStringCatalogTests: XCTestCase {
    func testEveryDeclaredKeyHasACatalogEntry() {
        let catalog = KodUIStringCatalog.components

        XCTAssertFalse(KodUIStringKey.componentKeys.isEmpty)
        for key in KodUIStringKey.componentKeys {
            let value = catalog.string(key, comment: "Catalog coverage check")
            XCTAssertFalse(value.isEmpty)
            XCTAssertNotEqual(
                value,
                key.rawValue,
                "\(key.rawValue) has no entry in the package's Localizable.strings"
            )
        }
    }

    func testReadOnlyTextRoleDescriptionResolvesToItsEnglishValue() {
        let value = KodUIStringCatalog.components.string(
            .readOnlyTextAccessibilityRoleDescription,
            comment: "Role description announced for a read-only text area"
        )

        XCTAssertEqual(value, "read-only text")
    }

    /// The documented fallback: an unknown key resolves to the key
    /// itself, which is visibly a key rather than plausible prose.
    func testUnknownKeyFallsBackToTheKeyItself() {
        let key = KodUIStringKey(rawValue: "kodui.tests.absentKey")

        let value = KodUIStringCatalog.components.string(key, comment: "Missing-entry fallback check")

        XCTAssertEqual(value, key.rawValue)
    }

    func testUnknownTableFallsBackToTheKeyItself() {
        let catalog = KodUIStringCatalog(bundle: .kodUIComponents, table: "KodUITestsAbsentTable")

        let value = catalog.string(
            .readOnlyTextAccessibilityRoleDescription,
            comment: "Missing-table fallback check"
        )

        XCTAssertEqual(value, KodUIStringKey.readOnlyTextAccessibilityRoleDescription.rawValue)
    }

    func testKeysAreNamespacedIdentifiersRatherThanEnglishProse() {
        for key in KodUIStringKey.componentKeys {
            XCTAssertTrue(
                key.rawValue.hasPrefix("kodui."),
                "\(key.rawValue) should be a namespaced key so a missing translation is observable"
            )
            XCTAssertFalse(key.rawValue.contains(" "))
        }
    }
}
