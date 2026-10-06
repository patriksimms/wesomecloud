import Foundation
import OwnCloudKit
import SyncStore
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

private struct ModelCapabilitiesFetcher: CapabilitiesFetching {
    func fetchCapabilities(serverURL _: URL, credentials _: Credentials) async throws -> ServerCapabilities {
        ServerCapabilities(versionString: "10.15.0", edition: "Community", remotePollInterval: 45)
    }
}

private struct ModelSpacesFetcher: SpacesFetching {
    var spaces: [OwnCloudSpace]
    var error: Error? = nil

    func fetchSpaces(serverURL _: URL, credentials _: Credentials) async throws -> [OwnCloudSpace] {
        if let error { throw error }
        return spaces
    }
}

private actor ModelNotificationsFetcher: NotificationsFetching {
    var deletedID: Int?
    var notifications: [UserNotification]
    var error: Error?

    init(notifications: [UserNotification], error: Error? = nil) {
        self.notifications = notifications
        self.error = error
    }

    func fetchNotifications(serverURL _: URL, credentials _: Credentials) async throws -> [UserNotification] {
        if let error { throw error }
        return notifications
    }

    func deleteNotification(id: Int, serverURL _: URL, credentials _: Credentials) async throws {
        deletedID = id
        notifications.removeAll { $0.id == id }
    }
}

private struct ModelOAuthAuthenticator: OAuthAuthenticating {
    func authenticate(serverURL _: URL) async throws -> OAuthTokenSet {
        OAuthTokenSet(username: "oauth-user", accessToken: "access", refreshToken: "refresh")
    }
}

private actor ModelConflictResolver: AppConflictResolving {
    var calls: [(record: ConflictRecord, account: PersistedAccountRecord, decision: ConflictResolutionDecision, resolvedName: String?)] = []
    var error: Error?
    private let metadataStore: MetadataStore?

    init(metadataStore: MetadataStore? = nil, error: Error? = nil) {
        self.metadataStore = metadataStore
        self.error = error
    }

    func resolveConflict(
        _ record: ConflictRecord,
        account: PersistedAccountRecord,
        decision: ConflictResolutionDecision,
        resolvedName: String?
    ) async throws {
        calls.append((record, account, decision, resolvedName))
        if let error { throw error }
        try await metadataStore?.resolveConflict(
            id: record.id,
            accountID: account.id,
            decision: decision,
            resolvedName: resolvedName,
            resolvedAt: Date(timeIntervalSince1970: 99)
        )
    }
}

private actor ModelAvailabilityResolver: AppAvailabilityResolving {
    var calls: [(intent: AvailabilityIntent, itemID: String, account: PersistedAccountRecord)] = []
    var affected: [String]
    var error: Error?
    private let metadataStore: MetadataStore?

    init(affected: [String] = [], metadataStore: MetadataStore? = nil, error: Error? = nil) {
        self.affected = affected
        self.metadataStore = metadataStore
        self.error = error
    }

    func setAvailabilityIntent(
        _ intent: AvailabilityIntent,
        itemID: String,
        account: PersistedAccountRecord
    ) async throws -> [String] {
        calls.append((intent, itemID, account))
        if let error { throw error }
        let affected = affected.isEmpty ? [itemID] : affected
        for affectedID in affected {
            try await metadataStore?.setAvailabilityIntent(intent, accountID: account.id, itemID: affectedID)
        }
        return affected
    }
}

private actor ModelPublicLinkCreator: AppPublicLinkCreating {
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

@Test
func appModelAddsAccountRegistersDomainAndPersistsRecord() async throws {
    let diagnostics = AppDiagnosticBuffer()
    let credentials = MemoryCredentialStore()
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        diagnostics: diagnostics
    )
    let domainManager = MemoryFileProviderDomainManager()
    let domainService = FileProviderDomainService(manager: domainManager, diagnostics: diagnostics)
    let repository = MemoryAccountRepository()
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: domainService,
        repository: repository,
        diagnostics: diagnostics
    )

    let record = try await model.addAccount(
        serverURL: URL(string: "https://cloud.example/")!,
        username: "alice",
        appPassword: "secret"
    )

    #expect(record.serverVersion == "10.15.0")
    #expect(record.serverPollInterval == 45)
    #expect(record.domain?.displayName == "alice")
    #expect(try await repository.records() == [record])
    #expect(try await domainManager.domains() == [record.domain])

    let snapshot = try await model.loadSnapshot()
    #expect(snapshot.accounts == [record])
    #expect(snapshot.diagnostics.contains { $0.category == "App" && $0.message == "Account alice is ready" })
}

