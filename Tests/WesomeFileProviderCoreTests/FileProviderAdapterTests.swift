import Foundation
import SyncStore
import Testing
import WesomeCloudShared
@testable import WesomeFileProviderCore

private actor StubProviderBackend: FileProviderBackend, FileProviderWorkingSetProviding {
    var calls: [String] = []
    var items: [ProviderItem]
    var fetchedURL: URL

    init(items: [ProviderItem], fetchedURL: URL = FileManager.default.temporaryDirectory) {
        self.items = items
        self.fetchedURL = fetchedURL
    }

    func enumerate(parentID: String?, remotePath: String) async throws -> [ProviderItem] {
        calls.append("enumerate:\(parentID ?? "nil"):\(remotePath)")
        return items
    }

    func workingSetItems() async throws -> [ProviderItem] {
        calls.append("workingSet")
        return items
    }

    func item(itemID: String) async throws -> ProviderItem? {
        calls.append("item:\(itemID)")
        return items.first { $0.id == itemID }
    }

    func fetchContents(itemID: String) async throws -> URL {
        calls.append("fetch:\(itemID)")
        return fetchedURL
    }

    func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        calls.append("upload:\(itemID):\(localURL.path)")
        return items[0]
    }

    func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem {
        calls.append("createFile:\(name):\(localURL.path):\(parentID ?? "nil"):\(parentPath)")
        return items[0]
    }

    func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem {
        calls.append("createFolder:\(name):\(parentID ?? "nil"):\(parentPath)")
        return items[0]
    }

    func delete(itemID: String) async throws {
        calls.append("delete:\(itemID)")
    }

    func move(itemID: String, to destinationPath: String) async throws -> ProviderItem {
        calls.append("move:\(itemID):\(destinationPath)")
        return items[0]
    }

    func pollRemoteChanges(parentID: String?, remotePath: String) async throws -> RemoteChangeSet {
        calls.append("changes:\(parentID ?? "nil"):\(remotePath)")
        return RemoteChangeSet(updated: items)
    }

    func setAvailabilityIntent(_ intent: AvailabilityIntent, itemID: String, includeDescendants: Bool) async throws -> [String] {
        calls.append("availability:\(itemID):\(intent.rawValue):\(includeDescendants)")
        return [itemID]
    }

    func evictMaterializedContentForDiskPressure() async throws -> [String] {
        calls.append("evictDiskPressure")
        return items.map(\.id)
    }

    func setItems(_ items: [ProviderItem]) {
        self.items = items
    }
}

private actor CustomWorkingSetChangeBackend: FileProviderBackend, FileProviderWorkingSetChangeProviding {
    var items: [ProviderItem]
    var calls: [String] = []
    var customChanges = RemoteChangeSet()

    init(items: [ProviderItem]) {
        self.items = items
    }

    func enumerate(parentID _: String?, remotePath _: String) async throws -> [ProviderItem] { items }
    func item(itemID: String) async throws -> ProviderItem? { items.first { $0.id == itemID } }
    func fetchContents(itemID _: String) async throws -> URL { FileManager.default.temporaryDirectory }
    func uploadModifiedContents(itemID _: String, contentsAt _: URL) async throws -> ProviderItem { items[0] }
    func createFile(named _: String, contentsAt _: URL, parentPath _: String, parentID _: String?) async throws -> ProviderItem { items[0] }
    func createFolder(named _: String, parentPath _: String, parentID _: String?) async throws -> ProviderItem { items[0] }
    func delete(itemID _: String) async throws {}
    func move(itemID _: String, to _: String) async throws -> ProviderItem { items[0] }
    func pollRemoteChanges(parentID _: String?, remotePath _: String) async throws -> RemoteChangeSet { RemoteChangeSet() }
    func setAvailabilityIntent(_: AvailabilityIntent, itemID: String, includeDescendants _: Bool) async throws -> [String] { [itemID] }
    func evictMaterializedContentForDiskPressure() async throws -> [String] { [] }

    func workingSetItems() async throws -> [ProviderItem] {
        calls.append("workingSet")
        return items
    }

    func workingSetChanges(previousItems: [ProviderItem]) async throws -> RemoteChangeSet {
        calls.append("workingSetChanges:\(previousItems.map(\.id).joined(separator: ","))")
        return customChanges
    }

    func setItems(_ items: [ProviderItem]) {
        self.items = items
    }

    func setCustomChanges(_ changes: RemoteChangeSet) {
        customChanges = changes
    }
}

