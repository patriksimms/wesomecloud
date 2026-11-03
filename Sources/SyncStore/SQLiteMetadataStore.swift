import Foundation
import SQLite3
import WesomeCloudShared

/// SQLite-backed sync journal shared by the app and the File Provider extension.
/// One connection per instance; `lock` serializes every statement and spans whole transactions,
/// because concurrent async callers would otherwise interleave BEGIN/COMMIT on the same handle.
public final class SQLiteMetadataStore: MetadataStore, @unchecked Sendable {
    public static let currentSchemaVersion = 6

    private let database: OpaquePointer
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw SQLiteStoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        self.database = handle
        // The app and the extension write to the same file; wait for the other process instead of failing with SQLITE_BUSY.
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    public func upsert(accountID: UUID, items newItems: [RemoteItem]) async throws {
        let sql = """
        INSERT INTO items (
            account_id, item_id, parent_id, name, path, kind, size, etag, file_id,
            checksum, permissions, created_at, modified_at, content_type, quota_used_bytes,
            quota_available_bytes, private_link, availability_intent, materialized_url, last_seen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, item_id) DO UPDATE SET
            parent_id=excluded.parent_id,
            name=excluded.name,
            path=excluded.path,
            kind=excluded.kind,
            size=excluded.size,
            etag=excluded.etag,
            file_id=excluded.file_id,
            checksum=excluded.checksum,
            permissions=excluded.permissions,
            created_at=excluded.created_at,
            modified_at=excluded.modified_at,
            content_type=excluded.content_type,
            quota_used_bytes=excluded.quota_used_bytes,
            quota_available_bytes=excluded.quota_available_bytes,
            private_link=excluded.private_link,
            last_seen=excluded.last_seen
        """
        try transaction {
            try withStatement(sql) { statement in
                for item in newItems {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(accountID.uuidString, to: statement, at: 1)
                    bind(item.id, to: statement, at: 2)
                    bind(item.parentID, to: statement, at: 3)
                    bind(item.name, to: statement, at: 4)
                    bind(item.path, to: statement, at: 5)
                    bind(item.kind.rawValue, to: statement, at: 6)
                    bind(item.size, to: statement, at: 7)
                    bind(item.etag, to: statement, at: 8)
                    bind(item.fileID, to: statement, at: 9)
                    bind(item.checksum, to: statement, at: 10)
                    bind(item.permissions, to: statement, at: 11)
                    bind(item.createdAt?.timeIntervalSince1970, to: statement, at: 12)
                    bind(item.modifiedAt?.timeIntervalSince1970, to: statement, at: 13)
                    bind(item.contentType, to: statement, at: 14)
                    bind(item.quotaUsedBytes, to: statement, at: 15)
                    bind(item.quotaAvailableBytes, to: statement, at: 16)
                    bind(item.privateLink?.absoluteString, to: statement, at: 17)
                    bind(AvailabilityIntent.unspecified.rawValue, to: statement, at: 18)
                    bind(nil as String?, to: statement, at: 19)
                    bind(Date().timeIntervalSince1970, to: statement, at: 20)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                }
            }
        }
    }

    public func remove(accountID: UUID, itemID: String) async throws {
        let accountID = accountID.uuidString
        try transaction {
            try executeItemDelete(
                "DELETE FROM sync_errors WHERE account_id = ? AND operation_id IN (SELECT operation_id FROM pending_operations WHERE account_id = ? AND item_id = ?)",
                accountID: accountID,
                itemID: itemID,
                bindAccountIDTwice: true
            )
            try executeItemDelete("DELETE FROM items WHERE account_id = ? AND item_id = ?", accountID: accountID, itemID: itemID)
            try executeItemDelete("DELETE FROM pending_operations WHERE account_id = ? AND item_id = ?", accountID: accountID, itemID: itemID)
            try executeItemDelete("DELETE FROM sync_errors WHERE account_id = ? AND item_id = ?", accountID: accountID, itemID: itemID)
            try executeItemDelete("DELETE FROM transfers WHERE account_id = ? AND item_id = ?", accountID: accountID, itemID: itemID)
            try executeItemDelete("DELETE FROM conflicts WHERE account_id = ? AND item_id = ?", accountID: accountID, itemID: itemID)
        }
    }

    public func item(accountID: UUID, id: String) async throws -> StoredItem? {
        try withStatement("SELECT * FROM items WHERE account_id = ? AND item_id = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(id, to: statement, at: 2)
            return try step(statement) ? try readStoredItem(statement) : nil
        }
    }

    public func items(accountID: UUID) async throws -> [StoredItem] {
        try storedItems(accountID: accountID)
    }

