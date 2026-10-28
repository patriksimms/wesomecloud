import Foundation
import SyncStore
import WesomeCloudShared
import WesomeFileProviderCore

public struct DiagnosticsEnvironment: Codable, Equatable, Sendable {
    public var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    public var buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    public var macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public var registeredDomainIDs: [String]?
    public var registrationError: String?
    public var collectionErrors: [String: String]?

    public init() {}
}

public struct DiagnosticsScope: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var scopeID: UUID
    public var domainID: String?
    public var nameReference: String
    public var rootReference: String
    public var serverPollInterval: TimeInterval?
    public var lastSuccessfulPoll: DiagnosticEvent?

    public init(record: PersistedAccountRecord, events: [DiagnosticEvent]) {
        accountID = record.id
        scopeID = record.metadataID
        domainID = record.domain?.id
        nameReference = DiagnosticRedactor.reference(record.locationName)
        rootReference = DiagnosticRedactor.reference(record.domain?.rootPath ?? "/")
        serverPollInterval = record.serverPollInterval
        lastSuccessfulPoll = events.last {
            $0.category == "RemotePoll" && $0.context?["scope"] == record.metadataID.uuidString
                && $0.context?["outcome"] == "success" && $0.context?["polled"] == "true"
        }
    }
}

public struct DiagnosticsPendingOperation: Codable, Equatable, Sendable {
    public var scopeID: UUID
    public var operation: PendingOperation

    public init(scopeID: UUID, operation: PendingOperation) {
        self.scopeID = scopeID
        self.operation = operation
        self.operation.itemID = DiagnosticRedactor.reference(operation.itemID)
        self.operation.sourcePath = operation.sourcePath.map(DiagnosticRedactor.reference)
        self.operation.destinationPath = operation.destinationPath.map(DiagnosticRedactor.reference)
        self.operation.lastErrorDescription = operation.lastErrorDescription.map(DiagnosticRedactor.redact)
    }
}

public struct DiagnosticsSyncError: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var domainID: String?
    public var error: SyncErrorRecord

    public init(_ issue: SyncIssue) {
        accountID = issue.accountID
        domainID = issue.domainID
        error = SyncErrorRecord(id: issue.id, scope: issue.scope, itemID: issue.itemID.map(DiagnosticRedactor.reference),
                                operationID: issue.operationID, message: DiagnosticRedactor.redact(issue.message),
                                isRecoverable: issue.isRecoverable, occurredAt: issue.occurredAt)
    }
}

public struct DiagnosticsTransfer: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var transfer: TransferRecord

    public init(_ item: AppTransfer) {
        accountID = item.accountID
        transfer = item.transfer
        transfer.itemID = DiagnosticRedactor.reference(transfer.itemID)
        transfer.remotePath = DiagnosticRedactor.reference(transfer.remotePath)
        transfer.localURL = nil
        transfer.lastErrorDescription = transfer.lastErrorDescription.map(DiagnosticRedactor.redact)
    }
}
