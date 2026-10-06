import Foundation
import SQLite3
import Testing
import SyncStore
import WesomeCloudShared

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@Test
func sqliteStoreRecordsCurrentSchemaVersionForNewDatabases() throws {
    let store = try SQLiteMetadataStore(databaseURL: temporaryDatabaseURL())
    #expect(try store.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
}

@Test
func sqliteStoreUpgradesUnversionedDatabasesWithoutDroppingData() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let item = RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file)

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.upsert(accountID: accountID, items: [item])
        try setUserVersion(0, databaseURL: databaseURL)
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try reopened.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
    #expect(try await reopened.item(accountID: accountID, id: "file-1")?.remote == item)
}

@Test
func sqliteStoreAddsCreationDateColumnToVersionTwoDatabases() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_600_000_000)

    try executeSQL("""
    CREATE TABLE items (
        account_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        parent_id TEXT,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        size INTEGER,
        etag TEXT,
        file_id TEXT,
        checksum TEXT,
        permissions TEXT,
        modified_at REAL,
        content_type TEXT,
        availability_intent TEXT NOT NULL DEFAULT 'unspecified',
        materialized_url TEXT,
        last_seen REAL NOT NULL,
        PRIMARY KEY (account_id, item_id)
    );
    PRAGMA user_version = 2;
    """, databaseURL: databaseURL)

    let store = try SQLiteMetadataStore(databaseURL: databaseURL)
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(
            id: "file-1",
            parentID: nil,
            name: "Report.txt",
            path: "/Report.txt",
            kind: .file,
            createdAt: createdAt
        )
    ])

    #expect(try store.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
    #expect(try await store.item(accountID: accountID, id: "file-1")?.remote.createdAt == createdAt)
}

@Test
func sqliteStoreAddsQuotaAndPrivateLinkColumnsToVersionThreeDatabases() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let privateLink = URL(string: "https://cloud.example/f/abc123")!

    try executeSQL("""
    CREATE TABLE items (
        account_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        parent_id TEXT,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        size INTEGER,
        etag TEXT,
        file_id TEXT,
        checksum TEXT,
        permissions TEXT,
        created_at REAL,
        modified_at REAL,
        content_type TEXT,
        availability_intent TEXT NOT NULL DEFAULT 'unspecified',
        materialized_url TEXT,
        last_seen REAL NOT NULL,
        PRIMARY KEY (account_id, item_id)
    );
    PRAGMA user_version = 3;
    """, databaseURL: databaseURL)

    let store = try SQLiteMetadataStore(databaseURL: databaseURL)
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(
            id: "root",
            parentID: nil,
            name: "",
            path: "/",
            kind: .folder,
            quotaUsedBytes: 1024,
            quotaAvailableBytes: 2048,
            privateLink: privateLink
        )
    ])

    #expect(try store.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
    let stored = try await store.item(accountID: accountID, id: "root")
    #expect(stored?.remote.quotaUsedBytes == 1024)
    #expect(stored?.remote.quotaAvailableBytes == 2048)
    #expect(stored?.remote.privateLink == privateLink)
}

@Test
func sqliteStoreAddsPendingOperationRetryColumnsToVersionFourDatabases() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let due = PendingOperation(
        kind: .upload,
        itemID: "file-1",
        sourcePath: "/tmp/file-1",
        destinationPath: "/Remote.txt",
        createdAt: Date(timeIntervalSince1970: 10),
        attemptCount: 2,
        nextAttemptAt: Date(timeIntervalSince1970: 50),
        lastErrorDescription: "network lost"
    )
    let future = PendingOperation(
        kind: .delete,
        itemID: "file-2",
        sourcePath: "/Remote2.txt",
        createdAt: Date(timeIntervalSince1970: 20),
        nextAttemptAt: Date(timeIntervalSince1970: 150)
    )

    try executeSQL("""
    CREATE TABLE pending_operations (
        account_id TEXT NOT NULL,
        operation_id TEXT NOT NULL PRIMARY KEY,
        kind TEXT NOT NULL,
        item_id TEXT NOT NULL,
        payload BLOB NOT NULL,
        created_at REAL NOT NULL
    );
    CREATE INDEX pending_account_kind ON pending_operations(account_id, kind, created_at);
    PRAGMA user_version = 4;
    """, databaseURL: databaseURL)
    try insertLegacyPendingOperation(due, accountID: accountID, databaseURL: databaseURL)
    try insertLegacyPendingOperation(future, accountID: accountID, databaseURL: databaseURL)

    let store = try SQLiteMetadataStore(databaseURL: databaseURL)

    #expect(try store.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
    #expect(try table(databaseURL: databaseURL, "pending_operations", hasColumn: "next_attempt_at"))
    #expect(try await store.pendingOperations(accountID: accountID) == [due, future])
    #expect(try await store.pendingOperations(accountID: accountID, dueAt: Date(timeIntervalSince1970: 100)) == [due])
}

