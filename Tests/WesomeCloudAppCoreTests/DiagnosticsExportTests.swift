import Foundation
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

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

    #expect(url.lastPathComponent == "wesomecloud-diagnostics-123.json")
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let bundle = try decoder.decode(DiagnosticsExportBundle.self, from: data)
    #expect(bundle.accounts.first?.serverHost == "cloud.example")
    #expect(bundle.accounts.first?.username == "alice")
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
