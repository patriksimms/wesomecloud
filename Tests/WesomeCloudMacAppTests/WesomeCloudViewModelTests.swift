import Foundation
import OwnCloudKit
import SyncStore
import Testing
import WesomeCloudAppCore
import WesomeCloudMacApp
import WesomeCloudShared
import WesomeFileProviderCore
import WesomeFileProviderExtension

private struct MacAppCapabilitiesFetcher: CapabilitiesFetching {
    func fetchCapabilities(serverURL _: URL, credentials _: Credentials) async throws -> ServerCapabilities {
        ServerCapabilities(versionString: "10.15.0", edition: "Community")
    }
}

private struct MacAppSpacesFetcher: SpacesFetching {
    var spaces: [OwnCloudSpace]

    func fetchSpaces(serverURL _: URL, credentials _: Credentials) async throws -> [OwnCloudSpace] {
        spaces
    }
}

private actor MacAppNotificationsFetcher: NotificationsFetching {
    var deletedID: Int?
    var notifications: [UserNotification]

    init(notifications: [UserNotification]) {
        self.notifications = notifications
    }

    func fetchNotifications(serverURL _: URL, credentials _: Credentials) async throws -> [UserNotification] {
        notifications
    }

    func deleteNotification(id: Int, serverURL _: URL, credentials _: Credentials) async throws {
        deletedID = id
        notifications.removeAll { $0.id == id }
    }
}

private struct MacAppOAuthAuthenticator: OAuthAuthenticating {
    func authenticate(serverURL _: URL) async throws -> OAuthTokenSet {
        OAuthTokenSet(username: "oauth-user", accessToken: "access", refreshToken: "refresh")
    }
}

private actor MacAppRefreshExchanger: OAuthRefreshTokenExchanging {
    var requestedRefreshToken: String?
    var tokenSet: OAuthTokenSet

    init(tokenSet: OAuthTokenSet) {
        self.tokenSet = tokenSet
    }

    func refreshAccessToken(_ refreshToken: String, serverURL _: URL, configuration _: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        requestedRefreshToken = refreshToken
        return tokenSet
    }
}

private actor MacAppPublicLinkCreator: AppPublicLinkCreating {
    var files: [AppFileItem] = []
    var share = PublicLinkShare(id: "share-1", path: "/Plan.md", url: URL(string: "https://cloud.example/s/share-1")!)
    var listedShares: [PublicLinkShare] = [
        PublicLinkShare(id: "share-1", path: "/Plan.md", url: URL(string: "https://cloud.example/s/share-1")!)
    ]
    var deletedShares: [PublicLinkShare] = []
    var privateLink = URL(string: "https://cloud.example/index.php/f/1")!

    func createPublicLink(for file: AppFileItem) async throws -> PublicLinkShare {
        files.append(file)
        return share
    }

    func publicLinks(for file: AppFileItem) async throws -> [PublicLinkShare] {
        files.append(file)
        return listedShares
    }

    func deletePublicLink(_ share: PublicLinkShare, for file: AppFileItem) async throws {
        files.append(file)
        deletedShares.append(share)
    }

    func privateLink(for file: AppFileItem) async throws -> URL {
        files.append(file)
        return privateLink
    }
}

private final class RecordingClipboardWriter: ClipboardWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func copy(_ string: String) {
        lock.withLock {
            values.append(string)
        }
    }

    var copiedValues: [String] {
        lock.withLock { values }
    }
}

private final class RecordingFileRevealer: FileRevealing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func reveal(_ url: URL) {
        lock.withLock {
            values.append(url)
        }
    }

    var revealedURLs: [URL] {
        lock.withLock { values }
    }
}

private final class RecordingURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func open(_ url: URL) {
        lock.withLock {
            values.append(url)
        }
    }

    var openedURLs: [URL] {
        lock.withLock { values }
    }
}

private actor MacOAuthTokenExchanger: OAuthTokenExchanging {
    var exchangedCode: String?
    var serverURL: URL?

    func exchangeAuthorizationCode(_ code: String, serverURL: URL, configuration _: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        exchangedCode = code
        self.serverURL = serverURL
        return OAuthTokenSet(username: "browser-user", accessToken: "access", refreshToken: "refresh")
    }
}

private actor MacBackgroundRunner: AccountSyncRunning {
    var pollCount = 0
    var queueCount = 0

    func pollRemote(account _: PersistedAccountRecord) async throws -> RemoteChangeSet {
        pollCount += 1
        return RemoteChangeSet()
    }

    func processQueue(account _: PersistedAccountRecord) async throws -> QueueProcessingSummary {
        queueCount += 1
        return QueueProcessingSummary()
    }
}

private actor MacManualSyncRunner: ManualSyncRunning {
    var accountIDs: [UUID] = []
    var error: Error?

    func set(error: Error) {
        self.error = error
    }

    func syncNow(accounts: [PersistedAccountRecord]) async throws {
        if let error {
            throw error
        }
        accountIDs.append(contentsOf: accounts.map(\.id))
    }
}

private actor MacFixtureTransport: HTTPTransport {
    var responses: [(Data, Int)] = []
    var requests: [URLRequest] = []

    init(_ responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        return (
            next.0,
            HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: nil, headerFields: nil)!
        )
    }
}

#if canImport(AuthenticationServices) && canImport(AppKit)
private actor MacOAuthSessionPresenter: ASWebAuthenticationSessionPresenting {
    var authorizationURL: URL?
    var callbackScheme: String?

    func openAuthorizationURL(_ authorizationURL: URL, callbackScheme: String) async throws -> URL {
        self.authorizationURL = authorizationURL
        self.callbackScheme = callbackScheme
        return URL(string: "wesomecloud://oauth/callback?code=browser-code&state=state-1")!
    }
}
#endif

@MainActor
@Test
func rowViewModelSummarizesAccountStatus() {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let record = PersistedAccountRecord(
        account: account,
        lastSyncStatus: SyncStatusSnapshot(state: .syncing, message: "Uploading")
    )

    let row = record.rowViewModel

    #expect(row.title == "Alice Cloud")
    #expect(row.subtitle == "alice • cloud.example")
    #expect(row.statusText == "Uploading")
    #expect(row.statusState == .syncing)
}

