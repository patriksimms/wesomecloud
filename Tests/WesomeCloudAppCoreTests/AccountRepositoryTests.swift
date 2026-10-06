import Foundation
import SQLite3
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

@Test
func jsonAccountRepositoryPersistsRecordsAndStatusAcrossInstances() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(
        account: account,
        domain: CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "alice"),
        serverVersion: "10.15.0"
    )

    do {
        let repository = JSONAccountRepository(fileURL: fileURL)
        try await repository.save(record)
        try await repository.updateStatus(SyncStatusSnapshot(state: .syncing, message: "Uploading"), accountID: account.id)
    }

    let reopened = JSONAccountRepository(fileURL: fileURL)
    let records = try await reopened.records()

    #expect(records.count == 1)
    #expect(records[0].account == account)
    #expect(records[0].domain == record.domain)
    #expect(records[0].lastSyncStatus.state == .syncing)
    #expect(records[0].lastSyncStatus.message == "Uploading")
    let raw = try Data(contentsOf: fileURL)
    let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
    #expect(json?["schemaVersion"] as? Int == JSONAccountRepository.currentSchemaVersion)
    #expect(json?["accounts"] is [[String: Any]])
}

@Test
func jsonAccountRepositoryMigratesLegacyArrayDocumentsOnNextWrite() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let encoder = JSONEncoder()
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode([record]).write(to: fileURL, options: [.atomic])

    let repository = JSONAccountRepository(fileURL: fileURL)
    #expect(try await repository.records().map(\.id) == [account.id])

    try await repository.updateStatus(SyncStatusSnapshot(state: .syncing, message: "Migrated"), accountID: account.id)

    let raw = try Data(contentsOf: fileURL)
    let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
    #expect(json?["schemaVersion"] as? Int == JSONAccountRepository.currentSchemaVersion)
    let reopened = JSONAccountRepository(fileURL: fileURL)
    #expect(try await reopened.records().first?.lastSyncStatus.message == "Migrated")
}

