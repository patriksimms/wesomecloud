import Foundation

public struct ProviderJournalState: Equatable, Sendable {
    public var epoch: String
    public var position: Int64
    public var floor: Int64
}

public enum ProviderJournalError: Error {
    case expired
}

public struct StoredProviderChange: Sendable {
    public var sequence: Int64
    public var accountID: UUID?
    public var item: StoredItem?
    public var previousParentID: String?
    public var hadPrevious: Bool
    public var deleted: Bool
    public var transfer: TransferRecord?
    public var presentationScope: String?
    public var presentationPayload: Data?
}

public struct ProviderPresentationChange: Sendable {
    public var payload: Data
    public var deleted: Bool
    public var previousParentID: String?
    public var hadPrevious: Bool

    public init(payload: Data, deleted: Bool, previousParentID: String?, hadPrevious: Bool) {
        self.payload = payload
        self.deleted = deleted
        self.previousParentID = previousParentID
        self.hadPrevious = hadPrevious
    }
}
