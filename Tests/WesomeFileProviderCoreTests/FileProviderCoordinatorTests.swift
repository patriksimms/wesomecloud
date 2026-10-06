import Foundation
import Testing
import OwnCloudKit
import SyncStore
import WesomeCloudShared
@testable import WesomeFileProviderCore

private actor FixtureTransport: HTTPTransport {
    var responses: [(Data, Int, [String: String]?)]
    var requests: [URLRequest] = []

    init(_ responses: [(Data, Int)]) {
        self.responses = responses.map { ($0.0, $0.1, nil) }
    }

    init(_ responses: [(Data, Int, [String: String]?)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        return (
            next.0,
            HTTPURLResponse(url: request.url!, statusCode: next.1, httpVersion: nil, headerFields: next.2)!
        )
    }
}

private actor BlockingTransport: HTTPTransport {
    private var continuations: [CheckedContinuation<(Data, HTTPURLResponse), Error>] = []
    private var responseURLs: [URL] = []
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            responseURLs.append(request.url!)
            continuations.append(continuation)
        }
    }

    func completeNext(data: Data, statusCode: Int = 200) {
        let continuation = continuations.removeFirst()
        let url = responseURLs.removeFirst()
        continuation.resume(returning: (
            data,
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        ))
    }

    var requestCount: Int {
        requests.count
    }
}

@Test
func enumerationPersistsRemoteItemsAndMapsCapabilities() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Readme.md</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>9</d:getcontentlength><d:getetag>"abc"</d:getetag><oc:fileid>readme</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: InMemoryMetadataStore(),
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.count == 1)
    #expect(items[0].filename == "Readme.md")
    #expect(items[0].capabilities.contains(.read))
    #expect(items[0].contentVersion.count == 32)
}

@Test
func enumerationAppliesHiddenFileAndDefaultAvailabilityPolicy() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Visible.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"visible"</d:getetag><oc:fileid>visible</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/.Hidden.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"hidden"</d:getetag><oc:fileid>hidden</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: false, defaultAvailabilityIntent: .alwaysLocal)
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.map(\.id) == ["visible"])
    #expect(try await store.item(accountID: account.id, id: "visible")?.availabilityIntent == .alwaysLocal)
    #expect(try await store.item(accountID: account.id, id: "hidden")?.availabilityIntent == .alwaysLocal)
}

@Test
func workingSetItemsReturnsVisibleStoredItemsAcrossFolders() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "root-file", parentID: nil, name: "Root.txt", path: "/Root.txt", kind: .file),
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "nested-file", parentID: "folder", name: "Nested.txt", path: "/Folder/Nested.txt", kind: .file),
        RemoteItem(id: "hidden", parentID: nil, name: ".Hidden.txt", path: "/.Hidden.txt", kind: .file),
        RemoteItem(id: "ignored", parentID: nil, name: "Draft.tmp", path: "/Draft.tmp", kind: .file),
        RemoteItem(id: "excluded", parentID: "folder", name: "Secret.txt", path: "/Folder/Secret.txt", kind: .file),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(
            showHiddenFiles: false,
            ignoredFilenamePatterns: ["*.tmp"],
            excludedRemotePaths: ["/Folder/Secret.txt"]
        )
    )

    let items = try await coordinator.workingSetItems()

    #expect(items.map { $0.id }.sorted() == ["folder", "nested-file", "root-file"])
    #expect(items.first { $0.id == "nested-file" }?.parentID == "folder")
    #expect(items.first { $0.id == "nested-file" }?.path == "/Folder/Nested.txt")
}

@Test
func enumerationCanShowHiddenFilesAndKeepSystemManagedAvailability() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/.Env</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>3</d:getcontentlength><d:getetag>"env"</d:getetag><oc:fileid>env</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true, defaultAvailabilityIntent: .unspecified)
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.map(\.id) == ["env"])
    #expect(try await store.item(accountID: account.id, id: "env")?.availabilityIntent == .unspecified)
}

@Test
func enumerationHidesIgnoredFilenamePatternsEvenWhenHiddenFilesAreShown() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/.~lock.Report.docx</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>2</d:getcontentlength><d:getetag>"lock"</d:getetag><oc:fileid>lock</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/.Env</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>3</d:getcontentlength><d:getetag>"env"</d:getetag><oc:fileid>env</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true, ignoredFilenamePatterns: [".~lock.*"])
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.map(\.id) == ["env"])
    #expect(try await store.item(accountID: account.id, id: "lock") != nil)
}

@Test
func enumerationHidesSelectiveSyncExcludedSubtreesButPersistsMetadata() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Visible.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"visible"</d:getetag><oc:fileid>visible</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Private</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><oc:fileid>private</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true, excludedRemotePaths: ["/Private"])
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.map(\.id) == ["visible"])
    #expect(try await store.item(accountID: account.id, id: "private") != nil)
    #expect(try await coordinator.item(itemID: "private") == nil)
}

@Test
func enumerationFallsBackToCachedChildrenForRetryableServerFailures() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "cached", parentID: nil, name: "Cached.txt", path: "/Cached.txt", kind: .file, etag: "cached")
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data(), 503)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let items = try await coordinator.enumerate(parentID: nil, remotePath: "/")

    #expect(items.map(\.id) == ["cached"])
}

@Test
func enumerationDoesNotHideAuthenticationFailuresWithCachedChildren() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "cached", parentID: nil, name: "Cached.txt", path: "/Cached.txt", kind: .file, etag: "cached")
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data(), 401)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 401, kind: .authentication))) {
        _ = try await coordinator.enumerate(parentID: nil, remotePath: "/")
    }
}

@Test
func nestedEnumerationResolvesPathParentToStableFolderID() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Nested.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"nested"</d:getetag><oc:fileid>nested-file</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let items = try await coordinator.enumerate(parentID: "folder", remotePath: "/Folder")

    #expect(items.map(\.id) == ["nested-file"])
    #expect(items.first?.parentID == "folder")
    #expect(try await store.item(accountID: account.id, id: "nested-file")?.remote.parentID == "folder")
}

@Test
func itemLookupUsesStoredIdentityWithoutEnumeratingParentPath() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: "moved-folder", name: "Report.txt", path: "/Current/Report.txt", kind: .file, etag: "etag")
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.item(itemID: "file-1")

    #expect(item?.id == "file-1")
    #expect(item?.filename == "Report.txt")
    #expect(await transport.requests.isEmpty)
}

@Test
func fetchContentsHonorsCancelledTransferBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 8)
    ])
    let transport = FixtureTransport([(Data("contents".utf8), 200)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await coordinator.cancelTransfers(for: "file-1")

    await #expect(throws: CancellationError.self) {
        _ = try await coordinator.fetchContents(itemID: "file-1")
    }
    #expect(await transport.requests.isEmpty)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .paused)
    #expect(transfers.first?.lastErrorDescription == "Transfer cancelled")
}

@Test
func fetchContentsLimitsConcurrentTransfers() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "One.txt", path: "/One.txt", kind: .file),
        RemoteItem(id: "file-2", parentID: nil, name: "Two.txt", path: "/Two.txt", kind: .file),
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let transport = BlockingTransport()
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory,
        transferConfiguration: TransferConfiguration(maximumConcurrentTransfers: 1)
    )

    async let first = coordinator.fetchContents(itemID: "file-1")
    try await waitUntil { await transport.requestCount == 1 }
    async let second = coordinator.fetchContents(itemID: "file-2")
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await transport.requestCount == 1)

    await transport.completeNext(data: Data("one".utf8))
    _ = try await first
    try await waitUntil { await transport.requestCount == 2 }
    await transport.completeNext(data: Data("two".utf8))
    _ = try await second

    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.filter { $0.phase == .completed }.count == 2)
}

