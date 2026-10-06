import Foundation
import SyncStore
import WesomeCloudShared

public struct RetryPolicy: Equatable, Sendable {
    public var baseDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var maximumAttempts: Int

    public init(baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 300, maximumAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
    }

    public func nextDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(maximumDelay, baseDelay * pow(2, Double(max(0, attempts - 1))))
    }
}

public struct QueueProcessingSummary: Equatable, Sendable {
    public var completed: [UUID]
    public var rescheduled: [UUID]
    public var failedPermanently: [UUID]
    public var permanentlyFailedOperations: [PendingOperation]

    public init(
        completed: [UUID] = [],
        rescheduled: [UUID] = [],
        failedPermanently: [UUID] = [],
        permanentlyFailedOperations: [PendingOperation] = []
    ) {
        self.completed = completed
        self.rescheduled = rescheduled
        self.failedPermanently = failedPermanently
        self.permanentlyFailedOperations = permanentlyFailedOperations
    }
}

public protocol PendingOperationExecuting: Sendable {
    func execute(_ operation: PendingOperation) async throws
}

public actor OfflineOperationQueue {
    private let accountID: UUID
    private let store: MetadataStore
    private let executor: PendingOperationExecuting
    private let retryPolicy: RetryPolicy
    private let clock: @Sendable () -> Date

    public init(
        accountID: UUID,
        store: MetadataStore,
        executor: PendingOperationExecuting,
        retryPolicy: RetryPolicy = RetryPolicy(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.store = store
        self.executor = executor
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    public func processDueOperations() async throws -> QueueProcessingSummary {
        let now = clock()
        let due = try await store.pendingOperations(accountID: accountID, dueAt: now)
        var summary = QueueProcessingSummary()

        for operation in due {
            do {
                try await executor.execute(operation)
                try await store.removePendingOperation(id: operation.id, accountID: accountID)
                summary.completed.append(operation.id)
            } catch {
                var updated = operation
                updated.attemptCount += 1
                updated.lastErrorDescription = String(describing: error)
                if !error.isRetryableOfflineFailure || updated.attemptCount >= retryPolicy.maximumAttempts {
                    try await store.removePendingOperation(id: operation.id, accountID: accountID)
                    summary.failedPermanently.append(operation.id)
                    summary.permanentlyFailedOperations.append(updated)
                } else {
                    updated.nextAttemptAt = now.addingTimeInterval(retryPolicy.nextDelay(afterAttempts: updated.attemptCount, error: error))
                    try await store.updatePendingOperation(updated, accountID: accountID)
                    summary.rescheduled.append(operation.id)
                }
            }
        }

        return summary
    }
}

public struct WebDAVPendingOperationExecutor: PendingOperationExecuting {
    private let backend: FileProviderBackend

    public init(backend: FileProviderBackend) {
        self.backend = backend
    }

    public func execute(_ operation: PendingOperation) async throws {
        switch operation.kind {
        case .upload:
            guard let sourcePath = operation.sourcePath else { throw WesomeCloudError.unsupported("Upload operation missing source path") }
            _ = try await backend.uploadModifiedContents(itemID: operation.itemID, contentsAt: URL(fileURLWithPath: sourcePath))
        case .createFile:
            guard let sourcePath = operation.sourcePath else { throw WesomeCloudError.unsupported("Create file operation missing source path") }
            guard let destinationPath = operation.destinationPath else { throw WesomeCloudError.unsupported("Create file operation missing destination path") }
            let parent = destinationPath.parentPath ?? "/"
            let name = destinationPath.lastPathComponent
            _ = try await backend.createFile(
                named: name,
                contentsAt: URL(fileURLWithPath: sourcePath),
                parentPath: parent,
                parentID: operation.itemID == parent ? (parent == "/" ? nil : parent) : operation.itemID
            )
        case .delete:
            try await backend.delete(itemID: operation.itemID)
        case .move:
            guard let destinationPath = operation.destinationPath else { throw WesomeCloudError.unsupported("Move operation missing destination path") }
            _ = try await backend.move(itemID: operation.itemID, to: destinationPath)
        case .createFolder:
            guard let destinationPath = operation.destinationPath else { throw WesomeCloudError.unsupported("Create folder operation missing destination path") }
            let parent = destinationPath.parentPath ?? "/"
            let name = destinationPath.lastPathComponent
            _ = try await backend.createFolder(named: name, parentPath: parent, parentID: operation.sourcePath ?? (parent == "/" ? nil : parent))
        }
    }
}

private extension RetryPolicy {
    func nextDelay(afterAttempts attempts: Int, error: Error) -> TimeInterval {
        if let retryAfter = error.retryAfterSeconds {
            return min(maximumDelay, max(0, retryAfter))
        }
        return nextDelay(afterAttempts: attempts)
    }
}

private extension Error {
    var retryAfterSeconds: TimeInterval? {
        guard let error = self as? WesomeCloudError else { return nil }
        if case .httpFailure(let failure) = error {
            return failure.retryAfterSeconds
        }
        return nil
    }

    var isRetryableOfflineFailure: Bool {
        if let error = self as? WesomeCloudError {
            switch error {
            case .httpFailure(let failure):
                failure.isRetryable
            case .httpStatus(let statusCode):
                HTTPFailure.classify(statusCode: statusCode).isRetryable
            case .invalidResponse:
                true
            case .missingItem, .unsupported, .transferIntegrityMismatch, .invalidFilename, .conflict:
                false
            }
        } else if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                true
            default:
                false
            }
        } else {
            true
        }
    }
}

private extension String {
    var lastPathComponent: String {
        split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? self
    }

    var parentPath: String? {
        let parts = split(separator: "/", omittingEmptySubsequences: true).dropLast()
        guard !parts.isEmpty else { return nil }
        return "/" + parts.joined(separator: "/")
    }
}