@MainActor
@Test
func dashboardContentScopesAccountSpecificSections() {
    let alice = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let bob = Account(serverURL: URL(string: "https://cloud.example/")!, username: "bob", displayName: "Bob")
    let aliceRecord = PersistedAccountRecord(account: alice)
    let bobRecord = PersistedAccountRecord(account: bob)
    let aliceItem = StoredItem(remote: RemoteItem(id: "alice-file", parentID: nil, name: "Alice.txt", path: "/Alice.txt", kind: .file))
    let bobItem = StoredItem(remote: RemoteItem(id: "bob-file", parentID: nil, name: "Bob.txt", path: "/Bob.txt", kind: .file))
    let aliceConflict = AppConflict(
        record: ConflictRecord(conflict: SyncConflict(kind: .nameCollision, itemID: "alice-file", remotePath: "/Alice.txt", message: "Collision")),
        account: aliceRecord
    )
    let bobConflict = AppConflict(
        record: ConflictRecord(conflict: SyncConflict(kind: .nameCollision, itemID: "bob-file", remotePath: "/Bob.txt", message: "Collision")),
        account: bobRecord
    )
    let content = DashboardContent(
        accounts: [aliceRecord, bobRecord],
        spaces: [
            AppSpace(accountID: alice.id, accountName: "Alice", space: OwnCloudSpace(id: "alice-space", name: "Alice Space", webDAVURL: URL(string: "https://cloud.example/dav/spaces/alice-space")!)),
            AppSpace(accountID: bob.id, accountName: "Bob", space: OwnCloudSpace(id: "bob-space", name: "Bob Space", webDAVURL: URL(string: "https://cloud.example/dav/spaces/bob-space")!)),
        ],
        notifications: [
            AppNotification(accountID: alice.id, accountName: "Alice", notification: UserNotification(id: 1, app: "files", user: "alice", subject: "Alice", message: "A")),
            AppNotification(accountID: bob.id, accountName: "Bob", notification: UserNotification(id: 2, app: "files", user: "bob", subject: "Bob", message: "B")),
        ],
        files: [
            AppFileItem(accountID: alice.id, accountName: "Alice", serverURL: alice.serverURL, item: aliceItem),
            AppFileItem(accountID: bob.id, accountName: "Bob", serverURL: bob.serverURL, item: bobItem),
        ],
        issues: [
            SyncIssue(accountID: alice.id, accountName: "Alice", scope: .item, itemID: "alice-file", message: "Alice issue", isRecoverable: true),
            SyncIssue(accountID: bob.id, accountName: "Bob", scope: .item, itemID: "bob-file", message: "Bob issue", isRecoverable: true),
        ],
        conflicts: [aliceConflict, bobConflict],
        transfers: [
            AppTransfer(accountID: alice.id, accountName: "Alice", transfer: TransferRecord(itemID: "alice-file", direction: .download, phase: .running, remotePath: "/Alice.txt")),
            AppTransfer(accountID: bob.id, accountName: "Bob", transfer: TransferRecord(itemID: "bob-file", direction: .download, phase: .running, remotePath: "/Bob.txt")),
        ],
        storage: [
            AppAccountStorage(accountID: alice.id, accountName: "Alice", usedBytes: 1, availableBytes: 9),
            AppAccountStorage(accountID: bob.id, accountName: "Bob", usedBytes: 2, availableBytes: 8),
        ],
        publicLinks: [
            AppPublicLink(accountID: alice.id, fileID: "alice-file", filePath: "/Alice.txt", accountName: "Alice", share: PublicLinkShare(id: "alice-link", path: "/Alice.txt", url: URL(string: "https://cloud.example/s/alice")!)),
            AppPublicLink(accountID: bob.id, fileID: "bob-file", filePath: "/Bob.txt", accountName: "Bob", share: PublicLinkShare(id: "bob-link", path: "/Bob.txt", url: URL(string: "https://cloud.example/s/bob")!)),
        ]
    )

    let scoped = content.filtered(selectedAccountID: bob.id)

    #expect(scoped.accounts.map { $0.id } == [bob.id])
    #expect(scoped.spaces.map { $0.accountID } == [bob.id])
    #expect(scoped.notifications.map { $0.accountID } == [bob.id])
    #expect(scoped.files.map { $0.accountID } == [bob.id])
    #expect(scoped.issues.map { $0.accountID } == [bob.id])
    #expect(scoped.conflicts.map { $0.accountID } == [bob.id])
    #expect(scoped.transfers.map { $0.accountID } == [bob.id])
    #expect(scoped.storage.map { $0.accountID } == [bob.id])
    #expect(scoped.publicLinks.map { $0.accountID } == [bob.id])
    #expect(content.filtered(selectedAccountID: Optional<UUID>.none).accounts.map { $0.id } == [alice.id, bob.id])
}

@MainActor
@Test
func viewModelRefreshesAndAddsAccountsThroughAppModel() async throws {
    let diagnostics = AppDiagnosticBuffer()
    let accountService = AccountSessionService(
        credentialStore: MemoryCredentialStore(),
        capabilitiesFetcher: MacAppCapabilitiesFetcher(),
        diagnostics: diagnostics
    )
    let repository = MemoryAccountRepository()
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager(), diagnostics: diagnostics),
        repository: repository,
        diagnostics: diagnostics
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    #expect(viewModel.accounts.isEmpty)

    await viewModel.addAccount(
        serverURL: URL(string: "https://cloud.example/")!,
        username: "alice",
        appPassword: "secret"
    )

    #expect(viewModel.accounts.count == 1)
    #expect(viewModel.accounts[0].serverVersion == "10.15.0")
    #expect(viewModel.lastErrorMessage == nil)
    #expect(viewModel.diagnostics.contains { $0.category == "App" })
}

@MainActor
@Test
func viewModelSyncNowRunsManualSyncAndRefreshesSnapshot() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [record])
    )
    let manualSync = MacManualSyncRunner()
    let viewModel = WesomeCloudViewModel(model: appModel, manualSync: manualSync)

    await viewModel.syncNow()

    #expect(await manualSync.accountIDs == [account.id])
    #expect(viewModel.accounts.map(\.id) == [account.id])
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelSyncNowReportsManualSyncFailure() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [record])
    )
    let manualSync = MacManualSyncRunner()
    await manualSync.set(error: WesomeCloudError.unsupported("manual sync failed"))
    let viewModel = WesomeCloudViewModel(model: appModel, manualSync: manualSync)

    await viewModel.syncNow()

    #expect(await manualSync.accountIDs.isEmpty)
    #expect(viewModel.lastErrorMessage?.contains("manual sync failed") == true)
}