@Test
func appModelAddsOAuthAccountRegistersDomainAndPersistsRecord() async throws {
    let diagnostics = AppDiagnosticBuffer()
    let credentials = MemoryCredentialStore()
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        diagnostics: diagnostics
    )
    let repository = MemoryAccountRepository()
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager(), diagnostics: diagnostics),
        repository: repository,
        diagnostics: diagnostics
    )

    let record = try await model.addOAuthAccount(
        serverURL: URL(string: "https://cloud.example/")!,
        authenticator: ModelOAuthAuthenticator()
    )

    #expect(record.account.username == "oauth-user")
    #expect(record.serverVersion == "10.15.0")
    #expect(record.domain?.displayName == "oauth-user")
    #expect(try await repository.records() == [record])
    let stored = try await credentials.credential(accountID: record.id)
    #expect(stored?.kind == .oauthRefreshToken)
    #expect(stored?.secret == "refresh")
}

@Test
func appModelReconnectsExistingAccountWithoutChangingIdentity() async throws {
    let diagnostics = AppDiagnosticBuffer()
    let credentials = MemoryCredentialStore()
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        diagnostics: diagnostics
    )
    let domainManager = MemoryFileProviderDomainManager()
    let repository = MemoryAccountRepository()
    let account = Account(
        id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        serverURL: URL(string: "https://cloud.example")!,
        username: "alice",
        displayName: "Alice Cloud"
    )
    let importedRecord = PersistedAccountRecord(
        account: account,
        lastSyncStatus: SyncStatusSnapshot(state: .error, message: "Imported from legacy client")
    )
    try await repository.save(importedRecord)
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: domainManager, diagnostics: diagnostics),
        repository: repository,
        diagnostics: diagnostics
    )

    let reconnected = try await model.reconnectAccount(accountID: account.id, appPassword: "secret")

    #expect(reconnected.id == account.id)
    #expect(reconnected.account.displayName == "Alice Cloud")
    #expect(reconnected.account.serverURL.absoluteString == "https://cloud.example/")
    #expect(reconnected.lastSyncStatus.state == .idle)
    #expect(reconnected.lastSyncStatus.message == "Connected")
    #expect(try await repository.records() == [reconnected])
    #expect(try await credentials.credential(accountID: account.id)?.secret == "secret")
    #expect(try await domainManager.domains() == [reconnected.domain])
}

@Test
func appModelReconnectKeepsSyncedSpaceDomain() async throws {
    let credentials = MemoryCredentialStore()
    let accountService = AccountSessionService(credentialStore: credentials, capabilitiesFetcher: ModelCapabilitiesFetcher())
    let domainManager = MemoryFileProviderDomainManager()
    let repository = MemoryAccountRepository()
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )
    let added = try await model.addAccount(serverURL: URL(string: "https://cloud.example/")!, username: "alice", appPassword: "old")
    let space = OwnCloudSpace(
        id: "space-1",
        name: "Marketing",
        driveType: "project",
        driveAlias: "project/marketing",
        webDAVURL: URL(string: "https://cloud.example/dav/spaces/space-1")!,
        quota: nil
    )
    let synced = try await model.syncSpace(AppSpace(accountID: added.id, accountName: "alice", space: space))

    let reconnected = try await model.reconnectAccount(accountID: added.id, appPassword: "new")

    #expect(reconnected.domains == synced.domains)
    #expect(Set(try await domainManager.domains().map(\.id)) == Set(synced.domains.map(\.id)))
    #expect(try await repository.records().map(\.domains) == [synced.domains])
}

