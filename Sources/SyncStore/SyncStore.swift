import Foundation
import WesomeCloudShared

public struct StoredItem: Codable, Equatable, Sendable {
    public var remote: RemoteItem
    public var availabilityIntent: AvailabilityIntent
    public var materializedURL: URL?
    public var lastSeen: Date

    public init(
        remote: RemoteItem,
        availabilityIntent: AvailabilityIntent = .unspecified,
        materializedURL: URL? = nil,
        lastSeen: Date = Date()
    ) {
        self.remote = remote
        self.availabilityIntent = availabilityIntent
        self.materializedURL = materializedURL
        self.lastSeen = lastSeen
    }
}

public enum PendingOperationKind: String, Codable, Equatable, Sendable {
    case upload
    case createFile
    case delete
    case move
    case createFolder
}

public struct PendingOperation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PendingOperationKind
    public var itemID: String
    public var sourcePath: String?
    public var destinationPath: String?
    public var createdAt: Date
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastErrorDescription: String?

    public init(
        id: UUID = UUID(),
        kind: PendingOperationKind,
        itemID: String,
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.itemID = itemID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.lastErrorDescription = lastErrorDescription
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case itemID
        case sourcePath
        case destinationPath
        case createdAt
        case attemptCount
        case nextAttemptAt
        case lastErrorDescription
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(PendingOperationKind.self, forKey: .kind)
        itemID = try container.decode(String.self, forKey: .itemID)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt) ?? createdAt
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
    }
}

public enum SyncErrorScope: String, Codable, Equatable, Sendable {
    case account
    case item
    case operation
}

public struct SyncErrorRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var scope: SyncErrorScope
    public var itemID: String?
    public var operationID: UUID?
    public var message: String
    public var isRecoverable: Bool
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        scope: SyncErrorScope,
        itemID: String? = nil,
        operationID: UUID? = nil,
        message: String,
        isRecoverable: Bool,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.itemID = itemID
        self.operationID = operationID
        self.message = message
        self.isRecoverable = isRecoverable
        self.occurredAt = occurredAt
    }
}

public enum TransferDirection: String, Codable, Equatable, Sendable {
    case download
    case upload
}

public enum TransferPhase: String, Codable, Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
}

public struct TransferRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var itemID: String
    public var direction: TransferDirection
    public var phase: TransferPhase
    public var bytesTransferred: Int64
    public var totalBytes: Int64?
    public var localURL: URL?
    public var remotePath: String
    public var lastErrorDescription: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        itemID: String,
        direction: TransferDirection,
        phase: TransferPhase,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64? = nil,
        localURL: URL? = nil,
        remotePath: String,
        lastErrorDescription: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.direction = direction
        self.phase = phase
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.localURL = localURL
        self.remotePath = remotePath
        self.lastErrorDescription = lastErrorDescription
        self.updatedAt = updatedAt
    }
}

public enum ConflictResolutionDecision: String, Codable, Equatable, Sendable, CaseIterable {
    case keepLocal
    case keepRemote
    case renameLocal
    case retry
}

public enum ConflictRecordState: String, Codable, Equatable, Sendable {
    case pending
    case resolved
}

