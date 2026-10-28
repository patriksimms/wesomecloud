import Foundation
import WesomeCloudShared
import SyncStore
import WesomeFileProviderCore

public struct DiagnosticsExportBundle: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var accounts: [DiagnosticsAccountSummary]
    public var preferences: AppPreferences
    public var events: [DiagnosticEvent]
    public var crashReports: [CrashReport]
    public var environment: DiagnosticsEnvironment?
    public var scopes: [DiagnosticsScope]?
    public var pendingOperations: [DiagnosticsPendingOperation]?
    public var syncErrors: [DiagnosticsSyncError]?
    public var transfers: [DiagnosticsTransfer]?
    public var fileProviderHealth: [String: FileProviderAccountIssue]?

    public init(
        generatedAt: Date = Date(),
        accounts: [DiagnosticsAccountSummary],
        preferences: AppPreferences,
        events: [DiagnosticEvent],
        crashReports: [CrashReport] = []
    ) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.preferences = preferences
        self.events = events
        self.crashReports = crashReports
    }
}

public struct DiagnosticsAccountSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var serverHost: String
    public var username: String
    public var displayName: String
    public var domainID: String?
    public var domainIDs: [String]?
    public var serverVersion: String?
    public var serverEdition: String?
    public var syncStatus: SyncStatusSnapshot

    public init(record: PersistedAccountRecord) {
        self.id = record.id
        self.serverHost = record.account.serverURL.host() ?? "unknown"
        self.username = DiagnosticRedactor.reference(record.account.username)
        self.displayName = DiagnosticRedactor.reference(record.account.displayName)
        self.domainID = record.domain?.id
        self.domainIDs = record.domains.map(\.id)
        self.serverVersion = record.serverVersion
        self.serverEdition = record.serverEdition
        self.syncStatus = record.lastSyncStatus
        // Removed Spaces no longer appear in record.domains; handle their persisted status too.
        for (prefix, suffix) in [("Selected ", " for Finder"), ("Removed ", " from Finder")] {
            if syncStatus.message.hasPrefix(prefix), syncStatus.message.hasSuffix(suffix) {
                let name = String(syncStatus.message.dropFirst(prefix.count).dropLast(suffix.count))
                syncStatus.message = prefix + DiagnosticRedactor.reference(name) + suffix
            }
        }
        let names = [record.account.username, record.account.displayName] + record.domains.map(\.displayName)
        for name in names.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            self.syncStatus.message = self.syncStatus.message.replacingOccurrences(of: name, with: DiagnosticRedactor.reference(name))
        }
        self.syncStatus.message = DiagnosticRedactor.redact(self.syncStatus.message)
    }
}

public struct DiagnosticsExporter: Sendable {
    private let encoder: JSONEncoder
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        self.clock = clock
    }

    public func export(snapshot: AppSnapshot, preferences: AppPreferences,
                       pendingOperations: [DiagnosticsPendingOperation] = [],
                       fileProviderHealth: [String: FileProviderAccountIssue] = [:],
                       environment: DiagnosticsEnvironment = DiagnosticsEnvironment(), to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let generatedAt = clock()
        var bundle = DiagnosticsExportBundle(
            generatedAt: generatedAt,
            accounts: snapshot.accounts.map(DiagnosticsAccountSummary.init),
            preferences: Self.redacted(preferences),
            events: snapshot.diagnostics.map(Self.redacted),
            crashReports: snapshot.crashReports.map(Self.redacted)
        )
        bundle.environment = environment
        bundle.scopes = snapshot.accounts.flatMap(\.syncLocations).map { record in
            DiagnosticsScope(record: record, events: bundle.events)
        }
        bundle.pendingOperations = pendingOperations
        bundle.syncErrors = snapshot.issues.map(DiagnosticsSyncError.init)
        bundle.transfers = snapshot.transfers.map(DiagnosticsTransfer.init)
        bundle.fileProviderHealth = fileProviderHealth
        // Use a unique staging directory so concurrent exports cannot overwrite each other.
        let staging = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try encoder.encode(bundle).write(to: staging.appending(path: "diagnostics.json"), options: .atomic)
        let readme = """
        WesomeCloud diagnostics
        Logs cover up to seven days, subject to a 10 MiB journal cap. Earlier activity may be unavailable.
        Paths, account names and item identifiers use stable references. No file contents or credentials are included.
        A completed poll covers the reported folders, not an exhaustive server scan.
        Menu bar visibility is controlled by macOS; registration does not prove that the icon is visible.
        """
        try readme.write(to: staging.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        let destination = directory.appending(path: "wesomecloud-diagnostics-\(Int(generatedAt.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { archive in
            do { try FileManager.default.copyItem(at: archive, to: destination) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    private static func redacted(_ preferences: AppPreferences) -> AppPreferences {
        var preferences = preferences
        preferences.files.excludedRemotePaths = preferences.files.excludedRemotePaths.map(DiagnosticRedactor.reference)
        preferences.files.ignoredFilenamePatterns = preferences.files.ignoredFilenamePatterns.map(DiagnosticRedactor.reference)
        preferences.updates.appcastURL = nil
        return preferences
    }

    private static func redacted(_ event: DiagnosticEvent) -> DiagnosticEvent {
        var redacted = event
        redacted.message = String(redact(event.message).prefix(8_192))
        redacted.context = event.context?.mapValues(redact)
        return redacted
    }

    private static func redacted(_ report: CrashReport) -> CrashReport {
        var redacted = report
        redacted.reason = redact(report.reason)
        redacted.details = report.details.map(redact)
        return redacted
    }

    static func redact(_ value: String) -> String {
        DiagnosticRedactor.redact(value)
    }
}
