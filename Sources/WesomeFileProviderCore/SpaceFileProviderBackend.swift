import Foundation
import SyncStore
import WesomeCloudShared

/// Finder identifiers are scoped to a space; server IDs can repeat across spaces.
public enum ProviderSpaceIdentifier {
    public static let domainID = "wesomecloud"

    public static func folder(_ spaceID: String) -> String {
        "space:" + Data(spaceID.utf8).base64EncodedString()
    }

    public static func item(_ itemID: String, spaceID: String) -> String {
        folder(spaceID) + ":" + itemID
    }

    public static func parse(_ identifier: String) -> (spaceID: String, itemID: String?)? {
        let parts = identifier.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "space",
              let data = Data(base64Encoded: String(parts[1])),
              let spaceID = String(data: data, encoding: .utf8) else { return nil }
        return (spaceID, parts.count == 3 ? String(parts[2]) : nil)
    }
}

public struct ProviderSpace: Sendable {
    public var id: String
    public var name: String
    public var rootPath: String
    public var backend: @Sendable () async throws -> any FileProviderBackend

    public init(id: String, name: String, rootPath: String = "/", backend: @escaping @Sendable () async throws -> any FileProviderBackend) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.backend = backend
    }

    var folder: ProviderItem {
        ProviderItem(
            id: ProviderSpaceIdentifier.folder(id), parentID: nil, filename: name,
            kind: .folder, size: nil, path: "/" + name,
            contentVersion: Data(id.utf8), metadataVersion: Data(name.utf8),
            availabilityIntent: .unspecified, capabilities: [.enumerate, .addChildren]
        )
    }

    public func presenting(_ item: ProviderItem) -> ProviderItem {
        var item = item
        item.id = ProviderSpaceIdentifier.item(item.id, spaceID: id)
        item.parentID = item.parentID.flatMap { parent in
            parent == rootPath ? nil : ProviderSpaceIdentifier.item(parent, spaceID: id)
        } ?? folder.id
        if let path = item.path { item.path = presentationPath(path) }
        return item
    }

    func presentationPath(_ remotePath: String) -> String {
        let relative = rootPath == "/" ? remotePath : String(remotePath.dropFirst(rootPath.count))
        return ("/" + name) + (relative.hasPrefix("/") ? relative : "/" + relative)
    }

    func remotePath(_ path: String) throws -> String {
        let prefix = "/" + name
        guard path == prefix || path.hasPrefix(prefix + "/") else {
            throw WesomeCloudError.unsupported("Moving files between spaces is not supported. Copy the file instead.")
        }
        let relative = String(path.dropFirst(prefix.count))
        return rootPath == "/" ? (relative.isEmpty ? "/" : relative) : rootPath + relative
    }
}