@Test
func appModelLoadsAvailableSpacesForConnectedAccounts() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        spacesFetcher: ModelSpacesFetcher(spaces: [
            OwnCloudSpace(
                id: "space-1",
                name: "Marketing",
                driveType: "project",
                driveAlias: "project/marketing",
                webDAVURL: URL(string: "https://cloud.example/dav/spaces/space-1")!,
                quota: SpaceQuota(used: 1024, remaining: 2048, total: 3072, state: "normal")
            ),
        ])
    )
    let original = CloudDomain(id: "selected-space", accountID: account.id, displayName: "alice - Marketing", webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!, storageID: UUID())
    let manager = MemoryFileProviderDomainManager()
    try await manager.register(original)
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account, domain: original)])
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: manager, repository: repository),
        repository: repository
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.spaces == [
        AppSpace(
            accountID: account.id,
            accountName: "alice",
            space: OwnCloudSpace(
                id: "space-1",
                name: "Marketing",
                driveType: "project",
                driveAlias: "project/marketing",
                webDAVURL: URL(string: "https://cloud.example/dav/spaces/space-1")!,
                quota: SpaceQuota(used: 1024, remaining: 2048, total: 3072, state: "normal")
            ),
            isSelected: true
        ),
    ])
    var renamed = original
    renamed.displayName = "Marketing"
    #expect(try await manager.domains() == [renamed])
    #expect(try await repository.records().first?.domains == [renamed])
    #expect(snapshot.accounts.first?.domains == [renamed])
}

@Test
func appModelRecordsUserFacingSpaceLoadDiagnostics() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let diagnostics = AppDiagnosticBuffer()
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        spacesFetcher: ModelSpacesFetcher(
            spaces: [],
            error: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable))
        )
    )
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        diagnostics: diagnostics
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.spaces.isEmpty)
    let event = try #require(await diagnostics.events().first { $0.category == "Spaces" })
    #expect(event.message == "Spaces unavailable for alice: The server is temporarily unavailable. Try again later.")
    #expect(event.message.contains("httpFailure") == false)
}

@Test
func appModelLoadsAndDismissesServerNotifications() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let notifications = ModelNotificationsFetcher(notifications: [
        UserNotification(
            id: 42,
            app: "files_sharing",
            user: "alice",
            subject: "Share request",
            date: Date(timeIntervalSince1970: 1_779_900_000)
        ),
    ])
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        notificationsFetcher: notifications
    )
    let diagnostics = AppDiagnosticBuffer()
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        diagnostics: diagnostics
    )

    let loaded = try await model.loadSnapshot().notifications
    try await model.dismissNotification(loaded[0])

    #expect(loaded.map(\.notification.id) == [42])
    #expect(try await model.loadSnapshot().notifications.isEmpty)
    #expect(await notifications.deletedID == 42)
    #expect(await diagnostics.events().contains { $0.category == "Notifications" && $0.message == "Dismissed notification 42" })
}

@Test
func appModelRecordsUserFacingNotificationLoadDiagnostics() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let diagnostics = AppDiagnosticBuffer()
    let notifications = ModelNotificationsFetcher(
        notifications: [],
        error: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 507, kind: .quotaExceeded))
    )
    let accountService = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: ModelCapabilitiesFetcher(),
        notificationsFetcher: notifications
    )
    let model = WesomeCloudAppModel(
        accountSessions: accountService,
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        diagnostics: diagnostics
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.notifications.isEmpty)
    let event = try #require(await diagnostics.events().first { $0.category == "Notifications" })
    #expect(event.message == "Notifications unavailable for alice: The server quota is full.")
    #expect(event.message.contains("quotaExceeded") == false)
}