@MainActor
@Test
func viewModelFormatsHTTPFailuresForUsers() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [record])
    )
    let manualSync = MacManualSyncRunner()
    await manualSync.set(error: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 401, kind: .authentication)))
    let viewModel = WesomeCloudViewModel(model: appModel, manualSync: manualSync)

    await viewModel.syncNow()

    #expect(viewModel.lastErrorMessage == "Authentication failed. Check the account credentials and try again.")
}

@MainActor
@Test
func viewModelAddsOAuthAccountThroughAppModel() async throws {
    let accountService = AccountSessionService(
        credentialStore: MemoryCredentialStore(),
        capabilitiesFetcher: MacAppCapabilitiesFetcher()
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository()
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.addOAuthAccount(
        serverURL: URL(string: "https://cloud.example/")!,
        authenticator: MacAppOAuthAuthenticator()
    )

    #expect(viewModel.accounts.count == 1)
    #expect(viewModel.accounts.first?.account.username == "oauth-user")
    #expect(viewModel.accounts.first?.serverVersion == "10.15.0")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelRemovesAccountThroughAppModel() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let domain = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "alice")
    let repository = MemoryAccountRepository(records: [
        PersistedAccountRecord(account: account, domain: domain)
    ])
    let domainManager = MemoryFileProviderDomainManager()
    try await domainManager.register(domain)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    await viewModel.removeAccount(account.id)

    #expect(viewModel.accounts.isEmpty)
    #expect(viewModel.spaces.isEmpty)
    #expect(try await repository.records().isEmpty)
    #expect(try await domainManager.domains().isEmpty)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelOpensAccountServerInBrowser() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [record])
    )
    let opener = RecordingURLOpener()
    let viewModel = WesomeCloudViewModel(model: appModel, urlOpener: opener)

    viewModel.openServerInBrowser(record)

    #expect(opener.openedURLs == [account.serverURL])
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelReconnectsImportedAccountThroughAppModel() async throws {
    let credentials = MemoryCredentialStore()
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: MacAppCapabilitiesFetcher()
    )
    let account = Account(
        id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        serverURL: URL(string: "https://cloud.example")!,
        username: "alice",
        displayName: "Alice Cloud"
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [
            PersistedAccountRecord(
                account: account,
                lastSyncStatus: SyncStatusSnapshot(state: .error, message: "Imported from legacy client")
            )
        ])
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.reconnectAccount(account.id, appPassword: "secret")

    #expect(viewModel.accounts.count == 1)
    #expect(viewModel.accounts.first?.id == account.id)
    #expect(viewModel.accounts.first?.lastSyncStatus.state == .idle)
    #expect(viewModel.accounts.first?.lastSyncStatus.message == "Connected")
    #expect(try await credentials.credential(accountID: account.id)?.secret == "secret")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelRefreshesAvailableSpaces() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: MacAppCapabilitiesFetcher(),
        spacesFetcher: MacAppSpacesFetcher(spaces: [
            OwnCloudSpace(
                id: "space-1",
                name: "Marketing",
                driveType: "project",
                driveAlias: "project/marketing",
                webDAVURL: URL(string: "https://cloud.example/dav/spaces/space-1")!,
                quota: SpaceQuota(used: 1024, remaining: 2048, total: 4096, state: "normal")
            ),
        ])
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()

    #expect(viewModel.spaces.count == 1)
    let row = try #require(viewModel.spaces.first?.rowViewModel)
    #expect(row.name == "Marketing")
    #expect(row.detail == "project • project/marketing")
    #expect(row.quotaText == "1 KB of 4 KB")
}

@MainActor
@Test
func viewModelRefreshesAndDismissesServerNotifications() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let notifications = MacAppNotificationsFetcher(notifications: [
        UserNotification(
            id: 42,
            app: "files_sharing",
            user: "alice",
            subject: "Share request",
            message: "Bob shared Project Plan",
            objectID: "share-1",
            objectType: "remote_share",
            date: Date(timeIntervalSince1970: 1_779_900_000)
        ),
    ])
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: MacAppCapabilitiesFetcher(),
        notificationsFetcher: notifications
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    let notification = try #require(viewModel.notifications.first)
    let row = notification.rowViewModel
    await viewModel.dismissNotification(notification)

    #expect(row.subject == "Share request")
    #expect(row.detail == "Bob shared Project Plan • files_sharing • remote_share")
    #expect(viewModel.notifications.isEmpty)
    #expect(await notifications.deletedID == 42)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelSyncsSelectedSpace() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: MacAppCapabilitiesFetcher(),
        spacesFetcher: MacAppSpacesFetcher(spaces: [
            OwnCloudSpace(
                id: "storage-users-1$space",
                name: "Marketing",
                webDAVURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$space")!
            ),
        ])
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    let space = try #require(viewModel.spaces.first)
    await viewModel.syncSpace(space)

    #expect(viewModel.accounts.first?.domain?.displayName == "Marketing")
    #expect(viewModel.accounts.first?.domain?.webDAVRootURL == URL(string: "https://cloud.example/dav/spaces/storage-users-1$space")!)
    #expect(viewModel.accounts.first?.lastSyncStatus.message == "Connected to Marketing")
    #expect(viewModel.lastErrorMessage == nil)
}

#if canImport(AuthenticationServices) && canImport(AppKit)
@MainActor
@Test
func productionOAuthAuthenticatorUsesASWebAuthenticationSessionPresenter() async throws {
    let presenter = MacOAuthSessionPresenter()
    let exchanger = MacOAuthTokenExchanger()
    let factory = ProductionOAuthAuthenticatorFactory(
        configuration: OAuthAuthorizationConfiguration(
            clientID: "client-1",
            redirectURI: URL(string: "wesomecloud://oauth/callback")!
        ),
        tokenExchanger: exchanger,
        discoveryClient: nil,
        stateProvider: { "state-1" },
        sessionPresenter: presenter
    )

    let tokenSet = try await factory.makeAuthenticator().authenticate(serverURL: URL(string: "https://cloud.example/")!)

    #expect(tokenSet.username == "browser-user")
    #expect(await presenter.callbackScheme == "wesomecloud")
    #expect(await presenter.authorizationURL?.absoluteString.contains("client_id=client-1") == true)
    #expect(await exchanger.exchangedCode == "browser-code")
    #expect(await exchanger.serverURL == URL(string: "https://cloud.example/")!)
}
#endif