@Test
func adapterMapsContainersAndDelegatesCallbacks() async throws {
    let item = ProviderItem(stored: StoredItem(remote: RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)))
    let backend = StubProviderBackend(items: [item])
    let adapter = FileProviderAdapter(backend: backend)

    let rootPage = try await adapter.enumerate(container: .root)
    let nestedPage = try await adapter.enumerate(container: .item(id: "folder", path: "/Folder"))
    let localURL = FileManager.default.temporaryDirectory.appending(path: "Child.txt")
    let lookedUpItem = try await adapter.itemForIdentifier("folder", parentPath: "/Stale")
    _ = try await adapter.createFile(named: "Child.txt", contentsAt: localURL, in: .item(id: "folder", path: "/Folder"))
    _ = try await adapter.createFolder(named: "Child", in: .item(id: "folder", path: "/Folder"))
    _ = try await adapter.changes(in: .path("/Folder"))
    _ = try await adapter.setAvailabilityIntent(.onlineOnly, itemID: "folder", includeDescendants: false)
    _ = try await adapter.evictMaterializedContentForDiskPressure()

    #expect(rootPage.items == [item])
    #expect(nestedPage.items == [item])
    #expect(lookedUpItem == item)
    #expect(await backend.calls == [
        "enumerate:nil:/",
        "enumerate:folder:/Folder",
        "item:folder",
        "createFile:Child.txt:\(localURL.path):folder:/Folder",
        "createFolder:Child:folder:/Folder",
        "changes:/Folder:/Folder",
        "availability:folder:onlineOnly:false",
        "evictDiskPressure",
    ])
}

@Test
func adapterFallsBackToParentEnumerationWhenDirectItemLookupMisses() async throws {
    let item = ProviderItem(stored: StoredItem(remote: RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file)))
    let backend = StubProviderBackend(items: [item])
    let adapter = FileProviderAdapter(backend: backend)

    let found = try await adapter.itemForIdentifier("missing-direct-item", parentPath: "/Folder")

    #expect(found == nil)
    #expect(await backend.calls == [
        "item:missing-direct-item",
        "enumerate:/Folder:/Folder",
    ])
}

