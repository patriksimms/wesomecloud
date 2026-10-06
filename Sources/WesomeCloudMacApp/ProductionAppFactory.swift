import Foundation
import OwnCloudKit
import SyncStore
import WesomeCloudAppCore
import WesomeFileProviderExtension
import WesomeCloudShared
import WesomeFileProviderCore

public struct ProductionAppConflictResolver: AppConflictResolving {
    private let credentials: CredentialStore
    private let preferencesRepository: PreferencesRepository
    private let runtimeFactory: ProductionExtensionRuntimeFactory
    private let credentialResolver: AccountCredentialResolver

    public init(
        credentials: CredentialStore,
        preferencesRepository: PreferencesRepository = MemoryPreferencesRepository(),
        runtimeFactory: ProductionExtensionRuntimeFactory,
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver()
    ) {
        self.credentials = credentials
        self.preferencesRepository = preferencesRepository
        self.runtimeFactory = runtimeFactory
        self.credentialResolver = credentialResolver
    }

    public func resolveConflict(
        _ record: ConflictRecord,
        account: PersistedAccountRecord,
        decision: ConflictResolutionDecision,
        resolvedName: String?
    ) async throws {
        guard let credential = try await credentials.credential(accountID: account.id) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(account.id.uuidString)")
        }
        let resolved = try await credentialResolver.resolve(account: account.account, credential: credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentials.save(updatedCredential)
        }
        let preferences = try await preferencesRepository.load()
        let coordinator = try runtimeFactory.makeCoordinator(
            configuration: ExtensionRuntimeAccountConfiguration(
                account: account.account,
                credential: credential,
                metadataID: account.metadataID,
                remoteRootPath: account.domain?.rootPath ?? "/",
                webDAVRootURL: account.domain?.webDAVRootURL,
                syncPreferences: preferences.sync,
                filePreferences: preferences.files
            ),
            credentials: resolved.credentials
        )
        _ = try await coordinator.resolveConflict(record, decision: decision, resolvedName: resolvedName)
    }
}

public struct ProductionAppAvailabilityResolver: AppAvailabilityResolving {
    private let credentials: CredentialStore
    private let preferencesRepository: PreferencesRepository
    private let runtimeFactory: ProductionExtensionRuntimeFactory
    private let credentialResolver: AccountCredentialResolver

    public init(
        credentials: CredentialStore,
        preferencesRepository: PreferencesRepository = MemoryPreferencesRepository(),
        runtimeFactory: ProductionExtensionRuntimeFactory,
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver()
    ) {
        self.credentials = credentials
        self.preferencesRepository = preferencesRepository
        self.runtimeFactory = runtimeFactory
        self.credentialResolver = credentialResolver
    }

    @discardableResult
    public func setAvailabilityIntent(
        _ intent: AvailabilityIntent,
        itemID: String,
        account: PersistedAccountRecord
    ) async throws -> [String] {
        guard let credential = try await credentials.credential(accountID: account.id) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(account.id.uuidString)")
        }
        let resolved = try await credentialResolver.resolve(account: account.account, credential: credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentials.save(updatedCredential)
        }
        let preferences = try await preferencesRepository.load()
        let coordinator = try runtimeFactory.makeCoordinator(
            configuration: ExtensionRuntimeAccountConfiguration(
                account: account.account,
                credential: credential,
                metadataID: account.metadataID,
                remoteRootPath: account.domain?.rootPath ?? "/",
                webDAVRootURL: account.domain?.webDAVRootURL,
                syncPreferences: preferences.sync,
                filePreferences: preferences.files
            ),
            credentials: resolved.credentials
        )
        return try await coordinator.setAvailabilityIntent(intent, itemID: itemID)
    }
}

public struct ProductionPublicLinkCreator: AppPublicLinkCreating {
    private let credentials: CredentialStore
    private let credentialResolver: AccountCredentialResolver
    private let transport: HTTPTransport

    public init(
        credentials: CredentialStore,
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver(),
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.credentials = credentials
        self.credentialResolver = credentialResolver
        self.transport = transport
    }