@Test
func appModelKeepsExistingFinderLocationsWhenAddingSpace() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let originalDomain = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "Alice Cloud")
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appending(path: "Accounts.sqlite")
    let repository = try SQLiteAccountRepository(databaseURL: databaseURL)
    try await repository.save(PersistedAccountRecord(account: account, domain: originalDomain))
    let domainManager = MemoryFileProviderDomainManager()
    try await domainManager.register(originalDomain)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )
    let space = AppSpace(
        accountID: account.id,
        accountName: account.displayName,
        space: OwnCloudSpace(
            id: "storage-users-1$space",
            name: "Marketing",
            webDAVURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$space")!
        )
    )

    let updated = try await model.syncSpace(space)

    let registered = try await domainManager.domains()
    #expect(registered.count == 2)
    #expect(registered.contains(originalDomain))
    #expect(registered.contains { $0.webDAVRootURL == space.space.webDAVURL })
    #expect(try await repository.records() == [updated])
    _ = try await model.syncSpace(space)
    #expect(try await domainManager.domains() == registered)

    let reopened = try SQLiteAccountRepository(databaseURL: databaseURL)
    let saved = try #require(try await reopened.records().first)
    #expect(saved.domains.count == 2)
    #expect(saved.domains.first?.metadataID == account.id)
    #expect(saved.domains.last?.metadataID != account.id)
    #expect(Set(try await reopened.domains(accountID: account.id).map(\.metadataID)) == Set(saved.domains.map(\.metadataID)))
    let restartedManager = MemoryFileProviderDomainManager()
    let metadata = InMemoryMetadataStore()
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "saved", kind: .appPassword))
    let restarted = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: credentials, capabilitiesFetcher: ModelCapabilitiesFetcher()),
        domains: FileProviderDomainService(manager: restartedManager, repository: reopened),
        repository: reopened,
        metadataStore: metadata
    )
    try await restarted.restoreFinderLocations()
    #expect(try await restartedManager.domains() == registered)

    let selected = try #require(saved.domains.last)
    let pending = PendingOperation(kind: .delete, itemID: "queued", sourcePath: "/Queued.txt")
    try await metadata.enqueue(pending, accountID: selected.metadataID)
    await #expect(throws: WesomeCloudError.self) { try await restarted.removeSpace(space) }
    #expect(try await restartedManager.domains() == registered)
    try await metadata.removePendingOperation(id: pending.id, accountID: selected.metadataID)

    try await restarted.removeSpace(space)
    #expect(try await restartedManager.domains() == [originalDomain])
    #expect(try await reopened.domains(accountID: account.id) == [originalDomain])
    #expect(try await credentials.credential(accountID: account.id)?.secret == "saved")
    let personal = AppSpace(accountID: account.id, accountName: "alice", space: OwnCloudSpace(
        id: "personal", name: "Alice", driveType: "personal", webDAVURL: URL(string: "https://cloud.example/dav/spaces/personal")!
    ))
    try await restarted.removeSpace(personal)
    let emptyRepository = try SQLiteAccountRepository(databaseURL: databaseURL)
    let empty = try #require(try await emptyRepository.records().first)
    #expect(empty.domains.isEmpty)
    #expect(empty.syncLocations.isEmpty)
    #expect(try await emptyRepository.domains(accountID: account.id).isEmpty)
    try await restarted.restoreFinderLocations()
    #expect(try await restartedManager.domains().isEmpty)
    let reconnected = try await restarted.reconnectAccount(accountID: account.id, appPassword: "new")
    #expect(reconnected.syncLocations.isEmpty)
    let readded = try await restarted.syncSpace(space)
    #expect(readded.domains.count == 1)
    #expect(readded.domain?.displayName == "Marketing")
    #expect(try await restartedManager.domains() == readded.domains)

}