@Test
func jsonAccountRepositoryRejectsFutureSchemaDocuments() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    {
      "schemaVersion": \(JSONAccountRepository.currentSchemaVersion + 1),
      "accounts": []
    }
    """.utf8).write(to: fileURL, options: [.atomic])

    let repository = JSONAccountRepository(fileURL: fileURL)

    await #expect(throws: AccountRepositoryError.unsupportedSchemaVersion(
        JSONAccountRepository.currentSchemaVersion + 1,
        supported: JSONAccountRepository.currentSchemaVersion
    )) {
        _ = try await repository.records()
    }
}

@Test
func memoryAccountRepositorySortsAndDeletesRecords() async throws {
    let beta = PersistedAccountRecord(account: Account(serverURL: URL(string: "https://b.example/")!, username: "beta", displayName: "Beta"))
    let alpha = PersistedAccountRecord(account: Account(serverURL: URL(string: "https://a.example/")!, username: "alpha", displayName: "Alpha"))
    let repository = MemoryAccountRepository(records: [beta, alpha])

    #expect(try await repository.records().map(\.account.displayName) == ["Alpha", "Beta"])

    try await repository.delete(accountID: alpha.id)

    #expect(try await repository.records().map(\.id) == [beta.id])
}

@Test
func legacyOwnCloudAccountRepositoryParsesDesktopClientConfig() async throws {
    let configURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("cfg")
    try Data("""
    [Accounts]
    0\\url=https:\\/\\/cloud.example\\/
    0\\user=alice
    0\\displayName=Alice Cloud
    0\\serverVersion=10.15.0
    1\\url=https://beta.example/owncloud
    1\\dav_user=bob
    """.utf8).write(to: configURL, options: [.atomic])

    let repository = LegacyOwnCloudAccountRepository(configURLs: [configURL])
    let records = try await repository.records()

    #expect(records.map(\.account.displayName) == ["Alice Cloud", "bob"])
    #expect(records[0].account.serverURL.absoluteString == "https://cloud.example/")
    #expect(records[0].account.username == "alice")
    #expect(records[0].serverVersion == "10.15.0")
    #expect(records[0].lastSyncStatus.state == .error)
    #expect(records[0].lastSyncStatus.message.contains("Imported from the legacy ownCloud desktop client"))
    #expect(records[1].account.serverURL.absoluteString == "https://beta.example/owncloud/")
    #expect(records[1].account.username == "bob")
}

@Test
func legacyOwnCloudAccountRepositoryUsesStableAccountIDsAndDeduplicatesCandidates() async throws {
    let firstConfigURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("cfg")
    let secondConfigURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("cfg")
    let config = Data("""
    [Accounts]
    0\\url=https://cloud.example/
    0\\user=alice
    0\\displayName=Alice
    """.utf8)
    try config.write(to: firstConfigURL, options: [.atomic])
    try config.write(to: secondConfigURL, options: [.atomic])

    let first = try await LegacyOwnCloudAccountRepository(configURLs: [firstConfigURL, secondConfigURL]).records()
    let second = try await LegacyOwnCloudAccountRepository(configURLs: [secondConfigURL]).records()

    #expect(first.count == 1)
    #expect(first.first?.id == second.first?.id)
}

@Test
func compositeLegacyAccountRepositoryDeduplicatesByServerAndUsername() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice JSON")
    let duplicate = Account(id: UUID(), serverURL: URL(string: "https://cloud.example/")!, username: "ALICE", displayName: "Alice Legacy")
    let beta = Account(serverURL: URL(string: "https://beta.example/")!, username: "beta", displayName: "Beta")
    let repository = CompositeLegacyAccountRepository([
        MemoryAccountRepository(records: [PersistedAccountRecord(account: account)]),
        MemoryAccountRepository(records: [
            PersistedAccountRecord(account: duplicate),
            PersistedAccountRecord(account: beta),
        ]),
    ])

    let records = try await repository.records()

    #expect(records.map(\.account.displayName) == ["Alice JSON", "Beta"])
}

@Test
func sqliteAccountRepositoryPersistsRecordsStatusAndDeletesAcrossReopen() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let record = PersistedAccountRecord(
        account: account,
        domain: CloudDomain(
            id: "domain-\(account.id.uuidString)",
            accountID: account.id,
            displayName: "Alice Cloud",
            rootPath: "/Projects",
            webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
        ),
        serverVersion: "10.15.0",
        serverEdition: "Community"
    )

    do {
        let repository = try SQLiteAccountRepository(databaseURL: databaseURL)
        #expect(try repository.schemaVersion() == SQLiteAccountRepository.currentSchemaVersion)
        try await repository.save(record)
        try await repository.updateStatus(
            SyncStatusSnapshot(state: .syncing, message: "Uploading", updatedAt: Date(timeIntervalSince1970: 123)),
            accountID: account.id
        )
    }

    let reopened = try SQLiteAccountRepository(databaseURL: databaseURL)
    let records = try await reopened.records()

    #expect(records.count == 1)
    #expect(records.first?.account == account)
    #expect(records.first?.domain == record.domain)
    #expect(records.first?.serverVersion == "10.15.0")
    #expect(records.first?.serverEdition == "Community")
    #expect(records.first?.lastSyncStatus.state == .syncing)
    #expect(records.first?.lastSyncStatus.message == "Uploading")
    #expect(try await reopened.domains(accountID: account.id) == [try #require(record.domain)])

    try await reopened.delete(accountID: account.id)
    #expect(try await reopened.records().isEmpty)
    #expect(try await reopened.domains(accountID: account.id).isEmpty)
}

@Test
func sqliteAccountRepositoryPersistsMultipleDomainsAcrossReopen() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let primary = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "Alice Cloud")
    let space = CloudDomain(
        id: "\(account.id.uuidString)-space-1",
        accountID: account.id,
        displayName: "Alice Cloud - Marketing",
        rootPath: "/",
        webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
    )
    let otherAccount = Account(serverURL: URL(string: "https://beta.example/")!, username: "bob", displayName: "Bob")
    let otherDomain = CloudDomain(id: otherAccount.id.uuidString, accountID: otherAccount.id, displayName: "Bob")

    do {
        let repository = try SQLiteAccountRepository(databaseURL: databaseURL)
        try await repository.save(PersistedAccountRecord(account: account, domain: primary))
        try await repository.save(PersistedAccountRecord(account: otherAccount, domain: otherDomain))
        try await repository.saveDomain(space)
    }

    let reopened = try SQLiteAccountRepository(databaseURL: databaseURL)
    #expect(try await reopened.domains(accountID: account.id) == [primary, space])
    #expect(try await reopened.domains(accountID: nil) == [primary, space, otherDomain])

    try await reopened.deleteDomain(id: space.id)
    #expect(try await reopened.domains(accountID: account.id) == [primary])
}

@Test
func sqliteAccountRepositoryMigratesInlineDomainsIntoDomainTable() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
    let accountID = UUID()
    let domainID = "\(accountID.uuidString)-space-1"
    let record = PersistedAccountRecord(
        account: Account(id: accountID, serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice"),
        domain: CloudDomain(
            id: domainID,
            accountID: accountID,
            displayName: "Alice - Marketing",
            rootPath: "/",
            webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
        )
    )
    let payload = try JSONEncoder().encode(record)
    let encodedPayload = payload.map { String(format: "%02x", $0) }.joined()
    try executeSQLite("""
    CREATE TABLE accounts (
        account_id TEXT PRIMARY KEY,
        server_url TEXT NOT NULL,
        username TEXT NOT NULL,
        display_name TEXT NOT NULL,
        domain_id TEXT,
        domain_root_path TEXT,
        domain_webdav_root_url TEXT,
        server_version TEXT,
        server_edition TEXT,
        status_state TEXT NOT NULL,
        status_message TEXT NOT NULL,
        status_updated_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    INSERT INTO accounts (
        account_id, server_url, username, display_name, domain_id,
        domain_root_path, domain_webdav_root_url, status_state,
        status_message, status_updated_at, payload
    ) VALUES (
        '\(accountID.uuidString)', 'https://cloud.example/', 'alice', 'Alice',
        '\(domainID)', '/', 'https://cloud.example/dav/spaces/space-1',
        'idle', 'Connected', 0, x'\(encodedPayload)'
    );
    PRAGMA user_version = 2;
    """, databaseURL: databaseURL)

    let repository = try SQLiteAccountRepository(databaseURL: databaseURL)

    #expect(try repository.schemaVersion() == SQLiteAccountRepository.currentSchemaVersion)
    #expect(try await repository.domains(accountID: accountID) == [try #require(record.domain)])
}

@Test
func sqliteAccountRepositorySortsByDisplayName() async throws {
    let repository = try SQLiteAccountRepository(databaseURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension("sqlite"))
    let beta = PersistedAccountRecord(account: Account(serverURL: URL(string: "https://b.example/")!, username: "beta", displayName: "Beta"))
    let alpha = PersistedAccountRecord(account: Account(serverURL: URL(string: "https://a.example/")!, username: "alpha", displayName: "Alpha"))

    try await repository.save(beta)
    try await repository.save(alpha)

    #expect(try await repository.records().map(\.account.displayName) == ["Alpha", "Beta"])
}

@Test
func sqliteAccountRepositoryRejectsFutureSchemaDocuments() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("sqlite")
    try setSQLiteUserVersion(SQLiteAccountRepository.currentSchemaVersion + 1, databaseURL: databaseURL)

    #expect(throws: AccountRepositoryError.unsupportedSchemaVersion(
        SQLiteAccountRepository.currentSchemaVersion + 1,
        supported: SQLiteAccountRepository.currentSchemaVersion
    )) {
        _ = try SQLiteAccountRepository(databaseURL: databaseURL)
    }
}

@Test
func migratingAccountRepositoryCopiesLegacyJSONIntoEmptySQLiteStore() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let legacyURL = root.appending(path: "Accounts.json")
    let databaseURL = root.appending(path: "Accounts.sqlite")
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(
        account: account,
        domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice", rootPath: "/Projects"),
        serverVersion: "10.15.0"
    )
    let legacy = JSONAccountRepository(fileURL: legacyURL)
    try await legacy.save(record)
    let primary = try SQLiteAccountRepository(databaseURL: databaseURL)
    let repository = MigratingAccountRepository(primary: primary, legacy: legacy)

    #expect(try await repository.records() == [record])

    let reopened = try SQLiteAccountRepository(databaseURL: databaseURL)
    #expect(try await reopened.records() == [record])
}

private func setSQLiteUserVersion(_ version: Int, databaseURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw AccountRepositoryError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
        throw AccountRepositoryError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}

private func executeSQLite(_ sql: String, databaseURL: URL) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
        throw AccountRepositoryError.openFailed("Could not open test database")
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw AccountRepositoryError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
}
