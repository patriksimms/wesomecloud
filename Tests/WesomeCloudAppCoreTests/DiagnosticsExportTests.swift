import Foundation
import Testing
import WesomeCloudAppCore
import WesomeCloudShared
import SyncStore
import SQLite3

@Test
func diagnosticsExporterWritesRedactedBundle() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let snapshot = AppSnapshot(
        accounts: [
            PersistedAccountRecord(
                account: account,
                domain: CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "Alice"),
                serverVersion: "10.15.0"
            )
        ],
        diagnostics: [
            DiagnosticEvent(date: Date(timeIntervalSince1970: 1), category: "Auth", level: .error, message: "password=secret token: abc Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
        ],
        crashReports: [
            CrashReport(
                occurredAt: Date(timeIntervalSince1970: 2),
                processName: "WesomeCloud",
                reason: "authorization=Bearer abc123",
                details: "token=very-secret"
            )
        ]
    )
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let exporter = DiagnosticsExporter(clock: { Date(timeIntervalSince1970: 123) })

    let url = try exporter.export(snapshot: snapshot, preferences: AppPreferences(), to: directory)

    #expect(url.pathExtension == "zip")
    let data = try diagnosticJSON(in: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let bundle = try decoder.decode(DiagnosticsExportBundle.self, from: data)
    #expect(bundle.accounts.first?.serverHost == "cloud.example")
    #expect(bundle.accounts.first?.username == DiagnosticRedactor.reference("alice"))
    #expect(bundle.events.first?.message.contains("secret") == false)
    #expect(bundle.events.first?.message.contains("[REDACTED]") == true)
    #expect(bundle.crashReports.first?.reason.contains("abc123") == false)
    #expect(bundle.crashReports.first?.details?.contains("very-secret") == false)
}

@Test
func appModelExportsDiagnosticsAndRecordsEvent() async throws {
    let diagnostics = AppDiagnosticBuffer()
    await diagnostics.record(DiagnosticEvent(category: "Test", level: .info, message: "hello"))
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        diagnostics: diagnostics
    )
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    let url = try await appModel.exportDiagnostics(to: directory, exporter: DiagnosticsExporter(clock: { Date(timeIntervalSince1970: 99) }))

    #expect(FileManager.default.fileExists(atPath: url.path))
    let snapshot = try await appModel.loadSnapshot()
    #expect(snapshot.diagnostics.contains { $0.category == "Diagnostics" })
}

@Test
func jsonCrashReportRepositoryPersistsReportsNewestFirst() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let repository = JSONCrashReportRepository(directory: directory)
    let older = CrashReport(
        id: UUID(),
        occurredAt: Date(timeIntervalSince1970: 1),
        processName: "WesomeCloud",
        reason: "old crash"
    )
    let newer = CrashReport(
        id: UUID(),
        occurredAt: Date(timeIntervalSince1970: 2),
        processName: "WesomeCloudFileProvider",
        reason: "new crash",
        details: "stack trace"
    )

    try await repository.save(older)
    try await repository.save(newer)

    let reopened = JSONCrashReportRepository(directory: directory)
    let reports = try await reopened.reports()
    #expect(reports.map(\.id) == [newer.id, older.id])

    try await reopened.delete(id: newer.id)
    #expect(try await reopened.reports().map(\.id) == [older.id])
}

@Test
func appModelRecordsCrashReportsInSnapshotAndDiagnostics() async throws {
    let crashReports = MemoryCrashReportRepository()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        crashReports: crashReports
    )
    let report = CrashReport(processName: "WesomeCloud", reason: "fatal error")

    try await appModel.recordCrashReport(report)

    let snapshot = try await appModel.loadSnapshot()
    #expect(snapshot.crashReports == [report])
    #expect(snapshot.diagnostics.contains { $0.category == "Crash" && $0.level == .error })
}