@Test
func appModelUpdatesStatusAndRemovesAccount() async throws {
    let diagnostics = AppDiagnosticBuffer()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let otherAccount = Account(serverURL: URL(string: "https://cloud.example/")!, username: "bob")
    let domain = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "alice")
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    try await credentials.save(Credential(accountID: otherAccount.id, username: "bob", secret: "keep-me", kind: .appPassword))
    let metadataStore = InMemoryMetadataStore()
    let localDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
    let materializedFile = localDirectory.appending(path: "report")
    let materializedPartial = materializedFile.appendingPathExtension("part")
    let transferPartial = localDirectory.appending(path: "upload.part")
    let otherAccountFile = localDirectory.appending(path: "bob")
    try Data("materialized".utf8).write(to: materializedFile)
    try Data("partial".utf8).write(to: materializedPartial)
    try Data("upload".utf8).write(to: transferPartial)
    try Data("keep".utf8).write(to: otherAccountFile)
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file)
    ])
    try await metadataStore.setMaterializedURL(materializedFile, accountID: account.id, itemID: "file-1")
    try await metadataStore.upsert(accountID: otherAccount.id, items: [
        RemoteItem(id: "file-2", parentID: nil, name: "Bob.txt", path: "/Bob.txt", kind: .file)
    ])
    try await metadataStore.setMaterializedURL(otherAccountFile, accountID: otherAccount.id, itemID: "file-2")
    try await metadataStore.enqueue(PendingOperation(kind: .delete, itemID: "file-1", sourcePath: "/Report.txt"), accountID: account.id)
    try await metadataStore.recordSyncError(SyncErrorRecord(scope: .account, message: "Offline", isRecoverable: true), accountID: account.id)
    try await metadataStore.upsertTransfer(TransferRecord(itemID: "file-1", direction: .download, phase: .running, localURL: transferPartial, remotePath: "/Report.txt"), accountID: account.id)
    try await metadataStore.recordConflict(
        ConflictRecord(conflict: SyncConflict(kind: .typeChanged, itemID: "file-1", message: "Type changed")),
        accountID: account.id
    )
    try await metadataStore.setSyncCursor("token-1", accountID: account.id, remotePath: "/")
    let repository = MemoryAccountRepository(records: [
        PersistedAccountRecord(account: account, domain: domain),
        PersistedAccountRecord(account: otherAccount),
    ])
    let domainManager = MemoryFileProviderDomainManager()
    try await domainManager.register(domain)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: credentials),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository,
        metadataStore: metadataStore,
        diagnostics: diagnostics
    )

    try await model.updateSyncStatus(SyncStatusSnapshot(state: .error, message: "Network unavailable"), accountID: account.id)
    #expect(try await repository.records().first?.lastSyncStatus.state == .error)

    try await model.removeAccount(accountID: account.id)

    #expect(try await repository.records().map(\.id) == [otherAccount.id])
    #expect(try await domainManager.domains().isEmpty)
    #expect(try await credentials.credential(accountID: account.id) == nil)
    #expect(try await credentials.credential(accountID: otherAccount.id)?.secret == "keep-me")
    #expect(try await metadataStore.items(accountID: account.id).isEmpty)
    #expect(try await metadataStore.pendingOperations(accountID: account.id).isEmpty)
    #expect(try await metadataStore.syncErrors(accountID: account.id).isEmpty)
    #expect(try await metadataStore.transfers(accountID: account.id).isEmpty)
    #expect(try await metadataStore.conflicts(accountID: account.id, state: nil).isEmpty)
    #expect(try await metadataStore.syncCursor(accountID: account.id, remotePath: "/") == nil)
    #expect(!FileManager.default.fileExists(atPath: materializedFile.path))
    #expect(!FileManager.default.fileExists(atPath: materializedPartial.path))
    #expect(!FileManager.default.fileExists(atPath: transferPartial.path))
    #expect(FileManager.default.fileExists(atPath: otherAccountFile.path))
    #expect(try await metadataStore.items(accountID: otherAccount.id).first?.materializedURL == otherAccountFile)
}

@Test
func appModelRemovesCurrentSpaceDomainWhenRemovingAccount() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let domain = CloudDomain(
        id: "\(account.id.uuidString)-space-1",
        accountID: account.id,
        displayName: "Alice - Space",
        webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
    )
    let repository = MemoryAccountRepository(records: [
        PersistedAccountRecord(account: account, domain: domain)
    ])
    let domainManager = MemoryFileProviderDomainManager()
    try await domainManager.register(domain)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )

    try await model.removeAccount(accountID: account.id)

    #expect(try await repository.records().isEmpty)
    #expect(try await domainManager.domains().isEmpty)
}

// Mirrors NSFileProviderManager.remove, which fails for domains that are not registered.
private actor StrictDomainManager: FileProviderDomainManaging {
    private var registered: [String: CloudDomain] = [:]

    func register(_ domain: CloudDomain) async throws {
        registered[domain.id] = domain
    }

    func remove(domainID: String) async throws {
        guard registered.removeValue(forKey: domainID) != nil else {
            throw WesomeCloudError.missingItem(domainID)
        }
    }

    func domains() async throws -> [CloudDomain] {
        Array(registered.values)
    }
}

