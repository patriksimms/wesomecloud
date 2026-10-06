import Foundation
import SyncStore
import Testing
import WesomeCloudAppCore
import WesomeCloudShared
import WesomeFileProviderCore

private actor StubAccountSyncRunner: AccountSyncRunning {
    var pollCount = 0
    var queueCount = 0
    var remoteChanges = RemoteChangeSet()
    var queueSummary = QueueProcessingSummary()
    var error: Error?

    func set(remoteChanges: RemoteChangeSet) {
        self.remoteChanges = remoteChanges
    }

    func set(queueSummary: QueueProcessingSummary) {
        self.queueSummary = queueSummary
    }

    func set(error: Error) {
        self.error = error
    }

    func pollRemote(account _: PersistedAccountRecord) async throws -> RemoteChangeSet {
        pollCount += 1
        if let error { throw error }
        return remoteChanges
    }

    func processQueue(account _: PersistedAccountRecord) async throws -> QueueProcessingSummary {
        queueCount += 1
        if let error { throw error }
        return queueSummary
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

private actor DynamicSyncConfigurationStore {
    var configuration: BackgroundSyncConfiguration

    init(_ configuration: BackgroundSyncConfiguration) {
        self.configuration = configuration
    }

    func set(_ configuration: BackgroundSyncConfiguration) {
        self.configuration = configuration
    }

    func load() -> BackgroundSyncConfiguration {
        configuration
    }
}

@Test
func schedulerRunsDuePollingAndQueueWorkAndUpdatesStatus() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    await runner.set(remoteChanges: RemoteChangeSet(added: [
        ProviderItem(stored: .init(remote: RemoteItem(id: "new", parentID: nil, name: "New.txt", path: "/New.txt", kind: .file)))
    ]))
    await runner.set(queueSummary: QueueProcessingSummary(completed: [UUID()]))
    let scheduler = BackgroundSyncScheduler(runner: runner, appModel: appModel, clock: { now })

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.polledRemote)
    #expect(result.processedQueue)
    #expect(result.completedOperations == 1)
    #expect(result.message == "1 remote change, 1 queued operation")
    #expect(await runner.pollCount == 1)
    #expect(await runner.queueCount == 1)
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .idle)
    #expect(saved?.lastSyncStatus.message == "1 remote change, 1 queued operation")
}

@Test
func schedulerReloadsDynamicConfigurationBeforeEachRun() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let configurations = DynamicSyncConfigurationStore(BackgroundSyncConfiguration())
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configurationProvider: { await configurations.load() },
        clock: { now }
    )

    let first = try await scheduler.runDueWork(for: record)
    await configurations.set(BackgroundSyncConfiguration(isPaused: true))
    let paused = try await scheduler.runDueWork(for: record)

    #expect(first.polledRemote)
    #expect(first.processedQueue)
    #expect(paused.polledRemote == false)
    #expect(paused.processedQueue == false)
    #expect(paused.message == "Sync paused")
    #expect(await runner.pollCount == 1)
    #expect(await runner.queueCount == 1)
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .paused)
}

@Test
func schedulerSignalsFileProviderEnumeratorWhenRemoteChangesArrive() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let domain = CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice")
    let record = PersistedAccountRecord(account: account, domain: domain)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    await runner.set(remoteChanges: RemoteChangeSet(
        updated: [
            ProviderItem(stored: .init(remote: RemoteItem(id: "changed", parentID: "folder", name: "Changed.txt", path: "/Folder/Changed.txt", kind: .file))),
            ProviderItem(stored: .init(remote: RemoteItem(id: "sibling", parentID: "folder", name: "Sibling.txt", path: "/Folder/Sibling.txt", kind: .file))),
        ],
        deletedItems: [
            DeletedProviderItem(id: "removed", parentID: "removed-parent", path: "/Removed/Old.txt"),
        ]
    ))
    let changeSignaler = MemoryFileProviderChangeSignaler()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        changeSignaler: changeSignaler,
        clock: { now }
    )

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.message == "3 remote changes, 0 queued operations")
    #expect(await changeSignaler.signaledEnumerators.map(\.domainID) == ["domain-1", "domain-1", "domain-1", "domain-1"])
    #expect(await changeSignaler.signaledEnumerators.map(\.containerItemIdentifier) == [
        "NSFileProviderRootContainerItemIdentifier",
        "NSFileProviderWorkingSetContainerItemIdentifier",
        "folder",
        "removed-parent",
    ])
}

