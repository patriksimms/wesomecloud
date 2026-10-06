import Foundation
import WesomeCloudAppCore
import OwnCloudKit
import SyncStore
import WesomeCloudShared
import WesomeFileProviderCore

public struct ExtensionRuntimeAccountConfiguration: Equatable, Sendable {
    public var account: Account
    public var credential: Credential
    public var metadataID: UUID
    public var remoteRootPath: String
    public var webDAVRootURL: URL?
    public var syncPreferences: SyncPreferences
    public var filePreferences: FilePreferences

    public init(
        account: Account,
        credential: Credential,
        metadataID: UUID? = nil,
        remoteRootPath: String = "/",
        webDAVRootURL: URL? = nil,
        syncPreferences: SyncPreferences = SyncPreferences(),
        filePreferences: FilePreferences = FilePreferences()
    ) {
        self.account = account
        self.credential = credential
        self.metadataID = metadataID ?? account.id
        self.remoteRootPath = remoteRootPath
        self.webDAVRootURL = webDAVRootURL
        self.syncPreferences = syncPreferences
        self.filePreferences = filePreferences
    }
}

public struct ProductionExtensionRuntimeFactory: Sendable {
    public let paths: WesomeCloudPaths
    private let transport: HTTPTransport
    private let uploadConfiguration: UploadConfiguration

    public init(
        paths: WesomeCloudPaths = .resolve(),
        transport: HTTPTransport = URLSessionTransport(),
        uploadConfiguration: UploadConfiguration = UploadConfiguration()
    ) {
        self.paths = paths
        self.transport = transport
        self.uploadConfiguration = uploadConfiguration
    }

    public func makeRuntime(configuration: ExtensionRuntimeAccountConfiguration) throws -> FileProviderExtensionRuntime {
        let coordinator = try makeCoordinator(configuration: configuration)
        let store = try SQLiteMetadataStore(databaseURL: paths.database)
        return FileProviderExtensionRuntime(
            adapter: FileProviderAdapter(
                backend: coordinator,
                pathResolver: RootedProviderPathResolver(rootPath: configuration.remoteRootPath)
            ),
            itemCache: ExtensionItemCache(storedItems: try store.storedItems(accountID: configuration.metadataID))
        )
    }

    public func makeRuntime(configuration: ExtensionRuntimeAccountConfiguration, credentials: Credentials) throws -> FileProviderExtensionRuntime {
        let coordinator = try makeCoordinator(configuration: configuration, credentials: credentials)
        let store = try SQLiteMetadataStore(databaseURL: paths.database)
        return FileProviderExtensionRuntime(
            adapter: FileProviderAdapter(
                backend: coordinator,
                pathResolver: RootedProviderPathResolver(rootPath: configuration.remoteRootPath)
            ),
            itemCache: ExtensionItemCache(storedItems: try store.storedItems(accountID: configuration.metadataID))
        )
    }

    public func makeCoordinator(configuration: ExtensionRuntimeAccountConfiguration) throws -> FileProviderCoordinator {
        try makeCoordinator(configuration: configuration, credentials: Self.credentials(from: configuration.credential))
    }

    public func makeCoordinator(configuration: ExtensionRuntimeAccountConfiguration, credentials: Credentials) throws -> FileProviderCoordinator {
        try paths.ensureDirectories()
        let store = try SQLiteMetadataStore(databaseURL: paths.database)
        let webDAV = WebDAVClient(
            baseURL: Self.webDAVBaseURL(account: configuration.account, webDAVRootURL: configuration.webDAVRootURL),
            credentials: credentials,
            transport: transport
        )
        let coordinator = FileProviderCoordinator(
            account: configuration.account,
            metadataID: configuration.metadataID,
            webDAV: webDAV,
            store: store,
            materializationDirectory: paths.materializedFiles.appending(path: configuration.metadataID.uuidString),
            uploadConfiguration: uploadConfiguration,
            presentationPolicy: configuration.filePreferences.fileProviderPresentationPolicy,
            transferConfiguration: configuration.syncPreferences.fileProviderTransferConfiguration
        )
        return coordinator
    }

    public static func webDAVBaseURL(account: Account) -> URL {
        webDAVBaseURL(account: account, webDAVRootURL: nil)
    }

    public static func webDAVBaseURL(account: Account, webDAVRootURL: URL?) -> URL {
        if let webDAVRootURL {
            return webDAVRootURL.absoluteString.hasSuffix("/") ? webDAVRootURL : webDAVRootURL.appending(path: "")
        }
        return account.serverURL
            .appending(path: "remote.php")
            .appending(path: "dav")
            .appending(path: "files")
            .appending(path: account.username)
            .appending(path: "")
    }

    public static func credentials(from credential: Credential) throws -> Credentials {
        switch credential.kind {
        case .oauthRefreshToken:
            throw WesomeCloudError.unsupported("OAuth refresh tokens must be exchanged for access tokens before building a runtime")
        case .appPassword, .basicPassword:
            Credentials(username: credential.username, password: credential.secret)
        }
    }
}

