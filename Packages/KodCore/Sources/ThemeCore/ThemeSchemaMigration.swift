import Foundation

public enum ThemeSchemaMigrationError: Error, Equatable {
    case newerThanSupported(fileVersion: Int, supportedVersion: Int)
    case notAJSONObject
}

/// Upgrades a persisted Kod-native theme JSON payload to the current schema
/// version before decoding, so a theme file saved by an older Kod build
/// keeps working and a file from a *newer*, unsupported schema version
/// fails with an explicit, typed error instead of decoding into incorrect
/// or partially-default data.
///
/// Schema version 1 is the only version Kod has ever shipped, so there are
/// no structural migration steps registered yet. Additive Git decoration
/// fields are decoded compatibly by `GitDecorationColors` itself, including
/// themes stored directly in UserDefaults where this file codec is bypassed.
public enum ThemeSchemaMigrator {
    static func migrate(rawJSON: [String: Any]) throws -> [String: Any] {
        guard let fileVersion = rawJSON["schemaVersion"] as? Int else {
            // Absent version: treat as the current version rather than
            // guessing, matching how a hand-authored file without the
            // field would already be expected to decode.
            return rawJSON
        }
        guard fileVersion <= KodTheme.currentSchemaVersion else {
            throw ThemeSchemaMigrationError.newerThanSupported(
                fileVersion: fileVersion,
                supportedVersion: KodTheme.currentSchemaVersion
            )
        }

        var migrated = rawJSON
        // Future migrations are inserted here, e.g.:
        //   if fileVersion < 2 { migrated = migrateV1ToV2(migrated) }
        migrated["schemaVersion"] = KodTheme.currentSchemaVersion
        return migrated
    }
}

/// Loads and saves Kod-native `KodTheme` JSON files, running every load
/// through `ThemeSchemaMigrator` first.
public enum ThemeFileCodec {
    public static func decode(_ data: Data) throws -> KodTheme {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw ThemeSchemaMigrationError.notAJSONObject
        }
        let migrated = try ThemeSchemaMigrator.migrate(rawJSON: object)
        let migratedData = try JSONSerialization.data(withJSONObject: migrated)
        return try JSONDecoder().decode(KodTheme.self, from: migratedData)
    }

    public static func encode(_ theme: KodTheme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(theme)
    }
}
