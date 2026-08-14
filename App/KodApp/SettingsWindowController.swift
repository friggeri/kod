import AppKit
import Combine
import DiagnosticsCore
import FontCore
import KodUIComponents
import SettingsCore
import SwiftUI
import ThemeCore

/// Backing store for `SettingsView`'s bindings. Each mutation is persisted
/// immediately; open surfaces observe the injected stores with owned
/// cancellation tokens (SPEC 7.2).
@MainActor
private final class SettingsModel: ObservableObject {
    private let themeStore: ThemeStore
    private let fontSettingsStore: FontSettingsStore
    @Published private(set) var persistenceError: SettingsRepositoryError?

    @Published var selectedThemeIdentifier: String {
        didSet {
            guard selectedThemeIdentifier != oldValue else {
                return
            }
            do {
                try themeStore.setActiveThemeIdentifier(
                    selectedThemeIdentifier
                )
                persistenceError = nil
            } catch {
                persistenceError = error
            }
        }
    }

    @Published var availableThemes: [KodTheme]

    @Published var fontSettings: FontSettings {
        didSet {
            guard fontSettings != oldValue else {
                return
            }
            do {
                try fontSettingsStore.save(fontSettings)
                persistenceError = nil
            } catch {
                persistenceError = error
            }
        }
    }

    init(
        themeStore: ThemeStore,
        fontSettingsStore: FontSettingsStore
    ) throws(SettingsRepositoryError) {
        self.themeStore = themeStore
        self.fontSettingsStore = fontSettingsStore
        let active = try themeStore.resolvedActiveTheme(
            systemIsDark: AppearanceCenter.systemIsDark(),
            systemIsHighContrast: AppearanceCenter.systemIsHighContrast()
        )
        self.selectedThemeIdentifier = active.identifier
        switch try themeStore.importedThemes() {
        case .value(let themes, _):
            self.availableThemes = BundledThemes.all + themes
        case .absent, .quarantined:
            self.availableThemes = BundledThemes.all
        }
        switch try fontSettingsStore.load() {
        case .value(let settings, _):
            self.fontSettings = settings
        case .absent, .quarantined:
            self.fontSettings = .default
        }
    }

    func refreshAvailableThemes() throws(SettingsRepositoryError) {
        switch try themeStore.importedThemes() {
        case .value(let themes, _):
            availableThemes = BundledThemes.all + themes
        case .absent, .quarantined:
            availableThemes = BundledThemes.all
        }
    }

    func addImportedTheme(
        _ theme: KodTheme
    ) throws(SettingsRepositoryError) {
        try themeStore.addImportedTheme(theme)
        try refreshAvailableThemes()
        selectedThemeIdentifier = theme.identifier
    }

    func removeImportedTheme(
        identifier: String
    ) throws(SettingsRepositoryError) {
        try themeStore.removeImportedTheme(identifier: identifier)
        try refreshAvailableThemes()
        if selectedThemeIdentifier == identifier {
            selectedThemeIdentifier = BundledThemes.defaultTheme(
                isDark: AppearanceCenter.systemIsDark(),
                isHighContrast: AppearanceCenter.systemIsHighContrast()
            ).identifier
        }
    }
}