@Test
func sqliteStoreRejectsDatabasesFromNewerSchemaVersions() throws {
    let databaseURL = temporaryDatabaseURL()
    try setUserVersion(SQLiteMetadataStore.currentSchemaVersion + 1, databaseURL: databaseURL)

    #expect(throws: SQLiteStoreError.unsupportedSchemaVersion(
        SQLiteMetadataStore.currentSchemaVersion + 1,
        supported: SQLiteMetadataStore.currentSchemaVersion
    )) {
        _ = try SQLiteMetadataStore(databaseURL: databaseURL)
    }
}

@Test
func sqliteStorePersistsItemsAcrossReopen() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
    let accountID = UUID()
    let item = RemoteItem(
        id: "file-1",
        parentID: nil,
        name: "Report.txt",
        path: "/Report.txt",
        kind: .file,
        size: 12,
        etag: "etag-1",
        fileID: "oc-1",
        checksum: "SHA1:abc",
        permissions: "RDNVW",
        createdAt: Date(timeIntervalSince1970: 1_600_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        contentType: "text/plain",
        quotaUsedBytes: 1024,
        quotaAvailableBytes: 2048,
        privateLink: URL(string: "https://cloud.example/f/abc123")
    )

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.upsert(accountID: accountID, items: [item])
        try await store.setAvailabilityIntent(.alwaysLocal, accountID: accountID, itemID: "file-1")
        try await store.setMaterializedURL(URL(filePath: "/tmp/materialized"), accountID: accountID, itemID: "file-1")
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    let stored = try await reopened.item(accountID: accountID, id: "file-1")
    #expect(stored?.remote.id == item.id)
    #expect(stored?.remote.name == item.name)
    #expect(stored?.remote.path == item.path)
    #expect(stored?.remote.size == item.size)
    #expect(stored?.remote.etag == item.etag)
    #expect(stored?.remote.fileID == item.fileID)
    #expect(stored?.remote.checksum == item.checksum)
    #expect(stored?.remote.permissions == item.permissions)
    #expect(stored?.remote.createdAt == item.createdAt)
    #expect(stored?.remote.modifiedAt == item.modifiedAt)
    #expect(stored?.remote.contentType == item.contentType)
    #expect(stored?.remote.quotaUsedBytes == item.quotaUsedBytes)
    #expect(stored?.remote.quotaAvailableBytes == item.quotaAvailableBytes)
    #expect(stored?.remote.privateLink == item.privateLink)
    #expect(stored?.availabilityIntent == .alwaysLocal)
    #expect(stored?.materializedURL == URL(filePath: "/tmp/materialized"))
}

@Test
func sqliteStorePreservesAvailabilityWhenRemoteMetadataUpdates() async throws {
    let store = try SQLiteMetadataStore(databaseURL: temporaryDatabaseURL())
    let accountID = UUID()
    try await store.upsert(accountID: accountID, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file, etag: "old")
    ])
    try await store.setAvailabilityIntent(.onlineOnly, accountID: accountID, itemID: "file-1")

    try await store.upsert(accountID: accountID, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file, etag: "new")
    ])

    let stored = try await store.item(accountID: accountID, id: "file-1")
    #expect(stored?.remote.etag == "new")
    #expect(stored?.availabilityIntent == .onlineOnly)
}

@Test
func sqliteStoreRecordsPendingOperationsInCreationOrder() async throws {
    let store = try SQLiteMetadataStore(databaseURL: temporaryDatabaseURL())
    let accountID = UUID()
    let first = PendingOperation(kind: .upload, itemID: "a", createdAt: Date(timeIntervalSince1970: 1))
    let second = PendingOperation(kind: .delete, itemID: "b", createdAt: Date(timeIntervalSince1970: 2))

    try await store.enqueue(second, accountID: accountID)
    try await store.enqueue(first, accountID: accountID)

    let pending = try await store.pendingOperations(accountID: accountID)
    #expect(pending == [first, second])
}