@Test
func fetchContentsDownloadsAndMaterializesFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(
            id: "file/1",
            parentID: nil,
            name: "Readme.md",
            path: "/Readme.md",
            kind: .file,
            size: 8,
            checksum: "SHA1:4a756ca07e9487f482465a99e8286abc86ba4dc7"
        )
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data("contents".utf8), 200)])),
        store: store,
        materializationDirectory: directory
    )

    let url = try await coordinator.fetchContents(itemID: "file/1")

    #expect(try String(contentsOf: url, encoding: .utf8) == "contents")
    let stored = try await store.item(accountID: account.id, id: "file/1")
    #expect(stored?.materializedURL == url)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.bytesTransferred == 8)
    #expect(transfers.first?.remotePath == "/Readme.md")
}

@Test
func itemReportsRunningDownloadTransferState() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    try await store.upsertTransfer(
        TransferRecord(itemID: "file-1", direction: .download, phase: .running, remotePath: "/Readme.md"),
        accountID: account.id
    )
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try #require(await coordinator.item(itemID: "file-1"))

    #expect(item.isDownloading)
    #expect(item.downloadErrorDescription == nil)
    #expect(item.isUploaded)
    #expect(!item.isUploading)
}

@Test
func itemReportsFailedUploadTransferState() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    try await store.upsertTransfer(
        TransferRecord(
            itemID: "file-1",
            direction: .upload,
            phase: .failed,
            remotePath: "/Readme.md",
            lastErrorDescription: "Insufficient quota"
        ),
        accountID: account.id
    )
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try #require(await coordinator.item(itemID: "file-1"))

    #expect(!item.isUploaded)
    #expect(!item.isUploading)
    #expect(item.uploadErrorDescription == "Insufficient quota")
}

@Test
func fetchContentsRejectsUnexpectedDownloadSize() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 9)
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data("contents".utf8), 200)])),
        store: store,
        materializationDirectory: directory
    )

    await #expect(throws: WesomeCloudError.transferIntegrityMismatch("Expected 9 bytes for /Readme.md, got 8")) {
        _ = try await coordinator.fetchContents(itemID: "file-1")
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "file-1").path))
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .failed)
    #expect(transfers.first?.bytesTransferred == 8)
}

@Test
func fetchContentsRejectsChecksumMismatch() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(
            id: "file-1",
            parentID: nil,
            name: "Readme.md",
            path: "/Readme.md",
            kind: .file,
            size: 8,
            checksum: "SHA1:a1ce829a6e4fb826d301d8571c127c518175f6e2"
        )
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data("contents".utf8), 200)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    await #expect(throws: WesomeCloudError.transferIntegrityMismatch("Checksum mismatch for /Readme.md")) {
        _ = try await coordinator.fetchContents(itemID: "file-1")
    }
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .failed)
    #expect(transfers.first?.lastErrorDescription?.contains("Checksum mismatch") == true)
}

@Test
func fetchContentsRejectsETagMismatch() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(
            id: "file-1",
            parentID: nil,
            name: "Readme.md",
            path: "/Readme.md",
            kind: .file,
            size: 8,
            etag: "expected-etag"
        )
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(
            baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!,
            transport: FixtureTransport([(Data("contents".utf8), 200, ["ETag": "\"different-etag\""])])
        ),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    await #expect(throws: WesomeCloudError.transferIntegrityMismatch("ETag mismatch for /Readme.md")) {
        _ = try await coordinator.fetchContents(itemID: "file-1")
    }
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .failed)
    #expect(transfers.first?.lastErrorDescription?.contains("ETag mismatch") == true)
}

@Test
func fetchContentsResumesPartialDownloadAndRecordsProgress() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file/1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 8, etag: "v1")
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appending(path: "file_1").appendingPathExtension("part")
    try Data("cont".utf8).write(to: partial)
    let transport = FixtureTransport([
        (Data("ents".utf8), 206, ["Content-Range": "bytes 4-7/8"])
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory
    )

    let url = try await coordinator.fetchContents(itemID: "file/1")

    #expect(try String(contentsOf: url, encoding: .utf8) == "contents")
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    let request = await transport.requests.first
    #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=4-")
    #expect(request?.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.bytesTransferred == 8)
    #expect(transfers.first?.totalBytes == 8)
}

@Test
func fetchPartialContentsDownloadsRequestedRangeAsSparseFile() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file/1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 8)
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let transport = FixtureTransport([
        (Data("ents".utf8), 206, ["Content-Range": "bytes 4-7/8"])
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory
    )

    let partial = try await coordinator.fetchPartialContents(
        itemID: "file/1",
        requestedRange: ProviderContentRange(offset: 4, length: 4),
        alignment: 1
    )

    #expect(partial.retrievedRange == ProviderContentRange(offset: 4, length: 4))
    let handle = try FileHandle(forReadingFrom: partial.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: 4)
    #expect(try handle.read(upToCount: 4) == Data("ents".utf8))
    #expect((try FileManager.default.attributesOfItem(atPath: partial.url.path)[.size] as? NSNumber)?.int64Value == 8)
    let stored = try await store.item(accountID: account.id, id: "file/1")
    #expect(stored?.materializedURL == nil)
    let request = await transport.requests.first
    #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=4-7")
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.bytesTransferred == 4)
    #expect(transfers.first?.totalBytes == 4)
}

@Test
func transferProgressSummarizesActiveTransfersByDirection() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsertTransfer(
        TransferRecord(itemID: "download-1", direction: .download, phase: .running, bytesTransferred: 4, totalBytes: 10, remotePath: "/Download.txt"),
        accountID: account.id
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "download-2", direction: .download, phase: .queued, bytesTransferred: 2, totalBytes: nil, remotePath: "/Queued.txt"),
        accountID: account.id
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "download-3", direction: .download, phase: .completed, bytesTransferred: 8, totalBytes: 8, remotePath: "/Done.txt"),
        accountID: account.id
    )
    try await store.upsertTransfer(
        TransferRecord(itemID: "upload-1", direction: .upload, phase: .paused, bytesTransferred: 3, totalBytes: 12, remotePath: "/Upload.txt"),
        accountID: account.id
    )
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    let downloads = try await coordinator.transferProgress(direction: TransferDirection.download)
    let uploads = try await coordinator.transferProgress(direction: TransferDirection.upload)

    #expect(downloads == TransferProgressSummary(completedUnitCount: 6, totalUnitCount: 12, activeTransferCount: 2))
    #expect(uploads == TransferProgressSummary(completedUnitCount: 3, totalUnitCount: 12, activeTransferCount: 1))
}

@Test
func fetchContentsRejectsMismatchedContentRangeWhenResumingAndDiscardsPartial() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file/1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 8)
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let partial = directory.appending(path: "file_1").appendingPathExtension("part")
    try Data("cont".utf8).write(to: partial)
    let transport = FixtureTransport([
        (Data("ents".utf8), 206, ["Content-Range": "bytes 5-7/8"])
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory
    )

    await #expect(throws: WesomeCloudError.transferIntegrityMismatch("Expected resumed download of /Readme.md to start at byte 4, got 5")) {
        _ = try await coordinator.fetchContents(itemID: "file/1")
    }
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .failed)
    #expect(transfers.first?.bytesTransferred == 4)
}

@Test
func setOnlineOnlyEvictsMaterializedSubtree() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rootFile = directory.appending(path: "root.txt")
    let childFile = directory.appending(path: "child.txt")
    let childPartial = childFile.appendingPathExtension("part")
    try Data("root".utf8).write(to: rootFile)
    try Data("child".utf8).write(to: childFile)
    try Data("part".utf8).write(to: childPartial)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file),
        RemoteItem(id: "root", parentID: nil, name: "Root.txt", path: "/Root.txt", kind: .file),
    ])
    try await store.setMaterializedURL(childFile, accountID: account.id, itemID: "child")
    try await store.setMaterializedURL(rootFile, accountID: account.id, itemID: "root")
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: directory
    )

    let affected = try await coordinator.setAvailabilityIntent(.onlineOnly, itemID: "folder")

    #expect(affected == ["folder", "child"])
    #expect(try await store.item(accountID: account.id, id: "folder")?.availabilityIntent == .onlineOnly)
    #expect(try await store.item(accountID: account.id, id: "child")?.availabilityIntent == .onlineOnly)
    #expect(try await store.item(accountID: account.id, id: "child")?.materializedURL == nil)
    #expect(try await store.item(accountID: account.id, id: "root")?.materializedURL == rootFile)
    #expect(!FileManager.default.fileExists(atPath: childFile.path))
    #expect(!FileManager.default.fileExists(atPath: childPartial.path))
    #expect(FileManager.default.fileExists(atPath: rootFile.path))
}

