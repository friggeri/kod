import AppKit
import Combine
import DiagnosticsCore
import FontCore
import KodUIComponents
import SettingsCore
import SwiftUI

/// Backing store for `SettingsView`'s font binding. Each mutation is persisted
/// immediately; open surfaces observe the injected stores with owned
/// cancellation tokens.
@MainActor
private final class SettingsModel: ObservableObject {
    private let fontSettingsStore: FontSettingsStore
    @Published private(set) var persistenceError: SettingsRepositoryError?

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
        fontSettingsStore: FontSettingsStore
    ) throws(SettingsRepositoryError) {
        self.fontSettingsStore = fontSettingsStore
        switch try fontSettingsStore.load() {
        case .value(let settings, _):
            self.fontSettings = settings
        case .absent, .quarantined:
            self.fontSettings = .default
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
    private var selectedTab = SettingsTab.font
    private var subscriptions: Set<AnyCancellable> = []

    convenience init(environment: AppEnvironment) throws {
        try self.init(
            fontSettingsStore: environment.fontSettingsStore,
            crashReportingSettingsStore: environment
                .makeCrashReportingSettingsStore(),
            settingsQuarantine: environment.settingsRepository.quarantine,
            diagnosticsLog: environment.diagnosticsLog,
            languageSupportService: environment.languageSupportService
        )
    }

    init(
        fontSettingsStore: FontSettingsStore,
        crashReportingSettingsStore: CrashReportingSettingsStore,
        settingsQuarantine: SettingsQuarantine,
        diagnosticsLog: BoundedEventLog,
        languageSupportService: LanguageSupportService
    ) throws {
        let model = try SettingsModel(fontSettingsStore: fontSettingsStore)
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
                get: { [weak self] in self?.selectedTab ?? .font },
                set: { [weak self] in self?.selectedTab = $0 }
            ),
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

}