@Test
func diagnosticReportsCrashImporterImportsMatchingCrashAndIPSReports() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let crashReport = directory.appending(path: "WesomeCloud_2026-05-27-191500_Mac.crash")
    try """
    Process:               WesomeCloud [123]
    Path:                  /Applications/WesomeCloud.app/Contents/MacOS/WesomeCloud
    Date/Time:             2026-05-27 19:15:00.000 +0200
    Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
    Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11
    """.write(to: crashReport, atomically: true, encoding: .utf8)
    let ipsReport = directory.appending(path: "WesomeFileProviderExtension-2026-05-27-191600.ips")
    try """
    {
      "procName": "WesomeFileProviderExtension",
      "captureTime": "2026-05-27T17:16:00Z",
      "exception": "EXC_CRASH",
      "termination": "Namespace SIGNAL, Code 6 Abort trap: 6"
    }
    """.write(to: ipsReport, atomically: true, encoding: .utf8)
    let ignoredReport = directory.appending(path: "OtherApp_2026-05-27-191700_Mac.crash")
    try """
    Process:               OtherApp [456]
    Date/Time:             2026-05-27 19:17:00.000 +0200
    Exception Type:        EXC_CRASH
    """.write(to: ignoredReport, atomically: true, encoding: .utf8)
    let repository = MemoryCrashReportRepository()
    let importer = DiagnosticReportsCrashImporter(
        directories: [directory],
        appVersion: "0.1.0",
        buildNumber: "1"
    )

    let imported = try await importer.importReports(into: repository)
    let reimported = try await importer.importReports(into: repository)
    let reports = try await repository.reports()

    #expect(imported == 2)
    #expect(reimported == 0)
    #expect(reports.map(\.processName).sorted() == ["WesomeCloud", "WesomeFileProviderExtension"])
    #expect(reports.allSatisfy { $0.appVersion == "0.1.0" && $0.buildNumber == "1" })
    #expect(reports.contains { $0.reason.contains("EXC_BAD_ACCESS") && $0.reason.contains("Segmentation fault") })
    #expect(reports.contains { $0.reason.contains("EXC_CRASH") && $0.reason.contains("Abort trap") })
}

@Test
func diagnosticReportsCrashImporterSkipsUnreadableReportLocations() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let inaccessibleDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inaccessibleDirectory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inaccessibleDirectory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessibleDirectory.path)
        try? FileManager.default.removeItem(at: inaccessibleDirectory)
    }
    let crashReport = directory.appending(path: "WesomeCloud_2026-05-27-191500_Mac.crash")
    try """
    Process:               WesomeCloud [123]
    Date/Time:             2026-05-27 19:15:00.000 +0200
    Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
    """.write(to: crashReport, atomically: true, encoding: .utf8)
    let repository = MemoryCrashReportRepository()
    let importer = DiagnosticReportsCrashImporter(directories: [inaccessibleDirectory, directory])

    let imported = try await importer.importReports(into: repository)
    let reports = try await repository.reports()

    #expect(imported == 1)
    #expect(reports.map(\.processName) == ["WesomeCloud"])
}

@Test
func appModelImportsDiagnosticCrashReportsWhenLoadingSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let crashReport = directory.appending(path: "WesomeCloud_2026-05-27-191500_Mac.crash")
    try """
    Process:               WesomeCloud [123]
    Date/Time:             2026-05-27 19:15:00.000 +0200
    Exception Type:        EXC_CRASH (SIGABRT)
    """.write(to: crashReport, atomically: true, encoding: .utf8)
    let crashReports = MemoryCrashReportRepository()
    let appModel = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        crashReports: crashReports,
        crashReportImporter: DiagnosticReportsCrashImporter(directories: [directory])
    )

    let snapshot = try await appModel.loadSnapshot()
    let refreshed = try await appModel.loadSnapshot()

    #expect(snapshot.crashReports.count == 1)
    #expect(snapshot.crashReports.first?.processName == "WesomeCloud")
    #expect(snapshot.diagnostics.contains { $0.category == "Crash" && $0.message.contains("Imported 1 macOS crash report") })
    #expect(refreshed.crashReports.count == 1)
    #expect(refreshed.diagnostics.filter { $0.category == "Crash" && $0.message.contains("Imported") }.count == 1)
}

// Exercise the archive as a consumer would, independently of our serialization code.
private func diagnosticJSON(in archive: URL) throws -> Data {
    func unzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }
    let listing = String(decoding: try unzip(["-Z1", archive.path]), as: UTF8.self)
    let entry = try #require(listing.split(separator: "\n").first { $0.hasSuffix("diagnostics.json") })
    return try unzip(["-p", archive.path, String(entry)])
}