@Test
func appModelRemovesSpaceAccountWhenBareAccountDomainIsAlreadyGone() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let domain = CloudDomain(id: "\(account.id.uuidString)-space-1", accountID: account.id, displayName: "Alice - Space")
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account, domain: domain)])
    let domainManager = StrictDomainManager()
    try await domainManager.register(domain)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: credentials),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )

    try await model.removeAccount(accountID: account.id)

    #expect(try await domainManager.domains().isEmpty)
    #expect(try await credentials.credential(accountID: account.id) == nil)
    #expect(try await repository.records().isEmpty)
}

@Test
func appModelRemovesOrphanedSpaceDomainsWhenRemovingAccount() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let currentDomain = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "alice")
    let staleSpaceDomain = CloudDomain(
        id: "\(account.id.uuidString)-old-space",
        accountID: account.id,
        displayName: "alice - Old Space",
        webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/old-space")!
    )
    let otherAccount = Account(serverURL: URL(string: "https://cloud.example/")!, username: "bob")
    let otherDomain = CloudDomain(id: otherAccount.id.uuidString, accountID: otherAccount.id, displayName: "bob")
    let repository = MemoryAccountRepository(records: [
        PersistedAccountRecord(account: account, domain: currentDomain),
        PersistedAccountRecord(account: otherAccount, domain: otherDomain),
    ])
    let domainManager = MemoryFileProviderDomainManager()
    try await domainManager.register(currentDomain)
    try await domainManager.register(staleSpaceDomain)
    try await domainManager.register(otherDomain)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: domainManager),
        repository: repository
    )

    try await model.removeAccount(accountID: account.id)

    #expect(try await repository.records().map(\.id) == [otherAccount.id])
    #expect(try await domainManager.domains() == [otherDomain])
}

@Test
func appModelLoadsFilesAndUpdatesAvailabilityIntent() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder-1", parentID: nil, name: "Projects", path: "/Projects", kind: .folder),
        RemoteItem(id: "file-1", parentID: "folder-1", name: "Plan.md", path: "/Projects/Plan.md", kind: .file),
    ])
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )

    var snapshot = try await model.loadSnapshot()
    #expect(snapshot.files.map(\.item.remote.path) == ["/Projects", "/Projects/Plan.md"])

    try await model.setAvailabilityIntent(.alwaysLocal, accountID: account.id, itemID: "file-1")
    snapshot = try await model.loadSnapshot()

    #expect(snapshot.files.first { $0.item.remote.id == "file-1" }?.item.availabilityIntent == .alwaysLocal)
    #expect(snapshot.diagnostics.contains { $0.category == "Files" && $0.message == "Set file-1 availability to alwaysLocal for 1 item" })
}

@Test
func appModelDelegatesAvailabilityIntentToExecutableResolver() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder-1", parentID: nil, name: "Projects", path: "/Projects", kind: .folder),
        RemoteItem(id: "file-1", parentID: "folder-1", name: "Plan.md", path: "/Projects/Plan.md", kind: .file),
    ])
    let resolver = ModelAvailabilityResolver(
        affected: ["folder-1", "file-1"],
        metadataStore: metadataStore
    )
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        availabilityResolver: resolver
    )

    try await model.setAvailabilityIntent(.onlineOnly, accountID: account.id, itemID: "folder-1")

    let calls = await resolver.calls
    #expect(calls.count == 1)
    #expect(calls.first?.intent == .onlineOnly)
    #expect(calls.first?.itemID == "folder-1")
    #expect(calls.first?.account.id == account.id)
    #expect(try await metadataStore.item(accountID: account.id, id: "folder-1")?.availabilityIntent == .onlineOnly)
    #expect(try await metadataStore.item(accountID: account.id, id: "file-1")?.availabilityIntent == .onlineOnly)
    let snapshot = try await model.loadSnapshot()
    #expect(snapshot.diagnostics.contains { $0.category == "Files" && $0.message == "Set folder-1 availability to onlineOnly for 2 items" })
}