@Test
func adapterSearchesVisibleWorkingSetItemsByNameAndPath() async throws {
    let report = ProviderItem(
        id: "report",
        parentID: nil,
        filename: "Quarterly Report.pdf",
        kind: .file,
        size: 10,
        path: "/Finance/Quarterly Report.pdf",
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let notes = ProviderItem(
        id: "notes",
        parentID: nil,
        filename: "Meeting Notes.txt",
        kind: .file,
        size: 10,
        path: "/Report Planning/Meeting Notes.txt",
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let unrelated = ProviderItem(
        id: "photo",
        parentID: nil,
        filename: "Photo.jpg",
        kind: .file,
        size: 10,
        path: "/Photos/Photo.jpg",
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let backend = StubProviderBackend(items: [unrelated, notes, report])
    let adapter = FileProviderAdapter(backend: backend, defaultPageSize: 1)

    let firstPage = try await adapter.search(query: "report")
    let token = try #require(firstPage.nextPageToken)
    let secondPage = try await adapter.search(query: "report", pageToken: token)

    #expect(firstPage.items.map(\.id) == ["notes"])
    #expect(secondPage.items.map(\.id) == ["report"])
    #expect(secondPage.nextPageToken == nil)
    #expect(await backend.calls.filter { $0 == "workingSet" }.count == 1)
}

@Test
func adapterSlicesEnumerationIntoStablePages() async throws {
    let items = (0..<5).map { index in
        ProviderItem(
            id: "item-\(index)",
            parentID: nil,
            filename: "Item \(index).txt",
            kind: .file,
            size: Int64(index),
            contentVersion: Data("content-\(index)".utf8),
            metadataVersion: Data("metadata-\(index)".utf8),
            availabilityIntent: .unspecified,
            capabilities: [.read]
        )
    }
    let backend = StubProviderBackend(items: items)
    let adapter = FileProviderAdapter(backend: backend, defaultPageSize: 2)

    let first = try await adapter.enumerate(container: .root)
    let second = try await adapter.enumerate(container: .root, pageToken: first.nextPageToken)
    let third = try await adapter.enumerate(container: .root, pageToken: second.nextPageToken)
    let empty = try await adapter.enumerate(container: .root, pageToken: "99")

    #expect(first.items.map(\.id) == ["item-0", "item-1"])
    #expect(first.nextPageToken != nil)
    #expect(second.items.map(\.id) == ["item-2", "item-3"])
    #expect(second.nextPageToken != nil)
    #expect(third.items.map(\.id) == ["item-4"])
    #expect(third.nextPageToken == nil)
    #expect(empty.items.isEmpty)
    #expect(empty.nextPageToken == nil)
}

@Test
func adapterKeepsPagedEnumerationStableWhenBackendChangesBetweenPages() async throws {
    let items = (0..<5).map { index in
        ProviderItem(
            id: "item-\(index)",
            parentID: nil,
            filename: "Item \(index).txt",
            kind: .file,
            size: Int64(index),
            contentVersion: Data("content-\(index)".utf8),
            metadataVersion: Data("metadata-\(index)".utf8),
            availabilityIntent: .unspecified,
            capabilities: [.read]
        )
    }
    let inserted = ProviderItem(
        id: "inserted",
        parentID: nil,
        filename: "Inserted.txt",
        kind: .file,
        size: 99,
        contentVersion: Data("inserted".utf8),
        metadataVersion: Data("inserted".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let backend = StubProviderBackend(items: items)
    let adapter = FileProviderAdapter(backend: backend, defaultPageSize: 2)

    let first = try await adapter.enumerate(container: .root)
    await backend.setItems([inserted] + items)
    let second = try await adapter.enumerate(container: .root, pageToken: first.nextPageToken)
    let third = try await adapter.enumerate(container: .root, pageToken: second.nextPageToken)
    let fresh = try await adapter.enumerate(container: .root)

    #expect(first.items.map(\.id) == ["item-0", "item-1"])
    #expect(second.items.map(\.id) == ["item-2", "item-3"])
    #expect(third.items.map(\.id) == ["item-4"])
    #expect(fresh.items.map(\.id) == ["inserted", "item-0"])
    #expect(await backend.calls.filter { $0 == "enumerate:nil:/" }.count == 2)
}

@Test
func adapterBoundsAbandonedPageSnapshots() async throws {
    func pageItems(prefix: String) -> [ProviderItem] {
        (0..<3).map { index in
            ProviderItem(
                id: "\(prefix)-\(index)",
                parentID: nil,
                filename: "\(prefix) \(index).txt",
                kind: .file,
                size: Int64(index),
                contentVersion: Data("\(prefix)-content-\(index)".utf8),
                metadataVersion: Data("\(prefix)-metadata-\(index)".utf8),
                availabilityIntent: .unspecified,
                capabilities: [.read]
            )
        }
    }
    let backend = StubProviderBackend(items: pageItems(prefix: "first"))
    let adapter = FileProviderAdapter(
        backend: backend,
        pathResolver: ProviderPathResolver(),
        defaultPageSize: 1,
        maxPageSnapshots: 2
    )

    let first = try await adapter.enumerate(container: .root)
    let firstToken = try #require(first.nextPageToken)
    await backend.setItems(pageItems(prefix: "second"))
    let second = try await adapter.enumerate(container: .root)
    let secondToken = try #require(second.nextPageToken)
    await backend.setItems(pageItems(prefix: "third"))
    let third = try await adapter.enumerate(container: .root)
    _ = try #require(third.nextPageToken)
    await backend.setItems(pageItems(prefix: "fresh"))

    let retained = try await adapter.enumerate(container: .root, pageToken: secondToken)
    let evicted = try await adapter.enumerate(container: .root, pageToken: firstToken)

    #expect(first.items.map(\.id) == ["first-0"])
    #expect(second.items.map(\.id) == ["second-0"])
    #expect(third.items.map(\.id) == ["third-0"])
    #expect(retained.items.map(\.id) == ["second-1"])
    #expect(evicted.items.map(\.id) == ["fresh-0"])
    #expect(await backend.calls.filter { $0 == "enumerate:nil:/" }.count == 4)
}

@Test
func adapterComputesWorkingSetChangesFromStoredWorkingSetSnapshots() async throws {
    let existing = ProviderItem(
        id: "existing",
        parentID: nil,
        filename: "Existing.txt",
        kind: .file,
        size: 1,
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("m1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let removed = ProviderItem(
        id: "removed",
        parentID: nil,
        filename: "Removed.txt",
        kind: .file,
        size: 2,
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("m1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let updated = ProviderItem(
        id: "existing",
        parentID: nil,
        filename: "Existing.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("v2".utf8),
        metadataVersion: Data("m2".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let added = ProviderItem(
        id: "added",
        parentID: "folder",
        filename: "Added.txt",
        kind: .file,
        size: 4,
        path: "/Folder/Added.txt",
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("m1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let backend = StubProviderBackend(items: [existing, removed])
    let adapter = FileProviderAdapter(backend: backend)

    _ = try await adapter.enumerate(container: .workingSet)
    await backend.setItems([updated, added])
    let changes = try await adapter.changes(in: .workingSet)

    #expect(changes.added == [added])
    #expect(changes.updated == [updated])
    #expect(changes.deleted == ["removed"])
    #expect(await backend.calls == [
        "workingSet",
        "workingSet",
    ])
}

@Test
func adapterUsesDedicatedWorkingSetChangeProviderWhenAvailable() async throws {
    let existing = ProviderItem(
        id: "existing",
        parentID: nil,
        filename: "Existing.txt",
        kind: .file,
        size: 1,
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("m1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let added = ProviderItem(
        id: "added",
        parentID: nil,
        filename: "Added.txt",
        kind: .file,
        size: 2,
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("m1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let backend = CustomWorkingSetChangeBackend(items: [existing])
    let adapter = FileProviderAdapter(backend: backend)

    _ = try await adapter.enumerate(container: .workingSet)
    await backend.setItems([existing, added])
    await backend.setCustomChanges(RemoteChangeSet(added: [added]))
    let changes = try await adapter.changes(in: .workingSet)

    #expect(changes.added == [added])
    #expect(changes.updated.isEmpty)
    #expect(changes.deleted.isEmpty)
    #expect(await backend.calls == [
        "workingSet",
        "workingSetChanges:existing",
        "workingSet",
    ])
}

@Test
func providerItemTreatsFinderPackagesAsDocuments() {
    let item = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "deck",
        parentID: nil,
        name: "Launch.key",
        path: "/Launch.key",
        kind: .folder
    )))

    #expect(item.contentType == nil)
    #expect(item.capabilities.contains(.read))
    #expect(item.capabilities.contains(.write))
    #expect(!item.capabilities.contains(.enumerate))
    #expect(!item.capabilities.contains(.addChildren))
}

@Test(arguments: [true, false])
func providerItemMapsOwnCloudFilePermissionsToCapabilities(canShare: Bool) {
    let readOnly = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "read-only",
        parentID: nil,
        name: "Readme.md",
        path: "/Readme.md",
        kind: .file,
        permissions: canShare ? "R" : "S"
    )))
    let editable = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "editable",
        parentID: nil,
        name: "Notes.md",
        path: "/Notes.md",
        kind: .file,
        permissions: canShare ? "RDNW" : "DNW"
    )))

    #expect(readOnly.capabilities == [.read])
    #expect(editable.capabilities.contains(.read))
    #expect(editable.capabilities.contains(.write))
    #expect(editable.capabilities.contains(.rename))
    #expect(editable.capabilities.contains(.delete))
    #expect(!editable.capabilities.contains(.reparent))
}

@Test
func providerItemMetadataVersionChangesWhenServerMetadataChanges() {
    let base = RemoteItem(
        id: "readme",
        parentID: nil,
        name: "Readme.md",
        path: "/Readme.md",
        kind: .file,
        size: 12,
        etag: "v1",
        fileID: "file-1",
        checksum: "SHA1:abc",
        permissions: "R",
        quotaUsedBytes: 1024,
        quotaAvailableBytes: 2048,
        privateLink: URL(string: "https://cloud.example/f/1")
    )
    var changedPermissions = base
    changedPermissions.permissions = "RDNW"
    var changedChecksum = base
    changedChecksum.checksum = "SHA1:def"
    var changedFileID = base
    changedFileID.fileID = "file-2"
    var changedQuota = base
    changedQuota.quotaAvailableBytes = 4096
    var changedPrivateLink = base
    changedPrivateLink.privateLink = URL(string: "https://cloud.example/f/2")

    let baseVersion = ProviderItem(stored: StoredItem(remote: base)).metadataVersion

    #expect(ProviderItem(stored: StoredItem(remote: changedPermissions)).metadataVersion != baseVersion)
    #expect(ProviderItem(stored: StoredItem(remote: changedChecksum)).metadataVersion != baseVersion)
    #expect(ProviderItem(stored: StoredItem(remote: changedFileID)).metadataVersion != baseVersion)
    #expect(ProviderItem(stored: StoredItem(remote: changedQuota)).metadataVersion != baseVersion)
    #expect(ProviderItem(stored: StoredItem(remote: changedPrivateLink)).metadataVersion != baseVersion)
}

@Test
func providerItemVersionComponentsStayWithinFileProviderLimit() {
    let item = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: String(repeating: "id", count: 200),
        parentID: String(repeating: "parent", count: 80),
        name: String(repeating: "LongName", count: 80) + ".txt",
        path: "/" + String(repeating: "Nested/", count: 80) + "File.txt",
        kind: .file,
        size: 12,
        etag: String(repeating: "etag", count: 200),
        fileID: String(repeating: "file", count: 200),
        checksum: String(repeating: "checksum", count: 200),
        permissions: String(repeating: "RDNVW", count: 80),
        quotaUsedBytes: 1024,
        quotaAvailableBytes: 2048,
        privateLink: URL(string: "https://cloud.example/f/" + String(repeating: "token", count: 200))
    )))

    #expect(item.contentVersion.count <= 128)
    #expect(item.metadataVersion.count <= 128)
    #expect(item.contentVersion.count == 32)
    #expect(item.metadataVersion.count == 32)
}

