import Foundation
import CryptoKit
import SQLite3
import WesomeCloudShared

public struct PersistedAccountRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { account.id }
    public var account: Account
    public var domain: CloudDomain?
    private var additionalDomains: [CloudDomain]?

    /// The first domain keeps the pre-Spaces account's cache and Finder identity.
    public var domains: [CloudDomain] {
        get { [domain].compactMap { $0 } + (additionalDomains ?? []) }
        set {
            domain = newValue.first
            additionalDomains = newValue.count == 1 ? nil : Array(newValue.dropFirst())
        }
    }

    public var metadataID: UUID { domain?.metadataID ?? id }
    public var locationName: String { domain?.displayName ?? account.displayName }

    public var syncLocations: [PersistedAccountRecord] {
        // A nil selection predates Spaces; an explicitly empty selection stays disconnected.
        domains.isEmpty && additionalDomains == nil ? [self] : domains.map { selecting($0) }
    }

    public func selecting(_ domain: CloudDomain) -> PersistedAccountRecord {
        var record = self
        record.domains = [domain]
        return record
    }
    public var serverVersion: String?
    public var serverEdition: String?
    public var serverPollInterval: TimeInterval?
    public var lastSyncStatus: SyncStatusSnapshot

    public init(
        account: Account,
        domain: CloudDomain? = nil,
        serverVersion: String? = nil,
        serverEdition: String? = nil,
        serverPollInterval: TimeInterval? = nil,
        lastSyncStatus: SyncStatusSnapshot = SyncStatusSnapshot()
    ) {
        self.account = account
        self.domain = domain
        self.serverVersion = serverVersion
        self.serverEdition = serverEdition
        self.serverPollInterval = serverPollInterval
        self.lastSyncStatus = lastSyncStatus
    }
}

public struct SyncStatusSnapshot: Codable, Equatable, Sendable {
    public var state: SyncStatusState
    public var message: String
    public var updatedAt: Date

    public init(state: SyncStatusState = .idle, message: String = "Idle", updatedAt: Date = Date()) {
        self.state = state
        self.message = message
        self.updatedAt = updatedAt
    }
}

public enum SyncStatusState: String, Codable, Equatable, Sendable {
    case idle
    case syncing
    case paused
    case offline
    case error
}

public protocol AccountRepository: Sendable {
    func records() async throws -> [PersistedAccountRecord]
    func save(_ record: PersistedAccountRecord) async throws
    func delete(accountID: UUID) async throws
    func updateStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws
}

public protocol CloudDomainRepository: Sendable {
    func domains(accountID: UUID?) async throws -> [CloudDomain]
    func saveDomain(_ domain: CloudDomain) async throws
    func deleteDomain(id: String) async throws
    func deleteDomains(accountID: UUID) async throws
}

public actor MemoryAccountRepository: AccountRepository, CloudDomainRepository {
    private var storage: [UUID: PersistedAccountRecord] = [:]
    private var domainsByID: [String: CloudDomain] = [:]

    public init(records: [PersistedAccountRecord] = []) {
        for record in records {
            storage[record.id] = record
            for domain in record.domains {
                domainsByID[domain.id] = domain
            }
        }
    }

    public func records() async throws -> [PersistedAccountRecord] {
        storage.values.sorted { $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending }
    }

    public func save(_ record: PersistedAccountRecord) async throws {
        storage[record.id] = record
        for domain in record.domains {
            domainsByID[domain.id] = domain
        }
    }

    public func delete(accountID: UUID) async throws {
        storage[accountID] = nil
        domainsByID = domainsByID.filter { $0.value.accountID != accountID }
    }

    public func updateStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws {
        guard var record = storage[accountID] else { throw WesomeCloudError.missingItem(accountID.uuidString) }
        record.lastSyncStatus = status
        storage[accountID] = record
    }

    public func domains(accountID: UUID?) async throws -> [CloudDomain] {
        domainsByID.values
            .filter { accountID == nil || $0.accountID == accountID }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func saveDomain(_ domain: CloudDomain) async throws {
        domainsByID[domain.id] = domain
    }

    public func deleteDomain(id: String) async throws {
        domainsByID[id] = nil
    }

    public func deleteDomains(accountID: UUID) async throws {
        domainsByID = domainsByID.filter { $0.value.accountID != accountID }
    }
}

public actor JSONAccountRepository: AccountRepository {
    public static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func records() async throws -> [PersistedAccountRecord] {
        try load().sorted { $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending }
    }

    public func save(_ record: PersistedAccountRecord) async throws {
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try persist(records)
    }

    public func delete(accountID: UUID) async throws {
        var records = try load()
        records.removeAll { $0.id == accountID }
        try persist(records)
    }

    public func updateStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == accountID }) else {
            throw WesomeCloudError.missingItem(accountID.uuidString)
        }
        records[index].lastSyncStatus = status
        try persist(records)
    }

    private func load() throws -> [PersistedAccountRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if let document = try? decoder.decode(AccountRepositoryDocument.self, from: data) {
            guard document.schemaVersion <= Self.currentSchemaVersion else {
                throw AccountRepositoryError.unsupportedSchemaVersion(document.schemaVersion, supported: Self.currentSchemaVersion)
            }
            return document.accounts
        }
        return try decoder.decode([PersistedAccountRecord].self, from: data)
    }

    private func persist(_ records: [PersistedAccountRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = AccountRepositoryDocument(schemaVersion: Self.currentSchemaVersion, accounts: records)
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
    }
}