@Test
func diskPressureEvictsMaterializedFilesExceptAlwaysLocal() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let keepFile = directory.appending(path: "keep.txt")
    let evictFile = directory.appending(path: "evict.txt")
    try Data("keep".utf8).write(to: keepFile)
    try Data("evict".utf8).write(to: evictFile)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "keep", parentID: nil, name: "Keep.txt", path: "/Keep.txt", kind: .file),
        RemoteItem(id: "evict", parentID: nil, name: "Evict.txt", path: "/Evict.txt", kind: .file),
    ])
    try await store.setMaterializedURL(keepFile, accountID: account.id, itemID: "keep")
    try await store.setMaterializedURL(evictFile, accountID: account.id, itemID: "evict")
    try await store.setAvailabilityIntent(.alwaysLocal, accountID: account.id, itemID: "keep")
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(Data, Int)]())),
        store: store,
        materializationDirectory: directory
    )

    let evicted = try await coordinator.evictMaterializedContentForDiskPressure()

    #expect(evicted == ["evict"])
    #expect(try await store.item(accountID: account.id, id: "keep")?.materializedURL == keepFile)
    #expect(try await store.item(accountID: account.id, id: "evict")?.materializedURL == nil)
    #expect(FileManager.default.fileExists(atPath: keepFile.path))
    #expect(!FileManager.default.fileExists(atPath: evictFile.path))
}

@Test
func uploadModifiedContentsPutsDataWithStoredEtagAndLeavesNoPendingReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 3, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated contents".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let uploadedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "new-etag", size: 16)
    let transport = FixtureTransport([(unchangedRemote, 207), (Data(), 204), (uploadedRemote, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)

    #expect(item.size == 16)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PROPFIND", "PUT", "PROPFIND"])
    #expect(requests[1].value(forHTTPHeaderField: "If-Match") == "\"old-etag\"")
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.isEmpty)
    let stored = try await store.item(accountID: account.id, id: "file-1")
    #expect(stored?.remote.etag == "new-etag")
    #expect(stored?.materializedURL == localURL)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.direction == .upload)
    #expect(transfers.first?.bytesTransferred == 16)
}

@Test
func uploadModifiedContentsKeepsLocalMetadataWhenPostUploadRefreshFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 3, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated contents".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let transport = FixtureTransport([(unchangedRemote, 207), (Data(), 204), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)

    #expect(item.size == 16)
    let stored = try await store.item(accountID: account.id, id: "file-1")
    #expect(stored?.remote.size == 16)
    #expect(stored?.remote.etag == "old-etag")
    #expect(stored?.materializedURL == localURL)
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND", "PUT", "PROPFIND"])
}

@Test
func uploadModifiedContentsQueuesRetryableFailureForOfflineReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 3, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated contents".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let transport = FixtureTransport([(unchangedRemote, 207), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PROPFIND", "PUT"])
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .upload)
    #expect(pending.first?.itemID == "file-1")
    #expect(pending.first?.sourcePath == localURL.path)
    #expect(pending.first?.destinationPath == "/Readme.md")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
    #expect(try await store.item(accountID: account.id, id: "file-1")?.remote.size == 3)
    #expect(try await store.item(accountID: account.id, id: "file-1")?.materializedURL == nil)
    #expect(try await store.transfers(accountID: account.id).first?.phase == .failed)
}

@Test
func createFileUploadsContentsPersistsRemoteMetadataAndLeavesNoPendingReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new file".utf8).write(to: localURL)
    let createdRemote = propfindXML(name: "Folder/New.txt", fileID: "new-file", etag: "new-etag")
    let transport = FixtureTransport([(Data(), 201), (createdRemote, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.createFile(named: "New.txt", contentsAt: localURL, parentPath: "/Folder", parentID: "folder")

    #expect(item.id == "new-file")
    #expect(item.parentID == "folder")
    #expect(item.filename == "New.txt")
    #expect(item.size == 7)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(requests.first?.url?.absoluteString == "https://cloud.example/remote.php/dav/files/alice/Folder/New.txt")
    #expect(requests.first?.httpBody == Data("new file".utf8))
    #expect(requests.first?.value(forHTTPHeaderField: "If-Match") == nil)
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.isEmpty)
    #expect(try await store.item(accountID: account.id, id: "new-file")?.materializedURL == localURL)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.direction == .upload)
    #expect(transfers.first?.remotePath == "/Folder/New.txt")
}

@Test
func createFileQueuesRetryableFailureForOfflineReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new file".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.createFile(named: "New.txt", contentsAt: localURL, parentPath: "/Folder", parentID: "folder")
    }

    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .createFile)
    #expect(pending.first?.itemID == "folder")
    #expect(pending.first?.sourcePath == localURL.path)
    #expect(pending.first?.destinationPath == "/Folder/New.txt")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .failed)
    #expect(transfers.first?.remotePath == "/Folder/New.txt")
}

@Test
func createFileKeepsLocalMetadataWhenPostCreateRefreshFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new file".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data(), 201), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.createFile(named: "New.txt", contentsAt: localURL, parentPath: "/Folder", parentID: "folder")

    #expect(item.id == "/Folder/New.txt")
    #expect(item.parentID == "folder")
    #expect(item.filename == "New.txt")
    #expect(item.size == 8)
    #expect(try await store.item(accountID: account.id, id: "/Folder/New.txt")?.materializedURL == localURL)
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
}

@Test
func createFileRetryableFailuresUpdateExistingOfflineReplayOperation() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new file".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data(), 503), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    for _ in 0..<2 {
        await expectHTTPFailure(statusCode: 503) {
            _ = try await coordinator.createFile(named: "New.txt", contentsAt: localURL, parentPath: "/Folder", parentID: "folder")
        }
    }

    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .createFile)
    #expect(pending.first?.itemID == "folder")
    #expect(pending.first?.sourcePath == localURL.path)
    #expect(pending.first?.destinationPath == "/Folder/New.txt")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
}

@Test
func createFolderPersistsPropfindMetadataAndParentIdentity() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let createdRemote = propfindXML(name: "Folder/Child", fileID: "child-folder", etag: "folder-etag", kind: .folder)
    let transport = FixtureTransport([(Data(), 201), (createdRemote, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.createFolder(named: "Child", parentPath: "/Folder", parentID: "folder")

    #expect(item.id == "child-folder")
    #expect(item.parentID == "folder")
    #expect(item.filename == "Child")
    let stored = try await store.item(accountID: account.id, id: "child-folder")
    #expect(stored?.remote.path == "/Folder/Child")
    #expect(stored?.remote.etag == "folder-etag")
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.isEmpty)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["MKCOL", "PROPFIND"])
    #expect(requests.first?.url?.absoluteString == "https://cloud.example/remote.php/dav/files/alice/Folder/Child")
}

