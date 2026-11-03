import Foundation
import SyncStore
import WesomeCloudShared

public enum ProviderEnumerationError: Error { case expired }

public struct ProviderPage: Equatable, Sendable {
    public var items: [ProviderItem]
    public var nextPageToken: String?

    public init(items: [ProviderItem], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}

public protocol FileProviderBackend: Sendable {
    func enumerate(parentID: String?, remotePath: String) async throws -> [ProviderItem]
    func item(itemID: String) async throws -> ProviderItem?
    func fetchContents(itemID: String) async throws -> URL
    func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem
    func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem
    func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem
    func delete(itemID: String) async throws
    func move(itemID: String, to destinationPath: String) async throws -> ProviderItem
    func pollRemoteChanges(parentID: String?, remotePath: String) async throws -> RemoteChangeSet
    func setAvailabilityIntent(_ intent: AvailabilityIntent, itemID: String, includeDescendants: Bool) async throws -> [String]
    func evictMaterializedContentForDiskPressure() async throws -> [String]
}

public protocol FileProviderWorkingSetProviding: Sendable {
    func workingSetItems() async throws -> [ProviderItem]
}

public protocol FileProviderPartialContentProviding: Sendable {
    func fetchPartialContents(itemID: String, requestedRange: ProviderContentRange, alignment: Int64) async throws -> PartialProviderContent
}

public protocol FileProviderTransferProgressProviding: Sendable {
    func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary
}

extension FileProviderCoordinator: FileProviderBackend {}
extension FileProviderCoordinator: FileProviderWorkingSetProviding {}
extension FileProviderCoordinator: FileProviderPartialContentProviding {}
extension FileProviderCoordinator: FileProviderTransferProgressProviding {}

public actor FileProviderAdapter {
    private let backend: FileProviderBackend
    private let pathResolver: ProviderPathResolving
    private let defaultPageSize: Int
    private let maxPageSnapshots: Int
    private var pageSnapshots: [String: (container: String, items: [ProviderItem])] = [:]
    private var pageSnapshotOrder: [String] = []

    public init(backend: FileProviderBackend, pathResolver: ProviderPathResolving = ProviderPathResolver(), defaultPageSize: Int = 200) {
        self.init(
            backend: backend,
            pathResolver: pathResolver,
            defaultPageSize: defaultPageSize,
            maxPageSnapshots: 32
        )
    }

    public init(
        backend: FileProviderBackend,
        pathResolver: ProviderPathResolving,
        defaultPageSize: Int,
        maxPageSnapshots: Int
    ) {
        self.backend = backend
        self.pathResolver = pathResolver
        self.defaultPageSize = Swift.max(1, defaultPageSize)
        self.maxPageSnapshots = Swift.max(1, maxPageSnapshots)
    }

    public func enumerate(container: ProviderContainerReference, pageToken: String? = nil, pageSize: Int? = nil) async throws -> ProviderPage {
        let containerKey = journalContainerKey(container)
        let requestedPageSize = pageSize ?? defaultPageSize
        if let pageToken {
            guard let token = PageToken(rawValue: pageToken), token.offset >= 0,
                  let snapshot = pageSnapshots[token.snapshotID], snapshot.container == containerKey else { throw ProviderEnumerationError.expired }
            return page(items: snapshot.items, snapshotID: token.snapshotID, offset: token.offset, pageSize: requestedPageSize, containerKey: containerKey)
        }
        if container == .workingSet {
            let items: [ProviderItem]
            if let provider = backend as? FileProviderWorkingSetProviding {
                items = try await provider.workingSetItems()
            } else {
                items = try await backend.enumerate(parentID: nil, remotePath: "/")
            }
            let snapshotID = UUID().uuidString
            return page(items: items, snapshotID: snapshotID, offset: 0, pageSize: requestedPageSize, containerKey: containerKey)
        }
        let resolved = pathResolver.resolve(container)
        let items = try await backend.enumerate(parentID: resolved.parentID, remotePath: resolved.remotePath)
        let snapshotID = UUID().uuidString
        return page(items: items, snapshotID: snapshotID, offset: 0, pageSize: requestedPageSize, containerKey: containerKey)
    }

    public func itemForIdentifier(_ identifier: String, parentPath: String) async throws -> ProviderItem? {
        if let item = try await backend.item(itemID: identifier) {
            return item
        }
        let items = try await backend.enumerate(parentID: ProviderContainerReference.path(parentPath).parentID, remotePath: parentPath)
        return items.first { $0.id == identifier }
    }

    public func fetchContents(for itemID: String) async throws -> URL {
        try await backend.fetchContents(itemID: itemID)
    }

    public func fetchPartialContents(for itemID: String, requestedRange: ProviderContentRange, alignment: Int64) async throws -> PartialProviderContent {
        if let provider = backend as? FileProviderPartialContentProviding {
            return try await provider.fetchPartialContents(itemID: itemID, requestedRange: requestedRange, alignment: alignment)
        }
        let url = try await backend.fetchContents(itemID: itemID)
        guard let item = try await backend.item(itemID: itemID) else { throw WesomeCloudError.missingItem(itemID) }
        return PartialProviderContent(url: url, item: item, retrievedRange: ProviderContentRange(offset: 0, length: item.size ?? 0))
    }

    public func modifyItem(_ itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        try await backend.uploadModifiedContents(itemID: itemID, contentsAt: localURL)
    }

    public func createFile(named name: String, contentsAt localURL: URL, in container: ProviderContainerReference) async throws -> ProviderItem {
        let resolved = pathResolver.resolve(container)
        return try await backend.createFile(named: name, contentsAt: localURL, parentPath: resolved.remotePath, parentID: resolved.parentID)
    }

    public func createFolder(named name: String, in container: ProviderContainerReference) async throws -> ProviderItem {
        let resolved = pathResolver.resolve(container)
        return try await backend.createFolder(named: name, parentPath: resolved.remotePath, parentID: resolved.parentID)
    }

    public func deleteItem(_ itemID: String) async throws {
        try await backend.delete(itemID: itemID)
    }

    public func moveItem(_ itemID: String, to destinationPath: String) async throws -> ProviderItem {
        try await backend.move(itemID: itemID, to: destinationPath)
    }

    public func changes(in container: ProviderContainerReference) async throws -> RemoteChangeSet {
        let resolved = pathResolver.resolve(container)
        return try await backend.pollRemoteChanges(parentID: resolved.parentID, remotePath: resolved.remotePath)
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, itemID: String, includeDescendants: Bool = true) async throws -> [String] {
        try await backend.setAvailabilityIntent(intent, itemID: itemID, includeDescendants: includeDescendants)
    }

    public func evictMaterializedContentForDiskPressure() async throws -> [String] {
        try await backend.evictMaterializedContentForDiskPressure()
    }

    public func search(query: String, pageToken: String? = nil, pageSize: Int? = nil) async throws -> ProviderPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return ProviderPage(items: [])
        }
        let containerKey = "search:" + normalizedQuery
        let requestedPageSize = pageSize ?? defaultPageSize
        if let pageToken {
            guard let token = PageToken(rawValue: pageToken), token.offset >= 0,
                  let snapshot = pageSnapshots[token.snapshotID], snapshot.container == containerKey else { throw ProviderEnumerationError.expired }
            return page(items: snapshot.items, snapshotID: token.snapshotID, offset: token.offset, pageSize: requestedPageSize, containerKey: containerKey)
        }
        let items: [ProviderItem]
        if let provider = backend as? FileProviderWorkingSetProviding {
            items = try await provider.workingSetItems()
        } else {
            items = try await backend.enumerate(parentID: nil, remotePath: "/")
        }
        let lowercasedQuery = normalizedQuery.lowercased()
        let matches = items
            .filter { item in
                item.filename.lowercased().contains(lowercasedQuery) ||
                    item.path?.lowercased().contains(lowercasedQuery) == true
            }
            .sorted { lhs, rhs in
                lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
            }
        let snapshotID = UUID().uuidString
        return page(items: matches, snapshotID: snapshotID, offset: 0, pageSize: requestedPageSize, containerKey: containerKey)
    }

    public func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary {
        guard let provider = backend as? FileProviderTransferProgressProviding else {
            return TransferProgressSummary(completedUnitCount: 0, totalUnitCount: 0, activeTransferCount: 0)
        }
        return try await provider.transferProgress(direction: direction)
    }

    private func page(items: [ProviderItem], snapshotID: String, offset: Int, pageSize: Int, containerKey: String) -> ProviderPage {
        let boundedPageSize = Swift.min(1000, Swift.max(1, pageSize))
        let offset = Swift.max(0, offset)
        guard offset < items.count else {
            pageSnapshots.removeValue(forKey: snapshotID)
            return ProviderPage(items: [])
        }
        let end = Swift.min(offset + boundedPageSize, items.count)
        let nextPageToken: String?
        if end < items.count {
            rememberPageSnapshot(items, snapshotID: snapshotID, containerKey: containerKey)
            nextPageToken = PageToken(snapshotID: snapshotID, offset: end).rawValue
        } else {
            nextPageToken = nil
        }
        return ProviderPage(items: Array(items[offset..<end]), nextPageToken: nextPageToken)
    }

    private func rememberPageSnapshot(_ items: [ProviderItem], snapshotID: String, containerKey: String) {
        pageSnapshots[snapshotID] = (containerKey, items)
        pageSnapshotOrder.removeAll { $0 == snapshotID }
        pageSnapshotOrder.append(snapshotID)
        while pageSnapshotOrder.count > maxPageSnapshots {
            let expiredSnapshotID = pageSnapshotOrder.removeFirst()
            pageSnapshots.removeValue(forKey: expiredSnapshotID)
        }
    }

}