@Test(arguments: [true, false])
func providerItemMapsOwnCloudFolderPermissionsToCapabilities(canShare: Bool) {
    let readOnly = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "folder",
        parentID: nil,
        name: "Folder",
        path: "/Folder",
        kind: .folder,
        permissions: canShare ? "R" : "S"
    )))
    let writable = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "writable",
        parentID: nil,
        name: "Writable",
        path: "/Writable",
        kind: .folder,
        permissions: canShare ? "RDNVC" : "DNVC"
    )))

    #expect(readOnly.capabilities == [.enumerate])
    #expect(writable.capabilities.contains(.enumerate))
    #expect(writable.capabilities.contains(.rename))
    #expect(writable.capabilities.contains(.reparent))
    #expect(writable.capabilities.contains(.delete))
    #expect(writable.capabilities.contains(.addChildren))
    #expect(!writable.capabilities.contains(.write))
}

@Test(arguments: [true, false])
func providerItemMapsFinderPackagePermissionsAsDocumentCapabilities(canShare: Bool) {
    let item = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "deck",
        parentID: nil,
        name: "Launch.key",
        path: "/Launch.key",
        kind: .folder,
        permissions: canShare ? "RDNW" : "DNW"
    )))

    #expect(item.capabilities.contains(.read))
    #expect(item.capabilities.contains(.write))
    #expect(item.capabilities.contains(.rename))
    #expect(!item.capabilities.contains(.reparent))
    #expect(item.capabilities.contains(.delete))
    #expect(!item.capabilities.contains(.enumerate))
    #expect(!item.capabilities.contains(.addChildren))
}