/// Hosts `SettingsView` in a native window. Constructed lazily by
/// `AppDelegate` on the first "Settings..." menu invocation; never shown
/// automatically, including in every automated test path.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel
    private let diagnosticsModel: DiagnosticsViewModel
    private let languageSupportService: LanguageSupportService
    private var selectedTab = SettingsTab.theme
    private var subscriptions: Set<AnyCancellable> = []

    convenience init(environment: AppEnvironment) throws {
        try self.init(
            themeStore: environment.themeStore,
            fontSettingsStore: environment.fontSettingsStore,
            crashReportingSettingsStore: environment
                .makeCrashReportingSettingsStore(),
            settingsQuarantine: environment.settingsRepository.quarantine,
            diagnosticsLog: environment.diagnosticsLog,
            languageSupportService: environment.languageSupportService
        )
    }

    init(
        themeStore: ThemeStore,
        fontSettingsStore: FontSettingsStore,
        crashReportingSettingsStore: CrashReportingSettingsStore,
        settingsQuarantine: SettingsQuarantine,
        diagnosticsLog: BoundedEventLog,
        languageSupportService: LanguageSupportService
    ) throws {
        let model = try SettingsModel(
            themeStore: themeStore,
            fontSettingsStore: fontSettingsStore
        )
        self.model = model
        self.diagnosticsModel = try DiagnosticsViewModel(
            diagnosticsLog: diagnosticsLog,
            crashReportingSettingsStore: crashReportingSettingsStore,
            settingsQuarantine: settingsQuarantine
        )
        self.languageSupportService = languageSupportService

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localized.string("Kod Settings", comment: "Title of the Settings window")
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.center()
        super.init(window: window)

        model.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] error in
                Task { @MainActor in
                    self?.presentPersistenceError(error)
                }
            }
            .store(in: &subscriptions)
        window.contentViewController = NSHostingController(rootView: makeView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeView() -> SettingsView {
        SettingsView(
            selectedTab: Binding(
                get: { [weak self] in self?.selectedTab ?? .theme },
                set: { [weak self] in self?.selectedTab = $0 }
            ),
            selectedThemeIdentifier: Binding(
                get: { [model] in model.selectedThemeIdentifier },
                set: { [model] in model.selectedThemeIdentifier = $0 }
            ),
            availableThemes: model.availableThemes,
            onImportVSCodeTheme: { [weak self] in self?.presentImportPanel() },
            onRemoveImportedTheme: { [weak self] identifier in
                self?.removeImportedTheme(identifier: identifier)
            },
            fontSettings: Binding(
                get: { [model] in model.fontSettings },
                set: { [model] in model.fontSettings = $0 }
            ),
            availableFamilies: Self.availableFamilies(currentFamily: model.fontSettings.familyName),
            diagnosticsModel: diagnosticsModel,
            onExportSupportBundle: { [weak self] in self?.presentSupportBundleExportPanel() },
            languageSupportService: languageSupportService,
            onChooseLanguageServerExecutable: { [weak self] languageKey in
                self?.presentLanguageServerExecutablePanel(
                    profileIdentifier: languageKey
                )
            },
            onFindLanguageServer: {
                NSWorkspace.shared.open(
                    LanguageSupportService.serverDirectoryURL
                )
            }
        )
    }

    private func removeImportedTheme(identifier: String) {
        do {
            try model.removeImportedTheme(identifier: identifier)
        } catch {
            presentImportError(error)
        }
    }

    private func presentPersistenceError(_ error: SettingsRepositoryError) {
        guard let window else {
            return
        }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    func showLanguageSupport(profileIdentifier: String? = nil) {
       selectedTab = .languages
       languageSupportService.focusProfile(identifier: profileIdentifier)
       window?.contentViewController = NSHostingController(rootView: makeView())
       showWindow(nil)
       window?.makeKeyAndOrderFront(nil)
    }

    private func presentLanguageServerExecutablePanel(
       profileIdentifier: String
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = Localized.string(
            "Choose an existing language-server executable.",
            comment: "Open panel message for selecting a language-server executable"
        )

        guard let window else {
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            do {
                try self.languageSupportService.setSelectedExecutable(
                    profileIdentifier: profileIdentifier,
                    url: url
                )
            } catch {
                self.languageSupportService.report(error)
            }
        }
    }

    private static func availableFamilies(currentFamily: String) -> [String] {
        var families = MonospacedFontDiscovery.availableMonospacedFamilies()
        if !families.contains(currentFamily) {
            families.insert(currentFamily, at: 0)
        }
        return families
    }

    /// SPEC 15's support-bundle export: writes to a location the user
    /// explicitly chooses via `NSSavePanel`, never a hardcoded path.
    /// `DiagnosticsViewModel.exportSupportBundle(to:)` performs the
    /// actual generate-then-write and records any failure for the
    /// Diagnostics tab to display.
    private func presentSupportBundleExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kod-Support-Bundle.json"
        panel.message = Localized.string(
            "Choose where to save the redacted diagnostics support bundle.",
            comment: "Save panel message for exporting the diagnostics support bundle"
        )

        guard let window else {
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            Task { @MainActor in
                await self.diagnosticsModel.exportSupportBundle(to: url)
            }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = Localized.string(
            "Choose a VS Code color-theme JSON file to import.",
            comment: "Open panel message for importing a VS Code theme"
        )

        guard let window else {
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            self.importTheme(from: url)
        }
    }

    private func importTheme(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let identifier = "imported.\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString.prefix(8))"
            let (theme, report) = try VSCodeThemeImporter.import(jsonData: data, identifier: identifier)
            try model.addImportedTheme(theme)
            window?.contentViewController = NSHostingController(rootView: makeView())

            if !report.isEmpty {
                presentImportReport(report, themeName: theme.name)
            }
        } catch {
            presentImportError(error)
        }
    }

    private func presentImportReport(_ report: ThemeImportReport, themeName: String) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = Localized.string(
            "Imported \"\(themeName)\" with Some Unsupported Fields",
            comment: "Alert title shown after importing a VS Code theme that had unsupported fields"
        )
        alert.informativeText = importReportSummary(report)
        alert.alertStyle = .informational
        alert.addButton(withTitle: Localized.string("OK", comment: "Button title dismissing the theme-import report alert"))
        alert.beginSheetModal(for: window)
    }

    private func importReportSummary(_ report: ThemeImportReport) -> String {
        var lines: [String] = []
        if !report.unsupportedTopLevelKeys.isEmpty {
            lines.append(
                Localized.string(
                    "Unsupported top-level keys: \(report.unsupportedTopLevelKeys.joined(separator: ", "))",
                    comment: "Line in the theme-import report listing unsupported top-level JSON keys"
                )
            )
        }
        if !report.unmappedColorKeys.isEmpty {
            lines.append(
                Localized.string(
                    "Unmapped workbench colors: \(report.unmappedColorKeys.joined(separator: ", "))",
                    comment: "Line in the theme-import report listing unmapped workbench color keys"
                )
            )
        }
        if !report.unsupportedTokenColorSettingsKeys.isEmpty {
            lines.append(
                Localized.string(
                    "Unsupported token/semantic settings: \(report.unsupportedTokenColorSettingsKeys.joined(separator: ", "))",
                    comment: "Line in the theme-import report listing unsupported token/semantic settings keys"
                )
            )
        }
        if !report.unparsableTokenColorEntries.isEmpty {
            lines.append(
                Localized.string(
                    "Unparsable entries: \(report.unparsableTokenColorEntries.joined(separator: ", "))",
                    comment: "Line in the theme-import report listing entries that could not be parsed"
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    private func presentImportError(_ error: Error) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = Localized.string("Could Not Import Theme", comment: "Alert title shown when a VS Code theme import fails")
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: Localized.string("OK", comment: "Button title dismissing the theme-import error alert"))
        alert.beginSheetModal(for: window)
    }
}
