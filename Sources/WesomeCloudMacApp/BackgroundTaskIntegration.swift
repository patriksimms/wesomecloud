import Foundation
import SyncStore
import WesomeCloudAppCore
import WesomeFileProviderCore
import WesomeFileProviderExtension
import WesomeCloudShared

public struct ProductionAccountSyncRunner: AccountSyncRunning {
    private let credentials: CredentialStore
    private let metadataStore: MetadataStore
    private let preferencesRepository: PreferencesRepository
    private let runtimeFactory: ProductionExtensionRuntimeFactory
    private let credentialResolver: AccountCredentialResolver

    public init(
        credentials: CredentialStore,
        metadataStore: MetadataStore,
        preferencesRepository: PreferencesRepository = MemoryPreferencesRepository(),
        runtimeFactory: ProductionExtensionRuntimeFactory,
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver()
    ) {
        self.credentials = credentials
        self.metadataStore = metadataStore
        self.preferencesRepository = preferencesRepository
        self.runtimeFactory = runtimeFactory
        self.credentialResolver = credentialResolver
    }

    public func pollRemote(account record: PersistedAccountRecord) async throws -> RemoteChangeSet {
        let coordinator = try await coordinator(for: record)
        let rootPath = record.domain?.rootPath ?? "/"
        var changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: rootPath)
        var polledFolderPaths = Set([rootPath])
        var foldersToPoll = changes.changedFoldersToPoll
        var folderPollCount = 0
        while let folder = foldersToPoll.first {
            foldersToPoll.removeFirst()
            guard folderPollCount < Self.maximumChangedFolderPolls else { break }
            guard let stored = try await metadataStore.item(accountID: record.metadataID, id: folder.id) else { continue }
            let folderPath = stored.remote.path
            guard polledFolderPaths.insert(folderPath).inserted else { continue }
            folderPollCount += 1
            let nested = try await coordinator.pollRemoteChanges(parentID: folder.id, remotePath: folderPath)
            changes.merge(nested)
            foldersToPoll.append(contentsOf: nested.changedFoldersToPoll)
        }
        return changes
    }

    private static let maximumChangedFolderPolls = 100

    public func processQueue(account record: PersistedAccountRecord) async throws -> QueueProcessingSummary {
        let coordinator = try await coordinator(for: record)
        let preferences = try await preferencesRepository.load()
        let queue = OfflineOperationQueue(
            accountID: record.metadataID,
            store: metadataStore,
            executor: WebDAVPendingOperationExecutor(backend: coordinator),
            retryPolicy: RetryPolicy(
                baseDelay: preferences.sync.retryBaseDelay,
                maximumDelay: preferences.sync.retryMaximumDelay,
                maximumAttempts: preferences.sync.retryMaximumAttempts
            )
        )
        return try await queue.processDueOperations()
    }

    private func coordinator(for record: PersistedAccountRecord) async throws -> FileProviderCoordinator {
        guard let credential = try await credentials.credential(accountID: record.account.id) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(record.account.id.uuidString)")
        }
        let resolved = try await credentialResolver.resolve(account: record.account, credential: credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentials.save(updatedCredential)
        }
        let preferences = try await preferencesRepository.load()
        return try runtimeFactory.makeCoordinator(
            configuration: ExtensionRuntimeAccountConfiguration(
                account: record.account,
                credential: credential,
                metadataID: record.metadataID,
                remoteRootPath: record.domain?.rootPath ?? "/",
                webDAVRootURL: record.domain?.webDAVRootURL,
                syncPreferences: preferences.sync,
                filePreferences: preferences.files
            ),
            credentials: resolved.credentials
        )
    }
}

public struct BackgroundManualSyncRunner: ManualSyncRunning {
    private let scheduler: BackgroundSyncScheduler

    public init(scheduler: BackgroundSyncScheduler) {
        self.scheduler = scheduler
    }

