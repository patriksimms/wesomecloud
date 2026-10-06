import Foundation
import Testing
import SyncStore
import WesomeCloudShared

@Test
func storeKeepsItemsSortedAndPreservesAvailabilityOnUpsert() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let first = RemoteItem(id: "b", parentID: nil, name: "Beta.txt", path: "/Beta.txt", kind: .file)
    let second = RemoteItem(id: "a", parentID: nil, name: "Alpha.txt", path: "/Alpha.txt", kind: .file)

    try await store.upsert(accountID: accountID, items: [first, second])
    try await store.setAvailabilityIntent(.alwaysLocal, accountID: accountID, itemID: "a")
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(id: "a", parentID: nil, name: "Alpha.txt", path: "/Alpha.txt", kind: .file, etag: "new")
    ])

    let children = try await store.children(accountID: accountID, parentID: nil)
    #expect(children.map(\.remote.id) == ["a", "b"])
    #expect(children.first?.availabilityIntent == .alwaysLocal)
    #expect(children.first?.remote.etag == "new")
}

@Test
func pendingOperationsAreRecorded() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let operation = PendingOperation(kind: .delete, itemID: "file-1", sourcePath: "/file.txt")

    try await store.enqueue(operation, accountID: accountID)

    let pending = try await store.pendingOperations(accountID: accountID)
    #expect(pending == [operation])
}

@Test
func pendingOperationsCanBeUpdatedAndRemoved() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    var operation = PendingOperation(kind: .upload, itemID: "file-1", sourcePath: "/tmp/file")
    try await store.enqueue(operation, accountID: accountID)

    operation.attemptCount = 1
    operation.nextAttemptAt = Date(timeIntervalSince1970: 42)
    operation.lastErrorDescription = "offline"
    try await store.updatePendingOperation(operation, accountID: accountID)

    #expect(try await store.pendingOperations(accountID: accountID) == [operation])

    try await store.removePendingOperation(id: operation.id, accountID: accountID)
    #expect(try await store.pendingOperations(accountID: accountID).isEmpty)
}

@Test
func syncErrorsAreRecordedNewestFirstAndCanBeCleared() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let older = SyncErrorRecord(
        scope: .item,
        itemID: "file-1",
        message: "Remote deleted while editing",
        isRecoverable: true,
        occurredAt: Date(timeIntervalSince1970: 1)
    )
    let newer = SyncErrorRecord(
        scope: .account,
        message: "Authentication failed",
        isRecoverable: false,
        occurredAt: Date(timeIntervalSince1970: 2)
    )

    try await store.recordSyncError(older, accountID: accountID)
    try await store.recordSyncError(newer, accountID: accountID)

    #expect(try await store.syncErrors(accountID: accountID) == [newer, older])

    try await store.clearSyncError(id: newer.id, accountID: accountID)
    #expect(try await store.syncErrors(accountID: accountID) == [older])
}

@Test
func transferRecordsAreUpsertedNewestFirstAndCanBeRemoved() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    var transfer = TransferRecord(
        itemID: "file-1",
        direction: .download,
        phase: .running,
        bytesTransferred: 10,
        totalBytes: 100,
        localURL: URL(filePath: "/tmp/file-1"),
        remotePath: "/file-1",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let upload = TransferRecord(
        itemID: "file-2",
        direction: .upload,
        phase: .queued,
        remotePath: "/file-2",
        updatedAt: Date(timeIntervalSince1970: 2)
    )

    try await store.upsertTransfer(transfer, accountID: accountID)
    transfer.phase = .completed
    transfer.bytesTransferred = 100
    transfer.updatedAt = Date(timeIntervalSince1970: 3)
    try await store.upsertTransfer(upload, accountID: accountID)
    try await store.upsertTransfer(transfer, accountID: accountID)

    #expect(try await store.transfers(accountID: accountID) == [transfer, upload])

    try await store.removeTransfer(id: transfer.id, accountID: accountID)
    #expect(try await store.transfers(accountID: accountID) == [upload])
}

@Test
func conflictRecordsAreRecordedAndResolved() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    let conflict = ConflictRecord(
        conflict: SyncConflict(
            kind: .nameCollision,
            itemID: "file-1",
            localPath: "/File.txt",
            remotePath: "/File.txt",
            message: "Name collision"
        ),
        createdAt: Date(timeIntervalSince1970: 1)
    )

    try await store.recordConflict(conflict, accountID: accountID)

    #expect(try await store.conflicts(accountID: accountID, state: .pending) == [conflict])

    let resolvedAt = Date(timeIntervalSince1970: 2)
    try await store.resolveConflict(
        id: conflict.id,
        accountID: accountID,
        decision: .renameLocal,
        resolvedName: "File local.txt",
        resolvedAt: resolvedAt
    )

    #expect(try await store.conflicts(accountID: accountID, state: .pending).isEmpty)
    let resolved = try await store.conflicts(accountID: accountID, state: .resolved).first
    #expect(resolved?.selectedResolution == .renameLocal)
    #expect(resolved?.resolvedName == "File local.txt")
    #expect(resolved?.resolvedAt == resolvedAt)
}

@Test
func syncCursorsCanBeStoredNormalizedAndCleared() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()

    try await store.setSyncCursor("token-1", accountID: accountID, remotePath: "Documents/")

    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/Documents") == "token-1")
    try await store.setSyncCursor(nil, accountID: accountID, remotePath: "/Documents/")
    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/Documents") == nil)
}

