import AppKit

extension FontWeight {
    public var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

/// Discovers monospaced font families installed on the Mac, for the font
/// picker described in SPEC 7.3. A family is considered monospaced when
/// its regular-weight member reports `isFixedPitch`, which is how AppKit
/// itself distinguishes fixed-pitch faces and matches what a user expects
/// when filtering a system font picker to "monospaced".
public enum MonospacedFontDiscovery {
    /// Installed monospaced family names, sorted for stable, predictable
    /// picker ordering.
    public static func availableMonospacedFamilies() -> [String] {
        let families = NSFontManager.shared.availableFontFamilies
        let monospaced = families.filter(isFamilyMonospaced)
        return monospaced.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func isFamilyMonospaced(_ familyName: String) -> Bool {
        guard let font = NSFont(name: familyName, size: 12) ?? sampleMember(ofFamily: familyName) else {
            return false
        }
        return font.isFixedPitch
    }

    private static func sampleMember(ofFamily familyName: String) -> NSFont? {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: familyName),
              let firstMember = members.first,
              let postScriptName = firstMember.first as? String else {
            return nil
        }
        return NSFont(name: postScriptName, size: 12)
    }
}
