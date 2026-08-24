import DiagnosticsCore
import FontCore
import Foundation
import GitCore
import KodUIComponents
import LanguageAdapters
import LanguageClient
import SettingsCore
import ThemeCore
import WorkspaceCore

/// App-lifetime composition root. Workspace-scoped subsystem lifetime
/// belongs to `WorkspaceSession`, which this type composes; views receive
/// a session rather than constructing subsystems themselves.
@MainActor
final class AppEnvironment {
    typealias TrustStoreFactory = () -> WorkspaceTrustStore
    typealias LayoutStoreFactory = () -> WorkspaceLayoutStore
    typealias DiagnosticsStoreFactory = () -> WorkspaceDiagnosticsStore

    let settingsRepository: CodableSettingsRepository
    let diagnosticsLog: BoundedEventLog
    let languageSupportService: LanguageSupportService
    let recentWorkspaceStore: RecentWorkspaceStore
    let themeStore: ThemeStore
    let fontSettingsStore: FontSettingsStore
    let appearanceCenter: AppearanceCenter

    private let trustStoreFactory: TrustStoreFactory
    private let layoutStoreFactory: LayoutStoreFactory
    private let diagnosticsStoreFactory: DiagnosticsStoreFactory

    private init(
        settingsRepository: CodableSettingsRepository,
        diagnosticsLog: BoundedEventLog,
        languageSupportService: LanguageSupportService,
        recentWorkspaceStore: RecentWorkspaceStore,
        themeStore: ThemeStore,
        fontSettingsStore: FontSettingsStore,
        appearanceCenter: AppearanceCenter,
        trustStoreFactory: @escaping TrustStoreFactory,
        layoutStoreFactory: @escaping LayoutStoreFactory,
        diagnosticsStoreFactory: @escaping DiagnosticsStoreFactory
    ) {
        self.settingsRepository = settingsRepository
        self.diagnosticsLog = diagnosticsLog
        self.languageSupportService = languageSupportService
        self.recentWorkspaceStore = recentWorkspaceStore
        self.themeStore = themeStore
        self.fontSettingsStore = fontSettingsStore
        self.appearanceCenter = appearanceCenter
        self.trustStoreFactory = trustStoreFactory
        self.layoutStoreFactory = layoutStoreFactory
        self.diagnosticsStoreFactory = diagnosticsStoreFactory
    }

    static func production() throws -> AppEnvironment {
        let store = UserDefaultsSettingsKeyValueStore(
            userDefaults: .standard
        )
        return try make(
            repository: CodableSettingsRepository(store: store)
        )
    }

    /// Explicit test composition. The caller supplies an isolated repository,
    /// so this path can never accidentally read or mutate process preferences.
    static func testing(
        settingsRepository: CodableSettingsRepository,
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        languageSupportService: LanguageSupportService? = nil,
        trustStoreFactory: TrustStoreFactory? = nil,
        layoutStoreFactory: LayoutStoreFactory? = nil,
        diagnosticsStoreFactory: DiagnosticsStoreFactory? = nil
    ) throws -> AppEnvironment {
        try make(
            repository: settingsRepository,
            diagnosticsLog: diagnosticsLog,
            languageSupportService: languageSupportService,
            trustStoreFactory: trustStoreFactory,
            layoutStoreFactory: layoutStoreFactory,
            diagnosticsStoreFactory: diagnosticsStoreFactory
        )
    }