@Test
func metadataStoreRemovesAllAccountScopedRecords() async throws {
    let accountID = UUID()
    let otherAccountID = UUID()
    let store = InMemoryMetadataStore()

    try await populateAccountScopedRecords(in: store, accountID: accountID)
    try await populateAccountScopedRecords(in: store, accountID: otherAccountID)

    try await store.removeAll(accountID: accountID)

    try await expectAccountScopedRecordsRemoved(from: store, accountID: accountID)
    try await expectAccountScopedRecordsPresent(in: store, accountID: otherAccountID)
}

@Test
func removingItemClearsOnlyItemScopedState() async throws {
    let accountID = UUID()
    let store = InMemoryMetadataStore()
    try await populateItemScopedRecords(in: store, accountID: accountID)

    try await store.remove(accountID: accountID, itemID: "file-1")

    #expect(try await store.items(accountID: accountID).map(\.remote.id) == ["file-2"])
    #expect(try await store.pendingOperations(accountID: accountID).map(\.itemID) == ["file-2"])
    #expect(try await store.syncErrors(accountID: accountID).map(\.message) == ["Account offline", "Other item failed"])
    #expect(try await store.transfers(accountID: accountID).map(\.itemID) == ["file-2"])
    #expect(try await store.conflicts(accountID: accountID, state: nil).map(\.conflict.itemID) == ["file-2"])
    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/") == "token-1")
}

private func populateAccountScopedRecords(in store: MetadataStore, accountID: UUID) async throws {
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file)
    ])
    try await store.enqueue(PendingOperation(kind: .delete, itemID: "file-1", sourcePath: "/Report.txt"), accountID: accountID)
    try await store.recordSyncError(
        SyncErrorRecord(scope: .account, message: "Offline", isRecoverable: true),
        accountID: accountID
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "file-1", direction: .download, phase: .running, remotePath: "/Report.txt"),
        accountID: accountID
    )
    try await store.recordConflict(
        ConflictRecord(conflict: SyncConflict(kind: .typeChanged, itemID: "file-1", message: "Type changed")),
        accountID: accountID
    )
    try await store.setSyncCursor("token-1", accountID: accountID, remotePath: "/")
}

private func expectAccountScopedRecordsRemoved(from store: MetadataStore, accountID: UUID) async throws {
    #expect(try await store.items(accountID: accountID).isEmpty)
    #expect(try await store.pendingOperations(accountID: accountID).isEmpty)
    #expect(try await store.syncErrors(accountID: accountID).isEmpty)
    #expect(try await store.transfers(accountID: accountID).isEmpty)
    #expect(try await store.conflicts(accountID: accountID, state: nil).isEmpty)
    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/") == nil)
}

private func expectAccountScopedRecordsPresent(in store: MetadataStore, accountID: UUID) async throws {
    #expect(try await store.items(accountID: accountID).map(\.remote.id) == ["file-1"])
    #expect(try await store.pendingOperations(accountID: accountID).map(\.itemID) == ["file-1"])
    #expect(try await store.syncErrors(accountID: accountID).map(\.message) == ["Offline"])
    #expect(try await store.transfers(accountID: accountID).map(\.itemID) == ["file-1"])
    #expect(try await store.conflicts(accountID: accountID, state: nil).map(\.conflict.itemID) == ["file-1"])
    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/") == "token-1")
}

private func populateItemScopedRecords(in store: MetadataStore, accountID: UUID) async throws {
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file),
        RemoteItem(id: "file-2", parentID: nil, name: "Notes.txt", path: "/Notes.txt", kind: .file),
    ])
    let removedOperation = PendingOperation(kind: .delete, itemID: "file-1", sourcePath: "/Report.txt")
    try await store.enqueue(removedOperation, accountID: accountID)
    try await store.enqueue(PendingOperation(kind: .upload, itemID: "file-2", sourcePath: "/Notes.txt"), accountID: accountID)
    try await store.recordSyncError(
        SyncErrorRecord(scope: .item, itemID: "file-1", message: "Deleted item failed", isRecoverable: true, occurredAt: Date(timeIntervalSince1970: 3)),
        accountID: accountID
    )
    try await store.recordSyncError(
        SyncErrorRecord(scope: .operation, operationID: removedOperation.id, message: "Deleted operation failed", isRecoverable: true, occurredAt: Date(timeIntervalSince1970: 4)),
        accountID: accountID
    )
    try await store.recordSyncError(
        SyncErrorRecord(scope: .item, itemID: "file-2", message: "Other item failed", isRecoverable: true, occurredAt: Date(timeIntervalSince1970: 2)),
        accountID: accountID
    )
    try await store.recordSyncError(
        SyncErrorRecord(scope: .account, message: "Account offline", isRecoverable: true, occurredAt: Date(timeIntervalSince1970: 5)),
        accountID: accountID
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "file-1", direction: .download, phase: .running, remotePath: "/Report.txt", updatedAt: Date(timeIntervalSince1970: 2)),
        accountID: accountID
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "file-2", direction: .upload, phase: .queued, remotePath: "/Notes.txt", updatedAt: Date(timeIntervalSince1970: 1)),
        accountID: accountID
    )
    try await store.recordConflict(
        ConflictRecord(conflict: SyncConflict(kind: .typeChanged, itemID: "file-1", message: "Deleted conflict")),
        accountID: accountID
    )
    try await store.recordConflict(
        ConflictRecord(conflict: SyncConflict(kind: .nameCollision, itemID: "file-2", message: "Other conflict")),
        accountID: accountID
    )
    try await store.setSyncCursor("token-1", accountID: accountID, remotePath: "/")
}
