import Foundation
import WesomeCloudShared

public struct DiagnosticsExportBundle: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var accounts: [DiagnosticsAccountSummary]
    public var preferences: AppPreferences
    public var events: [DiagnosticEvent]
    public var crashReports: [CrashReport]

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
        self.serverHost = record.account.serverURL.host() ?? record.account.serverURL.absoluteString
        self.username = record.account.username
        self.displayName = record.account.displayName
        self.domainID = record.domain?.id
        self.domainIDs = record.domains.map(\.id)
        self.serverVersion = record.serverVersion
        self.serverEdition = record.serverEdition
        self.syncStatus = record.lastSyncStatus
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

    public func export(snapshot: AppSnapshot, preferences: AppPreferences, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let generatedAt = clock()
        let bundle = DiagnosticsExportBundle(
            generatedAt: generatedAt,
            accounts: snapshot.accounts.map(DiagnosticsAccountSummary.init),
            preferences: preferences,
            events: snapshot.diagnostics.map(Self.redacted),
            crashReports: snapshot.crashReports.map(Self.redacted)
        )
        let filename = "wesomecloud-diagnostics-\(Int(generatedAt.timeIntervalSince1970)).json"
        let destination = directory.appending(path: filename)
        try encoder.encode(bundle).write(to: destination, options: [.atomic])
        return destination
    }

    private static func redacted(_ event: DiagnosticEvent) -> DiagnosticEvent {
        var redacted = event
        redacted.message = redact(event.message)
        return redacted
    }

    private static func redacted(_ report: CrashReport) -> CrashReport {
        var redacted = report
        redacted.reason = redact(report.reason)
        redacted.details = report.details.map(redact)
        return redacted
    }

    static func redact(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(password|token|secret|authorization)\s*[:=]\s*[^,\n]+"#,
            #"(?i)basic\s+[A-Za-z0-9+/=]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1: [REDACTED]", options: .regularExpression)
        }
        return result
    }
}