@Test
func diagnosticsExportIncludesRestartHistoryAndSanitizedPersistedState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "private-user")
    let domain = CloudDomain(id: "selected-space", accountID: account.id, displayName: "Private Client")
    let record = PersistedAccountRecord(account: account, domain: domain, lastSyncStatus: SyncStatusSnapshot(message: "Selected Private Client for Finder"))
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    let operation = PendingOperation(kind: .upload, itemID: "private-item", sourcePath: "/Users/private/report.xlsx", destinationPath: "/Clients/private/report.xlsx", lastErrorDescription: "token=secret")
    try await store.enqueue(operation, accountID: record.metadataID)
    try await store.recordSyncError(SyncErrorRecord(scope: .item, itemID: operation.itemID, message: "failed /Clients/private/report.xlsx", isRecoverable: true), accountID: record.metadataID)
    try await store.upsertTransfer(TransferRecord(itemID: operation.itemID, direction: .download, phase: .failed,
                                                 localURL: URL(fileURLWithPath: "/Users/private/report.xlsx"), remotePath: "/Clients/private/report.xlsx"), accountID: record.metadataID)
    let journal = PersistentDiagnosticLog(directory: paths.logs)
    try journal.append(DiagnosticEvent(category: "RemotePoll", level: .info, message: "Checked 3 folders", context: ["scope": record.metadataID.uuidString, "outcome": "success", "polled": "true"]))
    let buffer = AppDiagnosticBuffer(journal: PersistentDiagnosticLog(directory: paths.logs))
    await buffer.record(DiagnosticEvent(date: Date().addingTimeInterval(-8 * 86_400), category: "Test", level: .info, message: "expired-event"))
    let repository = MemoryAccountRepository(records: [record])
    let model = WesomeCloudAppModel(accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
                                   domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
                                   repository: repository, metadataStore: store,
                                   diagnostics: buffer)
    let archive = try await model.exportDiagnostics(to: root)
    let data = try diagnosticJSON(in: archive)
    let text = String(decoding: data, as: UTF8.self)
    for secret in ["private-user", "private-item", "Private Client", "report.xlsx", "secret", "expired-event"] { #expect(!text.contains(secret)) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let bundle = try decoder.decode(DiagnosticsExportBundle.self, from: data)
    #expect(bundle.pendingOperations?.first?.operation.attemptCount == 0)
    #expect(bundle.syncErrors?.count == 1)
    #expect(bundle.transfers?.first?.transfer.localURL == nil)
    #expect(bundle.scopes?.first?.lastSuccessfulPoll?.message == "Checked 3 folders")
    #expect(bundle.environment?.registeredDomainIDs == [])
    var removed = record
    removed.domains = []
    removed.lastSyncStatus.message = "Removed Private Client from Finder"
    try await repository.save(removed)
    let afterRemoval = try diagnosticJSON(in: await model.exportDiagnostics(to: root))
    #expect(!String(decoding: afterRemoval, as: UTF8.self).contains("Private Client"))
}

@Test
func diagnosticsExportPreservesAvailableEvidenceWhenLocalSourcesFail() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = WesomeCloudPaths(root: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // A file where the journal directory belongs reproduces a real filesystem failure.
    try Data().write(to: paths.logs)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account)
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    try await store.upsertTransfer(TransferRecord(itemID: "item", direction: .download, phase: .failed, remotePath: "/report.xlsx"), accountID: record.metadataID)
    // Corrupt only the queue table in this disposable database; other sources still work.
    var database: OpaquePointer?
    try #require(sqlite3_open(paths.database.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    try #require(sqlite3_exec(database, "DROP TABLE pending_operations", nil, nil, nil) == SQLITE_OK)
    let health = FileProviderHealthStore(paths: paths)
    try FileManager.default.createDirectory(at: root.appending(path: "FileProviderHealth/\(account.id).json"), withIntermediateDirectories: true)
    let buffer = AppDiagnosticBuffer(journal: PersistentDiagnosticLog(directory: paths.logs))
    await buffer.record(DiagnosticEvent(category: "Test", level: .info, message: "available evidence"))
    await buffer.record(DiagnosticEvent(date: Date().addingTimeInterval(-8 * 86_400), category: "Test", level: .info, message: "expired evidence"))
    let model = WesomeCloudAppModel(accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
                                   domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
                                   repository: MemoryAccountRepository(records: [record]), metadataStore: store, fileProviderHealth: health, diagnostics: buffer)
    let archive = try await model.exportDiagnostics(to: root)
    let data = try diagnosticJSON(in: archive)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let bundle = try decoder.decode(DiagnosticsExportBundle.self, from: data)
    #expect(bundle.events.map(\.message) == ["available evidence"])
    #expect(bundle.transfers?.count == 1)
    #expect(bundle.environment?.collectionErrors?["journal"] != nil)
    #expect(bundle.environment?.collectionErrors?["pendingOperations:" + record.metadataID.uuidString] != nil)
    #expect(bundle.environment?.collectionErrors?["fileProviderHealth:" + account.id.uuidString] != nil)
    #expect(!String(decoding: data, as: UTF8.self).contains(root.path))
}