@Test
func appModelDoesNotFlipAvailabilityMetadataWhenExecutableResolverFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file),
    ])
    let resolver = ModelAvailabilityResolver(error: WesomeCloudError.missingItem("file-1"))
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        availabilityResolver: resolver
    )

    await #expect(throws: WesomeCloudError.missingItem("file-1")) {
        try await model.setAvailabilityIntent(.onlineOnly, accountID: account.id, itemID: "file-1")
    }

    #expect(try await metadataStore.item(accountID: account.id, id: "file-1")?.availabilityIntent == .unspecified)
}

@Test
func appModelCreatesPublicLinkForStoredFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file),
    ])
    let linkCreator = ModelPublicLinkCreator()
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )

    let share = try await model.createPublicLink(accountID: account.id, itemID: "file-1")
    let snapshot = try await model.loadSnapshot()

    #expect(share.url.absoluteString == "https://cloud.example/s/share-1")
    #expect(snapshot.lastCreatedShare == share)
    #expect(snapshot.publicLinks.map(\.share) == [share])
    #expect(await linkCreator.files.first?.serverURL == account.serverURL)
    #expect(await linkCreator.files.first?.item.remote.path == "/Plan.md")
    #expect(snapshot.diagnostics.contains { $0.category == "Sharing" && $0.message == "Created public link for /Plan.md" })
}

@Test
func appModelRefreshesAndDeletesPublicLinksForStoredFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account)])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file),
    ])
    let linkCreator = ModelPublicLinkCreator()
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )

    let links = try await model.refreshPublicLinks(accountID: account.id, itemID: "file-1")
    try await model.deletePublicLink(links[0])

    #expect(links.map(\.share.id) == ["share-1"])
    #expect(try await model.loadSnapshot().publicLinks.isEmpty)
    #expect(await linkCreator.deletedShares.map(\.id) == ["share-1"])
}

@Test
func appModelLoadsPrivateLinkForStoredFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let domain = CloudDomain(
        id: "space-1",
        accountID: account.id,
        displayName: "Alice Space",
        webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
    )
    let repository = MemoryAccountRepository(records: [PersistedAccountRecord(account: account, domain: domain)])
    let metadataStore = InMemoryMetadataStore()
    try await metadataStore.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Plan.md", path: "/Plan.md", kind: .file),
    ])
    let linkCreator = ModelPublicLinkCreator()
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        publicLinkCreator: linkCreator
    )

    let url = try await model.privateLink(accountID: account.id, itemID: "file-1")

    #expect(url.absoluteString == "https://cloud.example/index.php/f/1")
    #expect(await linkCreator.files.first?.accountUsername == "alice")
    #expect(await linkCreator.files.first?.webDAVRootURL == domain.webDAVRootURL)
    #expect(try await model.loadSnapshot().diagnostics.contains { $0.message == "Loaded private link for /Plan.md" })
}

@Test
func appModelLoadsTransferActivityFromMetadataStore() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let metadataStore = InMemoryMetadataStore()
    let older = TransferRecord(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        itemID: "file-1",
        direction: .download,
        phase: .completed,
        bytesTransferred: 1024,
        totalBytes: 1024,
        remotePath: "/Archive.zip",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let newer = TransferRecord(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        itemID: "file-2",
        direction: .upload,
        phase: .running,
        bytesTransferred: 512,
        totalBytes: 1024,
        remotePath: "/Draft.md",
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    try await metadataStore.upsertTransfer(older, accountID: account.id)
    try await metadataStore.upsertTransfer(newer, accountID: account.id)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.transfers.map(\.transfer.id) == [newer.id, older.id])
    #expect(snapshot.transfers.map(\.accountName) == ["Alice", "Alice"])
}

@Test
func appModelLoadsAccountStorageFromRootQuotaMetadata() async throws {
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
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        metadataStore: metadataStore
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.storage == [
        AppAccountStorage(accountID: account.id, accountName: "Alice", usedBytes: 1_048_576, availableBytes: 3_145_728)
    ])
}