    public func syncNow(accounts: [PersistedAccountRecord]) async throws {
        var firstError: Error?
        for account in accounts.flatMap(\.syncLocations) {
            do {
                _ = try await scheduler.runNow(for: account)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}

public protocol BackgroundTaskScheduling: Sendable {
    func register(identifier: String, launchHandler: @escaping @Sendable () async -> Void) async -> Bool
    func submit(identifier: String, earliestBeginDate: Date) async throws
}

public actor BackgroundTaskSyncController {
    public let identifier: String
    private let scheduler: BackgroundSyncScheduler
    private let appModel: WesomeCloudAppModel
    private let taskScheduler: BackgroundTaskScheduling
    private let clock: @Sendable () -> Date

    public init(
        identifier: String = "cloud.wesome.wesomecloud.refresh",
        scheduler: BackgroundSyncScheduler,
        appModel: WesomeCloudAppModel,
        taskScheduler: BackgroundTaskScheduling = SystemBackgroundTaskScheduler(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identifier = identifier
        self.scheduler = scheduler
        self.appModel = appModel
        self.taskScheduler = taskScheduler
        self.clock = clock
    }

    @discardableResult
    public func registerAndSchedule() async throws -> Bool {
        let registered = await taskScheduler.register(identifier: identifier) { [weak self] in
            guard let self else { return }
            try? await self.runTaskAndReschedule()
        }
        try await scheduleNextRun()
        return registered
    }

    /// Always reschedules, even when loading accounts fails: tasks don't repeat on their own,
    /// so a skipped reschedule would stop background sync until the next launch.
    public func runTaskAndReschedule() async throws {
        var loadError: Error?
        do {
            let snapshot = try await appModel.loadSnapshot()
            for account in snapshot.accounts.flatMap(\.syncLocations) {
                _ = try? await scheduler.runDueWork(for: account)
            }
        } catch {
            loadError = error
        }
        try await scheduleNextRun()
        if let loadError { throw loadError }
    }

    public func scheduleNextRun() async throws {
        let preferences = try await appModel.loadPreferences()
        let interval = max(60, preferences.sync.backgroundSyncConfiguration.pollInterval)
        try await taskScheduler.submit(identifier: identifier, earliestBeginDate: clock().addingTimeInterval(interval))
    }
}

public final class InMemoryBackgroundTaskScheduler: BackgroundTaskScheduling, @unchecked Sendable {
    public private(set) var registeredIdentifiers: [String] = []
    public private(set) var submissions: [(identifier: String, earliestBeginDate: Date)] = []
    private var handlers: [String: @Sendable () async -> Void] = [:]

    public init() {}

    public func register(identifier: String, launchHandler: @escaping @Sendable () async -> Void) async -> Bool {
        registeredIdentifiers.append(identifier)
        handlers[identifier] = launchHandler
        return true
    }

    public func submit(identifier: String, earliestBeginDate: Date) async throws {
        submissions.append((identifier, earliestBeginDate))
    }

    public func launch(identifier: String) async {
        await handlers[identifier]?()
    }
}

public final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable () async -> Void] = [:]
    private var schedulers: [String: NSBackgroundActivityScheduler] = [:]

    public init() {}

    public func register(identifier: String, launchHandler: @escaping @Sendable () async -> Void) async -> Bool {
        lock.withLock {
            handlers[identifier] = launchHandler
        }
        return true
    }

    public func submit(identifier: String, earliestBeginDate: Date) async throws {
        let interval = max(60, earliestBeginDate.timeIntervalSinceNow)
        let handler = lock.withLock { handlers[identifier] }
        guard let handler else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.interval = interval
        scheduler.tolerance = min(interval / 2, 300)
        scheduler.repeats = false
        scheduler.schedule { completion in
            Task {
                await handler()
                completion(.finished)
            }
        }
        lock.withLock {
            schedulers[identifier] = scheduler
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension RemoteChangeSet {
    var changedFoldersToPoll: [ProviderItem] {
        (added + updated).filter { $0.kind == .folder }
    }

    mutating func merge(_ other: RemoteChangeSet) {
        added = Self.merge(added, with: other.added)
        updated = Self.merge(updated, with: other.updated)
        deletedItems = Self.merge(deletedItems, with: other.deletedItems)
    }

    private static func merge(_ first: [ProviderItem], with second: [ProviderItem]) -> [ProviderItem] {
        var result = first
        var indexesByID = Dictionary(uniqueKeysWithValues: first.enumerated().map { ($0.element.id, $0.offset) })
        for item in second {
            if let index = indexesByID[item.id] {
                result[index] = item
            } else {
                indexesByID[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func merge(_ first: [DeletedProviderItem], with second: [DeletedProviderItem]) -> [DeletedProviderItem] {
        var result = first
        var indexesByID = Dictionary(uniqueKeysWithValues: first.enumerated().map { ($0.element.id, $0.offset) })
        for item in second {
            if let index = indexesByID[item.id] {
                result[index] = item
            } else {
                indexesByID[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }
}