@Test
func schedulerRecordsRecoverableIssueWhenFileProviderSignalingFails() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let domain = CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice")
    let record = PersistedAccountRecord(account: account, domain: domain)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    await runner.set(remoteChanges: RemoteChangeSet(deleted: ["deleted-file"]))
    let changeSignaler = MemoryFileProviderChangeSignaler()
    await changeSignaler.set(error: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable)))
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        metadataStore: metadataStore,
        changeSignaler: changeSignaler,
        clock: { now }
    )

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.message == "1 remote change, 0 queued operations")
    let issue = try #require(await metadataStore.syncErrors(accountID: record.id).first)
    #expect(issue.scope == .account)
    #expect(issue.message.contains("File Provider refresh signaling failed") == true)
    #expect(issue.message.contains("The server is temporarily unavailable. Try again later.") == true)
    #expect(issue.message.contains("httpFailure") == false)
    #expect(issue.isRecoverable)
    #expect(issue.occurredAt == now)
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .idle)
}

@Test
func schedulerSkipsPollingAndQueueWorkWhenSyncIsPaused() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configuration: BackgroundSyncConfiguration(isPaused: true),
        clock: { now }
    )

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.polledRemote == false)
    #expect(result.processedQueue == false)
    #expect(result.message == "Sync paused")
    #expect(await runner.pollCount == 0)
    #expect(await runner.queueCount == 0)
    #expect(await scheduler.state(accountID: record.id).lastResult == result)
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .paused)
    #expect(saved?.lastSyncStatus.message == "Sync paused")
    #expect(saved?.lastSyncStatus.updatedAt == now)
}

@Test
func schedulerRecordsPermanentQueueFailuresInMetadataStore() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let failedOperationID = UUID()
    let failedOperation = PendingOperation(
        id: failedOperationID,
        kind: .move,
        itemID: "file-1",
        sourcePath: "/Old.txt",
        destinationPath: "/New.txt",
        attemptCount: 3,
        lastErrorDescription: "HTTP 507"
    )
    let runner = StubAccountSyncRunner()
    await runner.set(queueSummary: QueueProcessingSummary(
        failedPermanently: [failedOperationID],
        permanentlyFailedOperations: [failedOperation]
    ))
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        metadataStore: metadataStore,
        clock: { now }
    )

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.failedOperations == 1)
    let errors = try await metadataStore.syncErrors(accountID: record.id)
    #expect(errors.count == 1)
    #expect(errors.first?.scope == .operation)
    #expect(errors.first?.itemID == "file-1")
    #expect(errors.first?.operationID == failedOperationID)
    #expect(errors.first?.message.contains("move") == true)
    #expect(errors.first?.message.contains("/Old.txt") == true)
    #expect(errors.first?.message.contains("/New.txt") == true)
    #expect(errors.first?.message.contains("server quota is full") == true)
    #expect(errors.first?.isRecoverable == false)
    #expect(errors.first?.occurredAt == now)
}

@Test
func schedulerUsesReadableNamesForCreateFileQueueFailures() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let failedOperation = PendingOperation(
        kind: .createFile,
        itemID: "folder",
        sourcePath: "/tmp/New.txt",
        destinationPath: "/Folder/New.txt",
        attemptCount: 3,
        lastErrorDescription: "HTTP 507"
    )
    let runner = StubAccountSyncRunner()
    await runner.set(queueSummary: QueueProcessingSummary(
        failedPermanently: [failedOperation.id],
        permanentlyFailedOperations: [failedOperation]
    ))
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        metadataStore: metadataStore,
        clock: { now }
    )

    _ = try await scheduler.runDueWork(for: record)

    let issue = try #require(await metadataStore.syncErrors(accountID: record.id).first)
    #expect(issue.message.contains("file creation") == true)
    #expect(issue.message.contains("createFile") == false)
    #expect(issue.message.contains("/tmp/New.txt") == true)
    #expect(issue.message.contains("/Folder/New.txt") == true)
    #expect(issue.message.contains("server quota is full") == true)
}

@Test
func schedulerSurfacesNonRetryableQueueFailuresAsAccountErrors() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let failedOperation = PendingOperation(
        kind: .upload,
        itemID: "file-1",
        sourcePath: "/File.txt",
        attemptCount: 1,
        lastErrorDescription: "quotaExceeded"
    )
    let runner = StubAccountSyncRunner()
    await runner.set(queueSummary: QueueProcessingSummary(
        failedPermanently: [failedOperation.id],
        permanentlyFailedOperations: [failedOperation]
    ))
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        metadataStore: metadataStore,
        clock: { now }
    )

    let result = try await scheduler.runDueWork(for: record)

    #expect(result.failedOperations == 1)
    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .error)
    #expect(saved?.lastSyncStatus.message == "0 remote changes, 1 queued operation")
    let issue = try #require(await metadataStore.syncErrors(accountID: record.id).first)
    #expect(issue.scope == .operation)
    #expect(issue.itemID == "file-1")
    #expect(issue.message.contains("server quota is full") == true)
    #expect(issue.message.contains("quotaExceeded") == false)
    #expect(issue.isRecoverable == false)
}