private struct PageToken: Equatable {
    var snapshotID: String
    var offset: Int

    init(snapshotID: String, offset: Int) {
        self.snapshotID = snapshotID
        self.offset = offset
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let offset = Int(parts[1]) else { return nil }
        self.snapshotID = String(parts[0])
        self.offset = offset
    }

    var rawValue: String {
        "\(snapshotID):\(offset)"
    }
}

public enum ProviderContainerReference: Equatable, Sendable {
    case root
    case workingSet
    case item(id: String, path: String)
    case path(String)

    var parentID: String? {
        switch self {
        case .root, .workingSet: nil
        case .item(let id, _): id
        case .path(let path): path == "/" ? nil : path
        }
    }
}

public struct ResolvedProviderContainer: Equatable, Sendable {
    public var parentID: String?
    public var remotePath: String

    public init(parentID: String?, remotePath: String) {
        self.parentID = parentID
        self.remotePath = remotePath
    }
}

public protocol ProviderPathResolving: Sendable {
    func resolve(_ container: ProviderContainerReference) -> ResolvedProviderContainer
}

public struct ProviderPathResolver: ProviderPathResolving {
    public init() {}

    public func resolve(_ container: ProviderContainerReference) -> ResolvedProviderContainer {
        switch container {
        case .root:
            ResolvedProviderContainer(parentID: nil, remotePath: "/")
        case .workingSet:
            ResolvedProviderContainer(parentID: nil, remotePath: "/")
        case .item(let id, let path):
            ResolvedProviderContainer(parentID: id, remotePath: path)
        case .path(let path):
            ResolvedProviderContainer(parentID: path == "/" ? nil : path, remotePath: path)
        }
    }
}