@Test
func sqliteStorePersistsPendingOperationRetryState() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    var operation = PendingOperation(kind: .move, itemID: "file-1", sourcePath: "/Old.txt", destinationPath: "/New.txt")
    operation.attemptCount = 2
    operation.nextAttemptAt = Date(timeIntervalSince1970: 99)
    operation.lastErrorDescription = "timeout"

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.enqueue(operation, accountID: accountID)
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try await reopened.pendingOperations(accountID: accountID) == [operation])

    try await reopened.removePendingOperation(id: operation.id, accountID: accountID)
    #expect(try await reopened.pendingOperations(accountID: accountID).isEmpty)
}

@Test
func sqliteStoreReturnsOnlyDuePendingOperationsInCreationOrder() async throws {
    let store = try SQLiteMetadataStore(databaseURL: temporaryDatabaseURL())
    let accountID = UUID()
    let now = Date(timeIntervalSince1970: 100)
    let youngerDue = PendingOperation(kind: .delete, itemID: "younger", createdAt: Date(timeIntervalSince1970: 20), nextAttemptAt: now)
    let olderDue = PendingOperation(kind: .upload, itemID: "older", createdAt: Date(timeIntervalSince1970: 10), nextAttemptAt: now)
    let future = PendingOperation(kind: .move, itemID: "future", createdAt: Date(timeIntervalSince1970: 1), nextAttemptAt: now.addingTimeInterval(1))

    try await store.enqueue(youngerDue, accountID: accountID)
    try await store.enqueue(future, accountID: accountID)
    try await store.enqueue(olderDue, accountID: accountID)

    #expect(try await store.pendingOperations(accountID: accountID, dueAt: now) == [olderDue, youngerDue])
}

@Test
func sqliteStorePersistsSyncErrorsAcrossReopen() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let operationID = UUID()
    let older = SyncErrorRecord(
        scope: .operation,
        itemID: "file-1",
        operationID: operationID,
        message: "Upload timed out",
        isRecoverable: true,
        occurredAt: Date(timeIntervalSince1970: 1)
    )
    var newer = SyncErrorRecord(
        scope: .account,
        message: "Authentication failed",
        isRecoverable: false,
        occurredAt: Date(timeIntervalSince1970: 2)
    )

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.recordSyncError(older, accountID: accountID)
        try await store.recordSyncError(newer, accountID: accountID)
        newer.message = "Authentication expired"
        try await store.recordSyncError(newer, accountID: accountID)
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try await reopened.syncErrors(accountID: accountID) == [newer, older])

    try await reopened.clearSyncError(id: newer.id, accountID: accountID)
    #expect(try await reopened.syncErrors(accountID: accountID) == [older])
}

@Test
func sqliteStorePersistsTransferStateAcrossReopen() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    var download = TransferRecord(
        itemID: "file-1",
        direction: .download,
        phase: .running,
        bytesTransferred: 512,
        totalBytes: 1024,
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

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.upsertTransfer(download, accountID: accountID)
        download.phase = .failed
        download.lastErrorDescription = "checksum mismatch"
        download.updatedAt = Date(timeIntervalSince1970: 3)
        try await store.upsertTransfer(upload, accountID: accountID)
        try await store.upsertTransfer(download, accountID: accountID)
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try await reopened.transfers(accountID: accountID) == [download, upload])

    try await reopened.removeTransfer(id: download.id, accountID: accountID)
    #expect(try await reopened.transfers(accountID: accountID) == [upload])
}

@Test
func sqliteStorePersistsConflictResolutionAcrossReopen() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let older = ConflictRecord(
        conflict: SyncConflict(kind: .typeChanged, itemID: "folder-1", message: "Type changed"),
        createdAt: Date(timeIntervalSince1970: 1)
    )
    let newer = ConflictRecord(
        conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Local.txt", remotePath: "/Remote.txt", message: "Remote changed"),
        createdAt: Date(timeIntervalSince1970: 2)
    )
    let resolvedAt = Date(timeIntervalSince1970: 3)

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.recordConflict(older, accountID: accountID)
        try await store.recordConflict(newer, accountID: accountID)
        try await store.resolveConflict(id: newer.id, accountID: accountID, decision: .keepRemote, resolvedName: nil, resolvedAt: resolvedAt)
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try await reopened.conflicts(accountID: accountID, state: .pending) == [older])
    let resolved = try await reopened.conflicts(accountID: accountID, state: .resolved)
    #expect(resolved.count == 1)
    #expect(resolved.first?.id == newer.id)
    #expect(resolved.first?.selectedResolution == .keepRemote)
    #expect(resolved.first?.resolvedAt == resolvedAt)
}