/// Loads selections for each request so adding, removing or renaming a space does not
/// require restarting the File Provider extension. Each space retains its own sync store.
public actor SpaceFileProviderBackend: FileProviderBackend, FileProviderWorkingSetProviding, FileProviderPartialContentProviding, FileProviderTransferProgressProviding {
    private let spacesProvider: @Sendable () async throws -> [ProviderSpace]
    private var rootSnapshot: [String: ProviderItem] = [:]

    public init(spaces: @escaping @Sendable () async throws -> [ProviderSpace]) {
        self.spacesProvider = spaces
    }

    private func spaces() async throws -> [ProviderSpace] {
        var spaces = try await spacesProvider().sorted { $0.id < $1.id }
        // Finder names must be unique, including on case-insensitive volumes.
        var used = Set<String>()
        for index in spaces.indices {
            let rawName = spaces[index].name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let base = rawName.isEmpty || rawName == "." || rawName == ".." ? "Space" : rawName
            var name = base
            var suffix = 2
            while !used.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
            spaces[index].name = name
        }
        return spaces
    }

    private func resolve(_ identifier: String) async throws -> (ProviderSpace, String?) {
        guard let parsed = ProviderSpaceIdentifier.parse(identifier),
              let space = try await spaces().first(where: { $0.id == parsed.spaceID }) else {
            throw WesomeCloudError.missingItem(identifier)
        }
        return (space, parsed.itemID)
    }

    private func resolveItem(_ identifier: String) async throws -> (ProviderSpace, String) {
        let (space, itemID) = try await resolve(identifier)
        guard let itemID else { throw WesomeCloudError.unsupported("Space folders cannot be modified.") }
        return (space, itemID)
    }

    private func parent(_ parentID: String?) async throws -> (ProviderSpace, String?, String) {
        guard let parentID else { throw WesomeCloudError.unsupported("Create files inside a space folder.") }
        let (space, itemID) = try await resolve(parentID)
        // Cache misses can supply an identifier-shaped path. Resolve folders from the backend.
        let remotePath: String
        if let itemID {
            guard let item = try await space.backend().item(itemID: itemID), let path = item.path else {
                throw WesomeCloudError.missingItem(parentID)
            }
            remotePath = path
        } else {
            remotePath = space.rootPath
        }
        return (space, itemID, remotePath)
    }

    public func enumerate(parentID: String?, remotePath: String) async throws -> [ProviderItem] {
        guard parentID != nil else {
            let folders = try await spaces().map(\.folder)
            rootSnapshot = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            return folders
        }
        let (space, parentID, path) = try await parent(parentID)
        return try await space.backend().enumerate(parentID: parentID, remotePath: path).map(space.presenting)
    }

    public func item(itemID: String) async throws -> ProviderItem? {
        let (space, remoteID) = try await resolve(itemID)
        guard let remoteID else { return space.folder }
        return try await space.backend().item(itemID: remoteID).map(space.presenting)
    }

    public func fetchContents(itemID: String) async throws -> URL {
        let (space, remoteID) = try await resolveItem(itemID)
        return try await space.backend().fetchContents(itemID: remoteID)
    }

    public func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        let (space, remoteID) = try await resolveItem(itemID)
        return try await space.presenting(space.backend().uploadModifiedContents(itemID: remoteID, contentsAt: localURL))
    }

    public func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem {
        let (space, parentID, path) = try await parent(parentID)
        return try await space.presenting(space.backend().createFile(named: name, contentsAt: localURL, parentPath: path, parentID: parentID))
    }

    public func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem {
        let (space, parentID, path) = try await parent(parentID)
        return try await space.presenting(space.backend().createFolder(named: name, parentPath: path, parentID: parentID))
    }

    public func delete(itemID: String) async throws {
        let (space, remoteID) = try await resolveItem(itemID)
        try await space.backend().delete(itemID: remoteID)
    }

    public func move(itemID: String, to destinationPath: String) async throws -> ProviderItem {
        let (space, remoteID) = try await resolveItem(itemID)
        let path = try space.remotePath(destinationPath)
        return try await space.presenting(space.backend().move(itemID: remoteID, to: path))
    }

    public func pollRemoteChanges(parentID: String?, remotePath: String) async throws -> RemoteChangeSet {
        guard parentID != nil else {
            let previous = rootSnapshot
            let folders = try await enumerate(parentID: nil, remotePath: "/")
            return RemoteChangeSet(
                added: folders.filter { previous[$0.id] == nil },
                updated: folders.filter { previous[$0.id] != nil && previous[$0.id] != $0 },
                deleted: previous.keys.filter { rootSnapshot[$0] == nil }.sorted()
            )
        }
        let (space, parentID, path) = try await parent(parentID)
        let changes = try await space.backend().pollRemoteChanges(parentID: parentID, remotePath: path)
        return RemoteChangeSet(added: changes.added.map(space.presenting), updated: changes.updated.map(space.presenting), deletedItems: changes.deletedItems.map {
            DeletedProviderItem(id: ProviderSpaceIdentifier.item($0.id, spaceID: space.id),
                                parentID: $0.parentID.map { ProviderSpaceIdentifier.item($0, spaceID: space.id) } ?? space.folder.id,
                                path: $0.path.map(space.presentationPath))
        })
    }

    public func workingSetItems() async throws -> [ProviderItem] {
        let spaces = try await spaces()
        var items = spaces.map(\.folder)
        for space in spaces {
            if let provider = try await space.backend() as? any FileProviderWorkingSetProviding {
                items += try await provider.workingSetItems().map(space.presenting)
            }
        }
        return items
    }

    public func fetchPartialContents(itemID: String, requestedRange: ProviderContentRange, alignment: Int64) async throws -> PartialProviderContent {
        let (space, remoteID) = try await resolveItem(itemID)
        let backend = try await space.backend()
        if let provider = backend as? any FileProviderPartialContentProviding {
            var contents = try await provider.fetchPartialContents(itemID: remoteID, requestedRange: requestedRange, alignment: alignment)
            contents.item = space.presenting(contents.item)
            return contents
        }
        let url = try await backend.fetchContents(itemID: remoteID)
        guard let item = try await backend.item(itemID: remoteID) else { throw WesomeCloudError.missingItem(itemID) }
        return PartialProviderContent(url: url, item: space.presenting(item), retrievedRange: ProviderContentRange(offset: 0, length: item.size ?? 0))
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, itemID: String, includeDescendants: Bool) async throws -> [String] {
        let (space, remoteID) = try await resolve(itemID)
        let backend = try await space.backend()
        let remoteIDs: [String]
        if let remoteID {
            remoteIDs = [remoteID]
        } else if includeDescendants {
            remoteIDs = try await backend.enumerate(parentID: nil, remotePath: space.rootPath).map(\.id)
        } else {
            return []
        }
        var changed: [String] = []
        for remoteID in remoteIDs {
            changed += try await backend.setAvailabilityIntent(intent, itemID: remoteID, includeDescendants: includeDescendants).map {
                ProviderSpaceIdentifier.item($0, spaceID: space.id)
            }
        }
        return changed
    }

    public func evictMaterializedContentForDiskPressure() async throws -> [String] {
        var identifiers: [String] = []
        for space in try await spaces() {
            identifiers += try await space.backend().evictMaterializedContentForDiskPressure().map {
                ProviderSpaceIdentifier.item($0, spaceID: space.id)
            }
        }
        return identifiers
    }

    public func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary {
        var summary = TransferProgressSummary(completedUnitCount: 0, totalUnitCount: 0, activeTransferCount: 0)
        for space in try await spaces() {
            if let provider = try await space.backend() as? any FileProviderTransferProgressProviding {
                let progress = try await provider.transferProgress(direction: direction)
                summary.completedUnitCount += progress.completedUnitCount
                summary.totalUnitCount += progress.totalUnitCount
                summary.activeTransferCount += progress.activeTransferCount
            }
        }
        return summary
    }
}
