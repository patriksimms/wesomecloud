import Foundation
import SyncStore
import WesomeFileProviderCore
import WesomeCloudShared

public struct BackgroundSyncConfiguration: Equatable, Sendable {
    public var pollInterval: TimeInterval
    public var minimumQueueInterval: TimeInterval
    public var isPaused: Bool

    public init(pollInterval: TimeInterval = 60, minimumQueueInterval: TimeInterval = 10, isPaused: Bool = false) {
        self.pollInterval = pollInterval
        self.minimumQueueInterval = minimumQueueInterval
        self.isPaused = isPaused
    }
}

public struct AccountSyncScheduleState: Codable, Equatable, Sendable {
    public var lastPollAt: Date?
    public var lastQueueRunAt: Date?
    public var lastResult: AccountSyncRunResult?

    public init(lastPollAt: Date? = nil, lastQueueRunAt: Date? = nil, lastResult: AccountSyncRunResult? = nil) {
        self.lastPollAt = lastPollAt
        self.lastQueueRunAt = lastQueueRunAt
        self.lastResult = lastResult
    }
}

public struct AccountSyncRunResult: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var polledRemote: Bool
    public var processedQueue: Bool
    public var completedOperations: Int
    public var rescheduledOperations: Int
    public var failedOperations: Int
    public var message: String

    public init(
        accountID: UUID,
        polledRemote: Bool,
        processedQueue: Bool,
        completedOperations: Int = 0,
        rescheduledOperations: Int = 0,
        failedOperations: Int = 0,
        message: String
    ) {
        self.accountID = accountID
        self.polledRemote = polledRemote
        self.processedQueue = processedQueue
        self.completedOperations = completedOperations
        self.rescheduledOperations = rescheduledOperations
        self.failedOperations = failedOperations
        self.message = message
    }
}

public protocol AccountSyncRunning: Sendable {
    func pollRemote(account: PersistedAccountRecord) async throws -> RemoteChangeSet
    func processQueue(account: PersistedAccountRecord) async throws -> QueueProcessingSummary
}

