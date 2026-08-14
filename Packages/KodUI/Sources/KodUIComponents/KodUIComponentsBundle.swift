import Foundation

extension Bundle {
    /// This target's own resource bundle (the Material icon manifest,
    /// its SVG assets, and `en.lproj/Localizable.strings`).
    ///
    /// Production code takes `Bundle.module` through an explicit
    /// parameter default instead of reaching for a global; this
    /// internal alias exists so tests can name the same bundle without
    /// `Bundle.module` resolving to the *test* target's bundle.
    static var kodUIComponents: Bundle {
        .module
    }
}