public struct ConflictRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var conflict: SyncConflict
    public var state: ConflictRecordState
    public var selectedResolution: ConflictResolutionDecision?
    public var resolvedName: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        conflict: SyncConflict,
        state: ConflictRecordState = .pending,
        selectedResolution: ConflictResolutionDecision? = nil,
        resolvedName: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.conflict = conflict
        self.state = state
        self.selectedResolution = selectedResolution
        self.resolvedName = resolvedName
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public protocol MetadataStore: Sendable {
    func upsert(accountID: UUID, items: [RemoteItem]) async throws
    func remove(accountID: UUID, itemID: String) async throws
    func item(accountID: UUID, id: String) async throws -> StoredItem?
    func items(accountID: UUID) async throws -> [StoredItem]
    func children(accountID: UUID, parentID: String?) async throws -> [StoredItem]
    func removeAll(accountID: UUID) async throws
    func setAvailabilityIntent(_ intent: AvailabilityIntent, accountID: UUID, itemID: String) async throws
    func setMaterializedURL(_ url: URL?, accountID: UUID, itemID: String) async throws
    func enqueue(_ operation: PendingOperation, accountID: UUID) async throws
    func pendingOperations(accountID: UUID) async throws -> [PendingOperation]
    func pendingOperations(accountID: UUID, dueAt: Date) async throws -> [PendingOperation]
    func updatePendingOperation(_ operation: PendingOperation, accountID: UUID) async throws
    func removePendingOperation(id: UUID, accountID: UUID) async throws
    func recordSyncError(_ error: SyncErrorRecord, accountID: UUID) async throws
    func syncErrors(accountID: UUID) async throws -> [SyncErrorRecord]
    func clearSyncError(id: UUID, accountID: UUID) async throws
    func upsertTransfer(_ transfer: TransferRecord, accountID: UUID) async throws
    func transfers(accountID: UUID) async throws -> [TransferRecord]
    func removeTransfer(id: UUID, accountID: UUID) async throws
    func recordConflict(_ conflict: ConflictRecord, accountID: UUID) async throws
    func conflicts(accountID: UUID, state: ConflictRecordState?) async throws -> [ConflictRecord]
    func resolveConflict(id: UUID, accountID: UUID, decision: ConflictResolutionDecision, resolvedName: String?, resolvedAt: Date) async throws
    func syncCursor(accountID: UUID, remotePath: String) async throws -> String?
    func setSyncCursor(_ cursor: String?, accountID: UUID, remotePath: String) async throws
}

