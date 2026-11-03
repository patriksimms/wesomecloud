import Foundation
import FileProvider
import OwnCloudKit
import SyncStore
import Testing
import WesomeCloudShared
import WesomeFileProviderCore
import WesomeFileProviderExtension

private struct JournalFixture {
    let directory: URL
    let database: URL
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let store: SQLiteMetadataStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appending(path: "metadata.sqlite")
        store = try SQLiteMetadataStore(databaseURL: database)
    }

    func coordinator(policy: FileProviderPresentationPolicy = FileProviderPresentationPolicy()) throws -> FileProviderCoordinator {
        FileProviderCoordinator(account: account, webDAV: WebDAVClient(baseURL: account.serverURL, credentials: Credentials(username: "alice", password: "test")), store: try SQLiteMetadataStore(databaseURL: database), materializationDirectory: directory, presentationPolicy: policy)
    }

    func adapter() throws -> FileProviderAdapter { FileProviderAdapter(backend: try coordinator()) }

    func enumerator(adapter: FileProviderAdapter? = nil) throws -> WesomeFileProviderEnumerator {
        WesomeFileProviderEnumerator(adapter: try adapter ?? self.adapter(), container: .workingSet)
    }

    func item(_ id: String, parent: String? = nil, name: String? = nil) -> RemoteItem {
        RemoteItem(id: id, parentID: parent, name: name ?? "\(id).txt", path: "/\(parent.map { $0 + "/" } ?? "")\(name ?? "\(id).txt")", kind: .file)
    }
}

private func changeResult(_ enumerator: WesomeFileProviderEnumerator, from anchor: NSFileProviderSyncAnchor, limit: Int = 137) async throws -> ChangeObserver.Result {
    let observer = ChangeObserver(limit: limit)
    enumerator.enumerateChanges(for: observer, from: anchor)
    return try await observer.result()
}

@Test
func journalDeliversLargeListingsAndChangesWithinObserverLimitsAcrossRestart() async throws {
    let fixture = try JournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.store.upsert(accountID: fixture.account.id, items: (0..<20_001).map { fixture.item("known-\($0)") })
    let enumerator = try fixture.enumerator()
    let initialAnchor = try await currentAnchor(from: enumerator)
    var page = NSFileProviderPage.initialPageSortedByName as Data
    var known = Set<String>()
    repeat {
        let observer = EnumerationObserver(limit: 137)
        enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(page))
        let result = try await observer.result()
        known.formUnion(result.items.map(\.itemIdentifier.rawValue))
        guard let next = result.nextPage else { break }
        page = next.rawValue
    } while true
    #expect(known.count == 20_001)
    #expect(try await currentAnchor(from: enumerator).rawValue == initialAnchor.rawValue)
    #expect(try await changeResult(fixture.enumerator(), from: initialAnchor).updated.isEmpty)

    try await fixture.store.upsert(accountID: fixture.account.id, items: (0..<20_001).map { fixture.item("added-\($0)") })
    let first = try await changeResult(enumerator, from: initialAnchor)
    #expect(first.moreComing)
    let restarted = try fixture.enumerator()
    let retry = try await changeResult(restarted, from: initialAnchor)
    #expect(retry.updated.map(\.itemIdentifier) == first.updated.map(\.itemIdentifier))
    #expect(retry.anchor.rawValue == first.anchor.rawValue)
    // This write belongs to the next pass, even though it arrives before this pass ends.
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("concurrent")])
    var delivered = Set(first.updated.map(\.itemIdentifier.rawValue))
    var result = first
    while result.moreComing {
        result = try await changeResult(restarted, from: result.anchor)
        delivered.formUnion(result.updated.map(\.itemIdentifier.rawValue))
    }
    #expect(delivered == Set((0..<20_001).map { "added-\($0)" }))
    let next = try await changeResult(restarted, from: result.anchor)
    #expect(next.updated.map(\.itemIdentifier.rawValue) == ["concurrent"])
    #expect(try await changeResult(fixture.enumerator(), from: next.anchor).updated.isEmpty)
}