    public func createPublicLink(for file: AppFileItem) async throws -> PublicLinkShare {
        let client = try await sharingClient(for: file)
        return try await client.createPublicLink(path: file.item.remote.path, name: file.item.remote.name)
    }

    public func publicLinks(for file: AppFileItem) async throws -> [PublicLinkShare] {
        let client = try await sharingClient(for: file)
        return try await client.publicLinks(path: file.item.remote.path)
    }

    public func deletePublicLink(_ share: PublicLinkShare, for file: AppFileItem) async throws {
        let client = try await sharingClient(for: file)
        try await client.deleteShare(id: share.id)
    }

    public func privateLink(for file: AppFileItem) async throws -> URL {
        let resolved = try await resolvedCredential(for: file)
        let client = WebDAVClient(
            baseURL: file.webDAVRootURL ?? file.serverURL
                .appending(path: "remote.php/dav/files")
                .appending(path: file.accountUsername),
            credentials: resolved,
            transport: transport
        )
        return try await client.privateLink(path: file.item.remote.path)
    }

    private func sharingClient(for file: AppFileItem) async throws -> OCSSharingClient {
        let resolved = try await resolvedCredential(for: file)
        // A relative path alone addresses the personal drive in the OCS API.
        let resourceReference: String?
        if file.webDAVRootURL?.pathComponents.contains("spaces") == true {
            guard let fileID = file.item.remote.fileID, !fileID.isEmpty else {
                throw WesomeCloudError.unsupported("This Space item has no server ID. Open ownCloud in your browser to manage its links.")
            }
            resourceReference = fileID
        } else {
            resourceReference = nil
        }
        return OCSSharingClient(
            serverURL: file.serverURL,
            credentials: resolved,
            resourceReference: resourceReference,
            transport: transport
        )
    }

    private func resolvedCredential(for file: AppFileItem) async throws -> Credentials {
        guard let credential = try await credentials.credential(accountID: file.accountID) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(file.accountID.uuidString)")
        }
        let account = Account(
            id: file.accountID,
            serverURL: file.serverURL,
            username: file.accountUsername,
            displayName: file.accountName
        )
        let resolved = try await credentialResolver.resolve(account: account, credential: credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentials.save(updatedCredential)
        }
        return resolved.credentials
    }
}

public struct ProductionAppFactory: Sendable {
    public var paths: WesomeCloudPaths
    public var diagnosticsLimit: Int
    public var legacyOwnCloudConfigURLs: [URL]

    public init(
        paths: WesomeCloudPaths = .resolve(),
        diagnosticsLimit: Int = 500,
        legacyOwnCloudConfigURLs: [URL] = LegacyOwnCloudAccountRepository.defaultConfigURLs()
    ) {
        self.paths = paths
        self.diagnosticsLimit = diagnosticsLimit
        self.legacyOwnCloudConfigURLs = legacyOwnCloudConfigURLs
    }

    @MainActor
    public func makeViewModel() throws -> WesomeCloudViewModel {
        let components = try makeComponents()
        let scheduler = makeBackgroundSyncScheduler(components: components)
        return WesomeCloudViewModel(
            model: components.appModel,
            manualSync: BackgroundManualSyncRunner(scheduler: scheduler)
        )
    }

    @MainActor
    public func makeSoftwareUpdatePresenter() -> any SoftwareUpdatePresenting {
        #if canImport(Sparkle)
        guard SparkleUpdatePresenter.isConfigured() else {
            return UnavailableSoftwareUpdatePresenter()
        }
        #endif
        return SparkleUpdatePresenter()
    }

    public func makeAppModel() throws -> WesomeCloudAppModel {
        let components = try makeComponents()
        return components.appModel
    }

    public func makeBackgroundTaskController(
        identifier: String = "cloud.wesome.wesomecloud.refresh",
        taskScheduler: BackgroundTaskScheduling = SystemBackgroundTaskScheduler()
    ) throws -> BackgroundTaskSyncController {
        let components = try makeComponents()
        let scheduler = makeBackgroundSyncScheduler(components: components)
        return BackgroundTaskSyncController(
            identifier: identifier,
            scheduler: scheduler,
            appModel: components.appModel,
            taskScheduler: taskScheduler
        )
    }