@Test
func createFolderKeepsLocalMetadataWhenPostCreateRefreshFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let transport = FixtureTransport([(Data(), 201), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.createFolder(named: "Child", parentPath: "/Folder", parentID: "folder")

    #expect(item.id == "/Folder/Child")
    #expect(item.parentID == "folder")
    #expect(item.filename == "Child")
    let stored = try await store.item(accountID: account.id, id: "/Folder/Child")
    #expect(stored?.remote.path == "/Folder/Child")
    #expect(stored?.remote.kind == .folder)
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    #expect(await transport.requests.map(\.httpMethod) == ["MKCOL", "PROPFIND"])
}

@Test
func createFolderQueuesRetryableFailureForOfflineReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    let transport = FixtureTransport([(Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.createFolder(named: "Child", parentPath: "/Folder", parentID: "folder")
    }

    #expect(await transport.requests.map(\.httpMethod) == ["MKCOL"])
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .createFolder)
    #expect(pending.first?.itemID == "/Folder/Child")
    #expect(pending.first?.sourcePath == "folder")
    #expect(pending.first?.destinationPath == "/Folder/Child")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
    #expect(try await store.item(accountID: account.id, id: "/Folder/Child") == nil)
}

@Test
func uploadModifiedContentsUsesChunkedUploadAboveThreshold() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 6, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("abcdef".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let uploadedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "chunked-etag", size: 6)
    let transport = FixtureTransport([
        (unchangedRemote, 207),
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
        (uploadedRemote, 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        uploadConfiguration: UploadConfiguration(chunkingThreshold: 4, chunkSize: 3)
    )

    _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PROPFIND", "MKCOL", "PUT", "PUT", "MOVE", "PROPFIND"])
    #expect(requests[2].url?.absoluteString.contains("/remote.php/dav/uploads/alice/") == true)
    #expect(requests[2].httpBody == Data("abc".utf8))
    #expect(requests[3].httpBody == Data("def".utf8))
    #expect(requests[4].value(forHTTPHeaderField: "Destination") == "https://cloud.example/remote.php/dav/files/alice/Readme.md")
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.direction == .upload)
    #expect(transfers.first?.bytesTransferred == 6)
    #expect(try await store.item(accountID: account.id, id: "file-1")?.remote.etag == "chunked-etag")
}

@Test
func uploadModifiedContentsRecordsChunkedUploadProgress() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 6, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("abcdef".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let transport = BlockingTransport()
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        uploadConfiguration: UploadConfiguration(chunkingThreshold: 4, chunkSize: 3)
    )

    let uploadTask = Task {
        try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    try await waitUntil { await transport.requestCount == 1 }
    await transport.completeNext(data: unchangedRemote, statusCode: 207)
    try await waitUntil { await transport.requestCount == 2 }
    await transport.completeNext(data: Data(), statusCode: 201)
    try await waitUntil { await transport.requestCount == 3 }
    await transport.completeNext(data: Data(), statusCode: 201)
    try await waitUntil {
        (try? await store.transfers(accountID: account.id).first?.bytesTransferred) == 3
    }
    #expect(try await store.transfers(accountID: account.id).first?.phase == .running)

    try await waitUntil { await transport.requestCount == 4 }
    await transport.completeNext(data: Data(), statusCode: 201)
    try await waitUntil { await transport.requestCount == 5 }
    await transport.completeNext(data: Data(), statusCode: 201)
    try await waitUntil { await transport.requestCount == 6 }
    let uploadedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "chunked-etag", size: 6)
    await transport.completeNext(data: uploadedRemote, statusCode: 207)
    _ = try await uploadTask.value

    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .completed)
    #expect(transfers.first?.bytesTransferred == 6)
    #expect(try await store.item(accountID: account.id, id: "file-1")?.remote.etag == "chunked-etag")
}

@Test
func uploadModifiedContentsHonorsCancellationBetweenChunks() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 6, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("abcdef".utf8).write(to: localURL)
    let unchangedRemote = propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag")
    let transport = BlockingTransport()
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        uploadConfiguration: UploadConfiguration(chunkingThreshold: 4, chunkSize: 3)
    )

    let uploadTask = Task {
        try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    try await waitUntil { await transport.requestCount == 1 }
    await transport.completeNext(data: unchangedRemote, statusCode: 207)
    try await waitUntil { await transport.requestCount == 2 }
    await transport.completeNext(data: Data(), statusCode: 201)
    try await waitUntil { await transport.requestCount == 3 }
    await coordinator.cancelTransfers(for: "file-1")
    await transport.completeNext(data: Data(), statusCode: 201)

    await #expect(throws: CancellationError.self) {
        _ = try await uploadTask.value
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await transport.requestCount == 3)
    let transfers = try await store.transfers(accountID: account.id)
    #expect(transfers.first?.phase == .paused)
    #expect(transfers.first?.bytesTransferred == 3)
    #expect(transfers.first?.totalBytes == 6)
}

@Test
func deleteFolderRemovesDescendantMetadataAndMaterializedContent() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let childFile = directory.appending(path: "child.txt")
    let childPartial = childFile.appendingPathExtension("part")
    try Data("child".utf8).write(to: childFile)
    try Data("part".utf8).write(to: childPartial)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file),
        RemoteItem(id: "nested", parentID: "folder", name: "Nested", path: "/Folder/Nested", kind: .folder),
        RemoteItem(id: "grandchild", parentID: "nested", name: "Deep.txt", path: "/Folder/Nested/Deep.txt", kind: .file),
    ])
    try await store.setMaterializedURL(childFile, accountID: account.id, itemID: "child")
    let transport = FixtureTransport([(Data(), 204)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory
    )

    try await coordinator.delete(itemID: "folder")

    #expect(try await store.item(accountID: account.id, id: "folder") == nil)
    #expect(try await store.item(accountID: account.id, id: "child") == nil)
    #expect(try await store.item(accountID: account.id, id: "nested") == nil)
    #expect(try await store.item(accountID: account.id, id: "grandchild") == nil)
    #expect(!FileManager.default.fileExists(atPath: childFile.path))
    #expect(!FileManager.default.fileExists(atPath: childPartial.path))
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["DELETE"])
    #expect(requests.first?.url?.absoluteString == "https://cloud.example/remote.php/dav/files/alice/Folder")
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.isEmpty)
}

@Test
func deleteQueuesRetryableFailureForOfflineReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    let transport = FixtureTransport([(Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectHTTPFailure(statusCode: 503) {
        try await coordinator.delete(itemID: "file-1")
    }

    #expect(await transport.requests.map(\.httpMethod) == ["DELETE"])
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .delete)
    #expect(pending.first?.itemID == "file-1")
    #expect(pending.first?.sourcePath == "/Readme.md")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
    #expect(try await store.item(accountID: account.id, id: "file-1") != nil)
}

@Test
func deleteRejectsMissingOwnCloudDeletePermissionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, permissions: "RWNV")
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectUnsupported(contains: "delete /Readme.md") {
        try await coordinator.delete(itemID: "file-1")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func pollRemoteChangesReportsAddedUpdatedAndDeletedItems() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "stale", parentID: nil, name: "Old.txt", path: "/Old.txt", kind: .file, etag: "old"),
        RemoteItem(id: "changed", parentID: nil, name: "Changed.txt", path: "/Changed.txt", kind: .file, etag: "v1"),
    ])
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Changed.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>20</d:getcontentlength><d:getetag>"v2"</d:getetag><oc:fileid>changed</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/New.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"new"</d:getetag><oc:fileid>new</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.deleted == ["stale"])
    #expect(changes.deletedItems == [DeletedProviderItem(id: "stale", parentID: nil, path: "/Old.txt")])
    #expect(changes.added.map(\.id) == ["new"])
    #expect(changes.updated.map(\.id) == ["changed"])
    #expect(try await store.item(accountID: account.id, id: "stale") == nil)
    #expect(try await store.item(accountID: account.id, id: "changed")?.remote.etag == "v2")
}

@Test
func pollRemoteChangesPreservesFallbackIdentityWhenServerFileIDAppears() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("local".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "/New.txt", parentID: nil, name: "New.txt", path: "/New.txt", kind: .file, size: 5, etag: "fallback"),
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "/New.txt")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/New.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"server"</d:getetag><oc:fileid>server-new</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.isEmpty)
    #expect(changes.deleted.isEmpty)
    #expect(changes.updated.map(\.id) == ["/New.txt"])
    let stored = try #require(await store.item(accountID: account.id, id: "/New.txt"))
    #expect(stored.remote.fileID == "server-new")
    #expect(stored.remote.etag == "server")
    #expect(stored.materializedURL == localURL)
    #expect(FileManager.default.fileExists(atPath: localURL.path))
    #expect(try await store.item(accountID: account.id, id: "server-new") == nil)
}

