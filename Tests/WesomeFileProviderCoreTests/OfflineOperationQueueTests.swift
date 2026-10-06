import Foundation
import SyncStore
import Testing
import WesomeCloudShared
@testable import WesomeFileProviderCore

private actor RecordingOperationExecutor: PendingOperationExecuting {
    var executed: [UUID] = []
    var failingIDs: Set<UUID> = []
    var failure: Error

    init(
        failingIDs: Set<UUID> = [],
        failure: Error = WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable))
    ) {
        self.failingIDs = failingIDs
        self.failure = failure
    }

    func execute(_ operation: PendingOperation) async throws {
        executed.append(operation.id)
        if failingIDs.contains(operation.id) {
            throw failure
        }
    }
}

private actor RecordingBackend: FileProviderBackend {
    var calls: [String] = []
    private let placeholder = ProviderItem(
        id: "placeholder",
        parentID: nil,
        filename: "Placeholder",
        kind: .folder,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate]
    )

    func enumerate(parentID _: String?, remotePath _: String) async throws -> [ProviderItem] { [] }
    func item(itemID _: String) async throws -> ProviderItem? { nil }
    func fetchContents(itemID _: String) async throws -> URL { FileManager.default.temporaryDirectory }
    func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        calls.append("upload:\(itemID):\(localURL.path)")
        return placeholder
    }
    func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem {
        calls.append("createFile:\(name):\(localURL.path):\(parentPath):\(parentID ?? "nil")")
        return placeholder
    }
    func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem {
        calls.append("createFolder:\(name):\(parentPath):\(parentID ?? "nil")")
        return placeholder
    }
    func delete(itemID: String) async throws {
        calls.append("delete:\(itemID)")
    }
    func move(itemID: String, to destinationPath: String) async throws -> ProviderItem {
        calls.append("move:\(itemID):\(destinationPath)")
        return placeholder
    }
    func pollRemoteChanges(parentID _: String?, remotePath _: String) async throws -> RemoteChangeSet { RemoteChangeSet() }
    func setAvailabilityIntent(_: AvailabilityIntent, itemID: String, includeDescendants _: Bool) async throws -> [String] { [itemID] }
    func evictMaterializedContentForDiskPressure() async throws -> [String] { [] }
}

@Test
func offlineQueueProcessesOnlyDueOperationsAndRemovesCompleted() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let due = PendingOperation(kind: .delete, itemID: "due", createdAt: now.addingTimeInterval(-10), nextAttemptAt: now)
    let future = PendingOperation(kind: .delete, itemID: "future", createdAt: now, nextAttemptAt: now.addingTimeInterval(60))
    try await store.enqueue(due, accountID: accountID)
    try await store.enqueue(future, accountID: accountID)
    let executor = RecordingOperationExecutor()
    let queue = OfflineOperationQueue(accountID: accountID, store: store, executor: executor, clock: { now })

    let summary = try await queue.processDueOperations()

    #expect(summary.completed == [due.id])
    #expect(summary.rescheduled.isEmpty)
    #expect(await executor.executed == [due.id])
    #expect(try await store.pendingOperations(accountID: accountID) == [future])
}

@Test
func offlineQueueReschedulesFailuresWithBackoff() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let operation = PendingOperation(kind: .upload, itemID: "file", sourcePath: "/tmp/file", createdAt: now, nextAttemptAt: now)
    try await store.enqueue(operation, accountID: accountID)
    let executor = RecordingOperationExecutor(failingIDs: [operation.id])
    let queue = OfflineOperationQueue(
        accountID: accountID,
        store: store,
        executor: executor,
        retryPolicy: RetryPolicy(baseDelay: 5, maximumDelay: 60, maximumAttempts: 3),
        clock: { now }
    )

    let summary = try await queue.processDueOperations()

    #expect(summary.rescheduled == [operation.id])
    let updated = try #require(await store.pendingOperations(accountID: accountID).first)
    #expect(updated.attemptCount == 1)
    #expect(updated.nextAttemptAt == now.addingTimeInterval(5))
    #expect(updated.lastErrorDescription?.contains("httpFailure") == true)
    #expect(updated.lastErrorDescription?.contains("unavailable") == true)
}

@Test
func offlineQueueHonorsRetryAfterWhenReschedulingFailures() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let operation = PendingOperation(kind: .upload, itemID: "file", sourcePath: "/tmp/file", createdAt: now, nextAttemptAt: now)
    try await store.enqueue(operation, accountID: accountID)
    let executor = RecordingOperationExecutor(
        failingIDs: [operation.id],
        failure: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 429, kind: .rateLimited, retryAfterSeconds: 45))
    )
    let queue = OfflineOperationQueue(
        accountID: accountID,
        store: store,
        executor: executor,
        retryPolicy: RetryPolicy(baseDelay: 5, maximumDelay: 60, maximumAttempts: 3),
        clock: { now }
    )

    let summary = try await queue.processDueOperations()

    #expect(summary.rescheduled == [operation.id])
    let updated = try #require(await store.pendingOperations(accountID: accountID).first)
    #expect(updated.attemptCount == 1)
    #expect(updated.nextAttemptAt == now.addingTimeInterval(45))
}

