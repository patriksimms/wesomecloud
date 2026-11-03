import Foundation
import SyncStore
import WesomeCloudShared

/// All selected Spaces share the metadata database's sequence, but retain independent
/// Finder anchors. Reading a page never acknowledges or consumes another reader's work.
public protocol FileProviderJournalProviding: Sendable {
    func journalContext() async throws -> ProviderJournalContext
    func journalChanges(after: Int64, through: Int64, limit: Int) async throws -> ProviderJournalBatch
}

public struct ProviderJournalContext: Sendable {
    public var state: ProviderJournalState
    public var presentation: String
}

public struct ProviderJournalEntry: Sendable {
    public var sequence: Int64
    public var item: ProviderItem
    public var previousParentID: String?
    public var hadPrevious: Bool
    public var deleted: Bool
}

public struct ProviderJournalBatch: Sendable {
    public var entries: [ProviderJournalEntry]
    public var position: Int64
}

public struct ProviderChangePage: Sendable {
    public var updated: [ProviderItem]
    public var deleted: [String]
    public var anchor: Data
    public var moreComing: Bool
    public var position: Int64
    public var upperBound: Int64
}

struct ProviderSyncAnchor: Codable {
    var version = 1
    var epoch: String
    var presentation: String
    var container: String
    var position: Int64
    var upperBound: Int64?

    var data: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(self)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard let anchor = try? JSONDecoder().decode(Self.self, from: data), anchor.version == 1 else {
            throw ProviderJournalError.expired
        }
        return anchor
    }
}

/// The persisted configuration lets selection, naming and visibility changes produce
/// ordinary journal entries, including tombstones for items in a deselected Space.
private struct JournalPresentation: Codable {
    var spaceID: String?
    var metadataID: UUID
    var name: String
    var rootPath: String
    var policy: FileProviderPresentationPolicy

    func presenting(_ item: ProviderItem) -> ProviderItem {
        guard let spaceID else { return item }
        return ProviderSpace(id: spaceID, name: name, rootPath: rootPath, backend: { throw ProviderJournalError.expired }).presenting(item)
    }

    var folder: ProviderItem? {
        guard let spaceID else { return nil }
        return ProviderSpace(id: spaceID, name: name, rootPath: rootPath, backend: { throw ProviderJournalError.expired }).folder
    }

    func visible(_ stored: StoredItem) -> Bool {
        !policy.excludes(remotePath: stored.remote.path)
            && (policy.showHiddenFiles || !stored.remote.name.hasPrefix("."))
            && !policy.ignores(filename: stored.remote.name)
    }

    func items(in store: SQLiteMetadataStore) throws -> [ProviderItem] {
        var transfers: [String: TransferRecord] = [:]
        for transfer in try store.storedTransfers(accountID: metadataID) where transfers[transfer.itemID] == nil {
            transfers[transfer.itemID] = transfer
        }
        var result = try store.storedItems(accountID: metadataID).filter(visible).map {
            presenting(ProviderItem(stored: $0).applying(transfer: transfers[$0.remote.id]))
        }
        if let folder { result.append(folder) }
        return result
    }
}

private func reconcileJournalContext(store: SQLiteMetadataStore, scope: String, presentations: [JournalPresentation]) throws -> ProviderJournalContext {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let configuration = try encoder.encode(presentations)
    try store.reconcileProviderPresentation(scope: scope, configuration: configuration) { previous in
        guard let previous else { return [] }
        let oldPresentations = try JSONDecoder().decode([JournalPresentation].self, from: previous)
        let old = Dictionary(uniqueKeysWithValues: try oldPresentations.flatMap { try $0.items(in: store) }.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: try presentations.flatMap { try $0.items(in: store) }.map { ($0.id, $0) })
        var changes: [ProviderPresentationChange] = []
        for item in old.values.sorted(by: { $0.id < $1.id }) where new[item.id] == nil {
            changes.append(ProviderPresentationChange(payload: try JSONEncoder().encode(item), deleted: true, previousParentID: item.parentID, hadPrevious: true))
        }
        for item in new.values.sorted(by: { $0.id < $1.id }) where old[item.id] != item {
            changes.append(ProviderPresentationChange(payload: try JSONEncoder().encode(item), deleted: false, previousParentID: old[item.id]?.parentID, hadPrevious: old[item.id] != nil))
        }
        return changes
    }
    return ProviderJournalContext(state: try store.providerJournalState(), presentation: scope)
}