@Test
func pollRemoteChangesUsesPersistedSyncCollectionToken() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "deleted", parentID: nil, name: "Deleted.txt", path: "/Deleted.txt", kind: .file, etag: "old"),
        RemoteItem(id: "changed", parentID: nil, name: "Changed.txt", path: "/Changed.txt", kind: .file, etag: "v1"),
    ])
    try await store.setSyncCursor("token-1", accountID: account.id, remotePath: "/")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:sync-token>token-2</d:sync-token>
      <d:response><d:href>/remote.php/dav/files/alice/Changed.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>20</d:getcontentlength><d:getetag>"v2"</d:getetag><oc:fileid>changed</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/New.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"new"</d:getetag><oc:fileid>new</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Deleted.txt</d:href>
        <d:status>HTTP/1.1 404 Not Found</d:status>
      </d:response>
    </d:multistatus>
    """.utf8)
    let transport = FixtureTransport([(xml, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(await transport.requests.map(\.httpMethod) == ["REPORT"])
    let body = String(data: await transport.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(body.contains("<d:sync-token>token-1</d:sync-token>"))
    #expect(changes.deleted == ["deleted"])
    #expect(changes.deletedItems == [DeletedProviderItem(id: "deleted", parentID: nil, path: "/Deleted.txt")])
    #expect(changes.added.map(\.id) == ["new"])
    #expect(changes.updated.map(\.id) == ["changed"])
    #expect(try await store.item(accountID: account.id, id: "deleted") == nil)
    #expect(try await store.item(accountID: account.id, id: "changed")?.remote.etag == "v2")
    #expect(try await store.syncCursor(accountID: account.id, remotePath: "/") == "token-2")
}

@Test
func pollRemoteChangesWithSyncCollectionPreservesFallbackIdentityWhenServerFileIDAppears() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "/New.txt", parentID: nil, name: "New.txt", path: "/New.txt", kind: .file, size: 5, etag: "fallback"),
    ])
    try await store.setSyncCursor("token-1", accountID: account.id, remotePath: "/")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:sync-token>token-2</d:sync-token>
      <d:response><d:href>/remote.php/dav/files/alice/New.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"server"</d:getetag><oc:fileid>server-new</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.isEmpty)
    #expect(changes.deleted.isEmpty)
    #expect(changes.updated.map(\.id) == ["/New.txt"])
    let stored = try #require(await store.item(accountID: account.id, id: "/New.txt"))
    #expect(stored.remote.fileID == "server-new")
    #expect(stored.remote.etag == "server")
    #expect(try await store.item(accountID: account.id, id: "server-new") == nil)
    #expect(try await store.syncCursor(accountID: account.id, remotePath: "/") == "token-2")
}

@Test
func pollRemoteChangesWithSyncCollectionResolvesNestedParentsToStableIDs() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)
    ])
    try await store.setSyncCursor("token-1", accountID: account.id, remotePath: "/")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:sync-token>token-2</d:sync-token>
      <d:response><d:href>/remote.php/dav/files/alice/Folder/Nested.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"nested"</d:getetag><oc:fileid>nested-file</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.map(\.id) == ["nested-file"])
    #expect(changes.added.first?.parentID == "folder")
    #expect(try await store.item(accountID: account.id, id: "nested-file")?.remote.parentID == "folder")
    #expect(try await store.syncCursor(accountID: account.id, remotePath: "/") == "token-2")
}

@Test
func pollRemoteChangesFallsBackToPropfindWhenSyncCollectionTokenIsRejected() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.setSyncCursor("expired-token", accountID: account.id, remotePath: "/")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/New.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"new"</d:getetag><oc:fileid>new</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let transport = FixtureTransport([(Data(), 409), (xml, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(await transport.requests.map(\.httpMethod) == ["REPORT", "PROPFIND"])
    #expect(changes.added.map(\.id) == ["new"])
    #expect(try await store.syncCursor(accountID: account.id, remotePath: "/") == nil)
}

@Test
func pollRemoteChangesHidesHiddenAdditionsButPersistsThem() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/.Hidden.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"hidden"</d:getetag><oc:fileid>hidden</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: false, defaultAvailabilityIntent: .onlineOnly)
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.isEmpty)
    #expect(try await store.item(accountID: account.id, id: "hidden")?.availabilityIntent == .onlineOnly)
}

@Test
func pollRemoteChangesHidesIgnoredAdditionsButPersistsThem() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Visible.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"visible"</d:getetag><oc:fileid>visible</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Draft.tmp</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"draft"</d:getetag><oc:fileid>draft</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true, ignoredFilenamePatterns: ["*.tmp"])
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.map(\.id) == ["visible"])
    #expect(try await store.item(accountID: account.id, id: "draft") != nil)
}

@Test
func pollRemoteChangesHidesSelectiveSyncExcludedAdditionsButPersistsThem() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Visible.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"visible"</d:getetag><oc:fileid>visible</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Private/Secret.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"secret"</d:getetag><oc:fileid>secret</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(showHiddenFiles: true, excludedRemotePaths: ["/Private"])
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.added.map(\.id) == ["visible"])
    #expect(try await store.item(accountID: account.id, id: "secret") != nil)
}

@Test
func pollRemoteChangesRemovesDeletedFolderDescendantsAndMaterializedContent() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let childFile = directory.appending(path: "remote-child.txt")
    let childPartial = childFile.appendingPathExtension("part")
    try Data("child".utf8).write(to: childFile)
    try Data("part".utf8).write(to: childPartial)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file),
        RemoteItem(id: "nested", parentID: "folder", name: "Nested", path: "/Folder/Nested", kind: .folder),
        RemoteItem(id: "grandchild", parentID: "nested", name: "Deep.txt", path: "/Folder/Nested/Deep.txt", kind: .file),
        RemoteItem(id: "survivor", parentID: nil, name: "Survivor.txt", path: "/Survivor.txt", kind: .file, etag: "v1"),
    ])
    try await store.setMaterializedURL(childFile, accountID: account.id, itemID: "child")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Survivor.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"v1"</d:getetag><oc:fileid>survivor</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: directory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.deleted == ["child", "folder", "grandchild", "nested"])
    #expect(changes.deletedItems == [
        DeletedProviderItem(id: "child", parentID: "folder", path: "/Folder/Child.txt"),
        DeletedProviderItem(id: "folder", parentID: nil, path: "/Folder"),
        DeletedProviderItem(id: "grandchild", parentID: "nested", path: "/Folder/Nested/Deep.txt"),
        DeletedProviderItem(id: "nested", parentID: "folder", path: "/Folder/Nested"),
    ])
    #expect(try await store.item(accountID: account.id, id: "folder") == nil)
    #expect(try await store.item(accountID: account.id, id: "child") == nil)
    #expect(try await store.item(accountID: account.id, id: "nested") == nil)
    #expect(try await store.item(accountID: account.id, id: "grandchild") == nil)
    #expect(try await store.item(accountID: account.id, id: "survivor") != nil)
    #expect(!FileManager.default.fileExists(atPath: childFile.path))
    #expect(!FileManager.default.fileExists(atPath: childPartial.path))
}

@Test
func uploadModifiedContentsReportsConflictWhenRemoteEtagChanged() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let transport = FixtureTransport([
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "new-etag"), 207),
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "new-etag"), 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    await expectConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.conflict.kind == .remoteChangedDuringLocalEdit)
    #expect(conflicts.first?.conflict.itemID == "file-1")
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND"])
}

@Test
func uploadModifiedContentsReportsConflictWhenRemoteTypeChanged() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let transport = FixtureTransport([
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "folder-etag", kind: .folder), 207),
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "folder-etag", kind: .folder), 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .typeChanged, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    await expectConflict(kind: .typeChanged, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.conflict.kind == .typeChanged)
    #expect(conflicts.first?.conflict.itemID == "file-1")
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND"])
}

@Test
func resolvingConflictByKeepingRemoteRefreshesMetadataAndEvictsLocalContent() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("local".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await store.recordConflict(conflict, accountID: account.id)
    let transport = FixtureTransport([(propfindXML(name: "Readme.md", fileID: "file-1", etag: "remote-etag"), 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.resolveConflict(conflict, decision: .keepRemote)

    #expect(item?.id == "file-1")
    #expect(try await store.item(accountID: account.id, id: "file-1")?.remote.etag == "remote-etag")
    #expect(try await store.item(accountID: account.id, id: "file-1")?.materializedURL == nil)
    #expect(!FileManager.default.fileExists(atPath: localURL.path))
    #expect(try await store.conflicts(accountID: account.id, state: .pending).isEmpty)
    #expect(try await store.conflicts(accountID: account.id, state: .resolved).first?.selectedResolution == .keepRemote)
}

@Test
func resolvingConflictByKeepingLocalOverwritesRemoteAndLeavesNoPendingReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await store.recordConflict(conflict, accountID: account.id)
    let transport = FixtureTransport([
        (Data(), 204),
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "merged-etag"), 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.resolveConflict(conflict, decision: .keepLocal)

    #expect(item?.id == "file-1")
    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "If-Match") == nil)
    #expect(try await store.item(accountID: account.id, id: "file-1")?.remote.etag == "merged-etag")
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    #expect(try await store.conflicts(accountID: account.id, state: .resolved).first?.selectedResolution == .keepLocal)
}

@Test
func resolvingConflictByKeepingLocalKeepsLocalMetadataWhenPostUploadRefreshFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 3, etag: "old-etag")
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await store.recordConflict(conflict, accountID: account.id)
    let transport = FixtureTransport([(Data(), 204), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.resolveConflict(conflict, decision: .keepLocal)

    #expect(item?.id == "file-1")
    #expect(item?.size == 7)
    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(try await store.item(accountID: account.id, id: "file-1")?.materializedURL == localURL)
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    #expect(try await store.conflicts(accountID: account.id, state: .pending).isEmpty)
    #expect(try await store.conflicts(accountID: account.id, state: .resolved).first?.selectedResolution == .keepLocal)
}

@Test
func resolvingConflictByRenamingLocalUploadsCopyToValidatedName() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await store.recordConflict(conflict, accountID: account.id)
    let transport = FixtureTransport([
        (Data(), 201),
        (propfindXML(name: "Readme local.md", fileID: "file-local", etag: "local-etag"), 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.resolveConflict(conflict, decision: .renameLocal, resolvedName: "Readme local.md")

    #expect(item?.id == "file-local")
    #expect(item?.filename == "Readme local.md")
    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(await transport.requests.first?.url?.absoluteString.contains("Readme%20local.md") == true)
    #expect(try await store.item(accountID: account.id, id: "file-local")?.materializedURL == localURL)
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    let resolved = try await store.conflicts(accountID: account.id, state: .resolved).first
    #expect(resolved?.selectedResolution == .renameLocal)
    #expect(resolved?.resolvedName == "Readme local.md")
}

@Test
func resolvingConflictByRenamingLocalKeepsFallbackMetadataWhenPostUploadRefreshFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "file-1")
    let conflict = ConflictRecord(conflict: SyncConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1", localPath: "/Readme.md", remotePath: "/Readme.md", message: "Remote changed"))
    try await store.recordConflict(conflict, accountID: account.id)
    let transport = FixtureTransport([(Data(), 201), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let item = try await coordinator.resolveConflict(conflict, decision: .renameLocal, resolvedName: "Readme local.md")

    #expect(item?.id == "/Readme local.md")
    #expect(item?.filename == "Readme local.md")
    #expect(item?.size == 7)
    #expect(await transport.requests.map(\.httpMethod) == ["PUT", "PROPFIND"])
    #expect(try await store.item(accountID: account.id, id: "/Readme local.md")?.materializedURL == localURL)
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
    let resolved = try await store.conflicts(accountID: account.id, state: .resolved).first
    #expect(resolved?.selectedResolution == .renameLocal)
    #expect(resolved?.resolvedName == "Readme local.md")
}

@Test
func uploadModifiedContentsRejectsMissingOwnCloudWritePermissionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, permissions: "RDNV")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectUnsupported(contains: "upload /Readme.md") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func uploadModifiedContentsRejectsIgnoredExistingItemBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Scratch.swp", path: "/Scratch.swp", kind: .file)
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("swap".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(ignoredFilenamePatterns: ["*.swp"])
    )

    await expectInvalidFilename("Scratch.swp", violation: .ignoredPattern) {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func uploadModifiedContentsReportsConflictWhenRemoteItemIsMissingFromPropfind() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let emptyPropfind = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"></d:multistatus>
    """.utf8)
    let transport = FixtureTransport([(emptyPropfind, 207)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .remoteDeletedDuringLocalEdit, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND"])
}

@Test
func uploadModifiedContentsReportsConflictWhenPropfindReturnsNotFound() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data(), 404)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .remoteDeletedDuringLocalEdit, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND"])
}