    public func storedItems(accountID: UUID) throws -> [StoredItem] {
        try withStatement("SELECT * FROM items WHERE account_id = ? ORDER BY path COLLATE NOCASE") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            var result: [StoredItem] = []
            while try step(statement) {
                result.append(try readStoredItem(statement))
            }
            return result
        }
    }

    public func children(accountID: UUID, parentID: String?) async throws -> [StoredItem] {
        let sql: String
        if parentID == nil {
            sql = "SELECT * FROM items WHERE account_id = ? AND parent_id IS NULL ORDER BY name COLLATE NOCASE"
        } else {
            sql = "SELECT * FROM items WHERE account_id = ? AND parent_id = ? ORDER BY name COLLATE NOCASE"
        }
        return try withStatement(sql) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            if let parentID { bind(parentID, to: statement, at: 2) }
            var result: [StoredItem] = []
            while try step(statement) {
                result.append(try readStoredItem(statement))
            }
            return result
        }
    }

    public func removeAll(accountID: UUID) async throws {
        try executeAccountDeletes([
            "DELETE FROM items WHERE account_id = ?",
            "DELETE FROM pending_operations WHERE account_id = ?",
            "DELETE FROM sync_errors WHERE account_id = ?",
            "DELETE FROM transfers WHERE account_id = ?",
            "DELETE FROM conflicts WHERE account_id = ?",
            "DELETE FROM sync_cursors WHERE account_id = ?",
        ], accountID: accountID)
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, accountID: UUID, itemID: String) async throws {
        try updateSingleItem(
            sql: "UPDATE items SET availability_intent = ? WHERE account_id = ? AND item_id = ?",
            values: [intent.rawValue, accountID.uuidString, itemID],
            itemID: itemID
        )
    }

    public func setMaterializedURL(_ url: URL?, accountID: UUID, itemID: String) async throws {
        try updateSingleItem(
            sql: "UPDATE items SET materialized_url = ? WHERE account_id = ? AND item_id = ?",
            values: [url?.path, accountID.uuidString, itemID],
            itemID: itemID
        )
    }

    public func enqueue(_ operation: PendingOperation, accountID: UUID) async throws {
        let data = try encoder.encode(operation)
        try withStatement("""
        INSERT INTO pending_operations (
            account_id, operation_id, kind, item_id, source_path, destination_path,
            attempt_count, next_attempt_at, last_error_description, payload, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(operation.id.uuidString, to: statement, at: 2)
            bind(operation.kind.rawValue, to: statement, at: 3)
            bind(operation.itemID, to: statement, at: 4)
            bind(operation.sourcePath, to: statement, at: 5)
            bind(operation.destinationPath, to: statement, at: 6)
            bind(operation.attemptCount, to: statement, at: 7)
            bind(operation.nextAttemptAt.timeIntervalSince1970, to: statement, at: 8)
            bind(operation.lastErrorDescription, to: statement, at: 9)
            bind(data, to: statement, at: 10)
            bind(operation.createdAt.timeIntervalSince1970, to: statement, at: 11)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func pendingOperations(accountID: UUID) async throws -> [PendingOperation] {
        try readPendingOperations(
            sql: "SELECT payload FROM pending_operations WHERE account_id = ? ORDER BY created_at",
            bindParameters: { statement in
                bind(accountID.uuidString, to: statement, at: 1)
            }
        )
    }

    public func pendingOperations(accountID: UUID, dueAt: Date) async throws -> [PendingOperation] {
        try readPendingOperations(
            sql: "SELECT payload FROM pending_operations WHERE account_id = ? AND next_attempt_at <= ? ORDER BY created_at",
            bindParameters: { statement in
                bind(accountID.uuidString, to: statement, at: 1)
                bind(dueAt.timeIntervalSince1970, to: statement, at: 2)
            }
        )
    }

    private func readPendingOperations(sql: String, bindParameters: (OpaquePointer) throws -> Void) throws -> [PendingOperation] {
        try withStatement(sql) { statement in
            try bindParameters(statement)
            var result: [PendingOperation] = []
            while try step(statement) {
                guard let data = sqlite3_column_blob(statement, 0) else { continue }
                let size = Int(sqlite3_column_bytes(statement, 0))
                result.append(try decoder.decode(PendingOperation.self, from: Data(bytes: data, count: size)))
            }
            return result
        }
    }

    private func migratePendingOperationRetryColumnsFromPayload() throws {
        let operations = try withStatement("SELECT account_id, payload FROM pending_operations") { statement in
            var result: [(accountID: String, operation: PendingOperation)] = []
            while try step(statement) {
                guard let data = sqlite3_column_blob(statement, 1) else { continue }
                let size = Int(sqlite3_column_bytes(statement, 1))
                result.append((
                    accountID: columnText(statement, "account_id")!,
                    operation: try decoder.decode(PendingOperation.self, from: Data(bytes: data, count: size))
                ))
            }
            return result
        }

        try withStatement("""
        UPDATE pending_operations SET
            source_path = ?,
            destination_path = ?,
            attempt_count = ?,
            next_attempt_at = ?,
            last_error_description = ?
        WHERE account_id = ? AND operation_id = ?
        """) { statement in
            for (accountID, operation) in operations {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(operation.sourcePath, to: statement, at: 1)
                bind(operation.destinationPath, to: statement, at: 2)
                bind(operation.attemptCount, to: statement, at: 3)
                bind(operation.nextAttemptAt.timeIntervalSince1970, to: statement, at: 4)
                bind(operation.lastErrorDescription, to: statement, at: 5)
                bind(accountID, to: statement, at: 6)
                bind(operation.id.uuidString, to: statement, at: 7)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
        }
    }

    public func updatePendingOperation(_ operation: PendingOperation, accountID: UUID) async throws {
        let data = try encoder.encode(operation)
        try withStatement("""
        UPDATE pending_operations SET
            kind = ?,
            item_id = ?,
            source_path = ?,
            destination_path = ?,
            attempt_count = ?,
            next_attempt_at = ?,
            last_error_description = ?,
            payload = ?,
            created_at = ?
        WHERE account_id = ? AND operation_id = ?
        """) { statement in
            bind(operation.kind.rawValue, to: statement, at: 1)
            bind(operation.itemID, to: statement, at: 2)
            bind(operation.sourcePath, to: statement, at: 3)
            bind(operation.destinationPath, to: statement, at: 4)
            bind(operation.attemptCount, to: statement, at: 5)
            bind(operation.nextAttemptAt.timeIntervalSince1970, to: statement, at: 6)
            bind(operation.lastErrorDescription, to: statement, at: 7)
            bind(data, to: statement, at: 8)
            bind(operation.createdAt.timeIntervalSince1970, to: statement, at: 9)
            bind(accountID.uuidString, to: statement, at: 10)
            bind(operation.id.uuidString, to: statement, at: 11)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            guard sqlite3_changes(database) == 1 else { throw WesomeCloudError.missingItem(operation.id.uuidString) }
        }
    }

    public func removePendingOperation(id: UUID, accountID: UUID) async throws {
        try withStatement("DELETE FROM pending_operations WHERE account_id = ? AND operation_id = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(id.uuidString, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func recordSyncError(_ error: SyncErrorRecord, accountID: UUID) async throws {
        let data = try encoder.encode(error)
        try withStatement("""
        INSERT INTO sync_errors (
            account_id, error_id, scope, item_id, operation_id, message,
            recoverable, occurred_at, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, error_id) DO UPDATE SET
            scope=excluded.scope,
            item_id=excluded.item_id,
            operation_id=excluded.operation_id,
            message=excluded.message,
            recoverable=excluded.recoverable,
            occurred_at=excluded.occurred_at,
            payload=excluded.payload
        """) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(error.id.uuidString, to: statement, at: 2)
            bind(error.scope.rawValue, to: statement, at: 3)
            bind(error.itemID, to: statement, at: 4)
            bind(error.operationID?.uuidString, to: statement, at: 5)
            bind(error.message, to: statement, at: 6)
            bind(error.isRecoverable ? 1 : 0, to: statement, at: 7)
            bind(error.occurredAt.timeIntervalSince1970, to: statement, at: 8)
            bind(data, to: statement, at: 9)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func syncErrors(accountID: UUID) async throws -> [SyncErrorRecord] {
        try withStatement("SELECT payload FROM sync_errors WHERE account_id = ? ORDER BY occurred_at DESC") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            var result: [SyncErrorRecord] = []
            while try step(statement) {
                guard let data = sqlite3_column_blob(statement, 0) else { continue }
                let size = Int(sqlite3_column_bytes(statement, 0))
                result.append(try decoder.decode(SyncErrorRecord.self, from: Data(bytes: data, count: size)))
            }
            return result
        }
    }

    public func clearSyncError(id: UUID, accountID: UUID) async throws {
        try withStatement("DELETE FROM sync_errors WHERE account_id = ? AND error_id = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(id.uuidString, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func upsertTransfer(_ transfer: TransferRecord, accountID: UUID) async throws {
        let data = try encoder.encode(transfer)
        try withStatement("""
        INSERT INTO transfers (
            account_id, transfer_id, item_id, direction, phase,
            bytes_transferred, total_bytes, remote_path, updated_at, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, transfer_id) DO UPDATE SET
            item_id=excluded.item_id,
            direction=excluded.direction,
            phase=excluded.phase,
            bytes_transferred=excluded.bytes_transferred,
            total_bytes=excluded.total_bytes,
            remote_path=excluded.remote_path,
            updated_at=excluded.updated_at,
            payload=excluded.payload
        """) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(transfer.id.uuidString, to: statement, at: 2)
            bind(transfer.itemID, to: statement, at: 3)
            bind(transfer.direction.rawValue, to: statement, at: 4)
            bind(transfer.phase.rawValue, to: statement, at: 5)
            bind(transfer.bytesTransferred, to: statement, at: 6)
            bind(transfer.totalBytes, to: statement, at: 7)
            bind(transfer.remotePath, to: statement, at: 8)
            bind(transfer.updatedAt.timeIntervalSince1970, to: statement, at: 9)
            bind(data, to: statement, at: 10)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func transfers(accountID: UUID) async throws -> [TransferRecord] {
        try storedTransfers(accountID: accountID)
    }

    public func storedTransfers(accountID: UUID) throws -> [TransferRecord] {
        try withStatement("SELECT payload FROM transfers WHERE account_id = ? ORDER BY updated_at DESC") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            var result: [TransferRecord] = []
            while try step(statement) {
                guard let data = sqlite3_column_blob(statement, 0) else { continue }
                let size = Int(sqlite3_column_bytes(statement, 0))
                result.append(try decoder.decode(TransferRecord.self, from: Data(bytes: data, count: size)))
            }
            return result
        }
    }

    public func removeTransfer(id: UUID, accountID: UUID) async throws {
        try withStatement("DELETE FROM transfers WHERE account_id = ? AND transfer_id = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(id.uuidString, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func recordConflict(_ conflict: ConflictRecord, accountID: UUID) async throws {
        let data = try encoder.encode(conflict)
        try withStatement("""
        INSERT INTO conflicts (
            account_id, conflict_id, item_id, kind, state, created_at, resolved_at, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, conflict_id) DO UPDATE SET
            item_id=excluded.item_id,
            kind=excluded.kind,
            state=excluded.state,
            created_at=excluded.created_at,
            resolved_at=excluded.resolved_at,
            payload=excluded.payload
        """) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(conflict.id.uuidString, to: statement, at: 2)
            bind(conflict.conflict.itemID, to: statement, at: 3)
            bind(conflict.conflict.kind.rawValue, to: statement, at: 4)
            bind(conflict.state.rawValue, to: statement, at: 5)
            bind(conflict.createdAt.timeIntervalSince1970, to: statement, at: 6)
            bind(conflict.resolvedAt?.timeIntervalSince1970, to: statement, at: 7)
            bind(data, to: statement, at: 8)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func conflicts(accountID: UUID, state: ConflictRecordState?) async throws -> [ConflictRecord] {
        let sql: String
        if state == nil {
            sql = "SELECT payload FROM conflicts WHERE account_id = ? ORDER BY created_at DESC"
        } else {
            sql = "SELECT payload FROM conflicts WHERE account_id = ? AND state = ? ORDER BY created_at DESC"
        }
        return try withStatement(sql) { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            if let state { bind(state.rawValue, to: statement, at: 2) }
            var result: [ConflictRecord] = []
            while try step(statement) {
                guard let data = sqlite3_column_blob(statement, 0) else { continue }
                let size = Int(sqlite3_column_bytes(statement, 0))
                result.append(try decoder.decode(ConflictRecord.self, from: Data(bytes: data, count: size)))
            }
            return result
        }
    }

    public func resolveConflict(
        id: UUID,
        accountID: UUID,
        decision: ConflictResolutionDecision,
        resolvedName: String?,
        resolvedAt: Date
    ) async throws {
        let conflicts = try await conflicts(accountID: accountID, state: nil)
        guard var conflict = conflicts.first(where: { $0.id == id }) else { throw WesomeCloudError.missingItem(id.uuidString) }
        conflict.state = .resolved
        conflict.selectedResolution = decision
        conflict.resolvedName = resolvedName
        conflict.resolvedAt = resolvedAt
        try await recordConflict(conflict, accountID: accountID)
    }

    public func syncCursor(accountID: UUID, remotePath: String) async throws -> String? {
        try withStatement("SELECT sync_token FROM sync_cursors WHERE account_id = ? AND remote_path = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            bind(Self.normalizedRemotePath(remotePath), to: statement, at: 2)
            return try step(statement) ? columnText(statement, "sync_token") : nil
        }
    }

    public func setSyncCursor(_ cursor: String?, accountID: UUID, remotePath: String) async throws {
        let path = Self.normalizedRemotePath(remotePath)
        if let cursor {
            try withStatement("""
            INSERT INTO sync_cursors (account_id, remote_path, sync_token, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, remote_path) DO UPDATE SET
                sync_token=excluded.sync_token,
                updated_at=excluded.updated_at
            """) { statement in
                bind(accountID.uuidString, to: statement, at: 1)
                bind(path, to: statement, at: 2)
                bind(cursor, to: statement, at: 3)
                bind(Date().timeIntervalSince1970, to: statement, at: 4)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
        } else {
            try withStatement("DELETE FROM sync_cursors WHERE account_id = ? AND remote_path = ?") { statement in
                bind(accountID.uuidString, to: statement, at: 1)
                bind(path, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try queryInt("PRAGMA user_version")
    }

    private func migrate() throws {
        let version = try schemaVersion()
        guard version <= Self.currentSchemaVersion else {
            throw SQLiteStoreError.unsupportedSchemaVersion(version, supported: Self.currentSchemaVersion)
        }

        try transaction {
            try createCurrentSchema()
            try addMissingItemsCreatedAtColumn()
            try addMissingItemMetadataColumns()
            try createChangeJournal()
            let addedPendingRetryColumns = try addMissingPendingOperationRetryColumns()
            if addedPendingRetryColumns {
                try migratePendingOperationRetryColumnsFromPayload()
            }
            if version < Self.currentSchemaVersion {
                try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
            }
        }
    }

    private func createCurrentSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS items (
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
            quota_used_bytes INTEGER,
            quota_available_bytes INTEGER,
            private_link TEXT,
            availability_intent TEXT NOT NULL DEFAULT 'unspecified',
            materialized_url TEXT,
            last_seen REAL NOT NULL,
            PRIMARY KEY (account_id, item_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS items_account_file_id ON items(account_id, file_id)")
        try execute("CREATE INDEX IF NOT EXISTS items_parent_name ON items(account_id, parent_id, name)")
        try execute("CREATE INDEX IF NOT EXISTS items_path ON items(account_id, path)")
        try execute("CREATE INDEX IF NOT EXISTS items_etag ON items(account_id, etag)")
        try execute("""
        CREATE TABLE IF NOT EXISTS pending_operations (
            account_id TEXT NOT NULL,
            operation_id TEXT NOT NULL PRIMARY KEY,
            kind TEXT NOT NULL,
            item_id TEXT NOT NULL,
            source_path TEXT,
            destination_path TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL NOT NULL DEFAULT 0,
            last_error_description TEXT,
            payload BLOB NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS pending_account_kind ON pending_operations(account_id, kind, created_at)")
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_errors (
            account_id TEXT NOT NULL,
            error_id TEXT NOT NULL,
            scope TEXT NOT NULL,
            item_id TEXT,
            operation_id TEXT,
            message TEXT NOT NULL,
            recoverable INTEGER NOT NULL,
            occurred_at REAL NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (account_id, error_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS sync_errors_account_scope ON sync_errors(account_id, scope, occurred_at)")
        try execute("CREATE INDEX IF NOT EXISTS sync_errors_item ON sync_errors(account_id, item_id)")
        try execute("""
        CREATE TABLE IF NOT EXISTS transfers (
            account_id TEXT NOT NULL,
            transfer_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            phase TEXT NOT NULL,
            bytes_transferred INTEGER NOT NULL,
            total_bytes INTEGER,
            remote_path TEXT NOT NULL,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY (account_id, transfer_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS transfers_account_phase ON transfers(account_id, phase, updated_at)")
        try execute("CREATE INDEX IF NOT EXISTS transfers_item ON transfers(account_id, item_id)")
        try execute("""
        CREATE TABLE IF NOT EXISTS conflicts (
            account_id TEXT NOT NULL,
            conflict_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            created_at REAL NOT NULL,
            resolved_at REAL,
            payload BLOB NOT NULL,
            PRIMARY KEY (account_id, conflict_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS conflicts_account_state ON conflicts(account_id, state, created_at)")
        try execute("CREATE INDEX IF NOT EXISTS conflicts_item ON conflicts(account_id, item_id)")
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_cursors (
            account_id TEXT NOT NULL,
            remote_path TEXT NOT NULL,
            sync_token TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, remote_path)
        )
        """)
    }

    // Triggers run in the metadata writer's transaction, including writes from the app.
    // Keep 100,000 events globally. The retained floor survives pruning an account.
    private func createChangeJournal() throws {
        try execute("CREATE TABLE IF NOT EXISTS provider_journal_state (id INTEGER PRIMARY KEY CHECK(id = 1), epoch TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0, floor INTEGER NOT NULL DEFAULT 0)")
        try execute("INSERT OR IGNORE INTO provider_journal_state(id, epoch) VALUES (1, '\(UUID().uuidString)')")
        try execute("CREATE TABLE IF NOT EXISTS provider_changes AS SELECT CAST(0 AS INTEGER) AS sequence, CAST(NULL AS TEXT) AS previous_parent_id, CAST(0 AS INTEGER) AS had_previous, CAST(0 AS INTEGER) AS deleted, CAST(NULL AS BLOB) AS transfer_payload, CAST(NULL AS TEXT) AS presentation_scope, CAST(NULL AS BLOB) AS presentation_payload, items.* FROM items WHERE 0")
        try execute("CREATE TABLE IF NOT EXISTS provider_presentations (scope TEXT PRIMARY KEY, configuration BLOB NOT NULL)")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS provider_changes_sequence ON provider_changes(sequence)")
        let columns = ["account_id", "item_id", "parent_id", "name", "path", "kind", "size", "etag", "file_id", "checksum", "permissions", "created_at", "modified_at", "content_type", "quota_used_bytes", "quota_available_bytes", "private_link", "availability_intent", "materialized_url", "last_seen"]
        let copiedColumns = columns.joined(separator: ", ")
        func record(row: String, previousParent: String, deleted: Bool, hadPrevious: Bool = true, source: String = "") -> String {
            """
            UPDATE provider_journal_state SET position = position + 1 WHERE id = 1;
            INSERT INTO provider_changes (sequence, previous_parent_id, had_previous, deleted, transfer_payload, \(copiedColumns))
            SELECT (SELECT position FROM provider_journal_state WHERE id = 1), \(previousParent), \(hadPrevious ? 1 : 0), \(deleted ? 1 : 0),
                (SELECT payload FROM transfers WHERE account_id = \(row).account_id AND item_id = \(row).item_id ORDER BY updated_at DESC LIMIT 1),
                \(columns.map { "\(row).\($0)" }.joined(separator: ", "))\(source);
            UPDATE provider_journal_state SET floor = MAX(floor, position - 100000) WHERE id = 1;
            DELETE FROM provider_changes WHERE sequence <= (SELECT floor FROM provider_journal_state WHERE id = 1);
            """
        }
        try execute("CREATE TRIGGER IF NOT EXISTS provider_item_insert AFTER INSERT ON items BEGIN \(record(row: "NEW", previousParent: "NULL", deleted: false, hadPrevious: false)) END")
        let changed = columns.filter { $0 != "last_seen" && $0 != "account_id" }.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
        try execute("CREATE TRIGGER IF NOT EXISTS provider_item_update AFTER UPDATE ON items WHEN \(changed) BEGIN \(record(row: "NEW", previousParent: "OLD.parent_id", deleted: false)) END")
        try execute("CREATE TRIGGER IF NOT EXISTS provider_item_delete AFTER DELETE ON items BEGIN \(record(row: "OLD", previousParent: "OLD.parent_id", deleted: true)) END")
        // A transfer's byte counter is not exposed by ProviderItem. Only journal state/error changes.
        for operation in ["INSERT", "UPDATE", "DELETE"] {
            let row = operation == "DELETE" ? "OLD" : "NEW"
            let condition = operation == "UPDATE" ? "WHEN OLD.phase IS NOT NEW.phase OR OLD.direction IS NOT NEW.direction OR json_extract(OLD.payload, '$.lastErrorDescription') IS NOT json_extract(NEW.payload, '$.lastErrorDescription')" : ""
            let body = record(row: "i", previousParent: "i.parent_id", deleted: false,
                              source: " FROM items i WHERE i.account_id = \(row).account_id AND i.item_id = \(row).item_id")
            try execute("CREATE TRIGGER IF NOT EXISTS provider_transfer_\(operation.lowercased()) AFTER \(operation) ON transfers \(condition) BEGIN \(body) END")
        }
    }

    /// Configuration changes are discovered by readers, then journaled exactly once
    /// across processes. Building both presentations inside the transaction prevents
    /// metadata writes from slipping between the comparison and its journal entries.
    public func reconcileProviderPresentation(scope: String, configuration: Data, changes: (Data?) throws -> [ProviderPresentationChange]) throws {
        try transaction {
            let previous = try withStatement("SELECT configuration FROM provider_presentations WHERE scope = ?") { statement in
                bind(scope, to: statement, at: 1)
                return try step(statement) ? columnData(statement, "configuration") : nil
            }
            guard previous != configuration else { return }
            for change in try changes(previous) {
                try execute("UPDATE provider_journal_state SET position = position + 1 WHERE id = 1")
                try withStatement("INSERT INTO provider_changes(sequence, presentation_scope, presentation_payload, deleted, previous_parent_id, had_previous) SELECT position, ?, ?, ?, ?, ? FROM provider_journal_state WHERE id = 1") { statement in
                    bind(scope, to: statement, at: 1)
                    bind(change.payload, to: statement, at: 2)
                    bind(change.deleted ? 1 : 0, to: statement, at: 3)
                    bind(change.previousParentID, to: statement, at: 4)
                    bind(change.hadPrevious ? 1 : 0, to: statement, at: 5)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                }
            }
            try withStatement("INSERT INTO provider_presentations(scope, configuration) VALUES (?, ?) ON CONFLICT(scope) DO UPDATE SET configuration=excluded.configuration") { statement in
                bind(scope, to: statement, at: 1)
                bind(configuration, to: statement, at: 2)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            try execute("UPDATE provider_journal_state SET floor = MAX(floor, position - 100000) WHERE id = 1")
            try execute("DELETE FROM provider_changes WHERE sequence <= (SELECT floor FROM provider_journal_state WHERE id = 1)")
        }
    }

    public func providerJournalState() throws -> ProviderJournalState {
        try withStatement("SELECT epoch, position, floor FROM provider_journal_state WHERE id = 1") { statement in
            guard try step(statement), let epoch = columnText(statement, "epoch") else { throw lastError() }
            return ProviderJournalState(epoch: epoch, position: columnInt64(statement, "position") ?? 0, floor: columnInt64(statement, "floor") ?? 0)
        }
    }

    public func providerChanges(after position: Int64, through upperBound: Int64, limit: Int) throws -> [StoredProviderChange] {
        var result: [StoredProviderChange] = []
        try transaction {
            let state = try providerJournalState()
            guard position >= state.floor, position <= upperBound, upperBound <= state.position else { throw ProviderJournalError.expired }
            try withStatement("SELECT * FROM provider_changes WHERE sequence > ? AND sequence <= ? ORDER BY sequence LIMIT ?") { statement in
                bind(position, to: statement, at: 1)
                bind(upperBound, to: statement, at: 2)
                bind(max(1, min(1000, limit)), to: statement, at: 3)
                while try step(statement) {
                    let account = columnText(statement, "account_id").flatMap(UUID.init(uuidString:))
                    var transfer: TransferRecord?
                    let index = columnIndex(statement, "transfer_payload")
                    if let bytes = sqlite3_column_blob(statement, index) {
                        transfer = try decoder.decode(TransferRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
                    }
                    result.append(StoredProviderChange(sequence: columnInt64(statement, "sequence") ?? 0, accountID: account, item: columnText(statement, "presentation_scope") == nil ? try readStoredItem(statement) : nil, previousParentID: columnText(statement, "previous_parent_id"), hadPrevious: columnInt64(statement, "had_previous") == 1, deleted: columnInt64(statement, "deleted") == 1, transfer: transfer, presentationScope: columnText(statement, "presentation_scope"), presentationPayload: columnData(statement, "presentation_payload")))
                }
            }
        }
        return result
    }

    private func updateSingleItem(sql: String, values: [String?], itemID: String) throws {
        try withStatement(sql) { statement in
            for (index, value) in values.enumerated() {
                bind(value, to: statement, at: Int32(index + 1))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            guard sqlite3_changes(database) == 1 else { throw WesomeCloudError.missingItem(itemID) }
        }
    }

    private func executeAccountDeletes(_ statements: [String], accountID: UUID) throws {
        try transaction {
            for sql in statements {
                try withStatement(sql) { statement in
                    bind(accountID.uuidString, to: statement, at: 1)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                }
            }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Steps a query: true for a row, false when done, throws on BUSY/ERROR instead of
    /// silently ending the result set early.
    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw lastError()
        }
    }

    private func executeItemDelete(
        _ sql: String,
        accountID: String,
        itemID: String,
        bindAccountIDTwice: Bool = false
    ) throws {
        try withStatement(sql) { statement in
            bind(accountID, to: statement, at: 1)
            if bindAccountIDTwice {
                bind(accountID, to: statement, at: 2)
                bind(itemID, to: statement, at: 3)
            } else {
                bind(itemID, to: statement, at: 2)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    private func readStoredItem(_ statement: OpaquePointer) throws -> StoredItem {
        guard let kind = columnText(statement, "kind").flatMap(RemoteItemKind.init(rawValue:)) else {
            throw SQLiteStoreError.sqlite("Unknown item kind \(columnText(statement, "kind") ?? "nil")")
        }
        let remote = RemoteItem(
            id: columnText(statement, "item_id")!,
            parentID: columnText(statement, "parent_id"),
            name: columnText(statement, "name")!,
            path: columnText(statement, "path")!,
            kind: kind,
            size: columnInt64(statement, "size"),
            etag: columnText(statement, "etag"),
            fileID: columnText(statement, "file_id"),
            checksum: columnText(statement, "checksum"),
            permissions: columnText(statement, "permissions"),
            createdAt: columnDouble(statement, "created_at").map(Date.init(timeIntervalSince1970:)),
            modifiedAt: columnDouble(statement, "modified_at").map(Date.init(timeIntervalSince1970:)),
            contentType: columnText(statement, "content_type"),
            quotaUsedBytes: columnInt64(statement, "quota_used_bytes"),
            quotaAvailableBytes: columnInt64(statement, "quota_available_bytes"),
            privateLink: columnText(statement, "private_link").flatMap(URL.init(string:))
        )
        return StoredItem(
            remote: remote,
            availabilityIntent: AvailabilityIntent(rawValue: columnText(statement, "availability_intent")!) ?? .unspecified,
            materializedURL: columnText(statement, "materialized_url").map { URL(fileURLWithPath: $0) },
            lastSeen: Date(timeIntervalSince1970: columnDouble(statement, "last_seen") ?? 0)
        )
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func addMissingItemsCreatedAtColumn() throws {
        guard try tableExists("items"), !(try table("items", hasColumn: "created_at")) else { return }
        try execute("ALTER TABLE items ADD COLUMN created_at REAL")
    }

    private func addMissingItemMetadataColumns() throws {
        guard try tableExists("items") else { return }
        if try !table("items", hasColumn: "quota_used_bytes") {
            try execute("ALTER TABLE items ADD COLUMN quota_used_bytes INTEGER")
        }
        if try !table("items", hasColumn: "quota_available_bytes") {
            try execute("ALTER TABLE items ADD COLUMN quota_available_bytes INTEGER")
        }
        if try !table("items", hasColumn: "private_link") {
            try execute("ALTER TABLE items ADD COLUMN private_link TEXT")
        }
    }

    private func addMissingPendingOperationRetryColumns() throws -> Bool {
        guard try tableExists("pending_operations") else { return false }
        var added = false
        if try !table("pending_operations", hasColumn: "source_path") {
            try execute("ALTER TABLE pending_operations ADD COLUMN source_path TEXT")
            added = true
        }
        if try !table("pending_operations", hasColumn: "destination_path") {
            try execute("ALTER TABLE pending_operations ADD COLUMN destination_path TEXT")
            added = true
        }
        if try !table("pending_operations", hasColumn: "attempt_count") {
            try execute("ALTER TABLE pending_operations ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0")
            added = true
        }
        if try !table("pending_operations", hasColumn: "next_attempt_at") {
            try execute("ALTER TABLE pending_operations ADD COLUMN next_attempt_at REAL NOT NULL DEFAULT 0")
            added = true
        }
        if try !table("pending_operations", hasColumn: "last_error_description") {
            try execute("ALTER TABLE pending_operations ADD COLUMN last_error_description TEXT")
            added = true
        }
        try execute("CREATE INDEX IF NOT EXISTS pending_account_due ON pending_operations(account_id, next_attempt_at, created_at)")
        return added
    }

    private func tableExists(_ tableName: String) throws -> Bool {
        try withStatement("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?") { statement in
            bind(tableName, to: statement, at: 1)
            return try step(statement)
        }
    }

    private func table(_ tableName: String, hasColumn columnName: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(tableName))") { statement in
            while try step(statement) {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == columnName {
                    return true
                }
            }
            return false
        }
    }

    private func queryInt(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func lastError() -> SQLiteStoreError {
        SQLiteStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        var normalized = path.hasPrefix("/") ? path : "/" + path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

public enum SQLiteStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlite(String)
    case unsupportedSchemaVersion(Int, supported: Int)
}

private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
}

private func bind(_ value: Int64?, to statement: OpaquePointer, at index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, value)
}

private func bind(_ value: Int, to statement: OpaquePointer, at index: Int32) {
    sqlite3_bind_int(statement, index, Int32(value))
}

private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_double(statement, index, value)
}

private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
    _ = value.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnText(_ statement: OpaquePointer, _ name: String) -> String? {
    let index = columnIndex(statement, name)
    guard sqlite3_column_type(statement, index) != SQLITE_NULL, let text = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: text)
}

private func columnInt64(_ statement: OpaquePointer, _ name: String) -> Int64? {
    let index = columnIndex(statement, name)
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
}

private func columnDouble(_ statement: OpaquePointer, _ name: String) -> Double? {
    let index = columnIndex(statement, name)
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

private func columnIndex(_ statement: OpaquePointer, _ name: String) -> Int32 {
    for index in 0..<sqlite3_column_count(statement) {
        if String(cString: sqlite3_column_name(statement, index)) == name {
            return index
        }
    }
    preconditionFailure("Missing SQLite column \(name)")
}

private func columnData(_ statement: OpaquePointer, _ name: String) -> Data? {
    let index = columnIndex(statement, name)
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}