@Test
func schedulerSkipsWorkWhenIntervalsHaveNotElapsed() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configuration: BackgroundSyncConfiguration(pollInterval: 60, minimumQueueInterval: 30),
        clock: { clock.date }
    )

    _ = try await scheduler.runDueWork(for: record)
    clock.date = clock.date.addingTimeInterval(10)
    let skipped = try await scheduler.runDueWork(for: record)

    #expect(skipped.message == "No sync work due")
    #expect(await runner.pollCount == 1)
    #expect(await runner.queueCount == 1)
}

@Test
func schedulerUsesServerAdvertisedPollIntervalWhenPresent() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account, serverPollInterval: 30)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configuration: BackgroundSyncConfiguration(pollInterval: 120, minimumQueueInterval: 30),
        clock: { clock.date }
    )

    _ = try await scheduler.runDueWork(for: record)
    clock.date = clock.date.addingTimeInterval(40)
    let due = try await scheduler.runDueWork(for: record)

    #expect(due.polledRemote)
    #expect(await runner.pollCount == 2)
}

@Test
func schedulerRunNowForcesPollingAndQueueWorkBeforeIntervalsElapsed() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configuration: BackgroundSyncConfiguration(pollInterval: 60, minimumQueueInterval: 30),
        clock: { clock.date }
    )

    _ = try await scheduler.runDueWork(for: record)
    clock.date = clock.date.addingTimeInterval(10)
    let forced = try await scheduler.runNow(for: record)

    #expect(forced.polledRemote)
    #expect(forced.processedQueue)
    #expect(forced.message == "Up to date")
    #expect(await runner.pollCount == 2)
    #expect(await runner.queueCount == 2)
}

@Test
func schedulerRunNowHonorsPausedSync() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let scheduler = BackgroundSyncScheduler(
        runner: runner,
        appModel: appModel,
        configuration: BackgroundSyncConfiguration(isPaused: true),
        clock: { now }
    )

    let result = try await scheduler.runNow(for: record)

    #expect(result.polledRemote == false)
    #expect(result.processedQueue == false)
    #expect(result.message == "Sync paused")
    #expect(await runner.pollCount == 0)
    #expect(await runner.queueCount == 0)
}

@Test
func schedulerMarksAccountErrorWhenRunnerThrows() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let repository = MemoryAccountRepository(records: [record])
    let metadataStore = InMemoryMetadataStore()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: repository
    )
    let runner = StubAccountSyncRunner()
    let failure = WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable))
    await runner.set(error: failure)
    let scheduler = BackgroundSyncScheduler(runner: runner, appModel: appModel, metadataStore: metadataStore, clock: { now })

    await #expect(throws: failure) {
        try await scheduler.runDueWork(for: record)
    }

    let saved = try await repository.records().first
    #expect(saved?.lastSyncStatus.state == .error)
    #expect(saved?.lastSyncStatus.message == "Sync failed: The server is temporarily unavailable. Try again later.")
    let errors = try await metadataStore.syncErrors(accountID: record.id)
    #expect(errors.count == 1)
    #expect(errors.first?.scope == .account)
    #expect(errors.first?.message == "Sync failed: The server is temporarily unavailable. Try again later.")
    #expect(errors.first?.isRecoverable == true)
}

@Test
func schedulerPollsEachSelectedSpaceAndSignalsItsFinderLocation() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    var record = PersistedAccountRecord(account: account)
    record.domains = ["AM", "HR"].map {
        CloudDomain(id: $0, accountID: account.id, displayName: $0, storageID: UUID())
    }
    let repository = MemoryAccountRepository(records: [record])
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()), repository: repository
    )
    let runner = StubAccountSyncRunner()
    await runner.set(remoteChanges: RemoteChangeSet(added: [
        ProviderItem(stored: StoredItem(remote: RemoteItem(id: "file", parentID: nil, name: "File", path: "/File", kind: .file)))
    ]))
    let signaler = MemoryFileProviderChangeSignaler()
    let scheduler = BackgroundSyncScheduler(runner: runner, appModel: model, changeSignaler: signaler, clock: { Date(timeIntervalSince1970: 100) })
    for location in record.syncLocations {
        let result = try await scheduler.runDueWork(for: location)
        #expect(result.polledRemote)
        #expect(result.processedQueue)
        #expect(try await scheduler.runDueWork(for: location).polledRemote == false)
    }
    #expect(await runner.pollCount == 2)
    #expect(Set(await signaler.signaledEnumerators.map(\.domainID)) == ["AM", "HR"])
}