@Test
func createFolderRejectsInvalidOrCollidingNamesBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "existing", parentID: nil, name: "Archive", path: "/Archive", kind: .folder)
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    do {
        _ = try await coordinator.createFolder(named: "Bad/Name", parentPath: "/", parentID: nil)
        Issue.record("Expected invalid filename error")
    } catch WesomeCloudError.invalidFilename(let filename, let violation) {
        #expect(filename == "Bad/Name")
        #expect(violation == .containsSlash)
    } catch {
        Issue.record("Expected invalid filename error, got \(error)")
    }
    await expectConflict(kind: .nameCollision, itemID: "archive") {
        _ = try await coordinator.createFolder(named: "archive", parentPath: "/", parentID: nil)
    }
    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.conflict.kind == .nameCollision)
    #expect(conflicts.first?.conflict.itemID == "archive")
    #expect(await transport.requests.isEmpty)
}

@Test
func createItemsRejectIgnoredFilenamePatternsBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("temp".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: InMemoryMetadataStore(),
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(ignoredFilenamePatterns: ["*.tmp", "~$*"])
    )

    await expectInvalidFilename("Notes.tmp", violation: .ignoredPattern) {
        _ = try await coordinator.createFile(named: "Notes.tmp", contentsAt: localURL, parentPath: "/", parentID: nil)
    }
    await expectInvalidFilename("~$Draft.docx", violation: .ignoredPattern) {
        _ = try await coordinator.createFolder(named: "~$Draft.docx", parentPath: "/", parentID: nil)
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func localMutationsRejectSelectiveSyncExcludedPathsBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "private", parentID: nil, name: "Private", path: "/Private", kind: .folder),
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file),
        RemoteItem(id: "secret", parentID: "private", name: "Secret.txt", path: "/Private/Secret.txt", kind: .file),
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("secret".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(excludedRemotePaths: ["/Private"])
    )

    await expectUnsupported(contains: "excluded from selective sync") {
        _ = try await coordinator.createFile(named: "New.txt", contentsAt: localURL, parentPath: "/Private", parentID: "private")
    }
    await expectUnsupported(contains: "excluded from selective sync") {
        _ = try await coordinator.move(itemID: "file-1", to: "/Private/Readme.md")
    }
    await expectUnsupported(contains: "excluded from selective sync") {
        _ = try await coordinator.uploadModifiedContents(itemID: "secret", contentsAt: localURL)
    }
    await expectUnsupported(contains: "excluded from selective sync") {
        try await coordinator.delete(itemID: "secret")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func createFolderRejectsUnicodeNormalizationCollisionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "resume", parentID: nil, name: "Cafe\u{301}", path: "/Cafe\u{301}", kind: .folder)
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .unicodeNormalization, itemID: "Café") {
        _ = try await coordinator.createFolder(named: "Café", parentPath: "/", parentID: nil)
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func createItemsRejectMissingOwnCloudCreatePermissionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder, permissions: "RDNV")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new".utf8).write(to: localURL)
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectUnsupported(contains: "create items in /Folder") {
        _ = try await coordinator.createFolder(named: "Child", parentPath: "/Folder", parentID: "folder")
    }
    await expectUnsupported(contains: "create items in /Folder") {
        _ = try await coordinator.createFile(named: "Child.txt", contentsAt: localURL, parentPath: "/Folder", parentID: "folder")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func moveUpdatesStoredMetadataAndLeavesNoPendingReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag"),
    ])
    let transport = FixtureTransport([(Data(), 201)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let moved = try await coordinator.move(itemID: "file-1", to: "/Folder/Renamed.md")

    #expect(moved.id == "file-1")
    #expect(moved.parentID == "folder")
    #expect(moved.filename == "Renamed.md")
    let stored = try await store.item(accountID: account.id, id: "file-1")
    #expect(stored?.remote.path == "/Folder/Renamed.md")
    #expect(stored?.remote.parentID == "folder")
    #expect(stored?.remote.name == "Renamed.md")
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["MOVE"])
    #expect(requests.first?.value(forHTTPHeaderField: "Destination") == "https://cloud.example/remote.php/dav/files/alice/Folder/Renamed.md")
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.isEmpty)
}