@Test
func journalReplaysMixedMovesDeletionsAndPresentationChangesIndependentlyPerContainer() async throws {
    let fixture = try JournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let adapter = try fixture.adapter()
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("moved", parent: "a"), fixture.item("deleted", parent: "a"), fixture.item("updated", parent: "a")])
    let rootAnchor = try await adapter.currentSyncAnchor(in: .root)
    let workingAnchor = try await adapter.currentSyncAnchor(in: .workingSet)
    let sourceAnchor = try await adapter.currentSyncAnchor(in: .item(id: "a", path: "/a"))
    let destinationAnchor = try await adapter.currentSyncAnchor(in: .item(id: "b", path: "/b"))
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("moved", parent: "b"), fixture.item("added", parent: "a"), fixture.item("updated", parent: "a", name: "Renamed.txt")])
    try await fixture.store.remove(accountID: fixture.account.id, itemID: "deleted")
    try await fixture.store.setAvailabilityIntent(.alwaysLocal, accountID: fixture.account.id, itemID: "updated")
    try await fixture.store.setMaterializedURL(fixture.directory.appending(path: "content"), accountID: fixture.account.id, itemID: "updated")
    try await fixture.store.upsertTransfer(TransferRecord(itemID: "updated", direction: .upload, phase: .failed, remotePath: "/a/Renamed.txt", lastErrorDescription: "Offline"), accountID: fixture.account.id)

    var anchor = workingAnchor
    var updates: [String: ProviderItem] = [:]
    var deletions = Set<String>()
    var more = true
    while more {
        let page = try await fixture.adapter().changePage(in: .workingSet, from: anchor, pageSize: 2)
        for item in page.updated { updates[item.id] = item }
        deletions.formUnion(page.deleted)
        anchor = page.anchor
        more = page.moreComing
    }
    #expect(Set(updates.keys) == ["moved", "added", "updated"])
    #expect(deletions == ["deleted"])
    #expect(updates["updated"]?.filename == "Renamed.txt")
    #expect(updates["updated"]?.availabilityIntent == .alwaysLocal)
    #expect(updates["updated"]?.isMaterialized == true)
    #expect(updates["updated"]?.uploadErrorDescription == "Offline")
    let root = try await adapter.changePage(in: .root, from: rootAnchor)
    #expect(root.updated.isEmpty)
    #expect(root.deleted.isEmpty)
    let source = try await adapter.changePage(in: .item(id: "a", path: "/a"), from: sourceAnchor)
    #expect(Set(source.deleted) == ["moved", "deleted"])
    #expect(Set(source.updated.map(\.id)) == ["added", "updated"])
    let destination = try await adapter.changePage(in: .item(id: "b", path: "/b"), from: destinationAnchor)
    #expect(destination.updated.map(\.id) == ["moved"])
    await #expect(throws: ProviderJournalError.self) { try await adapter.changePage(in: .workingSet, from: sourceAnchor) }
}