@MainActor
@Test
func viewModelRefreshesAndClearsSyncIssues() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let error = SyncErrorRecord(
        scope: .operation,
        operationID: UUID(),
        message: "Queued operation failed permanently",
        isRecoverable: false,
        occurredAt: Date(timeIntervalSince1970: 3)
    )
    try await metadataStore.recordSyncError(error, accountID: account.id)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()

    #expect(viewModel.issues.count == 1)
    #expect(viewModel.issues.first?.message == "Queued operation failed permanently")

    let issue = try #require(viewModel.issues.first)
    await viewModel.clearIssue(issue)

    #expect(viewModel.issues.isEmpty)
    #expect(try await metadataStore.syncErrors(accountID: account.id).isEmpty)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelRefreshesAndResolvesConflicts() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(kind: .nameCollision, itemID: "file-1", localPath: "/File.txt", remotePath: "/File.txt", message: "Name collision"),
        createdAt: Date(timeIntervalSince1970: 1)
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()

    #expect(viewModel.conflicts.map(\.id) == [conflict.id])

    let appConflict = try #require(viewModel.conflicts.first)
    await viewModel.resolveConflict(appConflict, decision: .renameLocal, resolvedName: "File local.txt")

    #expect(viewModel.conflicts.isEmpty)
    let resolved = try await metadataStore.conflicts(accountID: account.id, state: .resolved).first
    #expect(resolved?.selectedResolution == .renameLocal)
    #expect(resolved?.resolvedName == "File local.txt")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelKeepsConflictVisibleWhenRenameResolutionIsInvalid() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(kind: .nameCollision, itemID: "file-1", localPath: "/File.txt", remotePath: "/File.txt", message: "Name collision")
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    let appConflict = try #require(viewModel.conflicts.first)
    await viewModel.resolveConflict(appConflict, decision: .renameLocal, resolvedName: "")

    #expect(viewModel.conflicts.map(\.id) == [conflict.id])
    #expect(viewModel.lastErrorMessage == "Choose a valid filename. The name cannot be empty.")
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .resolved).isEmpty)
}

@MainActor
@Test
func syncIssueRowViewModelSummarizesIssue() {
    let operationID = UUID()
    let issue = SyncIssue(
        accountID: UUID(),
        accountName: "Alice",
        scope: .operation,
        operationID: operationID,
        message: "Upload failed",
        isRecoverable: false
    )

    let row = issue.rowViewModel

    #expect(row.title == "Queued operation issue")
    #expect(row.accountName == "Alice")
    #expect(row.detail.contains("Upload failed"))
    #expect(row.detail.contains(operationID.uuidString))
    #expect(!row.isRecoverable)
}