@Test
func offlineQueueFailsNonRetryableErrorsPermanentlyWithoutBackoff() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let operation = PendingOperation(kind: .upload, itemID: "file", sourcePath: "/tmp/file", createdAt: now, nextAttemptAt: now)
    try await store.enqueue(operation, accountID: accountID)
    let executor = RecordingOperationExecutor(
        failingIDs: [operation.id],
        failure: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 507, kind: .quotaExceeded))
    )
    let queue = OfflineOperationQueue(
        accountID: accountID,
        store: store,
        executor: executor,
        retryPolicy: RetryPolicy(baseDelay: 5, maximumDelay: 60, maximumAttempts: 3),
        clock: { now }
    )

    let summary = try await queue.processDueOperations()

    #expect(summary.rescheduled.isEmpty)
    #expect(summary.failedPermanently == [operation.id])
    #expect(summary.permanentlyFailedOperations.first?.attemptCount == 1)
    #expect(summary.permanentlyFailedOperations.first?.lastErrorDescription?.contains("quotaExceeded") == true)
    #expect(try await store.pendingOperations(accountID: accountID).isEmpty)
}

@Test
func offlineQueueCapsRetryAfterAtMaximumDelay() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let operation = PendingOperation(kind: .upload, itemID: "file", sourcePath: "/tmp/file", createdAt: now, nextAttemptAt: now)
    try await store.enqueue(operation, accountID: accountID)
    let executor = RecordingOperationExecutor(
        failingIDs: [operation.id],
        failure: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable, retryAfterSeconds: 300))
    )
    let queue = OfflineOperationQueue(
        accountID: accountID,
        store: store,
        executor: executor,
        retryPolicy: RetryPolicy(baseDelay: 5, maximumDelay: 60, maximumAttempts: 3),
        clock: { now }
    )

    _ = try await queue.processDueOperations()

    let updated = try #require(await store.pendingOperations(accountID: accountID).first)
    #expect(updated.nextAttemptAt == now.addingTimeInterval(60))
}

@Test
func offlineQueueDropsPermanentlyFailedOperationsAtAttemptLimit() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let now = Date(timeIntervalSince1970: 100)
    let operation = PendingOperation(
        kind: .upload,
        itemID: "file",
        sourcePath: "/tmp/file",
        createdAt: now,
        attemptCount: 1,
        nextAttemptAt: now
    )
    try await store.enqueue(operation, accountID: accountID)
    let executor = RecordingOperationExecutor(failingIDs: [operation.id])
    let queue = OfflineOperationQueue(
        accountID: accountID,
        store: store,
        executor: executor,
        retryPolicy: RetryPolicy(baseDelay: 5, maximumDelay: 60, maximumAttempts: 2),
        clock: { now }
    )

    let summary = try await queue.processDueOperations()

    #expect(summary.failedPermanently == [operation.id])
    #expect(summary.permanentlyFailedOperations.count == 1)
    #expect(summary.permanentlyFailedOperations.first?.id == operation.id)
    #expect(summary.permanentlyFailedOperations.first?.attemptCount == 2)
    #expect(summary.permanentlyFailedOperations.first?.lastErrorDescription?.contains("httpFailure") == true)
    #expect(try await store.pendingOperations(accountID: accountID).isEmpty)
}

@Test
func webDAVPendingExecutorReplaysCreateFolderWithStoredParentIdentity() async throws {
    let backend = RecordingBackend()
    let executor = WebDAVPendingOperationExecutor(backend: backend)
    let operation = PendingOperation(
        kind: .createFolder,
        itemID: "child-folder",
        sourcePath: "stable-parent-id",
        destinationPath: "/Renamed Parent/Child"
    )

    try await executor.execute(operation)

    #expect(await backend.calls == [
        "createFolder:Child:/Renamed Parent:stable-parent-id"
    ])
}

@Test
func webDAVPendingExecutorReplaysCreateFileWithStoredParentIdentity() async throws {
    let backend = RecordingBackend()
    let executor = WebDAVPendingOperationExecutor(backend: backend)
    let operation = PendingOperation(
        kind: .createFile,
        itemID: "stable-parent-id",
        sourcePath: "/tmp/New.txt",
        destinationPath: "/Renamed Parent/New.txt"
    )

    try await executor.execute(operation)

    #expect(await backend.calls == [
        "createFile:New.txt:/tmp/New.txt:/Renamed Parent:stable-parent-id"
    ])
}

@Test
func webDAVPendingExecutorReplaysRootCreateFileWithoutParentIdentity() async throws {
    let backend = RecordingBackend()
    let executor = WebDAVPendingOperationExecutor(backend: backend)
    let operation = PendingOperation(
        kind: .createFile,
        itemID: "/",
        sourcePath: "/tmp/Root.txt",
        destinationPath: "/Root.txt"
    )

    try await executor.execute(operation)

    #expect(await backend.calls == [
        "createFile:Root.txt:/tmp/Root.txt:/:nil"
    ])
}
