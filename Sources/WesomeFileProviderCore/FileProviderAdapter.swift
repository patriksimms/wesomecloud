import Foundation
import SyncStore
import WesomeCloudShared

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

public protocol FileProviderWorkingSetChangeProviding: FileProviderWorkingSetProviding {
    func workingSetChanges(previousItems: [ProviderItem]) async throws -> RemoteChangeSet
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
    private var pageSnapshots: [String: [ProviderItem]] = [:]
    private var pageSnapshotOrder: [String] = []
    private var workingSetSnapshot: [String: ProviderItem] = [:]

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
        let requestedPageSize = pageSize ?? defaultPageSize
        if let pageToken, let token = PageToken(rawValue: pageToken), let items = pageSnapshots[token.snapshotID] {
            return page(items: items, snapshotID: token.snapshotID, offset: token.offset, pageSize: requestedPageSize)
        }
        if container == .workingSet {
            let items: [ProviderItem]
            if let provider = backend as? FileProviderWorkingSetProviding {
                items = try await provider.workingSetItems()
            } else {
                items = try await backend.enumerate(parentID: nil, remotePath: "/")
            }
            rememberWorkingSetSnapshot(items)
            let snapshotID = UUID().uuidString
            return page(items: items, snapshotID: snapshotID, offset: Int(pageToken ?? "") ?? 0, pageSize: requestedPageSize)
        }
        let resolved = pathResolver.resolve(container)
        let items = try await backend.enumerate(parentID: resolved.parentID, remotePath: resolved.remotePath)
        let snapshotID = UUID().uuidString
        return page(items: items, snapshotID: snapshotID, offset: Int(pageToken ?? "") ?? 0, pageSize: requestedPageSize)
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
        if container == .workingSet {
            return try await workingSetChanges()
        }
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
        let requestedPageSize = pageSize ?? defaultPageSize
        if let pageToken, let token = PageToken(rawValue: pageToken), let items = pageSnapshots[token.snapshotID] {
            return page(items: items, snapshotID: token.snapshotID, offset: token.offset, pageSize: requestedPageSize)
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
        return page(items: matches, snapshotID: snapshotID, offset: Int(pageToken ?? "") ?? 0, pageSize: requestedPageSize)
    }

    public func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary {
        guard let provider = backend as? FileProviderTransferProgressProviding else {
            return TransferProgressSummary(completedUnitCount: 0, totalUnitCount: 0, activeTransferCount: 0)
        }
        return try await provider.transferProgress(direction: direction)
    }

    private func page(items: [ProviderItem], snapshotID: String, offset: Int, pageSize: Int) -> ProviderPage {
        let boundedPageSize = Swift.max(1, pageSize)
        let offset = Swift.max(0, offset)
        guard offset < items.count else {
            pageSnapshots.removeValue(forKey: snapshotID)
            return ProviderPage(items: [])
        }
        let end = Swift.min(offset + boundedPageSize, items.count)
        let nextPageToken: String?
        if end < items.count {
            rememberPageSnapshot(items, snapshotID: snapshotID)
            nextPageToken = PageToken(snapshotID: snapshotID, offset: end).rawValue
        } else {
            forgetPageSnapshot(snapshotID)
            nextPageToken = nil
        }
        return ProviderPage(items: Array(items[offset..<end]), nextPageToken: nextPageToken)
    }

    private func rememberPageSnapshot(_ items: [ProviderItem], snapshotID: String) {
        pageSnapshots[snapshotID] = items
        pageSnapshotOrder.removeAll { $0 == snapshotID }
        pageSnapshotOrder.append(snapshotID)
        while pageSnapshotOrder.count > maxPageSnapshots {
            let expiredSnapshotID = pageSnapshotOrder.removeFirst()
            pageSnapshots.removeValue(forKey: expiredSnapshotID)
        }
    }

    private func forgetPageSnapshot(_ snapshotID: String) {
        pageSnapshots.removeValue(forKey: snapshotID)
        pageSnapshotOrder.removeAll { $0 == snapshotID }
    }

    private func workingSetChanges() async throws -> RemoteChangeSet {
        let previousItems = workingSetSnapshot.values.sorted { $0.id < $1.id }
        let changes: RemoteChangeSet
        if let provider = backend as? FileProviderWorkingSetChangeProviding {
            changes = try await provider.workingSetChanges(previousItems: previousItems)
            let current = try await provider.workingSetItems()
            rememberWorkingSetSnapshot(current)
            return changes
        }

        let current: [ProviderItem]
        if let provider = backend as? FileProviderWorkingSetProviding {
            current = try await provider.workingSetItems()
        } else {
            current = try await backend.enumerate(parentID: nil, remotePath: "/")
        }
        changes = diffWorkingSet(previous: workingSetSnapshot, current: current)
        rememberWorkingSetSnapshot(current)
        return changes
    }

    private func rememberWorkingSetSnapshot(_ items: [ProviderItem]) {
        workingSetSnapshot = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private func diffWorkingSet(previous: [String: ProviderItem], current: [ProviderItem]) -> RemoteChangeSet {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let added = current.filter { previous[$0.id] == nil }
        let updated = current.filter { item in
            guard let previousItem = previous[item.id] else { return false }
            return previousItem != item
        }
        let deleted = previous.keys
            .filter { currentByID[$0] == nil }
            .sorted()
            .map { DeletedProviderItem(id: $0) }
        return RemoteChangeSet(added: added, updated: updated, deletedItems: deleted)
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