@MainActor
@Test
func conflictRowViewModelSummarizesConflict() {
    let conflict = AppConflict(
        record: ConflictRecord(
            conflict: SyncConflict(
                kind: .caseOnlyRename,
                itemID: "Report.txt",
                localPath: "/report.txt",
                remotePath: "/Report.txt",
                message: "Case-only rename"
            )
        ),
        account: PersistedAccountRecord(account: Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice"))
    )

    let row = conflict.rowViewModel

    #expect(row.title == "Case-only rename")
    #expect(row.accountName == "Alice")
    #expect(row.detail.contains("Case-only rename"))
    #expect(row.suggestedRename == "Report.txt-local")
}

@MainActor
@Test
func conflictRowViewModelSummarizesUnicodeNormalizationConflict() {
    let conflict = AppConflict(
        record: ConflictRecord(
            conflict: SyncConflict(
                kind: .unicodeNormalization,
                itemID: "Cafe.txt",
                localPath: "/Café.txt",
                remotePath: "/Cafe\u{301}.txt",
                message: "Unicode-normalization-only rename"
            )
        ),
        account: PersistedAccountRecord(account: Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice"))
    )

    let row = conflict.rowViewModel

    #expect(row.title == "Unicode normalization")
    #expect(row.detail.contains("Unicode-normalization-only rename"))
}

@MainActor
@Test
func conflictRowViewModelSummarizesRemoteDeleteConflict() {
    let conflict = AppConflict(
        record: ConflictRecord(
            conflict: SyncConflict(
                kind: .remoteDeletedDuringLocalEdit,
                itemID: "file-1",
                localPath: "/File.txt",
                remotePath: "/File.txt",
                message: "Remote deleted"
            )
        ),
        account: PersistedAccountRecord(account: Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice"))
    )

    let row = conflict.rowViewModel

    #expect(row.title == "Remote deleted")
    #expect(row.detail.contains("Remote deleted"))
}

@MainActor
@Test
func accountSetupFormValidatesRequiredFieldsAndURLs() {
    let form = AccountSetupFormModel()

    #expect(!form.canSubmit)
    #expect(form.validateForSubmit() == nil)
    #expect(form.validationMessage == "Enter a valid server URL, username, and app password.")

    form.serverURLText = "not a url"
    form.username = " alice "
    form.appPassword = "secret"
    #expect(!form.canSubmit)

    form.serverURLText = "https://cloud.example/"
    let input = form.validateForSubmit()

    #expect(input?.serverURL == URL(string: "https://cloud.example/")!)
    #expect(input?.username == "alice")
    #expect(input?.appPassword == "secret")
    #expect(form.validationMessage == nil)

    form.reset()
    #expect(form.serverURLText.isEmpty)
    #expect(form.username.isEmpty)
    #expect(form.appPassword.isEmpty)
}

@MainActor
@Test
func accountSetupFormAllowsOAuthWithOnlyServerURL() {
    let form = AccountSetupFormModel()
    form.mode = .oauth
    form.serverURLText = "https://cloud.example/"

    let input = form.validateForSubmit()

    #expect(input?.mode == .oauth)
    #expect(input?.serverURL == URL(string: "https://cloud.example/")!)
    #expect(input?.username == "")
    #expect(input?.appPassword == "")
    #expect(form.validationMessage == nil)
}

@MainActor
@Test
func preferencesFormClampsValuesAndBuildsPreferences() {
    let form = PreferencesFormModel()
    form.isSyncPaused = true
    form.pollInterval = 1
    form.queueInterval = 1
    form.retryMaximumAttempts = 0
    form.maximumConcurrentTransfers = 0
    form.defaultAvailability = .alwaysLocal
    form.showHiddenFiles = true
    form.retainEventLimit = 1
    form.includeDebugEvents = true
    form.automaticallyCheckForUpdates = false
    form.appcastURLText = "https://updates.example/appcast.xml"
    form.updateCheckInterval = 1
    form.ignoredFilenamePatternsText = "*.tmp\n~$*; .~lock.*"
    form.excludedRemotePathsText = "Projects/Private\n/Archive/; /"

    let preferences = form.preferences

    #expect(preferences.sync.pollInterval == 15)
    #expect(preferences.sync.isSyncPaused)
    #expect(preferences.sync.queueInterval == 5)
    #expect(preferences.sync.retryMaximumAttempts == 1)
    #expect(preferences.sync.maximumConcurrentTransfers == 1)
    #expect(preferences.files.defaultAvailability == .alwaysLocal)
    #expect(preferences.files.showHiddenFiles)
    #expect(preferences.files.ignoredFilenamePatterns == ["*.tmp", "~$*", ".~lock.*"])
    #expect(preferences.files.excludedRemotePaths == ["/Projects/Private", "/Archive"])
    #expect(preferences.diagnostics.retainEventLimit == 50)
    #expect(preferences.diagnostics.includeDebugEvents)
    #expect(preferences.updates.automaticallyCheckForUpdates == false)
    #expect(preferences.updates.appcastURL?.absoluteString == "https://updates.example/appcast.xml")
    #expect(preferences.updates.checkInterval == 3600)
}

@MainActor
@Test
func viewModelSavesPreferencesThroughAppModel() async throws {
    let preferencesRepository = MemoryPreferencesRepository()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        preferencesRepository: preferencesRepository
    )
    let viewModel = WesomeCloudViewModel(model: appModel)
    var preferences = AppPreferences()
    preferences.sync.pollInterval = 180
    preferences.files.defaultAvailability = .alwaysLocal

    await viewModel.savePreferences(preferences)

    #expect(viewModel.preferences == preferences)
    #expect(try await preferencesRepository.load() == preferences)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelTogglesSyncPausePreference() async throws {
    let preferencesRepository = MemoryPreferencesRepository()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        preferencesRepository: preferencesRepository
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    await viewModel.toggleSyncPaused()

    #expect(viewModel.preferences.sync.isSyncPaused)
    #expect(try await preferencesRepository.load().sync.isSyncPaused)
    #expect(viewModel.lastErrorMessage == nil)

    await viewModel.toggleSyncPaused()

    #expect(!viewModel.preferences.sync.isSyncPaused)
    #expect(!(try await preferencesRepository.load().sync.isSyncPaused))
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelUpdatesFileAvailabilityIntent() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    await viewModel.setAvailabilityIntent(.onlineOnly, for: file)

    #expect(viewModel.files.first?.item.availabilityIntent == .onlineOnly)
    #expect(viewModel.files.first?.rowViewModel.availabilityText == "Online Only")
    #expect(viewModel.files.first?.rowViewModel.materializationText == "Dataless")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelRevealsDownloadedFilesInFinder() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    let materializedURL = FileManager.default.temporaryDirectory.appending(path: "Plan-\(UUID().uuidString).md")
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    try await metadataStore.setMaterializedURL(materializedURL, accountID: account.id, itemID: "file-1")
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )
    let revealer = RecordingFileRevealer()
    let viewModel = WesomeCloudViewModel(model: appModel, fileRevealer: revealer)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    viewModel.revealInFinder(file)

    #expect(viewModel.files.first?.rowViewModel.isDownloaded == true)
    #expect(revealer.revealedURLs == [materializedURL])
    #expect(viewModel.lastRevealedURL == materializedURL)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelReportsErrorWhenRevealingDatalessFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )
    let revealer = RecordingFileRevealer()
    let viewModel = WesomeCloudViewModel(model: appModel, fileRevealer: revealer)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    viewModel.revealInFinder(file)

    #expect(viewModel.files.first?.rowViewModel.isDownloaded == false)
    #expect(revealer.revealedURLs.isEmpty)
    #expect(viewModel.lastRevealedURL == nil)
    #expect(viewModel.lastErrorMessage == "File is not downloaded yet.")
}

@MainActor
@Test
func viewModelCreatesPublicLinkForFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let linkCreator = MacAppPublicLinkCreator()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )
    let viewModel = WesomeCloudViewModel(model: appModel)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    await viewModel.createPublicLink(for: file)

    #expect(viewModel.lastCreatedShare?.url.absoluteString == "https://cloud.example/s/share-1")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func productionPublicLinkCreatorRefreshesOAuthCredentialForPrivateLinks() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let credentialStore = MemoryCredentialStore()
    try await credentialStore.save(Credential(accountID: account.id, username: "alice", secret: "old-refresh", kind: .oauthRefreshToken))
    let exchanger = MacAppRefreshExchanger(
        tokenSet: OAuthTokenSet(username: "alice", accessToken: "new-access", refreshToken: "new-refresh")
    )
    let transport = MacFixtureTransport([
        (Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/alice/Plan.md</d:href>
            <d:propstat><d:prop>
              <oc:privatelink>https://cloud.example/index.php/f/11</oc:privatelink>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8), 207),
    ])
    let creator = ProductionPublicLinkCreator(
        credentials: credentialStore,
        credentialResolver: AccountCredentialResolver(discoveryClient: nil, refreshExchanger: exchanger),
        transport: transport
    )
    let file = AppFileItem(
        accountID: account.id,
        accountName: account.displayName,
        serverURL: account.serverURL,
        accountUsername: account.username,
        item: StoredItem(remote: RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file))
    )

    let url = try await creator.privateLink(for: file)

    #expect(url.absoluteString == "https://cloud.example/index.php/f/11")
    #expect(await exchanger.requestedRefreshToken == "old-refresh")
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    #expect(try await credentialStore.credential(accountID: account.id)?.secret == "new-refresh")
}