private func journalBatch(store: SQLiteMetadataStore, scope: String, presentations: [JournalPresentation], after: Int64, through: Int64, limit: Int) throws -> ProviderJournalBatch {
    let changes = try store.providerChanges(after: after, through: through, limit: limit)
    var entries: [ProviderJournalEntry] = []
    for change in changes {
        if change.presentationScope == scope, let payload = change.presentationPayload {
            let item = try JSONDecoder().decode(ProviderItem.self, from: payload)
            entries.append(ProviderJournalEntry(sequence: change.sequence, item: item, previousParentID: change.previousParentID, hadPrevious: change.hadPrevious, deleted: change.deleted))
        } else if change.presentationScope == nil, let stored = change.item {
            for presentation in presentations where presentation.metadataID == change.accountID {
                var previous = ProviderItem(stored: stored)
                previous.parentID = change.previousParentID
                entries.append(ProviderJournalEntry(sequence: change.sequence, item: presentation.presenting(ProviderItem(stored: stored).applying(transfer: change.transfer)), previousParentID: presentation.presenting(previous).parentID, hadPrevious: change.hadPrevious, deleted: change.deleted || !presentation.visible(stored)))
            }
        }
    }
    return ProviderJournalBatch(entries: entries, position: changes.last?.sequence ?? through)
}

extension FileProviderCoordinator: FileProviderJournalProviding {
    private var journalPresentation: JournalPresentation {
        JournalPresentation(metadataID: metadataID, name: "", rootPath: "/", policy: presentationPolicy)
    }

    public func journalContext() async throws -> ProviderJournalContext {
        guard let journal = store as? SQLiteMetadataStore else { throw ProviderJournalError.expired }
        return try reconcileJournalContext(store: journal, scope: metadataID.uuidString, presentations: [journalPresentation])
    }

    public func journalChanges(after: Int64, through: Int64, limit: Int) async throws -> ProviderJournalBatch {
        guard let journal = store as? SQLiteMetadataStore else { throw ProviderJournalError.expired }
        return try journalBatch(store: journal, scope: metadataID.uuidString, presentations: [journalPresentation], after: after, through: through, limit: limit)
    }
}

extension SpaceFileProviderBackend: FileProviderJournalProviding {
    private func journalPresentations() async throws -> [JournalPresentation] {
        var result: [JournalPresentation] = []
        for space in try await spaces() {
            guard let metadataID = space.metadataID else { throw ProviderJournalError.expired }
            result.append(JournalPresentation(spaceID: space.id, metadataID: metadataID, name: space.name, rootPath: space.rootPath, policy: space.presentationPolicy))
        }
        return result
    }

    public func journalContext() async throws -> ProviderJournalContext {
        guard let journalStore else { throw ProviderJournalError.expired }
        let presentations = try await journalPresentations()
        return try reconcileJournalContext(store: journalStore, scope: ProviderSpaceIdentifier.domainID, presentations: presentations)
    }

    public func journalChanges(after: Int64, through: Int64, limit: Int) async throws -> ProviderJournalBatch {
        guard let journalStore else { throw ProviderJournalError.expired }
        let presentations = try await journalPresentations()
        return try journalBatch(store: journalStore, scope: ProviderSpaceIdentifier.domainID, presentations: presentations, after: after, through: through, limit: limit)
    }
}