public enum AccountRepositoryError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlite(String)
    case unsupportedSchemaVersion(Int, supported: Int)
}

private struct AccountRepositoryDocument: Codable {
    var schemaVersion: Int
    var accounts: [PersistedAccountRecord]
}

public final class SQLiteAccountRepository: AccountRepository, CloudDomainRepository, @unchecked Sendable {
    public static let currentSchemaVersion = 4

    private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw AccountRepositoryError.openFailed(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database")
        }
        self.database = handle
        // Shared with the File Provider extension; wait for its writes instead of failing with SQLITE_BUSY.
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    public func records() async throws -> [PersistedAccountRecord] {
        try withStatement("SELECT payload FROM accounts ORDER BY display_name COLLATE NOCASE") { statement in
            var records: [PersistedAccountRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(statement, 0) else { continue }
                records.append(try decoder.decode(PersistedAccountRecord.self, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))))
            }
            return records
        }
    }

    public func save(_ record: PersistedAccountRecord) async throws {
        let payload = try encoder.encode(record)
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("""
            INSERT INTO accounts (
                account_id, server_url, username, display_name, domain_id,
                domain_root_path, domain_webdav_root_url, server_version, server_edition, status_state,
                status_message, status_updated_at, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                server_url=excluded.server_url,
                username=excluded.username,
                display_name=excluded.display_name,
                domain_id=excluded.domain_id,
                domain_root_path=excluded.domain_root_path,
                domain_webdav_root_url=excluded.domain_webdav_root_url,
                server_version=excluded.server_version,
                server_edition=excluded.server_edition,
                status_state=excluded.status_state,
                status_message=excluded.status_message,
                status_updated_at=excluded.status_updated_at,
                payload=excluded.payload
            """) { statement in
                bind(record.id.uuidString, to: statement, at: 1)
                bind(record.account.serverURL.absoluteString, to: statement, at: 2)
                bind(record.account.username, to: statement, at: 3)
                bind(record.account.displayName, to: statement, at: 4)
                bind(record.domain?.id, to: statement, at: 5)
                bind(record.domain?.rootPath, to: statement, at: 6)
                bind(record.domain?.webDAVRootURL?.absoluteString, to: statement, at: 7)
                bind(record.serverVersion, to: statement, at: 8)
                bind(record.serverEdition, to: statement, at: 9)
                bind(record.lastSyncStatus.state.rawValue, to: statement, at: 10)
                bind(record.lastSyncStatus.message, to: statement, at: 11)
                bind(record.lastSyncStatus.updatedAt.timeIntervalSince1970, to: statement, at: 12)
                bind(payload, to: statement, at: 13)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            for domain in record.domains {
                try saveDomainInOpenTransaction(domain)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func delete(accountID: UUID) async throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("DELETE FROM domains WHERE account_id = ?") { statement in
                bind(accountID.uuidString, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            try withStatement("DELETE FROM accounts WHERE account_id = ?") { statement in
                bind(accountID.uuidString, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func updateStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws {
        var records = try await records()
        guard let index = records.firstIndex(where: { $0.id == accountID }) else {
            throw WesomeCloudError.missingItem(accountID.uuidString)
        }
        records[index].lastSyncStatus = status
        try await save(records[index])
    }

    public func schemaVersion() throws -> Int {
        try queryInt("PRAGMA user_version")
    }

    public func domains(accountID: UUID? = nil) async throws -> [CloudDomain] {
        let sql: String
        if accountID == nil {
            sql = "SELECT domain_id, account_id, display_name, root_path, webdav_root_url, metadata_id FROM domains ORDER BY display_name COLLATE NOCASE"
        } else {
            sql = "SELECT domain_id, account_id, display_name, root_path, webdav_root_url, metadata_id FROM domains WHERE account_id = ? ORDER BY display_name COLLATE NOCASE"
        }
        return try withStatement(sql) { statement in
            if let accountID {
                bind(accountID.uuidString, to: statement, at: 1)
            }
            var result: [CloudDomain] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try readDomain(statement))
            }
            return result
        }
    }

    public func saveDomain(_ domain: CloudDomain) async throws {
        try saveDomainInOpenTransaction(domain)
    }

    public func deleteDomain(id: String) async throws {
        try withStatement("DELETE FROM domains WHERE domain_id = ?") { statement in
            bind(id, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    public func deleteDomains(accountID: UUID) async throws {
        try withStatement("DELETE FROM domains WHERE account_id = ?") { statement in
            bind(accountID.uuidString, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    private func migrate() throws {
        let version = try schemaVersion()
        guard version <= Self.currentSchemaVersion else {
            throw AccountRepositoryError.unsupportedSchemaVersion(version, supported: Self.currentSchemaVersion)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
            CREATE TABLE IF NOT EXISTS accounts (
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
            )
            """)
            try execute("""
            CREATE TABLE IF NOT EXISTS domains (
                domain_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                root_path TEXT NOT NULL,
                webdav_root_url TEXT
            )
            """)
            if version < 2 {
                try addColumnIfNeeded(table: "accounts", column: "domain_webdav_root_url", definition: "TEXT")
            }
            try addColumnIfNeeded(table: "domains", column: "metadata_id", definition: "TEXT")
            if version < 3 {
                try migrateInlineAccountDomains()
            }
            try execute("CREATE INDEX IF NOT EXISTS accounts_display_name ON accounts(display_name COLLATE NOCASE)")
            try execute("CREATE INDEX IF NOT EXISTS accounts_domain_id ON accounts(domain_id)")
            try execute("CREATE INDEX IF NOT EXISTS domains_account_id ON domains(account_id)")
            try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func saveDomainInOpenTransaction(_ domain: CloudDomain) throws {
        try withStatement("""
        INSERT INTO domains (domain_id, account_id, display_name, root_path, webdav_root_url, metadata_id)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(domain_id) DO UPDATE SET
            account_id=excluded.account_id,
            display_name=excluded.display_name,
            root_path=excluded.root_path,
            webdav_root_url=excluded.webdav_root_url,
            metadata_id=excluded.metadata_id
        """) { statement in
            bind(domain.id, to: statement, at: 1)
            bind(domain.accountID.uuidString, to: statement, at: 2)
            bind(domain.displayName, to: statement, at: 3)
            bind(domain.rootPath, to: statement, at: 4)
            bind(domain.webDAVRootURL?.absoluteString, to: statement, at: 5)
            bind(domain.storageID?.uuidString, to: statement, at: 6)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        }
    }

    private func migrateInlineAccountDomains() throws {
        var didMigratePayloadDomainIDs = Set<String>()
        try withStatement("SELECT payload FROM accounts WHERE domain_id IS NOT NULL") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(statement, 0) else { continue }
                let record = try decoder.decode(
                    PersistedAccountRecord.self,
                    from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
                )
                if let domain = record.domain {
                    try saveDomainInOpenTransaction(domain)
                    didMigratePayloadDomainIDs.insert(domain.id)
                }
            }
        }
        try withStatement("""
        SELECT domain_id, account_id, display_name, COALESCE(domain_root_path, '/'), domain_webdav_root_url
        FROM accounts
        WHERE domain_id IS NOT NULL
        """) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let domainID = String(cString: sqlite3_column_text(statement, 0))
                guard !didMigratePayloadDomainIDs.contains(domainID),
                      let accountID = UUID(uuidString: String(cString: sqlite3_column_text(statement, 1)))
                else {
                    continue
                }
                try saveDomainInOpenTransaction(CloudDomain(
                    id: domainID,
                    accountID: accountID,
                    displayName: String(cString: sqlite3_column_text(statement, 2)),
                    rootPath: String(cString: sqlite3_column_text(statement, 3)),
                    webDAVRootURL: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : URL(string: String(cString: sqlite3_column_text(statement, 4)))
                ))
            }
        }
    }

    private func readDomain(_ statement: OpaquePointer) throws -> CloudDomain {
        guard let accountID = UUID(uuidString: String(cString: sqlite3_column_text(statement, 1))) else {
            throw AccountRepositoryError.sqlite("Invalid domain account ID")
        }
        return CloudDomain(
            id: String(cString: sqlite3_column_text(statement, 0)),
            accountID: accountID,
            displayName: String(cString: sqlite3_column_text(statement, 2)),
            rootPath: String(cString: sqlite3_column_text(statement, 3)),
            webDAVRootURL: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : URL(string: String(cString: sqlite3_column_text(statement, 4))),
            storageID: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : UUID(uuidString: String(cString: sqlite3_column_text(statement, 5)))
        )
    }

    private func addColumnIfNeeded(table: String, column: String, definition: String) throws {
        guard try !columns(in: table).contains(column) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func columns(in table: String) throws -> Set<String> {
        try withStatement("PRAGMA table_info(\(table))") { statement in
            var names = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 1) else { continue }
                names.insert(String(cString: text))
            }
            return names
        }
    }

    private func queryInt(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func lastError() -> AccountRepositoryError {
        AccountRepositoryError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

public actor MigratingAccountRepository: AccountRepository, CloudDomainRepository {
    private let primary: AccountRepository
    private let legacy: AccountRepository
    private var didMigrate = false

    public init(primary: AccountRepository, legacy: AccountRepository) {
        self.primary = primary
        self.legacy = legacy
    }

    public func records() async throws -> [PersistedAccountRecord] {
        try await migrateIfNeeded()
        return try await primary.records()
    }

    public func save(_ record: PersistedAccountRecord) async throws {
        try await migrateIfNeeded()
        try await primary.save(record)
    }

    public func delete(accountID: UUID) async throws {
        try await migrateIfNeeded()
        try await primary.delete(accountID: accountID)
    }

    public func updateStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws {
        try await migrateIfNeeded()
        try await primary.updateStatus(status, accountID: accountID)
    }

    public func domains(accountID: UUID?) async throws -> [CloudDomain] {
        try await migrateIfNeeded()
        guard let repository = primary as? CloudDomainRepository else { return [] }
        return try await repository.domains(accountID: accountID)
    }

    public func saveDomain(_ domain: CloudDomain) async throws {
        try await migrateIfNeeded()
        guard let repository = primary as? CloudDomainRepository else { return }
        try await repository.saveDomain(domain)
    }

    public func deleteDomain(id: String) async throws {
        try await migrateIfNeeded()
        guard let repository = primary as? CloudDomainRepository else { return }
        try await repository.deleteDomain(id: id)
    }

    public func deleteDomains(accountID: UUID) async throws {
        try await migrateIfNeeded()
        guard let repository = primary as? CloudDomainRepository else { return }
        try await repository.deleteDomains(accountID: accountID)
    }

    private func migrateIfNeeded() async throws {
        guard !didMigrate else { return }
        didMigrate = true
        guard try await primary.records().isEmpty else { return }
        let legacyRecords = try await legacy.records()
        for record in legacyRecords {
            try await primary.save(record)
        }
    }
}

public struct CompositeLegacyAccountRepository: AccountRepository {
    private let repositories: [AccountRepository]

    public init(_ repositories: [AccountRepository]) {
        self.repositories = repositories
    }

    public func records() async throws -> [PersistedAccountRecord] {
        var recordsByKey: [String: PersistedAccountRecord] = [:]
        for repository in repositories {
            for record in try await repository.records() {
                let key = "\(record.account.serverURL.absoluteString.lowercased())\n\(record.account.username.lowercased())"
                recordsByKey[key] = recordsByKey[key] ?? record
            }
        }
        return recordsByKey.values.sorted {
            $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending
        }
    }

    public func save(_: PersistedAccountRecord) async throws {
        throw WesomeCloudError.unsupported("Composite legacy account repositories are read-only")
    }

    public func delete(accountID _: UUID) async throws {
        throw WesomeCloudError.unsupported("Composite legacy account repositories are read-only")
    }

    public func updateStatus(_: SyncStatusSnapshot, accountID _: UUID) async throws {
        throw WesomeCloudError.unsupported("Composite legacy account repositories are read-only")
    }
}

public struct LegacyOwnCloudAccountRepository: AccountRepository {
    private let configURLs: [URL]

    public init(configURLs: [URL]) {
        self.configURLs = configURLs
    }

    public static func defaultConfigURLs(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            homeDirectory.appending(path: "Library/Preferences/ownCloud/owncloud.cfg"),
            homeDirectory.appending(path: "Library/Application Support/ownCloud/owncloud.cfg"),
            homeDirectory.appending(path: ".config/ownCloud/owncloud.cfg"),
        ]
    }

    public func records() async throws -> [PersistedAccountRecord] {
        var recordsByKey: [String: PersistedAccountRecord] = [:]
        for url in configURLs where FileManager.default.fileExists(atPath: url.path) {
            let records = try Self.parseConfig(Data(contentsOf: url))
            for record in records {
                let key = "\(record.account.serverURL.absoluteString.lowercased())\n\(record.account.username.lowercased())"
                recordsByKey[key] = recordsByKey[key] ?? record
            }
        }
        return recordsByKey.values.sorted {
            $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending
        }
    }

    public func save(_: PersistedAccountRecord) async throws {
        throw WesomeCloudError.unsupported("Legacy ownCloud account import is read-only")
    }

    public func delete(accountID _: UUID) async throws {
        throw WesomeCloudError.unsupported("Legacy ownCloud account import is read-only")
    }

    public func updateStatus(_: SyncStatusSnapshot, accountID _: UUID) async throws {
        throw WesomeCloudError.unsupported("Legacy ownCloud account import is read-only")
    }

    public static func parseConfig(_ data: Data) throws -> [PersistedAccountRecord] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        let values = parseINI(text)
        var accountBuckets: [String: [String: String]] = [:]
        for (key, value) in values {
            guard let accountKey = legacyAccountKey(from: key) else { continue }
            accountBuckets[accountKey.index, default: [:]][accountKey.name] = value
        }

        return accountBuckets.values.compactMap { fields in
            guard
                let rawURL = fields["url"] ?? fields["serverurl"] ?? fields["server"],
                let serverURL = URL(string: rawURL.normalizedLegacyServerURL),
                let username = fields["user"] ?? fields["dav_user"] ?? fields["username"],
                !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            let displayName = fields["displayname"] ?? fields["display_name"] ?? username
            let account = Account(
                id: deterministicAccountID(serverURL: serverURL, username: username),
                serverURL: serverURL,
                username: username,
                displayName: displayName
            )
            return PersistedAccountRecord(
                account: account,
                serverVersion: fields["serverversion"],
                serverEdition: fields["serveredition"],
                lastSyncStatus: SyncStatusSnapshot(
                    state: .error,
                    message: "Imported from the legacy ownCloud desktop client. Add credentials to reconnect."
                )
            )
        }.sorted {
            $0.account.displayName.localizedStandardCompare($1.account.displayName) == .orderedAscending
        }
    }

    private static func parseINI(_ text: String) -> [String: String] {
        var section = ""
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let fullKey = section.isEmpty ? name : "\(section)/\(name)"
            values[fullKey.lowercased()] = value.removingLegacyEscapes
        }
        return values
    }

    private static func legacyAccountKey(from key: String) -> (index: String, name: String)? {
        let separators = CharacterSet(charactersIn: "/\\")
        let parts = key.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let accountsIndex = parts.firstIndex(of: "accounts"), parts.count > accountsIndex + 2 else {
            return nil
        }
        return (parts[accountsIndex + 1], parts[accountsIndex + 2])
    }

    private static func deterministicAccountID(serverURL: URL, username: String) -> UUID {
        let seed = "\(serverURL.absoluteString.lowercased())\n\(username.lowercased())"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension String {
    var removingLegacyEscapes: String {
        replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    var normalizedLegacyServerURL: String {
        var value = trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value + "/"
    }
}

private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
}

private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) {
    sqlite3_bind_double(statement, index, value)
}

private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
    _ = value.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
