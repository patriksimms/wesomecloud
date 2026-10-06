import Foundation
import SyncStore
import WesomeFileProviderCore

public struct CachedProviderItem: Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var filename: String
    public var path: String

    public init(id: String, parentID: String?, filename: String, path: String) {
        self.id = id
        self.parentID = parentID
        self.filename = filename
        self.path = path
    }
}

public actor ExtensionItemCache {
    private var items: [String: CachedProviderItem] = [:]

    public init() {}

    public init(storedItems: [StoredItem]) {
        items = Dictionary(uniqueKeysWithValues: storedItems.map { item in
            (item.remote.id, Self.cachedProviderItem(from: item))
        })
    }

    public func register(_ item: ProviderItem, parentPath: String?) {
        let path = item.path ?? makePath(parentPath: parentPath, filename: item.filename)
        items[item.id] = CachedProviderItem(id: item.id, parentID: item.parentID, filename: item.filename, path: path)
    }

    public func warm(with storedItems: [StoredItem]) {
        for item in storedItems {
            registerStored(item)
        }
    }

    public func register(_ page: ProviderPage, container: ProviderContainerReference) {
        let parentPath = container.remotePathForCache
        for item in page.items {
            register(item, parentPath: parentPath)
        }
    }

    public func cachedItem(id: String) -> CachedProviderItem? {
        items[id]
    }

    public func hasCachedDescendants(id: String) -> Bool {
        guard let item = items[id] else { return false }
        let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
        return items.values.contains { $0.path.hasPrefix(prefix) }
    }

    public func remove(id: String) {
        guard let removed = items.removeValue(forKey: id) else { return }
        let removedPrefix = removed.path.hasSuffix("/") ? removed.path : removed.path + "/"
        items = items.filter { _, item in
            !item.path.hasPrefix(removedPrefix)
        }
    }

    public func containerReference(for identifier: String) -> ProviderContainerReference {
        guard let item = items[identifier] else {
            return .item(id: identifier, path: "/" + identifier)
        }
        return .item(id: item.id, path: item.path)
    }

    public func parentPath(for identifier: String) -> String {
        guard let parentID = items[identifier]?.parentID else { return "/" }
        return items[parentID]?.path ?? "/"
    }

    public func destinationPath(parentID: String?, filename: String) -> String {
        let parentPath: String
        if let parentID {
            parentPath = items[parentID]?.path ?? "/"
        } else {
            parentPath = "/"
        }
        return makePath(parentPath: parentPath, filename: filename)
    }

    private func makePath(parentPath: String?, filename: String) -> String {
        let parent = parentPath ?? "/"
        if parent == "/" { return "/" + filename }
        return parent.hasSuffix("/") ? parent + filename : parent + "/" + filename
    }

    private func registerStored(_ item: StoredItem) {
        items[item.remote.id] = Self.cachedProviderItem(from: item)
    }

    private static func cachedProviderItem(from item: StoredItem) -> CachedProviderItem {
        CachedProviderItem(
            id: item.remote.id,
            parentID: item.remote.parentID,
            filename: item.remote.name,
            path: item.remote.path
        )
    }
}

private extension ProviderContainerReference {
    var remotePathForCache: String {
        switch self {
        case .root, .workingSet: "/"
        case .item(_, let path): path
        case .path(let path): path
        }
    }
}