    private static func make(
        repository: CodableSettingsRepository,
        diagnosticsLog: BoundedEventLog = BoundedEventLog(),
        languageSupportService: LanguageSupportService? = nil,
        trustStoreFactory: TrustStoreFactory? = nil,
        layoutStoreFactory: LayoutStoreFactory? = nil,
        diagnosticsStoreFactory: DiagnosticsStoreFactory? = nil
    ) throws -> AppEnvironment {
        let resolvedLanguageSupportService: LanguageSupportService
        if let suppliedService = languageSupportService {
            resolvedLanguageSupportService = suppliedService
        } else {
            let overrideStore = LanguageServerOverrideStore(
                repository: repository
            )
            let profileStore = try LanguageProfileStore(
                repository: repository,
                overrideStore: overrideStore
            )
            resolvedLanguageSupportService = LanguageSupportService(
                profileStore: profileStore,
                overrideStore: overrideStore,
                statusCacheStore: LanguageServerStatusCacheStore(
                    repository: repository
                )
            )
        }

        let themeStore = ThemeStore(repository: repository)
        let fontSettingsStore = FontSettingsStore(repository: repository)
        let appearanceCenter = try AppearanceCenter(
            themeStore: themeStore,
            fontSettingsStore: fontSettingsStore
        )
        appearanceCenter.onPersistenceError = { component, error in
            let subsystem: DiagnosticSubsystem =
                component == .theme ? .theme : .font
            Task {
                await diagnosticsLog.record(
                    subsystem: subsystem,
                    level: .error,
                    message: "Appearance settings could not be reloaded",
                    context: [
                        DiagnosticContextField(
                            name: "reason",
                            category: .diagnosticMessage,
                            value: error.localizedDescription
                        )
                    ]
                )
            }
        }

        return AppEnvironment(
            settingsRepository: repository,
            diagnosticsLog: diagnosticsLog,
            languageSupportService: resolvedLanguageSupportService,
            recentWorkspaceStore: RecentWorkspaceStore(
                repository: repository
            ),
            themeStore: themeStore,
            fontSettingsStore: fontSettingsStore,
            appearanceCenter: appearanceCenter,
            trustStoreFactory: trustStoreFactory
                ?? { WorkspaceTrustStore(repository: repository) },
            layoutStoreFactory: layoutStoreFactory
                ?? { WorkspaceLayoutStore(repository: repository) },
            diagnosticsStoreFactory: diagnosticsStoreFactory
                ?? { WorkspaceDiagnosticsStore() }
        )
    }

    func makeWorkspaceDependencies() -> WorkspaceDependencies {
        WorkspaceDependencies(
            diagnosticsLog: diagnosticsLog,
            languageSupportService: languageSupportService,
            appearanceCenter: appearanceCenter,
            trustStore: trustStoreFactory(),
            layoutStore: layoutStoreFactory(),
            diagnosticsStore: diagnosticsStoreFactory()
        )
    }

    /// Composes one workspace's headless subsystem session. Each call
    /// gets its own workspace-scoped stores while continuing to share
    /// app-lifetime services (diagnostics log, language support).
    func makeWorkspaceSession(
        identity: WorkspaceIdentity,
        services: WorkspaceSessionServices = WorkspaceSessionServices()
    ) -> WorkspaceSession {
        makeWorkspaceDependencies().makeWorkspaceSession(
            identity: identity,
            services: services
        )
    }
}

@MainActor
struct WorkspaceDependencies {
    let diagnosticsLog: BoundedEventLog
    let languageSupportService: LanguageSupportService
    let appearanceCenter: AppearanceCenter
    let trustStore: WorkspaceTrustStore
    let layoutStore: WorkspaceLayoutStore
    let diagnosticsStore: WorkspaceDiagnosticsStore

    func makeLanguageServicesCoordinator(
        identity: WorkspaceIdentity
    ) -> MultiLanguageServicesCoordinator {
        MultiLanguageServicesCoordinator(
            identity: identity,
            trustStore: trustStore,
            profileRegistry: languageSupportService.profileRegistry,
            overrideStore: languageSupportService.overrideStore,
            diagnosticsLog: diagnosticsLog,
            diagnosticsStore: diagnosticsStore
        )
    }

    func makeGitCoordinator(
        root: URL,
        onStatusChanged: @escaping (GitStatusSnapshot?) -> Void
    ) -> GitWorkspaceCoordinator {
        GitWorkspaceCoordinator(
            root: root,
            diagnosticsLog: diagnosticsLog,
            onStatusChanged: onStatusChanged
        )
    }

    /// Builds the headless session that owns this workspace's subsystem
    /// lifetime. Views receive the session; they never construct
    /// subsystems themselves.
    func makeWorkspaceSession(
        identity: WorkspaceIdentity,
        services: WorkspaceSessionServices = WorkspaceSessionServices()
    ) -> WorkspaceSession {
        WorkspaceSession(
            identity: identity,
            dependencies: self,
            services: services
        )
    }
}
