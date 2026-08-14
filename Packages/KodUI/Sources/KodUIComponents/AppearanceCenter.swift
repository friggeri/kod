import AppKit
import FontCore
import SettingsCore
import ThemeCore

@MainActor
public final class AppearanceCenter {
    public struct Snapshot: Equatable {
        public let theme: KodTheme
        public let fontSettings: FontSettings

        public init(theme: KodTheme, fontSettings: FontSettings) {
            self.theme = theme
            self.fontSettings = fontSettings
        }
    }

    public enum Component: Equatable {
        case theme
        case font
    }

    private let themeStore: ThemeStore?
    private let fontSettingsStore: FontSettingsStore?
    private var themeObservation: SettingsObservation?
    private var fontObservation: SettingsObservation?
    private var observers: [UUID: @MainActor @Sendable (Snapshot) -> Void] = [:]

    public private(set) var snapshot: Snapshot
    public private(set) var lastPersistenceError: SettingsRepositoryError?
    public var onPersistenceError: (@MainActor (Component, SettingsRepositoryError) -> Void)?

    public init(
        themeStore: ThemeStore,
        fontSettingsStore: FontSettingsStore
    ) throws(SettingsRepositoryError) {
        self.themeStore = themeStore
        self.fontSettingsStore = fontSettingsStore
        self.snapshot = Snapshot(
            theme: try Self.resolveTheme(from: themeStore),
            fontSettings: try Self.resolveFontSettings(from: fontSettingsStore)
        )
        themeObservation = themeStore.observeChanges { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        fontObservation = fontSettingsStore.observeChanges { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    init(testing snapshot: Snapshot) {
        self.themeStore = nil
        self.fontSettingsStore = nil
        self.snapshot = snapshot
    }

    @discardableResult
    public func observe(
        deliverCurrent: Bool = true,
        _ observer: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) -> SettingsObservation {
        let id = UUID()
        observers[id] = observer
        if deliverCurrent {
            observer(snapshot)
        }
        return SettingsObservation { [weak self] in
            Task { @MainActor [weak self] in
                self?.observers.removeValue(forKey: id)
            }
        }
    }

    public func refresh() {
        guard let themeStore, let fontSettingsStore else {
            return
        }

        var refreshed = snapshot
        var persistenceError: SettingsRepositoryError?
        do {
            refreshed = Snapshot(
                theme: try Self.resolveTheme(from: themeStore),
                fontSettings: refreshed.fontSettings
            )
        } catch {
            persistenceError = error
            onPersistenceError?(.theme, error)
        }
        do {
            refreshed = Snapshot(
                theme: refreshed.theme,
                fontSettings: try Self.resolveFontSettings(
                    from: fontSettingsStore
                )
            )
        } catch {
            persistenceError = error
            onPersistenceError?(.font, error)
        }

        lastPersistenceError = persistenceError
        guard refreshed != snapshot else {
            return
        }
        snapshot = refreshed
        for observer in observers.values {
            observer(refreshed)
        }
    }

    public static func systemIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua])
            == .darkAqua
    }

    public static func systemIsHighContrast() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func resolveTheme(
        from store: ThemeStore
    ) throws(SettingsRepositoryError) -> KodTheme {
        try store.resolvedActiveTheme(
            systemIsDark: systemIsDark(),
            systemIsHighContrast: systemIsHighContrast()
        )
    }

    private static func resolveFontSettings(
        from store: FontSettingsStore
    ) throws(SettingsRepositoryError) -> FontSettings {
        switch try store.load() {
        case .value(let settings, _):
            return settings
        case .absent, .quarantined:
            return .default
        }
    }
}