@Test
func moveQueuesRetryableFailureForOfflineReplay() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    let transport = FixtureTransport([(Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.move(itemID: "file-1", to: "/Folder/Renamed.md")
    }

    #expect(await transport.requests.map(\.httpMethod) == ["MOVE"])
    let pending = try await store.pendingOperations(accountID: account.id)
    #expect(pending.count == 1)
    #expect(pending.first?.kind == .move)
    #expect(pending.first?.itemID == "file-1")
    #expect(pending.first?.sourcePath == "/Readme.md")
    #expect(pending.first?.destinationPath == "/Folder/Renamed.md")
    #expect(pending.first?.lastErrorDescription?.contains("503") == true)
    let stored = try await store.item(accountID: account.id, id: "file-1")
    #expect(stored?.remote.path == "/Readme.md")
    #expect(stored?.remote.parentID == nil)
}

@Test
func moveRejectsIgnoredDestinationBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory,
        presentationPolicy: FileProviderPresentationPolicy(ignoredFilenamePatterns: ["*.tmp"])
    )

    await expectInvalidFilename("Readme.tmp", violation: .ignoredPattern) {
        _ = try await coordinator.move(itemID: "file-1", to: "/Readme.tmp")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func movingFolderUpdatesDescendantPaths() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "archive", parentID: nil, name: "Archive", path: "/Archive", kind: .folder),
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file),
        RemoteItem(id: "grandchild", parentID: "child-folder", name: "Nested.txt", path: "/Folder/Child Folder/Nested.txt", kind: .file),
        RemoteItem(id: "child-folder", parentID: "folder", name: "Child Folder", path: "/Folder/Child Folder", kind: .folder),
    ])
    let transport = FixtureTransport([(Data(), 201)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let moved = try await coordinator.move(itemID: "folder", to: "/Archive/Folder")

    #expect(moved.parentID == "archive")
    #expect(try await store.item(accountID: account.id, id: "folder")?.remote.path == "/Archive/Folder")
    #expect(try await store.item(accountID: account.id, id: "child")?.remote.path == "/Archive/Folder/Child.txt")
    #expect(try await store.item(accountID: account.id, id: "child-folder")?.remote.path == "/Archive/Folder/Child Folder")
    #expect(try await store.item(accountID: account.id, id: "grandchild")?.remote.path == "/Archive/Folder/Child Folder/Nested.txt")
}

@Test
func moveRejectsMissingOwnCloudRenamePermissionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, permissions: "RWDV")
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectUnsupported(contains: "rename /Readme.md") {
        _ = try await coordinator.move(itemID: "file-1", to: "/Renamed.md")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func moveRejectsMissingOwnCloudMovePermissionBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder, permissions: "RDNVC"),
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, permissions: "RDNW")
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectUnsupported(contains: "move /Readme.md") {
        _ = try await coordinator.move(itemID: "file-1", to: "/Folder/Readme.md")
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func moveRejectsCaseOnlyRenameBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file)
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .caseOnlyRename, itemID: "file-1") {
        _ = try await coordinator.move(itemID: "file-1", to: "/README.md")
    }
    await expectConflict(kind: .caseOnlyRename, itemID: "file-1") {
        _ = try await coordinator.move(itemID: "file-1", to: "/README.md")
    }
    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.conflict.kind == .caseOnlyRename)
    #expect(conflicts.first?.conflict.itemID == "file-1")
    #expect(await transport.requests.isEmpty)
}

@Test
func moveRejectsUnicodeNormalizationOnlyRenameBeforeNetworkCall() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Cafe\u{301}.txt", path: "/Cafe\u{301}.txt", kind: .file)
    ])
    let transport = FixtureTransport([(Data, Int)]())
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .unicodeNormalization, itemID: "file-1") {
        _ = try await coordinator.move(itemID: "file-1", to: "/Café.txt")
    }
    #expect(await transport.requests.isEmpty)
}

private func expectConflict(
    kind: SyncConflictKind,
    itemID: String,
    performing operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected conflict \(kind) for \(itemID)")
    } catch WesomeCloudError.conflict(let conflict) {
        #expect(conflict.kind == kind)
        #expect(conflict.itemID == itemID)
    } catch {
        Issue.record("Expected conflict, got \(error)")
    }
}

private func expectUnsupported(
    contains expectedMessage: String,
    performing operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected unsupported error containing \(expectedMessage)")
    } catch WesomeCloudError.unsupported(let message) {
        #expect(message.contains(expectedMessage))
    } catch {
        Issue.record("Expected unsupported error, got \(error)")
    }
}

private func expectInvalidFilename(
    _ filename: String,
    violation: FilenameViolation,
    performing operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected invalid filename \(filename)")
    } catch WesomeCloudError.invalidFilename(let actualFilename, let actualViolation) {
        #expect(actualFilename == filename)
        #expect(actualViolation == violation)
    } catch {
        Issue.record("Expected invalid filename, got \(error)")
    }
}

private func expectHTTPFailure(
    statusCode: Int,
    performing operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected HTTP failure \(statusCode)")
    } catch WesomeCloudError.httpFailure(let failure) {
        #expect(failure.statusCode == statusCode)
    } catch {
        Issue.record("Expected HTTP failure \(statusCode), got \(error)")
    }
}

private func propfindXML(name: String, fileID: String, etag: String, kind: RemoteItemKind = .file, size: Int = 7) -> Data {
    let resourceType = kind == .folder ? "<d:collection/>" : ""
    return Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/\(name)</d:href><d:propstat><d:prop>
        <d:resourcetype>\(resourceType)</d:resourcetype><d:getcontentlength>\(size)</d:getcontentlength><d:getetag>"\(etag)"</d:getetag><oc:fileid>\(fileID)</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
        try await Task.sleep(nanoseconds: 5_000_000)
        if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
            Issue.record("Timed out waiting for condition")
            return
        }
    }
}

@Test
func enumerationReplacesItemReuploadedWithNewFileIDAtSamePath() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "old", parentID: nil, name: "Report.txt", path: "/Report.txt", kind: .file, etag: "v1", fileID: "old"),
        RemoteItem(id: "gone", parentID: nil, name: "Gone.txt", path: "/Gone.txt", kind: .file, etag: "v1", fileID: "gone"),
    ])
    let listing = propfindXML(name: "Report.txt", fileID: "new", etag: "v2")
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(listing, 207), (listing, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    #expect(try await coordinator.enumerate(parentID: nil, remotePath: "/").map(\.id) == ["new"])
    #expect(try await coordinator.enumerate(parentID: nil, remotePath: "/").map(\.id) == ["new"])
    #expect(try await store.item(accountID: account.id, id: "old") == nil)
    #expect(try await store.item(accountID: account.id, id: "gone") == nil)
}