public actor InMemoryMetadataStore: MetadataStore {
    private var items: [UUID: [String: StoredItem]] = [:]
    private var operations: [UUID: [PendingOperation]] = [:]
    private var errors: [UUID: [SyncErrorRecord]] = [:]
    private var transferRecords: [UUID: [UUID: TransferRecord]] = [:]
    private var conflictRecords: [UUID: [UUID: ConflictRecord]] = [:]
    private var syncCursors: [UUID: [String: String]] = [:]

    public init() {}

    public func upsert(accountID: UUID, items newItems: [RemoteItem]) async throws {
        var accountItems = items[accountID, default: [:]]
        for item in newItems {
            let old = accountItems[item.id]
            accountItems[item.id] = StoredItem(
                remote: item,
                availabilityIntent: old?.availabilityIntent ?? .unspecified,
                materializedURL: old?.materializedURL,
                lastSeen: Date()
            )
        }
        items[accountID] = accountItems
    }

    public func remove(accountID: UUID, itemID: String) async throws {
        items[accountID]?[itemID] = nil
        let removedOperationIDs = Set(operations[accountID, default: []]
            .filter { $0.itemID == itemID }
            .map(\.id))
        operations[accountID, default: []].removeAll { $0.itemID == itemID }
        errors[accountID, default: []].removeAll {
            $0.itemID == itemID || $0.operationID.map(removedOperationIDs.contains) == true
        }
        transferRecords[accountID, default: [:]] = transferRecords[accountID, default: [:]]
            .filter { $0.value.itemID != itemID }
        conflictRecords[accountID, default: [:]] = conflictRecords[accountID, default: [:]]
            .filter { $0.value.conflict.itemID != itemID }
    }

    public func item(accountID: UUID, id: String) async throws -> StoredItem? {
        items[accountID]?[id]
    }

    public func items(accountID: UUID) async throws -> [StoredItem] {
        items[accountID, default: [:]]
            .values
            .sorted { $0.remote.path.localizedStandardCompare($1.remote.path) == .orderedAscending }
    }

    public func children(accountID: UUID, parentID: String?) async throws -> [StoredItem] {
        items[accountID, default: [:]]
            .values
            .filter { $0.remote.parentID == parentID }
            .sorted { $0.remote.name.localizedStandardCompare($1.remote.name) == .orderedAscending }
    }

    public func removeAll(accountID: UUID) async throws {
        items[accountID] = nil
        operations[accountID] = nil
        errors[accountID] = nil
        transferRecords[accountID] = nil
        conflictRecords[accountID] = nil
        syncCursors[accountID] = nil
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, accountID: UUID, itemID: String) async throws {
        guard var item = items[accountID]?[itemID] else { throw WesomeCloudError.missingItem(itemID) }
        item.availabilityIntent = intent
        items[accountID]?[itemID] = item
    }

    public func setMaterializedURL(_ url: URL?, accountID: UUID, itemID: String) async throws {
        guard var item = items[accountID]?[itemID] else { throw WesomeCloudError.missingItem(itemID) }
        item.materializedURL = url
        items[accountID]?[itemID] = item
    }

    public func enqueue(_ operation: PendingOperation, accountID: UUID) async throws {
        operations[accountID, default: []].append(operation)
    }

    public func pendingOperations(accountID: UUID) async throws -> [PendingOperation] {
        operations[accountID, default: []]
    }

    public func pendingOperations(accountID: UUID, dueAt: Date) async throws -> [PendingOperation] {
        operations[accountID, default: []]
            .filter { $0.nextAttemptAt <= dueAt }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func updatePendingOperation(_ operation: PendingOperation, accountID: UUID) async throws {
        var accountOperations = operations[accountID, default: []]
        guard let index = accountOperations.firstIndex(where: { $0.id == operation.id }) else {
            throw WesomeCloudError.missingItem(operation.id.uuidString)
        }
        accountOperations[index] = operation
        operations[accountID] = accountOperations
    }

    public func removePendingOperation(id: UUID, accountID: UUID) async throws {
        operations[accountID, default: []].removeAll { $0.id == id }
    }

    public func recordSyncError(_ error: SyncErrorRecord, accountID: UUID) async throws {
        errors[accountID, default: []].removeAll { $0.id == error.id }
        errors[accountID, default: []].append(error)
    }

    public func syncErrors(accountID: UUID) async throws -> [SyncErrorRecord] {
        errors[accountID, default: []].sorted { $0.occurredAt > $1.occurredAt }
    }

    public func clearSyncError(id: UUID, accountID: UUID) async throws {
        errors[accountID, default: []].removeAll { $0.id == id }
    }

    public func upsertTransfer(_ transfer: TransferRecord, accountID: UUID) async throws {
        transferRecords[accountID, default: [:]][transfer.id] = transfer
    }

    public func transfers(accountID: UUID) async throws -> [TransferRecord] {
        transferRecords[accountID, default: [:]].values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func removeTransfer(id: UUID, accountID: UUID) async throws {
        transferRecords[accountID, default: [:]][id] = nil
    }

    public func recordConflict(_ conflict: ConflictRecord, accountID: UUID) async throws {
        conflictRecords[accountID, default: [:]][conflict.id] = conflict
    }

    public func conflicts(accountID: UUID, state: ConflictRecordState?) async throws -> [ConflictRecord] {
        conflictRecords[accountID, default: [:]]
            .values
            .filter { state == nil || $0.state == state }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func resolveConflict(
        id: UUID,
        accountID: UUID,
        decision: ConflictResolutionDecision,
        resolvedName: String?,
        resolvedAt: Date
    ) async throws {
        guard var conflict = conflictRecords[accountID]?[id] else { throw WesomeCloudError.missingItem(id.uuidString) }
        conflict.state = .resolved
        conflict.selectedResolution = decision
        conflict.resolvedName = resolvedName
        conflict.resolvedAt = resolvedAt
        conflictRecords[accountID]?[id] = conflict
    }

    public func syncCursor(accountID: UUID, remotePath: String) async throws -> String? {
        syncCursors[accountID]?[Self.normalizedRemotePath(remotePath)]
    }

    public func setSyncCursor(_ cursor: String?, accountID: UUID, remotePath: String) async throws {
        let path = Self.normalizedRemotePath(remotePath)
        if let cursor {
            syncCursors[accountID, default: [:]][path] = cursor
        } else {
            syncCursors[accountID, default: [:]][path] = nil
        }
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        var normalized = path.hasPrefix("/") ? path : "/" + path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
