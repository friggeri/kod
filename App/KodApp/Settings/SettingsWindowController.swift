import AppKit
import Combine
import FontCore
import KodUIComponents
import SettingsCore
import SwiftUI

/// Observable source of truth for the settings window. Font mutations persist
/// immediately, while store observations keep an already-open window current.
@MainActor
final class SettingsModel: ObservableObject {
    private let fontSettingsStore: FontSettingsStore
    private let softwareUpdater: any SoftwareUpdateControlling
    private var fontSettingsObservation: SettingsObservation?
    private var isReloadingFontSettings = false

    @Published private(set) var persistenceError: SettingsRepositoryError?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            softwareUpdater.automaticallyChecksForUpdates =
                automaticallyChecksForUpdates
        }
    }

    @Published var fontSettings: FontSettings {
        didSet {
            guard !isReloadingFontSettings, fontSettings != oldValue else {
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
        fontSettingsStore: FontSettingsStore,
        softwareUpdater: any SoftwareUpdateControlling =
            DisabledSoftwareUpdateController()
    ) throws(SettingsRepositoryError) {
        self.fontSettingsStore = fontSettingsStore
        self.softwareUpdater = softwareUpdater
        self.automaticallyChecksForUpdates =
            softwareUpdater.automaticallyChecksForUpdates
        self.fontSettings = try Self.loadFontSettings(from: fontSettingsStore)
        self.fontSettingsObservation = fontSettingsStore.observeChanges {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFontSettings()
            }
        }
    }

    private static func loadFontSettings(
        from store: FontSettingsStore
    ) throws(SettingsRepositoryError) -> FontSettings {
        switch try store.load() {
        case .value(let settings, _):
            settings
        case .absent, .quarantined:
            .default
        }
    }

    private func reloadFontSettings() {
        let reloadedSettings: FontSettings
        do {
            reloadedSettings = try Self.loadFontSettings(
                from: fontSettingsStore
            )
            persistenceError = nil
        } catch {
            persistenceError = error
            return
        }

        guard reloadedSettings != fontSettings else {
            return
        }
        isReloadingFontSettings = true
        fontSettings = reloadedSettings
        isReloadingFontSettings = false
    }
}

/// Hosts the permanent Settings sidebar and detail pane in a native split
/// window. Constructed lazily by `AppDelegate` on the first "Settings..."
/// menu invocation; never shown automatically.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SettingsModel
    private let navigationModel = SettingsNavigationModel()
    private let languageSupportService: LanguageSupportService
    private let availableFamilies: [String]
    private var subscriptions: Set<AnyCancellable> = []

    convenience init(
        environment: AppEnvironment,
        softwareUpdater: any SoftwareUpdateControlling =
            DisabledSoftwareUpdateController()
    ) throws {
        try self.init(
            fontSettingsStore: environment.fontSettingsStore,
            languageSupportService: environment.languageSupportService,
            softwareUpdater: softwareUpdater
        )
    }

    init(
        fontSettingsStore: FontSettingsStore,
        languageSupportService: LanguageSupportService,
        softwareUpdater: any SoftwareUpdateControlling =
            DisabledSoftwareUpdateController()
    ) throws {
        let model = try SettingsModel(
            fontSettingsStore: fontSettingsStore,
            softwareUpdater: softwareUpdater
        )
        self.model = model
        self.languageSupportService = languageSupportService
        self.availableFamilies = Self.availableFamilies(
            currentFamily: model.fontSettings.familyName
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = Localized.string(
            "Font",
            comment: "Settings window title while Font is selected"
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.minSize = NSSize(width: 800, height: 560)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "KodSettingsToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
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
        navigationModel.$selectedDestination
            .sink { [weak self] destination in
                self?.updateWindowTitle(for: destination)
            }
            .store(in: &subscriptions)
        languageSupportService.$items
            .sink { [weak self] _ in
                self?.updateWindowTitle(
                    for: self?.navigationModel.selectedDestination
                )
            }
            .store(in: &subscriptions)

        window.contentViewController = makeSplitViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeSplitViewController() -> NSSplitViewController {
        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let sidebarController = NSHostingController(
            rootView: SettingsSidebarView(
                navigationModel: navigationModel,
                languageSupportService: languageSupportService
            )
        )
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 260
        sidebarItem.preferredThicknessFraction = 0.28
        sidebarItem.holdingPriority = .defaultHigh

        let detailController = NSHostingController(rootView: makeDetailView())
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 570

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        return splitViewController
    }

    private func makeDetailView() -> SettingsDetailView {
        SettingsDetailView(
            navigationModel: navigationModel,
            model: model,
            availableFamilies: availableFamilies,
            languageSupportService: languageSupportService
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
        if let profileIdentifier {
            navigationModel.selectLanguage(profileIdentifier)
        } else if let first = languageSupportService.items.first {
            navigationModel.selectLanguage(first.id)
        }
        languageSupportService.focusProfile(identifier: profileIdentifier)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateWindowTitle(for destination: SettingsDestination?) {
        let title: String
        switch destination ?? .updates {
        case .updates:
            title = Localized.string(
                "Updates",
                comment: "Settings window title while Updates is selected"
            )
        case .font:
            title = Localized.string(
                "Font",
                comment: "Settings window title while Font is selected"
            )
        case .language(let identifier):
            title = languageSupportService.items.first {
                $0.id == identifier
            }?.profile.displayName ?? Localized.string(
                "Languages",
                comment: "Settings window fallback title for Languages"
            )
        }
        window?.title = title
    }

    private static func availableFamilies(currentFamily: String) -> [String] {
        var families = MonospacedFontDiscovery.availableMonospacedFamilies()
        if !families.contains(currentFamily) {
            families.insert(currentFamily, at: 0)
        }
        return families
    }
}