@MainActor
@Test
func productionPublicLinkCreatorUsesSpaceWebDAVRootForPrivateLinks() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let credentialStore = MemoryCredentialStore()
    try await credentialStore.save(Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword))
    let transport = MacFixtureTransport([
        (Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/dav/spaces/space-1/Plan.md</d:href>
            <d:propstat><d:prop>
              <oc:privatelink>https://cloud.example/index.php/f/space-file</oc:privatelink>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8), 207),
    ])
    let creator = ProductionPublicLinkCreator(
        credentials: credentialStore,
        transport: transport
    )
    let file = AppFileItem(
        accountID: account.id,
        accountName: account.displayName,
        serverURL: account.serverURL,
        accountUsername: account.username,
        webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!,
        item: StoredItem(remote: RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file))
    )

    let url = try await creator.privateLink(for: file)

    #expect(url.absoluteString == "https://cloud.example/index.php/f/space-file")
    #expect(await transport.requests.first?.url?.absoluteString == "https://cloud.example/dav/spaces/space-1/Plan.md")
}

@MainActor
@Test
func viewModelRefreshesAndDeletesPublicLinksForFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let linkCreator = MacAppPublicLinkCreator()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )
    let viewModel = WesomeCloudViewModel(model: appModel)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    await viewModel.refreshPublicLinks(for: file)
    let link = try #require(viewModel.publicLinks.first)
    await viewModel.deletePublicLink(link)

    #expect(viewModel.publicLinks.isEmpty)
    #expect(await linkCreator.deletedShares.map(\.id) == ["share-1"])
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelCopiesPublicLinkToClipboard() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let linkCreator = MacAppPublicLinkCreator()
    let clipboard = RecordingClipboardWriter()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )
    let viewModel = WesomeCloudViewModel(model: appModel, clipboard: clipboard)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)
    await viewModel.refreshPublicLinks(for: file)
    let link = try #require(viewModel.publicLinks.first)

    viewModel.copyPublicLink(link)

    #expect(clipboard.copiedValues == ["https://cloud.example/s/share-1"])
    #expect(viewModel.lastCopiedPublicLink?.id == "share-1")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelCopiesPrivateLinkToClipboard() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file)
    ])
    let linkCreator = MacAppPublicLinkCreator()
    let clipboard = RecordingClipboardWriter()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )
    let viewModel = WesomeCloudViewModel(model: appModel, clipboard: clipboard)
    await viewModel.refresh()
    let file = try #require(viewModel.files.first)

    await viewModel.copyPrivateLink(for: file)

    #expect(clipboard.copiedValues == ["https://cloud.example/index.php/f/1"])
    #expect(viewModel.lastCopiedPrivateLink?.absoluteString == "https://cloud.example/index.php/f/1")
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelLoadsAndSummarizesTransferActivity() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    let transfer = TransferRecord(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        itemID: "file-1",
        direction: .download,
        phase: .running,
        bytesTransferred: 512,
        totalBytes: 1024,
        remotePath: "/Readme.md",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    try await metadataStore.upsertTransfer(transfer, accountID: account.id)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    let row = try #require(viewModel.transfers.first?.rowViewModel)

    #expect(row.title == "Downloading /Readme.md")
    #expect(row.phaseText == "Running")
    #expect(row.detail == "512 B of 1.0 KB")
    #expect(row.progress == 0.5)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelLoadsAndSummarizesAccountStorage() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(
            id: "root",
            parentID: nil,
            name: "Root",
            path: "/",
            kind: .folder,
            quotaUsedBytes: 1_048_576,
            quotaAvailableBytes: 3_145_728
        )
    ])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )
    let viewModel = WesomeCloudViewModel(model: appModel)

    await viewModel.refresh()
    let row = try #require(viewModel.storage.first?.rowViewModel)

    #expect(row.summaryText == "1.0 MB of 4.0 MB")
    #expect(row.progress == 0.25)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelExportsDiagnostics() async throws {
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository()
    )
    let viewModel = WesomeCloudViewModel(model: appModel)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    await viewModel.exportDiagnostics(to: directory)

    let url = try #require(viewModel.lastDiagnosticsExportURL)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelRevealsDiagnosticsExportInFinder() async throws {
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository()
    )
    let revealer = RecordingFileRevealer()
    let viewModel = WesomeCloudViewModel(model: appModel, fileRevealer: revealer)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    await viewModel.exportDiagnostics(to: directory)
    let url = try #require(viewModel.lastDiagnosticsExportURL)
    viewModel.revealDiagnosticsExport()

    #expect(revealer.revealedURLs == [url])
    #expect(viewModel.lastRevealedURL == url)
    #expect(viewModel.lastErrorMessage == nil)
}

@MainActor
@Test
func viewModelReportsErrorWhenRevealingMissingDiagnosticsExport() async throws {
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository()
    )
    let revealer = RecordingFileRevealer()
    let viewModel = WesomeCloudViewModel(model: appModel, fileRevealer: revealer)

    viewModel.revealDiagnosticsExport()

    #expect(revealer.revealedURLs.isEmpty)
    #expect(viewModel.lastRevealedURL == nil)
    #expect(viewModel.lastErrorMessage == "No diagnostics export is available.")
}

@MainActor
@Test
func productionAppFactoryCreatesViewModelAndRuntimeDirectories() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let factory = ProductionAppFactory(paths: paths, diagnosticsLimit: 10, legacyOwnCloudConfigURLs: [])

    let viewModel = try factory.makeViewModel()
    await viewModel.refresh()

    #expect(viewModel.accounts.isEmpty)
    #expect(viewModel.lastErrorMessage == nil)
    #expect(FileManager.default.fileExists(atPath: paths.root.path))
    #expect(FileManager.default.fileExists(atPath: paths.materializedFiles.path))
    #expect(FileManager.default.fileExists(atPath: paths.logs.path))
}

