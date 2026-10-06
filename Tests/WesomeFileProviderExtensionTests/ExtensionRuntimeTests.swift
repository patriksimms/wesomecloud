import Foundation
import OwnCloudKit
import SyncStore
import Testing
import WesomeCloudAppCore
import WesomeFileProviderCore
import WesomeFileProviderExtension
import WesomeCloudShared

#if canImport(FileProvider)
import FileProvider
import UniformTypeIdentifiers
#endif

private actor RuntimeFactoryTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var xml: Data

    init(xml: Data? = nil) {
        self.xml = xml ?? Data("""
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response><d:href>/remote.php/dav/files/alice/Root.txt</d:href><d:propstat><d:prop>
            <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"etag"</d:getetag><oc:fileid>root-file</oc:fileid>
          </d:prop></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            xml,
            HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor RuntimeBlockingTransport: HTTPTransport {
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

private actor RuntimeRefreshExchanger: OAuthRefreshTokenExchanging {
    var requestedRefreshToken: String?
    var tokenSet: OAuthTokenSet

    init(tokenSet: OAuthTokenSet) {
        self.tokenSet = tokenSet
    }

    func refreshAccessToken(_ refreshToken: String, serverURL _: URL, configuration _: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        requestedRefreshToken = refreshToken
        return tokenSet
    }
}

private actor ExtensionBackend: FileProviderBackend, FileProviderWorkingSetProviding, FileProviderPartialContentProviding, FileProviderTransferProgressProviding {
    var item = ProviderItem(stored: StoredItem(remote: RemoteItem(id: "root-file", parentID: nil, name: "Root.txt", path: "/Root.txt", kind: .file)))
    var workingSet: [ProviderItem] = []
    var changeSet = RemoteChangeSet()
    var deletedIDs: [String] = []
    var enumerateCalls: [(parentID: String?, remotePath: String)] = []
    var mutationCalls: [String] = []
    var fetchError: Error?
    var deleteError: Error?
    var createError: Error?
    var downloadProgress = TransferProgressSummary(completedUnitCount: 0, totalUnitCount: 0, activeTransferCount: 0)
    var uploadProgress = TransferProgressSummary(completedUnitCount: 0, totalUnitCount: 0, activeTransferCount: 0)
    var shouldBlockFetch = false
    var fetchStarted = false
    private var blockedFetchContinuation: CheckedContinuation<URL, Error>?
    var shouldBlockEnumeration = false
    var enumerationStarted = false
    private var blockedEnumerationContinuation: CheckedContinuation<[ProviderItem], Error>?

    func enumerate(parentID: String?, remotePath: String) async throws -> [ProviderItem] {
        enumerationStarted = true
        enumerateCalls.append((parentID, remotePath))
        if shouldBlockEnumeration {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedEnumerationContinuation = continuation
                }
            } onCancel: {
                Task {
                    await self.cancelBlockedEnumeration()
                }
            }
        }
        return [item]
    }
    func workingSetItems() async throws -> [ProviderItem] {
        workingSet
    }
    func item(itemID: String) async throws -> ProviderItem? {
        item.id == itemID ? item : nil
    }
    func fetchContents(itemID _: String) async throws -> URL {
        fetchStarted = true
        if let fetchError { throw fetchError }
        if shouldBlockFetch {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedFetchContinuation = continuation
                }
            } onCancel: {
                Task {
                    await self.cancelBlockedFetch()
                }
            }
        }
        return FileManager.default.temporaryDirectory
    }
    func fetchPartialContents(itemID _: String, requestedRange: ProviderContentRange, alignment _: Int64) async throws -> PartialProviderContent {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("partial")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(requestedRange.endExclusive))
        try handle.seek(toOffset: UInt64(requestedRange.offset))
        try handle.write(contentsOf: Data("ents".utf8))
        return PartialProviderContent(url: url, item: item, retrievedRange: requestedRange)
    }
    func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        mutationCalls.append("upload:\(itemID):\(localURL.path)")
        return item
    }
    func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem {
        if let createError { throw createError }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? -1)
        mutationCalls.append("createFile:\(name):\(parentPath):\(parentID ?? "nil"):\(size)")
        item = ProviderItem(
            id: "created-file",
            parentID: parentID,
            filename: name,
            kind: .file,
            size: size,
            contentVersion: Data(),
            metadataVersion: Data(),
            availabilityIntent: .unspecified,
            capabilities: [.read, .write, .rename, .delete]
        )
        return item
    }
    func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem {
        if let createError { throw createError }
        mutationCalls.append("createFolder:\(name):\(parentPath):\(parentID ?? "nil")")
        item = ProviderItem(
            id: "created-folder",
            parentID: parentID,
            filename: name,
            kind: .folder,
            size: nil,
            contentVersion: Data(),
            metadataVersion: Data(),
            availabilityIntent: .unspecified,
            capabilities: [.enumerate, .addChildren, .rename, .delete]
        )
        return item
    }
    func delete(itemID: String) async throws {
        if let deleteError { throw deleteError }
        deletedIDs.append(itemID)
    }
    func move(itemID: String, to destinationPath: String) async throws -> ProviderItem {
        mutationCalls.append("move:\(itemID):\(destinationPath)")
        let filename = destinationPath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? destinationPath
        item = ProviderItem(
            id: itemID,
            parentID: item.parentID,
            filename: filename,
            kind: item.kind,
            size: item.size,
            contentType: item.contentType,
            contentVersion: item.contentVersion,
            metadataVersion: item.metadataVersion,
            availabilityIntent: item.availabilityIntent,
            capabilities: item.capabilities
        )
        return item
    }
    func pollRemoteChanges(parentID _: String?, remotePath _: String) async throws -> RemoteChangeSet { changeSet }
    func setAvailabilityIntent(_: AvailabilityIntent, itemID: String, includeDescendants _: Bool) async throws -> [String] { [itemID] }
    func evictMaterializedContentForDiskPressure() async throws -> [String] { [] }
    func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary {
        direction == .download ? downloadProgress : uploadProgress
    }

    func setChangeSet(_ changeSet: RemoteChangeSet) {
        self.changeSet = changeSet
    }

    func failFetch(with error: Error) {
        fetchError = error
    }

    func failDelete(with error: Error) {
        deleteError = error
    }

    func failCreate(with error: Error) {
        createError = error
    }

    func setItem(_ item: ProviderItem) {
        self.item = item
    }

    func setWorkingSet(_ items: [ProviderItem]) {
        workingSet = items
    }

    func setTransferProgress(_ progress: TransferProgressSummary, direction: TransferDirection) {
        switch direction {
        case .download:
            downloadProgress = progress
        case .upload:
            uploadProgress = progress
        }
    }

    func blockFetchUntilCancelled() {
        shouldBlockFetch = true
    }

    private func cancelBlockedFetch() {
        blockedFetchContinuation?.resume(throwing: CancellationError())
        blockedFetchContinuation = nil
    }

    func blockEnumerationUntilCancelled() {
        shouldBlockEnumeration = true
    }

    private func cancelBlockedEnumeration() {
        blockedEnumerationContinuation?.resume(throwing: CancellationError())
        blockedEnumerationContinuation = nil
    }
}

private actor ExtensionRuntimeResolverProbe {
    private let runtime: FileProviderExtensionRuntime
    private(set) var domainIDs: [String] = []

    init(runtime: FileProviderExtensionRuntime) {
        self.runtime = runtime
    }

    func resolve(domainID: String) async throws -> FileProviderExtensionRuntime {
        domainIDs.append(domainID)
        return runtime
    }
}

@Test
func fileProviderCreateEmptyFileWithoutContentsURLUsesFileMutation() async throws {
    let backend = ExtensionBackend()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template",
        parentID: nil,
        filename: "Empty.txt",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    let filename = try await createItem(template, contents: nil, from: extensionInstance)

    #expect(filename == "Empty.txt")
    #expect(await backend.mutationCalls == ["createFile:Empty.txt:/:nil:0"])
}

@Test
func fileProviderSystemInitializerResolvesAndCachesRuntimeForDomain() async throws {
    let backend = ExtensionBackend()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let resolver = ExtensionRuntimeResolverProbe(runtime: runtime)
    let extensionInstance = WesomeFileProviderReplicatedExtension(
        domainIdentifier: "account-domain",
        runtimeResolver: { domainID in try await resolver.resolve(domainID: domainID) }
    )

    let firstItems = try await extensionInstance.enumerateRootForTestingBridge()
    let secondItems = try await extensionInstance.enumerateRootForTestingBridge()

    #expect(firstItems.map(\.filename) == ["Root.txt"])
    #expect(secondItems.map(\.filename) == ["Root.txt"])
    #expect(await resolver.domainIDs == ["account-domain"])
    #expect(await backend.enumerateCalls.map(\.remotePath) == ["/", "/"])
}

@Test
func fileProviderCreateFolderWithoutContentsURLUsesFolderMutation() async throws {
    let backend = ExtensionBackend()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template-folder",
        parentID: nil,
        filename: "Folder",
        kind: .folder,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate, .addChildren]
    ))

    let filename = try await createItem(template, contents: nil, from: extensionInstance)

    #expect(filename == "Folder")
    #expect(await backend.mutationCalls == ["createFolder:Folder:/:nil"])
}

@Test
func fileProviderInvalidFilenameReportsFilenameCollision() async throws {
    let backend = ExtensionBackend()
    await backend.failCreate(with: WesomeCloudError.invalidFilename("Bad:", .containsColon))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template",
        parentID: nil,
        filename: "Bad:",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    await expectFileProviderError(.filenameCollision) {
        _ = try await createItem(template, contents: nil, from: extensionInstance)
    }
    #expect(await backend.mutationCalls.isEmpty)
}

@Test
func fileProviderUnsupportedMutationReportsCannotSynchronize() async throws {
    let backend = ExtensionBackend()
    await backend.failCreate(with: WesomeCloudError.unsupported("Insufficient ownCloud permissions to create items in /"))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template",
        parentID: nil,
        filename: "Denied.txt",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    await expectFileProviderError(.cannotSynchronize) {
        _ = try await createItem(template, contents: nil, from: extensionInstance)
    }
    #expect(await backend.mutationCalls.isEmpty)
}

@Test
func fileProviderSelectiveSyncExclusionReportsExcludedFromSync() async throws {
    let backend = ExtensionBackend()
    await backend.failCreate(with: WesomeCloudError.unsupported("Path /Private/Denied.txt is excluded from selective sync"))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template",
        parentID: nil,
        filename: "Denied.txt",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    await expectFileProviderError(.excludedFromSync) {
        _ = try await createItem(template, contents: nil, from: extensionInstance)
    }
    #expect(await backend.mutationCalls.isEmpty)
}

@Test
func extensionRuntimeBridgeEnumeratesRootThroughAdapter() async throws {
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: ExtensionBackend()))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    let items = try await extensionInstance.enumerateRootForTestingBridge()

    #expect(items.map(\.id) == ["root-file"])
}

@Test
func fileProviderRootItemPreservesSystemRootIdentifier() async throws {
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: ExtensionBackend()))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    let item = try await itemSnapshot(for: .rootContainer, from: extensionInstance)

    #expect(item?.identifier == NSFileProviderItemIdentifier.rootContainer.rawValue)
    #expect(item?.parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue)
    #expect(item?.filename == "WesomeCloud")
    #expect(item?.contentTypeIdentifier == UTType.folder.identifier)
}

@Test
func fileProviderExtensionRecordsCallbackDiagnostics() async throws {
    let diagnostics = MemoryDiagnosticSink()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: ExtensionBackend()))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime, diagnostics: diagnostics)

    _ = try await itemSnapshot(for: NSFileProviderItemIdentifier("root-file"), from: extensionInstance)

    let messages = await diagnostics.events.map(\.message)
    #expect(messages.contains("item requested id=root-file"))
    #expect(messages.contains("item completed id=root-file"))
}

@Test
func fileProviderLifecycleSetCallbacksCompleteAndRecordDiagnostics() async throws {
    let diagnostics = MemoryDiagnosticSink()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: ExtensionBackend()))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime, diagnostics: diagnostics)

    await waitForCompletion { completion in
        extensionInstance.materializedItemsDidChange(completionHandler: completion)
    }
    await waitForCompletion { completion in
        extensionInstance.pendingItemsDidChange(completionHandler: completion)
    }
    try await waitUntil {
        await diagnostics.events.count >= 2
    }

    let messages = await diagnostics.events.map(\.message)
    #expect(messages.contains("materializedItemsDidChange domain=in-memory"))
    #expect(messages.contains("pendingItemsDidChange domain=in-memory"))
}

@Test
func fileProviderGlobalProgressReportsTransferJournalSummary() async throws {
    let backend = ExtensionBackend()
    await backend.setTransferProgress(
        TransferProgressSummary(completedUnitCount: 7, totalUnitCount: 20, activeTransferCount: 2),
        direction: .download
    )
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    let progress = extensionInstance.globalProgress(for: .downloading)
    try await waitUntil {
        progress.totalUnitCount == 20
    }

    #expect(progress.fileOperationKind == .downloading)
    #expect(progress.completedUnitCount == 7)
    #expect(progress.totalUnitCount == 20)
}

@Test
@available(macOS 26.0, *)
func fileProviderSearchEnumeratorReturnsCachedWorkingSetMatches() async throws {
    let report = ProviderItem(
        id: "report",
        parentID: nil,
        filename: "Report.pdf",
        kind: .file,
        size: 12,
        path: "/Finance/Report.pdf",
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let photo = ProviderItem(
        id: "photo",
        parentID: nil,
        filename: "Photo.jpg",
        kind: .file,
        size: 12,
        path: "/Photos/Photo.jpg",
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let backend = ExtensionBackend()
    await backend.setWorkingSet([photo, report])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let enumerator = WesomeFileProviderSearchEnumerator(
        runtimeProvider: { runtime },
        query: "report",
        desiredNumberOfResults: 10
    )
    let observer = SearchObserver()

    enumerator.enumerateSearchResults(for: observer, startingAt: nil)
    let result = try await observer.result()

    #expect(result.items.map(\.itemIdentifier.rawValue) == ["report"])
    #expect(result.items.first?.filename == "Report.pdf")
    #expect(result.nextPage == nil)
}

@Test
func fileProviderFetchMissingBackendItemReportsNoSuchItem() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.missingItem("missing-file"))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectNoSuchItem {
        _ = try await fetchContents(for: "missing-file", from: extensionInstance)
    }
}

@Test
func fileProviderFetchStaleRequestedVersionReportsVersionNoLongerAvailableBeforeDownload() async throws {
    let backend = ExtensionBackend()
    await backend.setItem(ProviderItem(
        id: "root-file",
        parentID: nil,
        filename: "Root.txt",
        kind: .file,
        size: 4,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let staleVersion = NSFileProviderItemVersion(
        contentVersion: Data("old-content".utf8),
        metadataVersion: Data("server-metadata".utf8)
    )

    await expectFileProviderError(.versionNoLongerAvailable) {
        _ = try await fetchContents(for: "root-file", version: staleVersion, from: extensionInstance)
    }
    #expect(await backend.fetchStarted == false)
}

@Test
func fileProviderFetchPartialContentsReturnsSparseRangeAndItem() async throws {
    let backend = ExtensionBackend()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(
        contentVersion: ProviderItem(stored: StoredItem(remote: RemoteItem(id: "root-file", parentID: nil, name: "Root.txt", path: "/Root.txt", kind: .file))).contentVersion,
        metadataVersion: ProviderItem(stored: StoredItem(remote: RemoteItem(id: "root-file", parentID: nil, name: "Root.txt", path: "/Root.txt", kind: .file))).metadataVersion
    )

    let partial = try await fetchPartialContents(
        for: "root-file",
        version: version,
        range: NSRange(location: 4, length: 4),
        from: extensionInstance
    )

    #expect(partial.itemIdentifier == "root-file")
    #expect(partial.range == NSRange(location: 4, length: 4))
    #expect(partial.flags.isEmpty)
    let handle = try #require(partial.url.map { try FileHandle(forReadingFrom: $0) })
    defer { try? handle.close() }
    try handle.seek(toOffset: 4)
    #expect(try handle.read(upToCount: 4) == Data("ents".utf8))
}

@Test
func fileProviderIncrementalFetchFallsBackToFullReplacementAndValidatesRequestedVersion() async throws {
    let backend = ExtensionBackend()
    let item = ProviderItem(
        id: "root-file",
        parentID: nil,
        filename: "Root.txt",
        kind: .file,
        size: 4,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    await backend.setItem(item)
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let existingURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("txt")
    try Data("old".utf8).write(to: existingURL)
    let requestedVersion = NSFileProviderItemVersion(
        contentVersion: item.contentVersion,
        metadataVersion: item.metadataVersion
    )
    let existingVersion = NSFileProviderItemVersion(
        contentVersion: Data("old-content".utf8),
        metadataVersion: Data("old-metadata".utf8)
    )

    let fetchedURL = try await fetchIncrementalContents(
        for: "root-file",
        version: requestedVersion,
        existingContents: existingURL,
        existingVersion: existingVersion,
        from: extensionInstance
    )

    #expect(fetchedURL == FileManager.default.temporaryDirectory)
    #expect(await backend.fetchStarted)
}

@Test
func fileProviderIncrementalFetchReusesExistingContentsWhenVersionMatches() async throws {
    let backend = ExtensionBackend()
    let item = ProviderItem(
        id: "root-file",
        parentID: nil,
        filename: "Root.txt",
        kind: .file,
        size: 4,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    await backend.setItem(item)
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let existingURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("txt")
    try Data("same".utf8).write(to: existingURL)
    let currentVersion = NSFileProviderItemVersion(
        contentVersion: item.contentVersion,
        metadataVersion: item.metadataVersion
    )

    let fetchedURL = try await fetchIncrementalContents(
        for: "root-file",
        version: currentVersion,
        existingContents: existingURL,
        existingVersion: currentVersion,
        from: extensionInstance
    )

    #expect(fetchedURL == existingURL)
    #expect(await backend.fetchStarted == false)
}

@Test
func fileProviderIncrementalFetchRejectsStaleRequestedVersionBeforeDownload() async throws {
    let backend = ExtensionBackend()
    await backend.setItem(ProviderItem(
        id: "root-file",
        parentID: nil,
        filename: "Root.txt",
        kind: .file,
        size: 4,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    ))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let staleVersion = NSFileProviderItemVersion(
        contentVersion: Data("stale".utf8),
        metadataVersion: Data("server-metadata".utf8)
    )
    let existingURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("old".utf8).write(to: existingURL)

    await expectFileProviderError(.versionNoLongerAvailable) {
        _ = try await fetchIncrementalContents(
            for: "root-file",
            version: staleVersion,
            existingContents: existingURL,
            existingVersion: staleVersion,
            from: extensionInstance
        )
    }
    #expect(await backend.fetchStarted == false)
}

@Test
func fileProviderFetchProgressCancellationCancelsUnderlyingTask() async throws {
    let backend = ExtensionBackend()
    await backend.blockFetchUntilCancelled()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let probe = FetchCompletionProbe()

    let progress = extensionInstance.fetchContents(
        for: NSFileProviderItemIdentifier("root-file"),
        version: nil,
        request: NSFileProviderRequest()
    ) { url, item, error in
        probe.complete(url: url, item: item, error: error)
    }
    try await waitUntil { await backend.fetchStarted }

    progress.cancel()

    do {
        _ = try await probe.result()
        Issue.record("Expected cancelled fetch to report an error")
    } catch let error as NSError {
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSUserCancelledError)
    }
}

@Test
func fileProviderDeleteMissingBackendItemCompletesAsAlreadyDeleted() async throws {
    let backend = ExtensionBackend()
    await backend.failDelete(with: WesomeCloudError.missingItem("missing-file"))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data())

    try await deleteItem("missing-file", version: version, from: extensionInstance)
    #expect(await backend.deletedIDs.isEmpty)
}

@Test
func fileProviderDeleteStaleBaseVersionReportsDeletionRejectedBeforeMutation() async throws {
    let backend = ExtensionBackend()
    await backend.setItem(ProviderItem(
        id: "root-file",
        parentID: nil,
        filename: "Root.txt",
        kind: .file,
        size: 4,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write, .delete]
    ))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let staleVersion = NSFileProviderItemVersion(
        contentVersion: Data("old-content".utf8),
        metadataVersion: Data("server-metadata".utf8)
    )

    do {
        try await deleteItem("root-file", version: staleVersion, from: extensionInstance)
        Issue.record("Expected stale delete base version to be rejected")
    } catch let error as NSError {
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == -1006)
    }
    #expect(await backend.deletedIDs.isEmpty)
}

@Test
func fileProviderDeleteNonRecursiveNonEmptyFolderReportsDirectoryNotEmpty() async throws {
    let backend = ExtensionBackend()
    await backend.setItem(ProviderItem(
        id: "folder",
        parentID: nil,
        filename: "Folder",
        kind: .folder,
        size: nil,
        contentVersion: Data("folder-content".utf8),
        metadataVersion: Data("folder-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate, .delete]
    ))
    let cache = ExtensionItemCache(storedItems: [
        StoredItem(remote: RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)),
        StoredItem(remote: RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file)),
    ])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend), itemCache: cache)
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(
        contentVersion: Data("folder-content".utf8),
        metadataVersion: Data("folder-metadata".utf8)
    )

    do {
        try await deleteItem("folder", version: version, from: extensionInstance)
        Issue.record("Expected non-recursive non-empty folder delete to fail")
    } catch let error as NSError {
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == -1007)
    }
    #expect(await backend.deletedIDs.isEmpty)
    #expect(await cache.cachedItem(id: "folder") != nil)
    #expect(await cache.cachedItem(id: "child") != nil)
}

@Test
func fileProviderHTTPNotFoundReportsNoSuchItem() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 404, kind: .notFound)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectNoSuchItem {
        _ = try await fetchContents(for: "missing-file", from: extensionInstance)
    }
}

@Test
func fileProviderAuthFailureReportsNotAuthenticated() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 401, kind: .authentication)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectFileProviderError(.notAuthenticated) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

@Test
func fileProviderUnavailableFailureReportsServerUnreachable() async throws {
    let backend = ExtensionBackend()
    await backend.failDelete(with: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data())

    await expectFileProviderError(.serverUnreachable) {
        try await deleteItem("root-file", version: version, from: extensionInstance)
    }
    #expect(await backend.deletedIDs.isEmpty)
}

@Test
func fileProviderQuotaFailureReportsInsufficientQuota() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 507, kind: .quotaExceeded)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectFileProviderError(.insufficientQuota) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

@Test(arguments: [409, 412, 423])
func fileProviderHTTPConflictStatusReportsRetryableCannotSynchronize(statusCode: Int) async throws {
    let backend = ExtensionBackend()
    await backend.failDelete(with: WesomeCloudError.httpFailure(HTTPFailure.classify(statusCode: statusCode)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data())

    await expectFileProviderError(.cannotSynchronize) {
        try await deleteItem("root-file", version: version, from: extensionInstance)
    }
    #expect(await backend.deletedIDs.isEmpty)
}

@Test
func fileProviderForbiddenReportsNoPermissionInsteadOfSignIn() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 403, kind: .authorization)))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    do {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
        Issue.record("Expected permission error")
    } catch let error as NSError {
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSFileWriteNoPermissionError)
    }
}

@Test
func fileProviderIgnoredFilenameReportsExcludedFromSync() async throws {
    let backend = ExtensionBackend()
    await backend.failCreate(with: WesomeCloudError.invalidFilename(".DS_Store", .ignoredPattern))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "template",
        parentID: nil,
        filename: ".DS_Store",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    await expectFileProviderError(.excludedFromSync) {
        _ = try await createItem(template, contents: nil, from: extensionInstance)
    }
}

@Test
func fileProviderMissingCredentialReportsNotAuthenticated() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account, domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"))
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [record]),
        credentials: MemoryCredentialStore(),
        factory: ProductionExtensionRuntimeFactory(paths: WesomeCloudPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    )
    let extensionInstance = WesomeFileProviderReplicatedExtension(
        domainIdentifier: "domain-1",
        runtimeResolver: { domainID in try await resolver.makeRuntime(domainID: domainID) }
    )

    await expectFileProviderError(.notAuthenticated) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

private struct DeniedCredentialStore: CredentialStore {
    func save(_: Credential) async throws {}
    func credential(accountID _: UUID) async throws -> Credential? { throw KeychainError.status(-67701) }
    func delete(accountID _: UUID) async throws {}
}

@Test
func fileProviderKeychainDenialReportsNotAuthenticatedInsteadOfUnsupportedDomain() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account, domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"))
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [record]),
        credentials: DeniedCredentialStore(),
        factory: ProductionExtensionRuntimeFactory(paths: WesomeCloudPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    )
    let extensionInstance = WesomeFileProviderReplicatedExtension(
        domainIdentifier: "domain-1",
        runtimeResolver: { domainID in try await resolver.makeRuntime(domainID: domainID) }
    )

    await expectFileProviderError(.notAuthenticated) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

@Test
func fileProviderRemoteEditConflictDoesNotReportFilenameCollision() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.conflict(SyncConflict(
        kind: .remoteChangedDuringLocalEdit,
        itemID: "root-file",
        message: "Remote changed"
    )))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectFileProviderError(.cannotSynchronize) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

@Test
func fileProviderSyncConflictReportsFilenameCollision() async throws {
    let backend = ExtensionBackend()
    await backend.failFetch(with: WesomeCloudError.conflict(SyncConflict(
        kind: .nameCollision,
        itemID: "root-file",
        localPath: "/Root.txt",
        remotePath: "/Root.txt",
        message: "Name collision"
    )))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)

    await expectFileProviderError(.filenameCollision) {
        _ = try await fetchContents(for: "root-file", from: extensionInstance)
    }
}

@Test
func extensionItemCacheTracksEnumeratedPathsAndParents() async {
    let cache = ExtensionItemCache()
    let parent = ProviderItem(
        id: "folder",
        parentID: nil,
        filename: "Folder",
        kind: .folder,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate]
    )
    let child = ProviderItem(
        id: "child",
        parentID: "folder",
        filename: "Child.txt",
        kind: .file,
        size: 1,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )

    await cache.register(ProviderPage(items: [parent]), container: .root)
    await cache.register(ProviderPage(items: [child]), container: .item(id: "folder", path: "/Folder"))

    #expect(await cache.cachedItem(id: "folder")?.path == "/Folder")
    #expect(await cache.cachedItem(id: "child")?.path == "/Folder/Child.txt")
    #expect(await cache.parentPath(for: "child") == "/Folder")
    #expect(await cache.destinationPath(parentID: "folder", filename: "New.txt") == "/Folder/New.txt")
    #expect(await cache.containerReference(for: "folder") == .item(id: "folder", path: "/Folder"))
}

@Test
func extensionItemCacheWarmsFromStoredMetadataPaths() async {
    let cache = ExtensionItemCache(storedItems: [
        StoredItem(remote: RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)),
        StoredItem(remote: RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file)),
    ])

    #expect(await cache.cachedItem(id: "child")?.path == "/Folder/Child.txt")
    #expect(await cache.parentPath(for: "child") == "/Folder")
    #expect(await cache.destinationPath(parentID: "folder", filename: "New.txt") == "/Folder/New.txt")
    #expect(await cache.containerReference(for: "folder") == .item(id: "folder", path: "/Folder"))
}

@Test
func extensionItemCacheRemovesDeletedSubtrees() async {
    let cache = ExtensionItemCache(storedItems: [
        StoredItem(remote: RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)),
        StoredItem(remote: RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file)),
        StoredItem(remote: RemoteItem(id: "nested", parentID: "folder", name: "Nested", path: "/Folder/Nested", kind: .folder)),
        StoredItem(remote: RemoteItem(id: "grandchild", parentID: "nested", name: "Deep.txt", path: "/Folder/Nested/Deep.txt", kind: .file)),
        StoredItem(remote: RemoteItem(id: "sibling", parentID: nil, name: "Sibling.txt", path: "/Sibling.txt", kind: .file)),
    ])

    await cache.remove(id: "folder")

    #expect(await cache.cachedItem(id: "folder") == nil)
    #expect(await cache.cachedItem(id: "child") == nil)
    #expect(await cache.cachedItem(id: "nested") == nil)
    #expect(await cache.cachedItem(id: "grandchild") == nil)
    #expect(await cache.cachedItem(id: "sibling")?.path == "/Sibling.txt")
}

@Test
func productionRuntimeFactoryBuildsRuntimeFromAccountCredentialAndPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let transport = RuntimeFactoryTransport()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword)
    let factory = ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    try paths.ensureDirectories()
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder),
        RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file),
    ])

    let runtime = try factory.makeRuntime(configuration: ExtensionRuntimeAccountConfiguration(account: account, credential: credential))
    let items = try await runtime.adapter.enumerate(container: .root).items

    // The server listing is authoritative: cached "folder" is gone remotely, so enumeration prunes it.
    #expect(items.map(\.id) == ["root-file"])
    #expect(FileManager.default.fileExists(atPath: paths.root.path))
    #expect(FileManager.default.fileExists(atPath: paths.materializedFiles.path))
    let request = await transport.requests.first
    #expect(request?.url?.absoluteString == "https://cloud.example/remote.php/dav/files/alice/")
    #expect(request?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    #expect(await runtime.itemCache.parentPath(for: "child") == "/Folder")
}

@Test
func productionRuntimeFactoryBuildsExpectedWebDAVURLAndCredentials() throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/base/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword)

    #expect(ProductionExtensionRuntimeFactory.webDAVBaseURL(account: account).absoluteString == "https://cloud.example/base/remote.php/dav/files/alice/")
    #expect(try ProductionExtensionRuntimeFactory.credentials(from: credential).authorizationHeader.hasPrefix("Basic ") == true)
    #expect(throws: WesomeCloudError.unsupported("OAuth refresh tokens must be exchanged for access tokens before building a runtime")) {
        _ = try ProductionExtensionRuntimeFactory.credentials(
            from: Credential(accountID: account.id, username: "alice", secret: "refresh", kind: .oauthRefreshToken)
        )
    }
}

@Test
func domainRuntimeResolverResolvesDomainToRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let transport = RuntimeFactoryTransport()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let domain = CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice")
    let record = PersistedAccountRecord(account: account, domain: domain)
    let credential = Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword)
    let credentials = MemoryCredentialStore()
    try await credentials.save(credential)
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [record]),
        credentials: credentials,
        factory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    )

    let resolution = try await resolver.resolve(domainID: "domain-1")
    let runtime = try await resolver.makeRuntime(domainID: "domain-1")
    let items = try await runtime.adapter.enumerate(container: .root).items

    #expect(resolution.record == record)
    #expect(resolution.credential == credential)
    #expect(items.map(\.id) == ["root-file"])
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}

private struct SpaceRuntimeTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let space = url.pathComponents[3]
        let data: Data
        let status: Int
        if request.httpMethod == "GET" {
            data = Data(space.utf8)
            status = 200
        } else {
            data = Data("""
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
              <d:response><d:href>/dav/spaces/\(space)/\(space).txt</d:href><d:propstat><d:prop>
                <d:resourcetype/><d:getcontentlength>2</d:getcontentlength><d:getetag>"etag"</d:getetag><oc:fileid>same-id</oc:fileid>
              </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>
            """.utf8)
            status = 207
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Test
func domainRuntimesKeepSpaceListingsAndDownloadedFilesSeparateAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = WesomeCloudPaths(root: root)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    var record = PersistedAccountRecord(account: account)
    record.domains = ["AM", "HR"].map { name in
        CloudDomain(id: name, accountID: account.id, displayName: name,
                    webDAVRootURL: URL(string: "https://cloud.example/dav/spaces/\(name)")!, storageID: UUID())
    }
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let accounts = MemoryAccountRepository(records: [record])
    let factory = ProductionExtensionRuntimeFactory(paths: paths, transport: SpaceRuntimeTransport())
    let resolver = ProductionDomainRuntimeResolver(accounts: accounts, credentials: credentials, factory: factory)
    let am = try await resolver.makeRuntime(domainID: "AM")
    let hr = try await resolver.makeRuntime(domainID: "HR")
    #expect(try await am.adapter.enumerate(container: .root).items.map(\.filename) == ["AM.txt"])
    #expect(try await hr.adapter.enumerate(container: .root).items.map(\.filename) == ["HR.txt"])
    let amURL = try await am.adapter.fetchContents(for: "same-id")
    let hrURL = try await hr.adapter.fetchContents(for: "same-id")
    #expect(amURL != hrURL)
    #expect(try Data(contentsOf: amURL) == Data("AM".utf8))
    #expect(try Data(contentsOf: hrURL) == Data("HR".utf8))

    let restarted = ProductionDomainRuntimeResolver(accounts: accounts, credentials: credentials, factory: factory)
    let restoredAM = try await restarted.makeRuntime(domainID: "AM")
    let restoredHR = try await restarted.makeRuntime(domainID: "HR")
    #expect(await restoredAM.itemCache.cachedItem(id: "same-id")?.path == "/AM.txt")
    #expect(await restoredHR.itemCache.cachedItem(id: "same-id")?.path == "/HR.txt")
    #expect(try await restoredAM.adapter.itemForIdentifier("same-id", parentPath: "/")?.filename == "AM.txt")
    #expect(try await restoredHR.adapter.itemForIdentifier("same-id", parentPath: "/")?.filename == "HR.txt")
}

@Test
func domainRuntimeResolverRefreshesOAuthCredentialBeforeBuildingRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let transport = RuntimeFactoryTransport()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice")
    let record = PersistedAccountRecord(
        account: account,
        domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice")
    )
    let credentials = MemoryCredentialStore()
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "old-refresh", kind: .oauthRefreshToken))
    let exchanger = RuntimeRefreshExchanger(
        tokenSet: OAuthTokenSet(username: "alice", accessToken: "new-access", refreshToken: "new-refresh")
    )
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [record]),
        credentials: credentials,
        factory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport),
        credentialResolver: AccountCredentialResolver(discoveryClient: nil, refreshExchanger: exchanger)
    )

    let runtime = try await resolver.makeRuntime(domainID: "domain-1")
    _ = try await runtime.adapter.enumerate(container: .root).items

    #expect(await exchanger.requestedRefreshToken == "old-refresh")
    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    #expect(try await credentials.credential(accountID: account.id)?.secret == "new-refresh")
}

@Test
func domainRuntimeResolverAppliesFilePreferencesToRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/remote.php/dav/files/alice/Visible.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>7</d:getcontentlength><d:getetag>"visible"</d:getetag><oc:fileid>visible</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/.Hidden.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>6</d:getcontentlength><d:getetag>"hidden"</d:getetag><oc:fileid>hidden</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Draft.tmp</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"draft"</d:getetag><oc:fileid>draft</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/remote.php/dav/files/alice/Private</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><oc:fileid>private</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let transport = RuntimeFactoryTransport(xml: xml)
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword)
    let credentials = MemoryCredentialStore()
    try await credentials.save(credential)
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [PersistedAccountRecord(account: account, domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"))]),
        credentials: credentials,
        preferences: MemoryPreferencesRepository(preferences: AppPreferences(files: FilePreferences(defaultAvailability: .alwaysLocal, showHiddenFiles: false, ignoredFilenamePatterns: ["*.tmp"], excludedRemotePaths: ["/Private"]))),
        factory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    )

    let runtime = try await resolver.makeRuntime(domainID: "domain-1")
    let items = try await runtime.adapter.enumerate(container: .root).items
    let store = try SQLiteMetadataStore(databaseURL: paths.database)

    #expect(items.map(\.id) == ["visible"])
    #expect(try await store.item(accountID: account.id, id: "visible")?.availabilityIntent == .alwaysLocal)
    #expect(try await store.item(accountID: account.id, id: "hidden")?.availabilityIntent == .alwaysLocal)
    #expect(try await store.item(accountID: account.id, id: "draft")?.availabilityIntent == .alwaysLocal)
    #expect(try await store.item(accountID: account.id, id: "private")?.availabilityIntent == .alwaysLocal)
}

@Test
func domainRuntimeResolverAppliesTransferPreferencesToRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)
    try paths.ensureDirectories()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "app-password", kind: .appPassword)
    let credentials = MemoryCredentialStore()
    try await credentials.save(credential)
    let store = try SQLiteMetadataStore(databaseURL: paths.database)
    try await store.upsert(accountID: account.id, items: [
        RemoteItem(id: "file-1", parentID: nil, name: "One.txt", path: "/One.txt", kind: .file, size: 3),
        RemoteItem(id: "file-2", parentID: nil, name: "Two.txt", path: "/Two.txt", kind: .file, size: 3),
    ])
    let transport = RuntimeBlockingTransport()
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [PersistedAccountRecord(account: account, domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"))]),
        credentials: credentials,
        preferences: MemoryPreferencesRepository(preferences: AppPreferences(sync: SyncPreferences(maximumConcurrentTransfers: 1))),
        factory: ProductionExtensionRuntimeFactory(paths: paths, transport: transport)
    )

    let runtime = try await resolver.makeRuntime(domainID: "domain-1")
    async let first = runtime.adapter.fetchContents(for: "file-1")
    try await waitUntil { await transport.requestCount == 1 }
    async let second = runtime.adapter.fetchContents(for: "file-2")
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await transport.requestCount == 1)

    await transport.completeNext(data: Data("one".utf8))
    _ = try await first
    try await waitUntil { await transport.requestCount == 2 }
    await transport.completeNext(data: Data("two".utf8))
    _ = try await second
}

@Test
func domainRuntimeResolverReportsMissingCredential() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let record = PersistedAccountRecord(account: account, domain: CloudDomain(id: "domain-1", accountID: account.id, displayName: "Alice"))
    let resolver = ProductionDomainRuntimeResolver(
        accounts: MemoryAccountRepository(records: [record]),
        credentials: MemoryCredentialStore(),
        factory: ProductionExtensionRuntimeFactory(paths: WesomeCloudPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    )

    do {
        _ = try await resolver.resolve(domainID: "domain-1")
        Issue.record("Expected missing credential error")
    } catch WesomeCloudError.unsupported(let message) {
        #expect(message == "Missing credential for account \(account.id.uuidString)")
    } catch {
        Issue.record("Expected missing credential error, got \(error)")
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
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

private func waitForCompletion(_ operation: (@escaping () -> Void) -> Void) async {
    await withCheckedContinuation { continuation in
        operation {
            continuation.resume()
        }
    }
}

#if canImport(FileProvider)
private final class PackageTemplateItem: NSObject, NSFileProviderItem {
    let filename: String

    init(filename: String) {
        self.filename = filename
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier("package-template") }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var contentType: UTType { .rtfd }
}

private final class TrashParentItem: NSObject, NSFileProviderItem {
    private let item: NSFileProviderItem

    init(item: NSFileProviderItem) {
        self.item = item
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        item.itemIdentifier
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        .trashContainer
    }

    var filename: String {
        item.filename
    }

    var contentType: UTType {
        item.contentType ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        item.capabilities ?? []
    }

    var itemVersion: NSFileProviderItemVersion {
        item.itemVersion ?? NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data())
    }
}

@Test
func fileProviderItemMapsProviderMetadata() {
    let createdAt = Date(timeIntervalSince1970: 1_600_000_000)
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let providerItem = ProviderItem(
        id: "file-1",
        parentID: "parent",
        filename: "Report.txt",
        kind: .file,
        size: 42,
        contentType: "text/plain",
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        isMaterialized: true,
        capabilities: [.read, .write, .rename, .delete]
    )

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(item.itemIdentifier.rawValue == "file-1")
    #expect(item.parentItemIdentifier.rawValue == "parent")
    #expect(item.filename == "Report.txt")
    #expect(item.contentType == .plainText)
    #expect(item.documentSize == 42)
    #expect(item.creationDate == createdAt)
    #expect(item.contentModificationDate == modifiedAt)
    #expect(item.isDownloaded)
    #expect(!item.isDownloading)
    #expect(item.downloadingError == nil)
    #expect(item.isMostRecentVersionDownloaded)
    #expect(item.isUploaded)
    #expect(!item.isUploading)
    #expect(item.uploadingError == nil)
    #expect(item.capabilities.contains(.allowsReading))
    #expect(item.capabilities.contains(.allowsWriting))
    #expect(item.capabilities.contains(.allowsRenaming))
    #expect(!item.capabilities.contains(.allowsReparenting))
    #expect(item.capabilities.contains(.allowsDeleting))
    #expect(item.capabilities.contains(.allowsTrashing))
}

@Test
func fileProviderItemMarksDatalessFilesAsNotDownloaded() {
    let providerItem = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "cloud-only",
        parentID: nil,
        name: "Notes.txt",
        path: "/Notes.txt",
        kind: .file
    )))

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(!item.isDownloaded)
    #expect(!item.isDownloading)
    #expect(!item.isMostRecentVersionDownloaded)
    #expect(item.isUploaded)
    #expect(!item.isUploading)
}

@Test
func fileProviderItemMapsTransferStateAndErrors() {
    let providerItem = ProviderItem(
        id: "file-1",
        parentID: nil,
        filename: "Report.txt",
        kind: .file,
        size: 42,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        isUploaded: false,
        isUploading: true,
        isDownloading: true,
        uploadErrorDescription: "Upload unavailable",
        downloadErrorDescription: "Download unavailable",
        capabilities: [.read, .write]
    )

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(!item.isUploaded)
    #expect(item.isUploading)
    #expect(item.uploadingError?.localizedDescription == "Upload unavailable")
    #expect(item.isDownloading)
    #expect(item.downloadingError?.localizedDescription == "Download unavailable")
}

@Test
func fileProviderItemMapsAvailabilityIntentToContentPolicy() {
    func item(intent: AvailabilityIntent) -> WesomeFileProviderItem {
        WesomeFileProviderItem(item: ProviderItem(
            id: "file-\(intent.rawValue)",
            parentID: nil,
            filename: "Notes.txt",
            kind: .file,
            size: 4,
            contentVersion: Data("content".utf8),
            metadataVersion: Data("metadata".utf8),
            availabilityIntent: intent,
            capabilities: [.read]
        ))
    }

    #expect(item(intent: .alwaysLocal).contentPolicy == .downloadEagerlyAndKeepDownloaded)
    #expect(item(intent: .onlineOnly).contentPolicy == .downloadLazily)
    #expect(item(intent: .unspecified).contentPolicy == .downloadLazily)
    #expect(item(intent: .inherited).contentPolicy == .inherited)
}

@Test
func fileProviderItemInfersIWorkPackageContentTypeAndCapabilities() {
    let providerItem = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "package-1",
        parentID: nil,
        name: "Roadmap.pages",
        path: "/Roadmap.pages",
        kind: .folder
    )))

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(item.contentType.identifier == "com.apple.iwork.pages.sffpages")
}

@Test
func fileProviderFolderMapsContainerCapabilities() {
    let providerItem = ProviderItem(
        id: "folder-1",
        parentID: nil,
        filename: "Documents",
        kind: .folder,
        size: nil,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate, .addChildren]
    )

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(item.contentType == .folder)
    #expect(item.parentItemIdentifier == .rootContainer)
    #expect(item.capabilities.contains(.allowsContentEnumerating))
    #expect(item.capabilities.contains(.allowsAddingSubItems))
}

@Test
func fileProviderItemOmitsUnavailableOwnCloudPermissionCapabilities() {
    let providerItem = ProviderItem(stored: StoredItem(remote: RemoteItem(
        id: "read-only",
        parentID: nil,
        name: "Readme.md",
        path: "/Readme.md",
        kind: .file,
        permissions: "R"
    )))

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(item.capabilities.contains(.allowsReading))
    #expect(!item.capabilities.contains(.allowsWriting))
    #expect(!item.capabilities.contains(.allowsRenaming))
    #expect(!item.capabilities.contains(.allowsReparenting))
    #expect(!item.capabilities.contains(.allowsDeleting))
    #expect(!item.capabilities.contains(.allowsTrashing))
}

@Test
func fileProviderItemMapsReparentCapabilitySeparatelyFromRename() {
    let providerItem = ProviderItem(
        id: "file-1",
        parentID: nil,
        filename: "Movable.txt",
        kind: .file,
        size: 4,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .reparent]
    )

    let item = WesomeFileProviderItem(item: providerItem)

    #expect(item.capabilities.contains(.allowsReparenting))
    #expect(!item.capabilities.contains(.allowsRenaming))
}

@Test
func fileProviderEnumeratorKeepsCurrentSyncAnchorStableUntilChangesAdvanceIt() async throws {
    let backend = ExtensionBackend()
    let updated = ProviderItem(
        id: "updated-file",
        parentID: nil,
        filename: "Updated.txt",
        kind: .file,
        size: 12,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    await backend.setChangeSet(RemoteChangeSet(added: [updated], updated: [], deleted: ["deleted-file"]))
    let enumerator = WesomeFileProviderEnumerator(adapter: FileProviderAdapter(backend: backend), container: .root)

    let firstAnchor = try await currentAnchor(from: enumerator)
    let repeatedAnchor = try await currentAnchor(from: enumerator)
    let observer = ChangeObserver()

    enumerator.enumerateChanges(for: observer, from: firstAnchor)
    let result = try await observer.result()
    let advancedAnchor = try await currentAnchor(from: enumerator)

    #expect(anchorData(firstAnchor) == anchorData(repeatedAnchor))
    #expect(anchorData(result.anchor) == anchorData(advancedAnchor))
    #expect(anchorData(result.anchor) != anchorData(firstAnchor))
    #expect(result.updated.map(\.itemIdentifier.rawValue) == ["updated-file"])
    #expect(result.deleted.map(\.rawValue) == ["deleted-file"])
    #expect(result.moreComing == false)
}

@Test
func fileProviderWorkingSetEnumeratorReportsChangesFromWorkingSetSnapshot() async throws {
    let backend = ExtensionBackend()
    let original = ProviderItem(
        id: "nested-file",
        parentID: "folder",
        filename: "Nested.txt",
        kind: .file,
        size: 1,
        path: "/Folder/Nested.txt",
        contentVersion: Data("content-1".utf8),
        metadataVersion: Data("metadata-1".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let updated = ProviderItem(
        id: "nested-file",
        parentID: "folder",
        filename: "Nested.txt",
        kind: .file,
        size: 2,
        path: "/Folder/Nested.txt",
        contentVersion: Data("content-2".utf8),
        metadataVersion: Data("metadata-2".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    let added = ProviderItem(
        id: "added-file",
        parentID: "folder",
        filename: "Added.txt",
        kind: .file,
        size: 3,
        path: "/Folder/Added.txt",
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    await backend.setWorkingSet([original])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let enumerator = WesomeFileProviderEnumerator(
        runtimeProvider: { runtime },
        containerIdentifier: NSFileProviderItemIdentifier.workingSet.rawValue
    )
    let itemObserver = EnumerationObserver()

    enumerator.enumerateItems(for: itemObserver, startingAt: NSFileProviderPage(Data()))
    _ = try await itemObserver.result()
    await backend.setWorkingSet([updated, added])

    let changeObserver = ChangeObserver()
    enumerator.enumerateChanges(for: changeObserver, from: try await currentAnchor(from: enumerator))
    let result = try await changeObserver.result()

    #expect(result.updated.map(\.itemIdentifier.rawValue) == ["added-file", "nested-file"])
    #expect(result.deleted.isEmpty)
    #expect(result.moreComing == false)
    #expect(await backend.enumerateCalls.isEmpty)
}

@Test
func fileProviderDeleteInvalidatesExtensionItemCache() async throws {
    let backend = ExtensionBackend()
    let cache = ExtensionItemCache(storedItems: [
        StoredItem(remote: RemoteItem(id: "folder", parentID: nil, name: "Folder", path: "/Folder", kind: .folder)),
        StoredItem(remote: RemoteItem(id: "child", parentID: "folder", name: "Child.txt", path: "/Folder/Child.txt", kind: .file)),
    ])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend), itemCache: cache)
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let version = NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data())

    try await deleteItem(
        "folder",
        version: version,
        options: NSFileProviderDeleteItemOptions(rawValue: 1 << 0),
        from: extensionInstance
    )

    #expect(await backend.deletedIDs == ["folder"])
    #expect(await cache.cachedItem(id: "folder") == nil)
    #expect(await cache.cachedItem(id: "child") == nil)
}

@Test
func fileProviderModifyAppliesMoveBeforeUploadingChangedContents() async throws {
    let backend = ExtensionBackend()
    let parent = ProviderItem(
        id: "folder",
        parentID: nil,
        filename: "Folder",
        kind: .folder,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.enumerate]
    )
    let file = ProviderItem(
        id: "file-1",
        parentID: "folder",
        filename: "Old.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write, .rename]
    )
    let cache = ExtensionItemCache()
    await cache.register(parent, parentPath: "/")
    await cache.register(file, parentPath: "/Folder")
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend), itemCache: cache)
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let contents = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new".utf8).write(to: contents)
    let movedTemplate = WesomeFileProviderItem(item: ProviderItem(
        id: "file-1",
        parentID: "folder",
        filename: "New.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write, .rename]
    ))

    let filename = try await modifyItem(
        movedTemplate,
        changedFields: [.filename],
        contents: contents,
        from: extensionInstance
    )

    #expect(await backend.mutationCalls == [
        "move:file-1:/Folder/New.txt",
        "upload:file-1:\(contents.path)",
    ])
    #expect(filename == "New.txt")
    #expect(await cache.cachedItem(id: "file-1")?.path == "/Folder/New.txt")
}

@Test
func fileProviderModifyToTrashDeletesRemoteItemAndInvalidatesCache() async throws {
    let backend = ExtensionBackend()
    let file = ProviderItem(
        id: "file-1",
        parentID: nil,
        filename: "Old.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .delete]
    )
    let cache = ExtensionItemCache()
    await cache.register(file, parentPath: "/")
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend), itemCache: cache)
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let trashTemplate = TrashParentItem(item: WesomeFileProviderItem(item: file))

    let filename = try await modifyItem(
        trashTemplate,
        changedFields: [.parentItemIdentifier],
        contents: nil,
        from: extensionInstance
    )

    #expect(filename == nil)
    #expect(await backend.deletedIDs == ["file-1"])
    #expect(await backend.mutationCalls.isEmpty)
    #expect(await cache.cachedItem(id: "file-1") == nil)
}

@Test
func fileProviderModifyMetadataOnlyReportsMissingItemInsteadOfRootFallback() async throws {
    let backend = ExtensionBackend()
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let missingTemplate = WesomeFileProviderItem(item: ProviderItem(
        id: "missing-file",
        parentID: nil,
        filename: "Missing.txt",
        kind: .file,
        size: nil,
        contentVersion: Data(),
        metadataVersion: Data(),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write]
    ))

    do {
        _ = try await modifyItem(
            missingTemplate,
            changedFields: [],
            contents: nil,
            from: extensionInstance
        )
        Issue.record("Expected no-such-item error")
    } catch let error as NSError {
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == NSFileProviderError.noSuchItem.rawValue)
    }
    #expect(await backend.mutationCalls.isEmpty)
}

@Test
func fileProviderModifyFailOnConflictRejectsStaleBaseVersionBeforeMutation() async throws {
    let backend = ExtensionBackend()
    await backend.setItem(ProviderItem(
        id: "file-1",
        parentID: nil,
        filename: "Doc.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write, .rename]
    ))
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let contents = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("new".utf8).write(to: contents)
    let template = WesomeFileProviderItem(item: ProviderItem(
        id: "file-1",
        parentID: nil,
        filename: "Doc.txt",
        kind: .file,
        size: 3,
        contentVersion: Data("server-content".utf8),
        metadataVersion: Data("server-metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read, .write, .rename]
    ))
    let staleVersion = NSFileProviderItemVersion(
        contentVersion: Data("old-content".utf8),
        metadataVersion: Data("server-metadata".utf8)
    )

    do {
        _ = try await modifyItem(
            template,
            baseVersion: staleVersion,
            changedFields: [.contents],
            contents: contents,
            options: NSFileProviderModifyItemOptions(rawValue: 1 << 1),
            from: extensionInstance
        )
        Issue.record("Expected stale base version to fail before mutation")
    } catch let error as NSError {
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == -2015)
    }
    #expect(await backend.mutationCalls.isEmpty)
}

@Test
func fileProviderEnumeratorResolvesCachedFolderPathBeforeEnumerating() async throws {
    let backend = ExtensionBackend()
    let cache = ExtensionItemCache(storedItems: [
        StoredItem(remote: RemoteItem(id: "folder-fileid", parentID: nil, name: "Projects", path: "/Team/Projects", kind: .folder)),
    ])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend), itemCache: cache)
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let enumerator = try extensionInstance.enumerator(
        for: NSFileProviderItemIdentifier("folder-fileid"),
        request: NSFileProviderRequest()
    )
    let observer = EnumerationObserver()

    enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
    _ = try await observer.result()

    let calls = await backend.enumerateCalls
    #expect(calls.count == 1)
    #expect(calls.first?.parentID == "folder-fileid")
    #expect(calls.first?.remotePath == "/Team/Projects")
}

@Test
func fileProviderWorkingSetEnumerationUsesStoredWorkingSetInsteadOfRoot() async throws {
    let backend = ExtensionBackend()
    let nested = ProviderItem(
        id: "nested-file",
        parentID: "folder",
        filename: "Nested.txt",
        kind: .file,
        size: 6,
        path: "/Folder/Nested.txt",
        contentVersion: Data("content".utf8),
        metadataVersion: Data("metadata".utf8),
        availabilityIntent: .unspecified,
        capabilities: [.read]
    )
    await backend.setWorkingSet([nested])
    let runtime = FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    let extensionInstance = WesomeFileProviderReplicatedExtension(runtime: runtime)
    let enumerator = try extensionInstance.enumerator(
        for: .workingSet,
        request: NSFileProviderRequest()
    )
    let observer = EnumerationObserver()

    enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
    let result = try await observer.result()

    #expect(result.items.map(\.itemIdentifier.rawValue) == ["nested-file"])
    #expect(result.items.map(\.parentItemIdentifier.rawValue) == ["folder"])
    #expect(await backend.enumerateCalls.isEmpty)
}

@Test
func fileProviderTrashContainerEnumeratesAsEmptyWithoutHittingBackend() async throws {
    let backend = ExtensionBackend()
    let extensionInstance = WesomeFileProviderReplicatedExtension(
        runtime: FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    )
    let enumerator = try extensionInstance.enumerator(for: .trashContainer, request: NSFileProviderRequest())
    let observer = EnumerationObserver()

    enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
    let result = try await observer.result()

    #expect(result.items.isEmpty)
    #expect(result.nextPage == nil)
    #expect(await backend.enumerateCalls.isEmpty)
}

@Test
func fileProviderCreatePackageCreatesRemoteFolderAndUploadsContents() async throws {
    let backend = ExtensionBackend()
    let extensionInstance = WesomeFileProviderReplicatedExtension(
        runtime: FileProviderExtensionRuntime(adapter: FileProviderAdapter(backend: backend))
    )
    let package = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).rtfd")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("rtf".utf8).write(to: package.appending(path: "TXT.rtf"))
    defer { try? FileManager.default.removeItem(at: package) }
    let template = PackageTemplateItem(filename: "Notes.rtfd")

    let filename = try await createItem(template, contents: package, from: extensionInstance)

    #expect(filename == "Notes.rtfd")
    #expect(await backend.mutationCalls == [
        "createFolder:Notes.rtfd:/:nil",
        "createFile:TXT.rtf:/Notes.rtfd:created-folder:3",
    ])
}

@Test
func fileProviderEnumeratorInvalidationCancelsInFlightEnumeration() async throws {
    let backend = ExtensionBackend()
    await backend.blockEnumerationUntilCancelled()
    let enumerator = WesomeFileProviderEnumerator(adapter: FileProviderAdapter(backend: backend), container: .root)
    let observer = EnumerationObserver()

    enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
    try await waitUntil { await backend.enumerationStarted }

    enumerator.invalidate()

    do {
        _ = try await observer.result()
        Issue.record("Expected invalidated enumeration to report an error")
    } catch let error as NSError {
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSUserCancelledError)
    }
}

private struct ItemSnapshot: Sendable {
    var identifier: String
    var parentIdentifier: String
    var filename: String
    var contentTypeIdentifier: String
}

private final class FetchCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Error>?
    private var completed: Result<URL?, Error>?

    func complete(url: URL?, item _: NSFileProviderItem?, error: Error?) {
        lock.lock()
        let result: Result<URL?, Error> = if let error {
            .failure(error)
        } else {
            .success(url)
        }
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            completed = result
            lock.unlock()
        }
    }

    func result() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completed {
                self.completed = nil
                lock.unlock()
                continuation.resume(with: completed)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private func itemSnapshot(
    for identifier: NSFileProviderItemIdentifier,
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> ItemSnapshot? {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.item(for: identifier, request: NSFileProviderRequest()) { item, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                let snapshot = item.map {
                    ItemSnapshot(
                        identifier: $0.itemIdentifier.rawValue,
                        parentIdentifier: $0.parentItemIdentifier.rawValue,
                        filename: $0.filename,
                        contentTypeIdentifier: $0.contentType?.identifier ?? ""
                    )
                }
                continuation.resume(returning: snapshot)
            }
        }
    }
}

private func fetchContents(
    for identifier: String,
    version: NSFileProviderItemVersion? = nil,
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> URL? {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.fetchContents(
            for: NSFileProviderItemIdentifier(identifier),
            version: version,
            request: NSFileProviderRequest()
        ) { url, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: url)
            }
        }
    }
}

private struct PartialContentSnapshot: Sendable {
    var url: URL?
    var itemIdentifier: String?
    var range: NSRange
    var flags: NSFileProviderMaterializationFlags
}

private func fetchPartialContents(
    for identifier: String,
    version: NSFileProviderItemVersion,
    range: NSRange,
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> PartialContentSnapshot {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.fetchPartialContents(
            for: NSFileProviderItemIdentifier(identifier),
            version: version,
            request: NSFileProviderRequest(),
            minimalRange: range,
            aligningTo: 1,
            options: []
        ) { url, item, retrievedRange, flags, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: PartialContentSnapshot(url: url, itemIdentifier: item?.itemIdentifier.rawValue, range: retrievedRange, flags: flags))
            }
        }
    }
}

private func fetchIncrementalContents(
    for identifier: String,
    version: NSFileProviderItemVersion?,
    existingContents: URL,
    existingVersion: NSFileProviderItemVersion,
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> URL? {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.fetchContents(
            for: NSFileProviderItemIdentifier(identifier),
            version: version,
            usingExistingContentsAt: existingContents,
            existingVersion: existingVersion,
            request: NSFileProviderRequest()
        ) { url, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: url)
            }
        }
    }
}

private func createItem(
    _ item: NSFileProviderItem,
    contents: URL?,
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.createItem(
            basedOn: item,
            fields: [.filename],
            contents: contents,
            request: NSFileProviderRequest()
        ) { item, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: item?.filename)
            }
        }
    }
}

private func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion: NSFileProviderItemVersion = NSFileProviderItemVersion(contentVersion: Data(), metadataVersion: Data()),
    changedFields: NSFileProviderItemFields,
    contents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
        _ = extensionInstance.modifyItem(
            item,
            baseVersion: baseVersion,
            changedFields: changedFields,
            contents: contents,
            options: options,
            request: NSFileProviderRequest()
        ) { item, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: item?.filename)
            }
        }
    }
}

private func deleteItem(
    _ identifier: String,
    version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    from extensionInstance: WesomeFileProviderReplicatedExtension
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        _ = extensionInstance.deleteItem(
            identifier: NSFileProviderItemIdentifier(identifier),
            baseVersion: version,
            options: options,
            request: NSFileProviderRequest()
        ) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

private func expectNoSuchItem(_ operation: () async throws -> Void) async {
    await expectFileProviderError(.noSuchItem, operation)
}

private func expectFileProviderError(
    _ expected: NSFileProviderError.Code,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected File Provider error \(expected.rawValue)")
    } catch let error as NSError {
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == expected.rawValue)
    } catch {
        Issue.record("Expected File Provider error \(expected.rawValue), got \(error)")
    }
}

private final class EnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    struct Result {
        var items: [NSFileProviderItem]
        var nextPage: NSFileProviderPage?
    }

    private let lock = NSLock()
    private var items: [NSFileProviderItem] = []
    private var continuation: CheckedContinuation<Result, Error>?
    private var completed: Result?
    private var completedError: Error?

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock()
        items += updatedItems
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        let result = Result(items: items, nextPage: nextPage)
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            completed = result
            lock.unlock()
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            completedError = error
            lock.unlock()
        }
    }

    func result() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(returning: completed)
            } else if let completedError {
                lock.unlock()
                continuation.resume(throwing: completedError)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

@available(macOS 26.0, *)
private final class SearchObserver: NSObject, NSFileProviderSearchEnumerationObserver, @unchecked Sendable {
    struct Result {
        var items: [NSFileProviderSearchResult]
        var nextPage: NSFileProviderPage?
    }

    private let lock = NSLock()
    private var items: [NSFileProviderSearchResult] = []
    private var continuation: CheckedContinuation<Result, Error>?
    private var completed: Result?
    private var completedError: Error?
    var maximumNumberOfResultsPerPage: Int { 20 }

    func didEnumerate(_ searchResults: [NSFileProviderSearchResult]) {
        lock.lock()
        items += searchResults
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        let result = Result(items: items, nextPage: nextPage)
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            completed = result
            lock.unlock()
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            completedError = error
            lock.unlock()
        }
    }

    func result() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(returning: completed)
            } else if let completedError {
                lock.unlock()
                continuation.resume(throwing: completedError)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private func currentAnchor(from enumerator: WesomeFileProviderEnumerator) async throws -> NSFileProviderSyncAnchor {
    try await withCheckedThrowingContinuation { continuation in
        enumerator.currentSyncAnchor { anchor in
            if let anchor {
                continuation.resume(returning: anchor)
            } else {
                continuation.resume(throwing: WesomeCloudError.unsupported("Missing sync anchor"))
            }
        }
    }
}

private func anchorData(_ anchor: NSFileProviderSyncAnchor) -> Data {
    anchor.rawValue
}

private final class ChangeObserver: NSObject, NSFileProviderChangeObserver, @unchecked Sendable {
    struct Result {
        var updated: [NSFileProviderItem]
        var deleted: [NSFileProviderItemIdentifier]
        var anchor: NSFileProviderSyncAnchor
        var moreComing: Bool
    }

    private let lock = NSLock()
    private var updatedItems: [NSFileProviderItem] = []
    private var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
    private var continuation: CheckedContinuation<Result, Error>?
    private var completed: Result?

    func didUpdate(_ updatedItems: [NSFileProviderItem]) {
        lock.lock()
        self.updatedItems += updatedItems
        lock.unlock()
    }

    func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
        lock.lock()
        self.deletedIdentifiers += deletedItemIdentifiers
        lock.unlock()
    }

    func finishEnumeratingChanges(upTo syncAnchor: NSFileProviderSyncAnchor, moreComing: Bool) {
        lock.lock()
        let result = Result(updated: updatedItems, deleted: deletedIdentifiers, anchor: syncAnchor, moreComing: moreComing)
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            completed = result
            lock.unlock()
        }
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            lock.unlock()
        }
    }

    func result() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completed {
                lock.unlock()
                continuation.resume(returning: completed)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
#endif