extension FileProviderAdapter {
    public func currentSyncAnchor(in container: ProviderContainerReference) async throws -> Data {
        guard let provider = backend as? any FileProviderJournalProviding else { throw ProviderJournalError.expired }
        let context = try await provider.journalContext()
        return try ProviderSyncAnchor(epoch: context.state.epoch, presentation: context.presentation, container: journalContainerKey(container), position: context.state.position).data
    }

    public func changePage(in container: ProviderContainerReference, from data: Data, pageSize: Int = 200) async throws -> ProviderChangePage {
        guard let provider = backend as? any FileProviderJournalProviding else { throw ProviderJournalError.expired }
        var anchor = try ProviderSyncAnchor.decode(data)
        let context = try await provider.journalContext()
        guard anchor.epoch == context.state.epoch, anchor.presentation == context.presentation,
              anchor.container == journalContainerKey(container), anchor.position >= context.state.floor,
              anchor.position <= context.state.position else { throw ProviderJournalError.expired }
        let upper = anchor.upperBound ?? context.state.position
        guard upper >= anchor.position, upper <= context.state.position else { throw ProviderJournalError.expired }
        let batch = try await provider.journalChanges(after: anchor.position, through: upper, limit: min(1000, max(1, pageSize)))
        var updated: [String: ProviderItem] = [:]
        var deleted = Set<String>()
        let parent = pathResolver.resolve(container).parentID
        for entry in batch.entries {
            let belongs = container == .workingSet || entry.item.parentID == parent || entry.item.id == parent
            let belonged = entry.hadPrevious && (container == .workingSet || entry.previousParentID == parent || entry.item.id == parent)
            if belongs && !entry.deleted {
                updated[entry.item.id] = entry.item
                deleted.remove(entry.item.id)
            } else if belonged || belongs {
                updated.removeValue(forKey: entry.item.id)
                deleted.insert(entry.item.id)
            }
        }
        anchor.position = batch.position
        let more = batch.position < upper
        anchor.upperBound = more ? upper : nil
        return ProviderChangePage(updated: updated.values.sorted { $0.id < $1.id }, deleted: deleted.sorted(), anchor: try anchor.data, moreComing: more, position: batch.position, upperBound: upper)
    }

    private func journalContainerKey(_ container: ProviderContainerReference) -> String {
        switch container {
        case .workingSet: "workingSet"
        case .root: "root"
        case .item(let id, _): "item:" + id
        case .path(let path): "path:" + path
        }
    }
}