@MainActor
@Test
func productionAppFactoryMigratesLegacyJSONAccountsToSQLite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(
        account: account,
        domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"),
        serverVersion: "10.15.0"
    )
    try await JSONAccountRepository(fileURL: paths.accounts).save(record)
    let factory = ProductionAppFactory(paths: paths, diagnosticsLimit: 10, legacyOwnCloudConfigURLs: [])

    let viewModel = try factory.makeViewModel()
    await viewModel.refresh()

    #expect(viewModel.accounts.map(\.id) == [account.id])
    #expect(FileManager.default.fileExists(atPath: paths.accountDatabase.path))
    let sqliteRecords = try await SQLiteAccountRepository(databaseURL: paths.accountDatabase).records()
    #expect(sqliteRecords == [record])
}

@MainActor
@Test
func productionAppFactoryMigratesLegacyOwnCloudDesktopAccountsToSQLite() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let legacyConfigURL = root.appending(path: "owncloud.cfg")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("""
    [Accounts]
    0\\url=https://cloud.example/
    0\\user=alice
    0\\displayName=Alice Cloud
    """.utf8).write(to: legacyConfigURL, options: [.atomic])
    let factory = ProductionAppFactory(
        paths: paths,
        diagnosticsLimit: 10,
        legacyOwnCloudConfigURLs: [legacyConfigURL]
    )

    let viewModel = try factory.makeViewModel()
    await viewModel.refresh()

    #expect(viewModel.accounts.map(\.account.displayName) == ["Alice Cloud"])
    #expect(viewModel.accounts.first?.lastSyncStatus.state == .error)
    #expect(viewModel.accounts.first?.lastSyncStatus.message.contains("Add credentials") == true)
    let sqliteRecords = try await SQLiteAccountRepository(databaseURL: paths.accountDatabase).records()
    #expect(sqliteRecords.map(\.account.displayName) == ["Alice Cloud"])
}

@Test
func productionConflictResolverBuildsCoordinatorAndExecutesResolution() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credentialStore = MemoryCredentialStore()
    try await credentialStore.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let metadataStore = try SQLiteMetadataStore(databaseURL: paths.database)
    let localURL = paths.materializedFiles.appending(path: "local.txt")
    try Data("updated".utf8).write(to: localURL)
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    try await metadataStore.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let transport = MacFixtureTransport([
        (Data(), 204),
        (macPropfindXML(name: "Readme.md", fileID: "file-1", etag: "merged-etag"), 207),
    ])
    let resolver = ProductionAppConflictResolver(
        credentials: credentialStore,
        runtimeFactory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    )

    try await resolver.resolveConflict(
        conflict,
        account: PersistedAccountRecord(account: account),
        decision: .keepLocal,
        resolvedName: nil
    )

    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
    #expect(try await metadataStore.item(accountID: account.id, id: "file-1")?.remote.etag == "merged-etag")
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .pending).isEmpty)
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .resolved).first?.selectedResolution == .keepLocal)
}

@Test
func productionAccountSyncRunnerPollsFoldersChangedAtRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credentialStore = MemoryCredentialStore()
    try await credentialStore.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let metadataStore = try SQLiteMetadataStore(databaseURL: paths.database)
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "/Folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder, etag: "old-folder"),
        RemoteItem(id: "/Folder/Subfolder", parentID: "/Folder", name: "Subfolder", path: "/Folder/Subfolder", kind: .folder, etag: "old-subfolder"),
    ])
    let transport = MacFixtureTransport([
        (macFolderPropfindXML(etag: "new-folder"), 207),
        (macFolderChildrenPropfindXML(), 207),
        (macSubfolderChildrenPropfindXML(), 207),
    ])
    let runner = ProductionAccountSyncRunner(
        credentials: credentialStore,
        metadataStore: metadataStore,
        runtimeFactory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    )

    let changes = try await runner.pollRemote(account: PersistedAccountRecord(account: account))

    #expect(changes.updated.map(\.id) == ["/Folder", "/Folder/Subfolder"])
    #expect(changes.added.map(\.id) == ["/Folder/Nested.txt", "/Folder/Subfolder/Deep.txt"])
    #expect(try await metadataStore.item(accountID: account.id, id: "/Folder/Nested.txt")?.remote.parentID == "/Folder")
    #expect(try await metadataStore.item(accountID: account.id, id: "/Folder/Subfolder/Deep.txt")?.remote.parentID == "/Folder/Subfolder")
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND", "PROPFIND"])
    #expect(await transport.requests.map { $0.url?.path } == [
        "/remote.php/dav/files/alice",
        "/remote.php/dav/files/alice/Folder",
        "/remote.php/dav/files/alice/Folder/Subfolder",
    ])
}

@MainActor
@Test
func backgroundTaskControllerRegistersSchedulesAndRunsAccounts() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let preferences = MemoryPreferencesRepository(
        preferences: AppPreferences(sync: SyncPreferences(pollInterval: 120, queueInterval: 30))
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        preferencesRepository: preferences
    )
    let runner = MacBackgroundRunner()
    let scheduler = BackgroundSyncScheduler(runner: runner, appModel: appModel, clock: { now })
    let taskScheduler = InMemoryBackgroundTaskScheduler()
    let controller = BackgroundTaskSyncController(
        identifier: "cloud.wesome.wesomecloud.refresh",
        scheduler: scheduler,
        appModel: appModel,
        taskScheduler: taskScheduler,
        clock: { now }
    )

    let registered = try await controller.registerAndSchedule()
    await taskScheduler.launch(identifier: "cloud.wesome.wesomecloud.refresh")

    #expect(registered)
    #expect(taskScheduler.registeredIdentifiers == ["cloud.wesome.wesomecloud.refresh"])
    #expect(taskScheduler.submissions.map(\.identifier) == ["cloud.wesome.wesomecloud.refresh", "cloud.wesome.wesomecloud.refresh"])
    #expect(taskScheduler.submissions.first?.earliestBeginDate == now.addingTimeInterval(120))
    #expect(await runner.pollCount == 1)
    #expect(await runner.queueCount == 1)
}