private struct RootedProviderPathResolver: ProviderPathResolving {
    var rootPath: String
    private let fallback = ProviderPathResolver()

    init(rootPath: String) {
        self.rootPath = rootPath.normalizedRootPath
    }

    func resolve(_ container: ProviderContainerReference) -> ResolvedProviderContainer {
        let resolved = fallback.resolve(container)
        guard resolved.remotePath == "/" else { return resolved }
        return ResolvedProviderContainer(parentID: resolved.parentID, remotePath: rootPath)
    }
}

private extension String {
    var normalizedRootPath: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return prefixed.count > 1 && prefixed.hasSuffix("/") ? String(prefixed.dropLast()) : prefixed
    }
}

private extension FilePreferences {
    var fileProviderPresentationPolicy: FileProviderPresentationPolicy {
        FileProviderPresentationPolicy(
            showHiddenFiles: showHiddenFiles,
            defaultAvailabilityIntent: defaultAvailability.fileProviderAvailabilityIntent,
            ignoredFilenamePatterns: ignoredFilenamePatterns,
            excludedRemotePaths: excludedRemotePaths
        )
    }
}

private extension SyncPreferences {
    var fileProviderTransferConfiguration: TransferConfiguration {
        TransferConfiguration(maximumConcurrentTransfers: maximumConcurrentTransfers)
    }
}

private extension DefaultAvailability {
    var fileProviderAvailabilityIntent: AvailabilityIntent {
        switch self {
        case .onlineOnly: .onlineOnly
        case .alwaysLocal: .alwaysLocal
        case .systemManaged: .unspecified
        }
    }
}

public struct DomainRuntimeResolution: Equatable, Sendable {
    public var record: PersistedAccountRecord
    public var credential: Credential

    public init(record: PersistedAccountRecord, credential: Credential) {
        self.record = record
        self.credential = credential
    }
}

public actor ProductionDomainRuntimeResolver {
    private let accounts: AccountRepository
    private let credentials: CredentialStore
    private let preferences: PreferencesRepository
    private let factory: ProductionExtensionRuntimeFactory
    private let credentialResolver: AccountCredentialResolver

    public init(
        accounts: AccountRepository,
        credentials: CredentialStore,
        preferences: PreferencesRepository = MemoryPreferencesRepository(),
        factory: ProductionExtensionRuntimeFactory = ProductionExtensionRuntimeFactory(),
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver()
    ) {
        self.accounts = accounts
        self.credentials = credentials
        self.preferences = preferences
        self.factory = factory
        self.credentialResolver = credentialResolver
    }

    public static func production(paths: WesomeCloudPaths = .resolve()) throws -> ProductionDomainRuntimeResolver {
        ProductionDomainRuntimeResolver(
            accounts: MigratingAccountRepository(
                primary: try SQLiteAccountRepository(databaseURL: paths.accountDatabase),
                legacy: JSONAccountRepository(fileURL: paths.accounts)
            ),
            credentials: KeychainCredentialStore(),
            preferences: JSONPreferencesRepository(fileURL: paths.preferences),
            factory: ProductionExtensionRuntimeFactory(paths: paths),
            credentialResolver: AccountCredentialResolver()
        )
    }

    public func resolve(domainID: String) async throws -> DomainRuntimeResolution {
        let records = try await accounts.records()
        guard let account = records.first(where: { $0.domains.contains { $0.id == domainID } }),
              let domain = account.domains.first(where: { $0.id == domainID }) else {
            throw WesomeCloudError.missingItem(domainID)
        }
        let record = account.selecting(domain)
        guard let credential = try await credentials.credential(accountID: record.account.id) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(record.account.id.uuidString)")
        }
        return DomainRuntimeResolution(record: record, credential: credential)
    }

    public func makeRuntime(domainID: String) async throws -> FileProviderExtensionRuntime {
        let resolution = try await resolve(domainID: domainID)
        let preferences = try await preferences.load()
        let resolved = try await credentialResolver.resolve(account: resolution.record.account, credential: resolution.credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentials.save(updatedCredential)
        }
        let account = resolution.record.account
        let webDAVBase = ProductionExtensionRuntimeFactory.webDAVBaseURL(account: account, webDAVRootURL: resolution.record.domain?.webDAVRootURL)
        await WesomeLogger(category: "FileProvider").info(
            "runtime resolved domain=\(domainID) credential=\(resolution.credential.kind.rawValue) webDAV=\(webDAVBase.absoluteString)"
        )
        return try factory.makeRuntime(
            configuration: ExtensionRuntimeAccountConfiguration(
                account: resolution.record.account,
                credential: resolution.credential,
                metadataID: resolution.record.metadataID,
                remoteRootPath: resolution.record.domain?.rootPath ?? "/",
                webDAVRootURL: resolution.record.domain?.webDAVRootURL,
                syncPreferences: preferences.sync,
                filePreferences: preferences.files
            ),
            credentials: resolved.credentials
        )
    }
}