public actor BackgroundSyncScheduler {
    public typealias ConfigurationProvider = @Sendable () async throws -> BackgroundSyncConfiguration

    private let runner: AccountSyncRunning
    private let appModel: WesomeCloudAppModel
    private let metadataStore: MetadataStore?
    private let changeSignaler: FileProviderChangeSignaling?
    private let configuration: BackgroundSyncConfiguration
    private let configurationProvider: ConfigurationProvider?
    private let clock: @Sendable () -> Date
    private let diagnostics: (any DiagnosticSink)?
    private var states: [UUID: AccountSyncScheduleState] = [:]

    public init(
        runner: AccountSyncRunning,
        appModel: WesomeCloudAppModel,
        metadataStore: MetadataStore? = nil,
        configuration: BackgroundSyncConfiguration = BackgroundSyncConfiguration(),
        configurationProvider: ConfigurationProvider? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        diagnostics: (any DiagnosticSink)? = nil
    ) {
        self.init(
            runner: runner,
            appModel: appModel,
            metadataStore: metadataStore,
            changeSignaler: nil,
            configuration: configuration,
            configurationProvider: configurationProvider,
            clock: clock,
            diagnostics: diagnostics
        )
    }

    public init(
        runner: AccountSyncRunning,
        appModel: WesomeCloudAppModel,
        metadataStore: MetadataStore? = nil,
        changeSignaler: FileProviderChangeSignaling? = nil,
        configuration: BackgroundSyncConfiguration = BackgroundSyncConfiguration(),
        configurationProvider: ConfigurationProvider? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        diagnostics: (any DiagnosticSink)? = nil
    ) {
        self.runner = runner
        self.appModel = appModel
        self.metadataStore = metadataStore
        self.changeSignaler = changeSignaler
        self.configuration = configuration
        self.configurationProvider = configurationProvider
        self.clock = clock
        self.diagnostics = diagnostics
    }

    public func state(accountID: UUID) -> AccountSyncScheduleState {
        states[accountID] ?? AccountSyncScheduleState()
    }

    public func runDueWork(for account: PersistedAccountRecord) async throws -> AccountSyncRunResult {
        try await runWork(for: account, force: false)
    }

    public func runNow(for account: PersistedAccountRecord) async throws -> AccountSyncRunResult {
        try await runWork(for: account, force: true)
    }

    private func runWork(for account: PersistedAccountRecord, force: Bool) async throws -> AccountSyncRunResult {
        let now = clock()
        let runID = UUID().uuidString
        let started = Date()
        var context = ["run": runID, "scope": account.metadataID.uuidString, "account": account.id.uuidString,
                       "trigger": force ? "manual" : "scheduled"]
        let configuration = try await effectiveConfiguration(for: account)
        var state = states[account.metadataID] ?? AccountSyncScheduleState()
        if configuration.isPaused {
            await diagnostics?.record(DiagnosticEvent(category: "SyncRun", level: .info, message: "Sync skipped: paused", context: context))
            let result = AccountSyncRunResult(
                accountID: account.id,
                polledRemote: false,
                processedQueue: false,
                message: "Sync paused"
            )
            state.lastResult = result
            states[account.metadataID] = state
            try await appModel.updateSyncStatus(
                SyncStatusSnapshot(state: .paused, message: "Sync paused", updatedAt: now),
                accountID: account.id
            )
            return result
        }

        let shouldPoll = force || (state.lastPollAt.map { now.timeIntervalSince($0) >= configuration.pollInterval } ?? true)
        let shouldProcessQueue = force || (state.lastQueueRunAt.map { now.timeIntervalSince($0) >= configuration.minimumQueueInterval } ?? true)

        if !shouldPoll && !shouldProcessQueue {
            let result = AccountSyncRunResult(
                accountID: account.id,
                polledRemote: false,
                processedQueue: false,
                message: "No sync work due"
            )
            state.lastResult = result
            states[account.metadataID] = state
            return result
        }

        await diagnostics?.record(DiagnosticEvent(category: "SyncRun", level: .info, message: "Sync started", context: context))
        try await appModel.updateSyncStatus(SyncStatusSnapshot(state: .syncing, message: "Syncing"), accountID: account.id)

        do {
            var remoteChanges = RemoteChangeSet()
            var queueSummary = QueueProcessingSummary()
            if shouldPoll {
                remoteChanges = try await runner.pollRemote(account: account)
                state.lastPollAt = now
                var pollContext = context
                pollContext["outcome"] = "success"
                pollContext["polled"] = "true"
                pollContext["folders"] = remoteChanges.checkedFolderCount.map(String.init) ?? "unknown"
                pollContext["folderLimitReached"] = String(remoteChanges.folderLimitReached)
                pollContext["durationMs"] = String(Int(Date().timeIntervalSince(started) * 1_000))
                await diagnostics?.record(DiagnosticEvent(category: "RemotePoll", level: .info, message: "Remote poll completed", context: pollContext))
                // A successful authenticated poll can release an old Finder sign-in error,
                // even when no remote files changed. The extension verifies its own recovery.
                if let domainID = account.domain?.id {
                    do {
                        try await changeSignaler?.signalAuthenticationResolved(domainID: domainID)
                    } catch {
                        await WesomeLogger(category: "FileProvider").error("Could not retry Finder authentication: \(error)")
                    }
                }
                try await signalRemoteChanges(remoteChanges, for: account, occurredAt: now)
            }
            if shouldProcessQueue {
                queueSummary = try await runner.processQueue(account: account)
                state.lastQueueRunAt = now
            }
            let summary = Self.message(remoteChanges: remoteChanges, queueSummary: queueSummary)
            let folderDetail = shouldPoll ? remoteChanges.checkedFolderCount.map { "Checked \($0) folders\(remoteChanges.folderLimitReached ? " (limit reached)" : ""). " } ?? "" : ""
            let message = folderDetail + summary
            context["outcome"] = queueSummary.failedPermanently.isEmpty ? "success" : "queueFailed"
            context["polled"] = String(shouldPoll)
            context["folders"] = remoteChanges.checkedFolderCount.map(String.init) ?? "unknown"
            context["folderLimitReached"] = String(remoteChanges.folderLimitReached)
            context["durationMs"] = String(Int(Date().timeIntervalSince(started) * 1_000))
            context["queueFailed"] = String(queueSummary.failedPermanently.count)
            context["queueRescheduled"] = String(queueSummary.rescheduled.count)
            await diagnostics?.record(DiagnosticEvent(category: "SyncRun", level: queueSummary.failedPermanently.isEmpty ? .info : .error, message: message, context: context))
            let result = AccountSyncRunResult(
                accountID: account.id,
                polledRemote: shouldPoll,
                processedQueue: shouldProcessQueue,
                completedOperations: queueSummary.completed.count,
                rescheduledOperations: queueSummary.rescheduled.count,
                failedOperations: queueSummary.failedPermanently.count,
                message: message
            )
            state.lastResult = result
            states[account.metadataID] = state
            let statusState: SyncStatusState = queueSummary.failedPermanently.isEmpty ? .idle : .error
            if queueSummary.permanentlyFailedOperations.isEmpty {
                for failed in queueSummary.failedPermanently {
                    try await metadataStore?.recordSyncError(
                        SyncErrorRecord(
                            scope: .operation,
                            operationID: failed,
                            message: "Queued operation failed permanently",
                            isRecoverable: false,
                            occurredAt: now
                        ),
                        accountID: account.metadataID
                    )
                }
            } else {
                for failed in queueSummary.permanentlyFailedOperations {
                    try await metadataStore?.recordSyncError(
                        SyncErrorRecord(
                            scope: .operation,
                            itemID: failed.itemID,
                            operationID: failed.id,
                            message: Self.permanentFailureMessage(for: failed),
                            isRecoverable: false,
                            occurredAt: now
                        ),
                        accountID: account.metadataID
                    )
                }
            }
            try await appModel.updateSyncStatus(SyncStatusSnapshot(state: statusState, message: message, updatedAt: now), accountID: account.id)
            return result
        } catch {
            let message = "Sync failed: \(UserFacingErrorFormatter.message(for: error))"
            context["outcome"] = "failed"
            context["durationMs"] = String(Int(Date().timeIntervalSince(started) * 1_000))
            await diagnostics?.record(DiagnosticEvent(category: "SyncRun", level: .error, message: message, context: context))
            let result = AccountSyncRunResult(accountID: account.id, polledRemote: shouldPoll, processedQueue: shouldProcessQueue, failedOperations: 1, message: message)
            state.lastResult = result
            states[account.metadataID] = state
            try await metadataStore?.recordSyncError(
                SyncErrorRecord(
                    scope: .account,
                    message: message,
                    isRecoverable: true,
                    occurredAt: now
                ),
                accountID: account.metadataID
            )
            try await appModel.updateSyncStatus(SyncStatusSnapshot(state: .error, message: message, updatedAt: now), accountID: account.id)
            throw error
        }
    }

    private func effectiveConfiguration(for account: PersistedAccountRecord) async throws -> BackgroundSyncConfiguration {
        var configuration: BackgroundSyncConfiguration
        if let configurationProvider {
            configuration = try await configurationProvider()
        } else {
            configuration = self.configuration
        }
        if let serverPollInterval = account.serverPollInterval {
            configuration.pollInterval = SyncPreferences.clampedPollInterval(serverPollInterval)
        }
        return configuration
    }

    private static func message(remoteChanges: RemoteChangeSet, queueSummary: QueueProcessingSummary) -> String {
        let remoteCount = remoteChanges.added.count + remoteChanges.updated.count + remoteChanges.deleted.count
        let queueCount = queueSummary.completed.count + queueSummary.rescheduled.count + queueSummary.failedPermanently.count
        if remoteCount == 0 && queueCount == 0 { return "No changes detected" }
        return "\(remoteCount) remote change\(remoteCount == 1 ? "" : "s"), \(queueCount) queued operation\(queueCount == 1 ? "" : "s")"
    }

    private static func permanentFailureMessage(for operation: PendingOperation) -> String {
        var parts = ["Queued \(operation.kind.displayName) operation failed permanently for \(operation.itemID)"]
        if let sourcePath = operation.sourcePath {
            parts.append("source: \(sourcePath)")
        }
        if let destinationPath = operation.destinationPath {
            parts.append("destination: \(destinationPath)")
        }
        if let lastError = operation.lastErrorDescription {
            parts.append("error: \(UserFacingErrorFormatter.message(forStoredErrorDescription: lastError))")
        }
        return parts.joined(separator: "; ")
    }

    private func signalRemoteChanges(_ changes: RemoteChangeSet, for account: PersistedAccountRecord, occurredAt: Date) async throws {
        guard changes.isEmpty == false, let domainID = account.domain?.id, let changeSignaler else {
            return
        }
        do {
            for containerID in changes.fileProviderContainerIdentifiersToSignal {
                try await changeSignaler.signalEnumerator(domainID: domainID, containerItemIdentifier: containerID)
                await diagnostics?.record(DiagnosticEvent(category: "FinderRefresh", level: .info, message: "Refresh signaled", context: ["scope": account.metadataID.uuidString, "container": DiagnosticRedactor.reference(containerID)]))
            }
        } catch {
            try await metadataStore?.recordSyncError(
                SyncErrorRecord(
                    scope: .account,
                    message: "Remote changes were detected but File Provider refresh signaling failed: \(UserFacingErrorFormatter.message(for: error))",
                    isRecoverable: true,
                    occurredAt: occurredAt
                ),
                accountID: account.metadataID
            )
        }
    }
}

private let FileProviderRootContainerIdentifier = "NSFileProviderRootContainerItemIdentifier"
private let FileProviderWorkingSetContainerIdentifier = "NSFileProviderWorkingSetContainerItemIdentifier"

private extension RemoteChangeSet {
    var isEmpty: Bool {
        added.isEmpty && updated.isEmpty && deleted.isEmpty
    }

    var fileProviderContainerIdentifiersToSignal: [String] {
        var identifiers = [FileProviderRootContainerIdentifier, FileProviderWorkingSetContainerIdentifier]
        var seen = Set(identifiers)
        for item in added + updated {
            guard let parentID = item.parentID else { continue }
            if seen.insert(parentID).inserted {
                identifiers.append(parentID)
            }
        }
        for item in deletedItems {
            guard let parentID = item.parentID else { continue }
            if seen.insert(parentID).inserted {
                identifiers.append(parentID)
            }
        }
        return identifiers
    }
}

private extension PendingOperationKind {
    var displayName: String {
        switch self {
        case .upload: "upload"
        case .createFile: "file creation"
        case .delete: "delete"
        case .move: "move"
        case .createFolder: "folder creation"
        }
    }
}