    private func makeBackgroundSyncScheduler(components: ProductionAppComponents) -> BackgroundSyncScheduler {
        let runner = ProductionAccountSyncRunner(
            credentials: components.credentials,
            metadataStore: components.metadataStore,
            preferencesRepository: components.preferencesRepository,
            runtimeFactory: ProductionExtensionRuntimeFactory(paths: paths)
        )
        return BackgroundSyncScheduler(
            runner: runner,
            appModel: components.appModel,
            metadataStore: components.metadataStore,
            changeSignaler: Self.systemChangeSignaler(),
            configurationProvider: {
                try await components.preferencesRepository.load().sync.backgroundSyncConfiguration
            }
        )
    }

    private func makeComponents() throws -> ProductionAppComponents {
        try paths.ensureDirectories()
        let diagnostics = AppDiagnosticBuffer(limit: diagnosticsLimit)
        let credentials = KeychainCredentialStore()
        let metadataStore = try SQLiteMetadataStore(databaseURL: paths.database)
        let accountRepository = MigratingAccountRepository(
            primary: try SQLiteAccountRepository(databaseURL: paths.accountDatabase),
            legacy: CompositeLegacyAccountRepository([
                JSONAccountRepository(fileURL: paths.accounts),
                LegacyOwnCloudAccountRepository(configURLs: legacyOwnCloudConfigURLs),
            ])
        )
        let preferencesRepository = JSONPreferencesRepository(fileURL: paths.preferences)
        let crashReports = JSONCrashReportRepository(directory: paths.crashReports)
        let crashReportImporter = DiagnosticReportsCrashImporter(
            appVersion: Self.currentAppVersion(),
            buildNumber: Self.currentBuildNumber()
        )
        let updateChecker = UpdateCheckingService(currentVersion: Self.currentAppVersion(), securityPolicy: .signedDownloads) { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        let accountSessions = AccountSessionService(
            credentialStore: credentials,
            spacesFetcher: OwnCloudSpacesFetcher(),
            notificationsFetcher: OwnCloudNotificationsFetcher(),
            diagnostics: diagnostics
        )
        let domains = FileProviderDomainService(
            manager: Self.systemDomainManager(),
            repository: accountRepository,
            changeSignaler: Self.systemChangeSignaler(),
            diagnostics: diagnostics
        )
        let runtimeFactory = ProductionExtensionRuntimeFactory(paths: paths)
        let conflictResolver = ProductionAppConflictResolver(
            credentials: credentials,
            preferencesRepository: preferencesRepository,
            runtimeFactory: runtimeFactory
        )
        let availabilityResolver = ProductionAppAvailabilityResolver(
            credentials: credentials,
            preferencesRepository: preferencesRepository,
            runtimeFactory: runtimeFactory
        )
        let publicLinkCreator = ProductionPublicLinkCreator(credentials: credentials)
        let appModel = WesomeCloudAppModel(
            accountSessions: accountSessions,
            domains: domains,
            repository: accountRepository,
            preferencesRepository: preferencesRepository,
            metadataStore: metadataStore,
            crashReports: crashReports,
            crashReportImporter: crashReportImporter,
            updateChecker: updateChecker,
            conflictResolver: conflictResolver,
            availabilityResolver: availabilityResolver,
            publicLinkCreator: publicLinkCreator,
            diagnostics: diagnostics
        )
        return ProductionAppComponents(
            appModel: appModel,
            credentials: credentials,
            metadataStore: metadataStore,
            preferencesRepository: preferencesRepository
        )
    }

    private static func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static func currentBuildNumber() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private static func systemDomainManager() -> FileProviderDomainManaging {
        #if canImport(FileProvider)
        SystemFileProviderDomainManager()
        #else
        MemoryFileProviderDomainManager()
        #endif
    }

    private static func systemChangeSignaler() -> FileProviderChangeSignaling {
        #if canImport(FileProvider)
        SystemFileProviderChangeSignaler()
        #else
        MemoryFileProviderChangeSignaler()
        #endif
    }
}

private struct ProductionAppComponents {
    var appModel: WesomeCloudAppModel
    var credentials: CredentialStore
    var metadataStore: MetadataStore
    var preferencesRepository: PreferencesRepository
}