@MainActor
@Test
func backgroundTaskControllerHonorsPersistedSyncPause() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let preferences = MemoryPreferencesRepository(
        preferences: AppPreferences(sync: SyncPreferences(isSyncPaused: true, pollInterval: 120, queueInterval: 30))
    )
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        preferencesRepository: preferences
    )
    let runner = MacBackgroundRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configurationProvider: {
            try await preferences.load().sync.backgroundSyncConfiguration
        },
        clock: { now }
    )
    let taskScheduler = InMemoryBackgroundTaskScheduler()
    let controller = BackgroundTaskSyncController(
        identifier: "cloud.wesome.wesomecloud.refresh",
        scheduler: scheduler,
        appModel: appModel,
        taskScheduler: taskScheduler,
        clock: { now }
    )

    _ = await taskScheduler.register(identifier: "cloud.wesome.wesomecloud.refresh") {
        try? await controller.runTaskAndReschedule()
    }
    await taskScheduler.launch(identifier: "cloud.wesome.wesomecloud.refresh")

    #expect(await runner.pollCount == 0)
    #expect(await runner.queueCount == 0)
    #expect(taskScheduler.submissions.map(\.earliestBeginDate) == [now.addingTimeInterval(120)])
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .paused)
    #expect(saved?.lastSyncStatus.message == "Sync paused")
}

private struct UnreadableAccountRepository: AccountRepository {
    func records() async throws -> [PersistedAccountRecord] { throw WesomeCloudError.invalidResponse }
    func save(_: PersistedAccountRecord) async throws {}
    func delete(accountID _: UUID) async throws {}
    func updateStatus(_: SyncStatusSnapshot, accountID _: UUID) async throws {}
}

@MainActor
@Test
func backgroundTaskControllerReschedulesWhenLoadingAccountsFails() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: UnreadableAccountRepository(),
        preferencesRepository: MemoryPreferencesRepository(
            preferences: AppPreferences(sync: SyncPreferences(pollInterval: 120, queueInterval: 30))
        )
    )
    let taskScheduler = InMemoryBackgroundTaskScheduler()
    let controller = BackgroundTaskSyncController(
        scheduler: BackgroundSyncScheduler(runner: MacBackgroundRunner(), appModel: appModel, clock: { now }),
        appModel: appModel,
        taskScheduler: taskScheduler,
        clock: { now }
    )

    await #expect(throws: WesomeCloudError.invalidResponse) {
        try await controller.runTaskAndReschedule()
    }
    #expect(taskScheduler.submissions.map(\.earliestBeginDate) == [now.addingTimeInterval(120)])
}

private func macPropfindXML(name: String, fileID: String, etag: String) -> Data {
    Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/\(name)</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"\(etag)"</d:getetag><oc:fileid>\(fileID)</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
}

private func macFolderPropfindXML(etag: String) -> Data {
    Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Folder/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"\(etag)"</d:getetag>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
}

private func macFolderChildrenPropfindXML() -> Data {
    Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Folder/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"new-folder"</d:getetag>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Nested.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"nested"</d:getetag>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Subfolder/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"new-subfolder"</d:getetag>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
}

private func macSubfolderChildrenPropfindXML() -> Data {
    Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Subfolder/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"new-subfolder"</d:getetag>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Subfolder/Deep.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"deep"</d:getetag>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
}

@Test
func productionSyncRunnerOnlyReplaysTheSelectedSpaceQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let locations = ["AM", "HR"].map { name in
        PersistedAccountRecord(account: account, domain: CloudDomain(
            id: name, accountID: account.id, displayName: name,
            webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/\(name)")!, storageID: UUID()
        ))
    }
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    for location in locations {
        try await store.upsert(accountID: location.metadataID, items: [
            RemoteItem(id: "same-id", parentID: nil, name: "File.txt", path: "/File.txt", kind: .file)
        ])
        try await store.enqueue(PendingOperation(kind: .delete, itemID: "same-id"), accountID: location.metadataID)
    }
    let transport = MacFixtureTransport([(Data(), 204), (Data(), 204)])
    let runner = ProductionAccountSyncRunner(credentials: credentials, metadataStore: store,
                                             runtimeFactory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport))
    #expect(try await runner.processQueue(account: locations[0]).completed.count == 1)
    #expect(try await store.pendingOperations(accountID: locations[1].metadataID).count == 1)
    #expect(try await store.item(accountID: locations[1].metadataID, id: "same-id") != nil)
    #expect(try await runner.processQueue(account: locations[1]).completed.count == 1)
    #expect(await transport.requests.map { $0.url?.path } == ["/dav/spaces/AM/File.txt", "/dav/spaces/HR/File.txt"])
    #expect(await transport.requests.allSatisfy { $0.httpMethod == "DELETE" })
}

@MainActor
@Test
func dashboardFileActionsUseTheFilesSpace() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    var record = PersistedAccountRecord(account: account)
    record.domains = ["AM", "HR"].map {
        CloudDomain(id: $0, accountID: account.id, displayName: $0,
                    webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/\($0)")!, storageID: UUID())
    }
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    for domain in record.domains {
        try await store.upsert(accountID: domain.metadataID, items: [
            RemoteItem(id: "same-id", parentID: nil, name: "File.txt", path: "/File.txt", kind: .file, fileID: "storage$\(domain.id)!file")
        ])
    }
    let transport = MacFixtureTransport([(Data(#"{"ocs":{"meta":{"statuscode":100},"data":[]}}"#.utf8), 200)])
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: credentials),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [record]), metadataStore: store,
        availabilityResolver: ProductionAppAvailabilityResolver(credentials: credentials, runtimeFactory: ProductionExtensionRuntimeFactory(paths: paths)),
        publicLinkCreator: ProductionPublicLinkCreator(credentials: credentials, transport: transport)
    )
    let viewModel = WesomeCloudViewModel(model: model)
    await viewModel.refresh()
    #expect(Set(viewModel.files.map(\.id)).count == 2)
    let hr = try #require(viewModel.files.first { $0.domainID == "HR" })
    await viewModel.setAvailabilityIntent(.alwaysLocal, for: hr)
    #expect(viewModel.lastErrorMessage == nil)
    #expect(try await store.item(accountID: record.domains[1].metadataID, id: "same-id")?.availabilityIntent == .alwaysLocal)
    #expect(try await store.item(accountID: record.domains[0].metadataID, id: "same-id")?.availabilityIntent == .unspecified)
    await viewModel.refreshPublicLinks(for: hr)
    #expect(viewModel.lastErrorMessage == nil)
    let url = try #require(await transport.requests.first?.url)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "space_ref" }?.value == "storage$HR!file")
}
