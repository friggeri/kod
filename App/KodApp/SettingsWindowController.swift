import AppKit
import Combine
import DiagnosticsCore
import FontCore
import SwiftUI
import ThemeCore

/// Backing store for `SettingsView`'s bindings; persists every change
/// immediately and broadcasts `.kodAppearanceSettingsChanged` so open
/// windows re-apply live (SPEC 7.2: "Theme switching updates the visible
/// UI immediately").
@MainActor
private final class SettingsModel: ObservableObject {
    private let themeStore: ThemeStore
    private let fontSettingsStore: FontSettingsStore

    @Published var selectedThemeIdentifier: String {
        didSet {
            guard selectedThemeIdentifier != oldValue else {
                return
            }
            themeStore.setActiveThemeIdentifier(selectedThemeIdentifier)
            AppearanceSettings.broadcastChange()
        }
    }

    @Published var availableThemes: [KodTheme]

    @Published var fontSettings: FontSettings {
        didSet {
            guard fontSettings != oldValue else {
                return
            }
            fontSettingsStore.save(fontSettings)
            AppearanceSettings.broadcastChange()
        }
    }

    init(themeStore: ThemeStore, fontSettingsStore: FontSettingsStore) {
        self.themeStore = themeStore
        self.fontSettingsStore = fontSettingsStore
        let active = themeStore.resolvedActiveTheme(
            systemIsDark: AppearanceSettings.isSystemDark(),
            systemIsHighContrast: AppearanceSettings.isSystemHighContrast()
        )
        self.selectedThemeIdentifier = active.identifier
        self.availableThemes = BundledThemes.all + themeStore.importedThemes()
        self.fontSettings = fontSettingsStore.load()
    }

    func refreshAvailableThemes() {
        availableThemes = BundledThemes.all + themeStore.importedThemes()
    }

    func addImportedTheme(_ theme: KodTheme) {
        themeStore.addImportedTheme(theme)
        refreshAvailableThemes()
        selectedThemeIdentifier = theme.identifier
    }

    func removeImportedTheme(identifier: String) {
        themeStore.removeImportedTheme(identifier: identifier)
        refreshAvailableThemes()
        if selectedThemeIdentifier == identifier {
            selectedThemeIdentifier = BundledThemes.defaultTheme(
                isDark: AppearanceSettings.isSystemDark(),
                isHighContrast: AppearanceSettings.isSystemHighContrast()
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

    convenience init(diagnosticsLog: BoundedEventLog = BoundedEventLog()) {
        self.init(themeStore: ThemeStore(), fontSettingsStore: FontSettingsStore(), diagnosticsLog: diagnosticsLog)
    }

    init(
        themeStore: ThemeStore,
        fontSettingsStore: FontSettingsStore,
        diagnosticsLog: BoundedEventLog = BoundedEventLog()
    ) {
        let model = SettingsModel(themeStore: themeStore, fontSettingsStore: fontSettingsStore)
        self.model = model
        self.diagnosticsModel = DiagnosticsViewModel(diagnosticsLog: diagnosticsLog)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localized.string("Kod Settings", comment: "Title of the Settings window")
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.center()
        super.init(window: window)

        window.contentViewController = NSHostingController(rootView: makeView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeView() -> SettingsView {
        SettingsView(
            selectedThemeIdentifier: Binding(
                get: { [model] in model.selectedThemeIdentifier },
                set: { [model] in model.selectedThemeIdentifier = $0 }
            ),
            availableThemes: model.availableThemes,
            onImportVSCodeTheme: { [weak self] in self?.presentImportPanel() },
            onRemoveImportedTheme: { [model] identifier in model.removeImportedTheme(identifier: identifier) },
            fontSettings: Binding(
                get: { [model] in model.fontSettings },
                set: { [model] in model.fontSettings = $0 }
            ),
            availableFamilies: Self.availableFamilies(currentFamily: model.fontSettings.familyName),
            diagnosticsModel: diagnosticsModel,
            onExportSupportBundle: { [weak self] in self?.presentSupportBundleExportPanel() }
        )
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
            model.addImportedTheme(theme)
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