@Test
func sqliteStorePersistsSyncCursorsAcrossReopen() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()

    do {
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try await store.setSyncCursor("token-1", accountID: accountID, remotePath: "Documents/")
    }

    let reopened = try SQLiteMetadataStore(databaseURL: databaseURL)
    #expect(try reopened.schemaVersion() == SQLiteMetadataStore.currentSchemaVersion)
    #expect(try await reopened.syncCursor(accountID: accountID, remotePath: "/Documents") == "token-1")

    try await reopened.setSyncCursor(nil, accountID: accountID, remotePath: "/Documents/")
    #expect(try await reopened.syncCursor(accountID: accountID, remotePath: "/Documents") == nil)
}

@Test
func sqliteStoreRemovesAllAccountScopedRecords() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let otherAccountID = UUID()
    let store = try SQLiteMetadataStore(databaseURL: databaseURL)

    try await populateAccountScopedRecords(in: store, accountID: accountID)
    try await populateAccountScopedRecords(in: store, accountID: otherAccountID)

    try await store.removeAll(accountID: accountID)

    try await expectAccountScopedRecordsRemoved(from: store, accountID: accountID)
    try await expectAccountScopedRecordsPresent(in: store, accountID: otherAccountID)
}

@Test
func sqliteStoreRemovingItemClearsOnlyItemScopedState() async throws {
    let databaseURL = temporaryDatabaseURL()
    let accountID = UUID()
    let store = try SQLiteMetadataStore(databaseURL: databaseURL)
    try await populateItemScopedRecords(in: store, accountID: accountID)

    try await store.remove(accountID: accountID, itemID: "file-1")

    #expect(try await store.items(accountID: accountID).map(\.remote.id) == ["file-2"])
    #expect(try await store.pendingOperations(accountID: accountID).map(\.itemID) == ["file-2"])
    #expect(try await store.syncErrors(accountID: accountID).map(\.message) == ["Account offline", "Other item failed"])
    #expect(try await store.transfers(accountID: accountID).map(\.itemID) == ["file-2"])
    #expect(try await store.conflicts(accountID: accountID, state: nil).map(\.conflict.itemID) == ["file-2"])
    #expect(try await store.syncCursor(accountID: accountID, remotePath: "/") == "token-1")
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func setUserVersion(_ version: Int, databaseURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw SQLiteStoreError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
        throw SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

private func executeSQL(_ sql: String, databaseURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw SQLiteStoreError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

private func insertLegacyPendingOperation(_ operation: PendingOperation, accountID: UUID, databaseURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw SQLiteStoreError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }

    let data = try JSONEncoder().encode(operation)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        handle,
        "INSERT INTO pending_operations (account_id, operation_id, kind, item_id, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, accountID.uuidString, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, operation.id.uuidString, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 3, operation.kind.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 4, operation.itemID, -1, SQLITE_TRANSIENT)
    _ = data.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, 5, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
    }
    sqlite3_bind_double(statement, 6, operation.createdAt.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

private func table(databaseURL: URL, _ tableName: String, hasColumn columnName: String) throws -> Bool {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw SQLiteStoreError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(tableName))", -1, &statement, nil) == SQLITE_OK, let statement else {
        throw SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }

    while sqlite3_step(statement) == SQLITE_ROW {
        guard let name = sqlite3_column_text(statement, 1) else { continue }
        if String(cString: name) == columnName {
            return true
        }
    }
    return false
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

@Test
func sqliteStoreKeepsTransactionsIntactUnderConcurrentWrites() async throws {
    let store = try SQLiteMetadataStore(databaseURL: temporaryDatabaseURL())
    let accountID = UUID()
    let items = (0..<200).map { RemoteItem(id: "file-\($0)", parentID: nil, name: "f\($0).txt", path: "/f\($0).txt", kind: .file) }
    try await store.upsert(accountID: accountID, items: items)

    // Removes run BEGIN/COMMIT transactions; interleaved upserts must neither break them nor be rolled back.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask { try await store.remove(accountID: accountID, itemID: "file-\(index)") }
            group.addTask {
                try await store.upsert(accountID: accountID, items: [
                    RemoteItem(id: "new-\(index)", parentID: nil, name: "n\(index).txt", path: "/n\(index).txt", kind: .file),
                ])
            }
        }
        try await group.waitForAll()
    }

    let remaining = try await store.items(accountID: accountID).map(\.remote.id)
    #expect(remaining.count == 200)
    #expect(remaining.filter { $0.hasPrefix("file-") }.count == 100)
    #expect(remaining.filter { $0.hasPrefix("new-") }.count == 100)
}