@Test
func enumerationIgnoresTheRequestedFolderOwnEntry() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "docs", parentID: nil, name: "Docs", path: "/Docs", kind: .folder, fileID: "docs"),
        RemoteItem(id: "sub", parentID: "docs", name: "Sub", path: "/Docs/Sub", kind: .folder, fileID: "sub"),
    ])
    let subListing = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Docs/Sub/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"sub"</d:getetag><oc:fileid>sub</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Docs/Sub/Child.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"child"</d:getetag><oc:fileid>child</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let rootListing = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"root"</d:getetag><oc:fileid>root</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Docs/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"docs"</d:getetag><oc:fileid>docs</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(subListing, 207), (rootListing, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    #expect(try await coordinator.enumerate(parentID: "sub", remotePath: "/Docs/Sub").map(\.id) == ["child"])
    #expect(try await store.item(accountID: account.id, id: "sub")?.remote.parentID == "docs")
    #expect(try await coordinator.enumerate(parentID: nil, remotePath: "/").map(\.id) == ["docs"])
    #expect(try await store.item(accountID: account.id, id: "root") == nil)
}

@Test
func pollRemoteChangesWithSyncCollectionTreatsFolderRenameAsMoveOfSubtree() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("child".utf8).write(to: localURL)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Old", path: "/Old", kind: .folder, etag: "f1", fileID: "folder"),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Old/Child.txt", kind: .file, etag: "c1", fileID: "child"),
    ])
    try await store.setMaterializedURL(localURL, accountID: account.id, itemID: "child")
    try await store.setAvailabilityIntent(.alwaysLocal, accountID: account.id, itemID: "child")
    try await store.setSyncCursor("token-1", accountID: account.id, remotePath: "/")
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:sync-token>token-2</d:sync-token>
      <d:response><d:href>/remote.php/dav/files/alice/Old</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/New/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><d:getetag>"f2"</d:getetag><oc:fileid>folder</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: FixtureTransport([(xml, 207)])),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.deleted.isEmpty)
    #expect(changes.updated.map(\.id) == ["folder"])
    #expect(try await store.item(accountID: account.id, id: "folder")?.remote.path == "/New")
    let child = try #require(await store.item(accountID: account.id, id: "child"))
    #expect(child.remote.path == "/New/Child.txt")
    #expect(child.materializedURL == localURL)
    #expect(child.availabilityIntent == .alwaysLocal)
    #expect(FileManager.default.fileExists(atPath: localURL.path))
}

@Test
func pollRemoteChangesMovesDescendantsOfRemotelyRenamedFolder() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Old", path: "/Old", kind: .folder, etag: "f1", fileID: "folder"),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Old/Child.txt", kind: .file, etag: "c1", fileID: "child"),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(
            baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!,
            transport: FixtureTransport([(propfindXML(name: "New", fileID: "folder", etag: "f2", kind: .folder), 207)])
        ),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let changes = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")

    #expect(changes.updated.map(\.id) == ["folder"])
    #expect(try await store.item(accountID: account.id, id: "child")?.remote.path == "/New/Child.txt")
}

@Test
func fetchContentsVerifiesFirstSupportedChecksumFromOwnCloudChecksumList() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(
            id: "good", parentID: nil, name: "Good.md", path: "/Good.md", kind: .file, size: 8,
            checksum: "SHA1:4a756ca07e9487f482465a99e8286abc86ba4dc7 MD5:98bf7d8c15784f0a3d63204441e1e2aa ADLER32:0f0f0f0f"
        ),
        RemoteItem(
            id: "bad", parentID: nil, name: "Bad.md", path: "/Bad.md", kind: .file, size: 8,
            checksum: "SHA1:a1ce829a6e4fb826d301d8571c127c518175f6e2 MD5:98bf7d8c15784f0a3d63204441e1e2aa"
        ),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(
            baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!,
            transport: FixtureTransport([(Data("contents".utf8), 200), (Data("contents".utf8), 200)])
        ),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    let url = try await coordinator.fetchContents(itemID: "good")
    #expect(try String(contentsOf: url, encoding: .utf8) == "contents")
    await #expect(throws: WesomeCloudError.transferIntegrityMismatch("Checksum mismatch for /Bad.md")) {
        _ = try await coordinator.fetchContents(itemID: "bad")
    }
}

@Test
func fetchContentsRestartsInsteadOfResumingOversizedPartial() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, size: 8)
    ])
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("stale old version".utf8).write(to: directory.appending(path: "file-1").appendingPathExtension("part"))
    let transport = FixtureTransport([(Data("contents".utf8), 200)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: directory
    )

    let url = try await coordinator.fetchContents(itemID: "file-1")

    #expect(try String(contentsOf: url, encoding: .utf8) == "contents")
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Range") == nil)
}

@Test
func createFolderAllowsNamesThatDifferOnlyByAccents() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "existing", parentID: nil, name: "Résumé", path: "/Résumé", kind: .folder)
    ])
    let transport = FixtureTransport([(Data(), 201), (Data(), 503), (Data(), 201), (Data(), 503)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    let created = try await coordinator.createFolder(named: "Resume", parentPath: "/", parentID: nil)

    #expect(created.filename == "Resume")
    await expectConflict(kind: .nameCollision, itemID: "RÉSUMÉ") {
        _ = try await coordinator.createFolder(named: "RÉSUMÉ", parentPath: "/", parentID: nil)
    }
}

@Test
func uploadModifiedContentsRecordsConflictWhenIfMatchFails() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "old-etag")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("updated".utf8).write(to: localURL)
    let transport = FixtureTransport([(propfindXML(name: "Readme.md", fileID: "file-1", etag: "old-etag"), 207), (Data(), 412)])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )

    await expectConflict(kind: .remoteChangedDuringLocalEdit, itemID: "file-1") {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }

    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.map(\.conflict.kind) == [.remoteChangedDuringLocalEdit])
    #expect(try await store.pendingOperations(accountID: account.id).isEmpty)
}

@Test
func queuedOfflineUploadDoesNotOverwriteRemoteEditSeenByPoll() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "base", fileID: "file-1")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("local edit".utf8).write(to: localURL)
    let remoteEdit = propfindXML(name: "Readme.md", fileID: "file-1", etag: "remote-edit")
    let transport = FixtureTransport([
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "base"), 207), (Data(), 503),
        (remoteEdit, 207),
        (remoteEdit, 207), (Data(), 204), (remoteEdit, 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )
    let queue = OfflineOperationQueue(accountID: account.id, store: store, executor: WebDAVPendingOperationExecutor(backend: coordinator))

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    _ = try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/")
    _ = try await queue.processDueOperations()

    #expect(await transport.requests.map(\.httpMethod) == ["PROPFIND", "PUT", "PROPFIND", "PROPFIND"])
    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.map(\.conflict.kind) == [.remoteChangedDuringLocalEdit])
}

@Test
func remoteDeleteDuringQueuedOfflineUploadSurfacesConflict() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example")!, username: "alice")
    let store = InMemoryMetadataStore()
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "Readme.md", path: "/Readme.md", kind: .file, etag: "base", fileID: "file-1")
    ])
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("local edit".utf8).write(to: localURL)
    let emptyListing = Data("<d:multistatus xmlns:d=\"DAV:\"></d:multistatus>".utf8)
    let transport = FixtureTransport([
        (propfindXML(name: "Readme.md", fileID: "file-1", etag: "base"), 207), (Data(), 503),
        (emptyListing, 207),
        (Data(), 404),
        (emptyListing, 207),
    ])
    let coordinator = FileProviderCoordinator(
        account: account,
        webDAV: WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport),
        store: store,
        materializationDirectory: FileManager.default.temporaryDirectory
    )
    let queue = OfflineOperationQueue(accountID: account.id, store: store, executor: WebDAVPendingOperationExecutor(backend: coordinator))

    await expectHTTPFailure(statusCode: 503) {
        _ = try await coordinator.uploadModifiedContents(itemID: "file-1", contentsAt: localURL)
    }
    #expect(try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/").deleted.isEmpty)
    _ = try await queue.processDueOperations()
    #expect(try await coordinator.pollRemoteChanges(parentID: nil, remotePath: "/").deleted.isEmpty)

    let conflicts = try await store.conflicts(accountID: account.id, state: .pending)
    #expect(conflicts.map(\.conflict.kind) == [.remoteDeletedDuringLocalEdit])
    #expect(try await store.item(accountID: account.id, id: "file-1") != nil)
}