@Test
func initialListingBoundaryRetainsWritesDuringPaginationAndExpiredPagesRequestRecovery() async throws {
    let fixture = try JournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("a"), fixture.item("b")])
    let adapter = try fixture.adapter()
    let enumerator = try fixture.enumerator(adapter: adapter)
    let firstObserver = EnumerationObserver(limit: 1)
    enumerator.enumerateItems(for: firstObserver, startingAt: NSFileProviderPage(Data()))
    let first = try await firstObserver.result()
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("during-listing")])
    let secondObserver = EnumerationObserver(limit: 1)
    let token = try #require(first.nextPage)
    enumerator.enumerateItems(for: secondObserver, startingAt: token)
    let second = try await secondObserver.result()
    #expect(second.items.map(\.itemIdentifier.rawValue) == ["b"])
    let listingAnchor = try await currentAnchor(from: enumerator)
    let changes = try await changeResult(enumerator, from: listingAnchor)
    #expect(changes.updated.map(\.itemIdentifier.rawValue) == ["during-listing"])
    let restartObserver = EnumerationObserver(limit: 1)
    try fixture.enumerator().enumerateItems(for: restartObserver, startingAt: token)
    await #expect { try await restartObserver.result() } throws: { error in
        (error as NSError).code == NSFileProviderError.pageExpired.rawValue
    }
    await #expect { try await changeResult(enumerator, from: NSFileProviderSyncAnchor(Data("v1".utf8))) } throws: { error in
        (error as NSError).code == NSFileProviderError.syncAnchorExpired.rawValue
    }
    let freshObserver = EnumerationObserver(limit: 1)
    enumerator.enumerateItems(for: freshObserver, startingAt: NSFileProviderPage(Data()))
    _ = try await freshObserver.result()
    let freshAnchor = try await currentAnchor(from: enumerator)
    #expect(freshAnchor.rawValue != listingAnchor.rawValue)
    #expect(try await changeResult(enumerator, from: freshAnchor).updated.isEmpty)
}

private actor SelectedJournalSpaces {
    var spaces: [ProviderSpace] = []
    func set(_ spaces: [ProviderSpace]) { self.spaces = spaces }
}

@Test
func journalPersistsSpaceSelectionRenameAndVisibilityChanges() async throws {
    let fixture = try JournalFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("visible"), fixture.item("hidden", name: ".hidden")])
    let selected = SelectedJournalSpaces()
    let coordinator = try fixture.coordinator()
    await selected.set([ProviderSpace(id: "space", name: "Original", metadataID: fixture.account.id, backend: { coordinator })])
    func adapter() -> FileProviderAdapter {
        FileProviderAdapter(backend: SpaceFileProviderBackend(journalStore: fixture.store, spaces: { await selected.spaces }))
    }
    var anchor = try await adapter().currentSyncAnchor(in: .workingSet)
    // The source can gain files after its original configuration snapshot was saved.
    try await fixture.store.upsert(accountID: fixture.account.id, items: [fixture.item("later")])
    var page = try await adapter().changePage(in: .workingSet, from: anchor)
    #expect(page.updated.map(\.filename) == ["later.txt"])
    anchor = page.anchor
    let showHidden = try fixture.coordinator(policy: FileProviderPresentationPolicy(showHiddenFiles: true))
    await selected.set([ProviderSpace(id: "space", name: "Renamed", metadataID: fixture.account.id, presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true), backend: { showHidden })])
    page = try await adapter().changePage(in: .workingSet, from: anchor)
    #expect(Set(page.updated.map(\.filename)) == ["Renamed", "visible.txt", "later.txt", ".hidden"])
    #expect(page.updated.first { $0.filename == ".hidden" }?.path == "/Renamed/.hidden")
    anchor = page.anchor
    await selected.set([])
    page = try await adapter().changePage(in: .workingSet, from: anchor, pageSize: 2)
    var deleted = Set(page.deleted)
    while page.moreComing {
        page = try await adapter().changePage(in: .workingSet, from: page.anchor, pageSize: 2)
        deleted.formUnion(page.deleted)
    }
    #expect(deleted == [ProviderSpaceIdentifier.folder("space"), ProviderSpaceIdentifier.item("visible", spaceID: "space"), ProviderSpaceIdentifier.item("later", spaceID: "space"), ProviderSpaceIdentifier.item("hidden", spaceID: "space")])
    #expect(try await fixture.store.items(accountID: fixture.account.id).count == 3)
    anchor = page.anchor
    await selected.set([ProviderSpace(id: "space", name: "Renamed", metadataID: fixture.account.id, presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true), backend: { showHidden })])
    page = try await adapter().changePage(in: .workingSet, from: anchor)
    #expect(Set(page.updated.map(\.filename)) == ["Renamed", "visible.txt", "later.txt", ".hidden"])
}