@Test
func appModelLoadsAndClearsPersistedSyncIssues() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let older = SyncErrorRecord(
        scope: .item,
        itemID: "file-1",
        message: "Name collision",
        isRecoverable: true,
        occurredAt: Date(timeIntervalSince1970: 1)
    )
    let newer = SyncErrorRecord(
        scope: .account,
        message: "Authentication expired",
        isRecoverable: false,
        occurredAt: Date(timeIntervalSince1970: 2)
    )
    try await metadataStore.recordSyncError(older, accountID: account.id)
    try await metadataStore.recordSyncError(newer, accountID: account.id)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.issues.map(\.id) == [newer.id, older.id])
    #expect(snapshot.issues.first?.accountName == "Alice")
    #expect(snapshot.issues.first?.message == "Authentication expired")

    try await model.clearIssue(newer.id, accountID: account.id)

    #expect(try await model.loadSnapshot().issues.map(\.id) == [older.id])
}

@Test
func appModelLoadsAndResolvesPendingConflicts() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(
            kind: .remoteChangedDuringLocalEdit,
            itemID: "file-1",
            localPath: "/Report.txt",
            remotePath: "/Report.txt",
            message: "The remote file changed before upload."
        ),
        createdAt: Date(timeIntervalSince1970: 4)
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )

    let snapshot = try await model.loadSnapshot()

    #expect(snapshot.conflicts.count == 1)
    #expect(snapshot.conflicts.first?.accountName == "Alice")
    #expect(snapshot.conflicts.first?.conflict.kind == .remoteChangedDuringLocalEdit)

    try await model.resolveConflict(conflict.id, accountID: account.id, decision: .keepLocal)

    #expect(try await model.loadSnapshot().conflicts.isEmpty)
    let resolved = try await metadataStore.conflicts(accountID: account.id, state: .resolved).first
    #expect(resolved?.selectedResolution == .keepLocal)
}

@Test
func appModelDelegatesConflictResolutionToExecutableResolver() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(
            kind: .remoteChangedDuringLocalEdit,
            itemID: "file-1",
            localPath: "/Report.txt",
            remotePath: "/Report.txt",
            message: "The remote file changed before upload."
        )
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let resolver = ModelConflictResolver(metadataStore: metadataStore)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        conflictResolver: resolver
    )

    try await model.resolveConflict(conflict.id, accountID: account.id, decision: .renameLocal, resolvedName: "Report local.txt")

    let calls = await resolver.calls
    #expect(calls.count == 1)
    #expect(calls.first?.record.id == conflict.id)
    #expect(calls.first?.account.id == account.id)
    #expect(calls.first?.decision == .renameLocal)
    #expect(calls.first?.resolvedName == "Report local.txt")
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .pending).isEmpty)
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .resolved).first?.selectedResolution == .renameLocal)
}

@Test
func appModelKeepsConflictPendingWhenExecutableResolverFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(
            kind: .remoteChangedDuringLocalEdit,
            itemID: "file-1",
            localPath: "/Report.txt",
            remotePath: "/Report.txt",
            message: "The remote file changed before upload."
        )
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let resolver = ModelConflictResolver(error: WesomeCloudError.missingItem("materialized content for file-1"))
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore,
        conflictResolver: resolver
    )

    await #expect(throws: WesomeCloudError.missingItem("materialized content for file-1")) {
        try await model.resolveConflict(conflict.id, accountID: account.id, decision: .keepLocal)
    }

    #expect(try await metadataStore.conflicts(accountID: account.id, state: .pending).map(\.id) == [conflict.id])
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .resolved).isEmpty)
}

@Test
func appModelRejectsRenameConflictResolutionWithoutUsableName() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(
            kind: .nameCollision,
            itemID: "file-1",
            localPath: "/Report.txt",
            remotePath: "/Report.txt",
            message: "Name collision"
        )
    )
    try await metadataStore.recordConflict(conflict, accountID: account.id)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository,
        metadataStore: metadataStore
    )

    await #expect(throws: WesomeCloudError.invalidFilename("", .empty)) {
        try await model.resolveConflict(conflict.id, accountID: account.id, decision: .renameLocal, resolvedName: "   ")
    }

    #expect(try await metadataStore.conflicts(accountID: account.id, state: .pending).map(\.id) == [conflict.id])
    #expect(try await metadataStore.conflicts(accountID: account.id, state: .resolved).isEmpty)
}
