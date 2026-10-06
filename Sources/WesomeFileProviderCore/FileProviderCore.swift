import Foundation
import CryptoKit
import OwnCloudKit
import SyncStore
import WesomeCloudShared

public struct ProviderItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var filename: String
    public var kind: RemoteItemKind
    public var size: Int64?
    public var contentType: String?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var path: String?
    public var contentVersion: Data
    public var metadataVersion: Data
    public var availabilityIntent: AvailabilityIntent
    public var isMaterialized: Bool
    public var isUploaded: Bool
    public var isUploading: Bool
    public var isDownloading: Bool
    public var uploadErrorDescription: String?
    public var downloadErrorDescription: String?
    public var capabilities: Set<ProviderCapability>

    public init(
        id: String,
        parentID: String?,
        filename: String,
        kind: RemoteItemKind,
        size: Int64?,
        contentType: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        path: String? = nil,
        contentVersion: Data,
        metadataVersion: Data,
        availabilityIntent: AvailabilityIntent,
        isMaterialized: Bool = false,
        isUploaded: Bool = true,
        isUploading: Bool = false,
        isDownloading: Bool = false,
        uploadErrorDescription: String? = nil,
        downloadErrorDescription: String? = nil,
        capabilities: Set<ProviderCapability>
    ) {
        self.id = id
        self.parentID = parentID
        self.filename = filename
        self.kind = kind
        self.size = size
        self.contentType = contentType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.path = path
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.availabilityIntent = availabilityIntent
        self.isMaterialized = isMaterialized
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.isDownloading = isDownloading
        self.uploadErrorDescription = uploadErrorDescription
        self.downloadErrorDescription = downloadErrorDescription
        self.capabilities = capabilities
    }

    public init(stored: StoredItem) {
        let remote = stored.remote
        self.id = remote.id
        self.parentID = remote.parentID
        self.filename = remote.name
        self.kind = remote.kind
        self.size = remote.size
        self.contentType = remote.contentType
        self.createdAt = remote.createdAt
        self.modifiedAt = remote.modifiedAt
        self.path = remote.path
        self.contentVersion = Self.versionComponent(remote.etag ?? remote.checksum ?? remote.id)
        self.metadataVersion = Self.versionComponent(Self.metadataFingerprint(remote))
        self.availabilityIntent = stored.availabilityIntent
        self.isMaterialized = stored.materializedURL != nil
        self.isUploaded = true
        self.isUploading = false
        self.isDownloading = false
        self.uploadErrorDescription = nil
        self.downloadErrorDescription = nil
        self.capabilities = Self.capabilities(for: remote)
    }

    public func applying(transfer: TransferRecord?) -> ProviderItem {
        guard let transfer else { return self }
        var item = self
        switch (transfer.direction, transfer.phase) {
        case (.upload, .queued), (.upload, .running), (.upload, .paused):
            item.isUploaded = false
            item.isUploading = transfer.phase == .running
            item.uploadErrorDescription = transfer.phase == .paused ? transfer.lastErrorDescription : nil
        case (.upload, .failed):
            item.isUploaded = false
            item.isUploading = false
            item.uploadErrorDescription = transfer.lastErrorDescription
        case (.upload, .completed):
            item.isUploaded = true
            item.isUploading = false
            item.uploadErrorDescription = nil
        case (.download, .queued), (.download, .running), (.download, .paused):
            item.isDownloading = transfer.phase == .running
            item.downloadErrorDescription = transfer.phase == .paused ? transfer.lastErrorDescription : nil
        case (.download, .failed):
            item.isDownloading = false
            item.downloadErrorDescription = transfer.lastErrorDescription
        case (.download, .completed):
            item.isDownloading = false
            item.downloadErrorDescription = nil
        }
        return item
    }

    private static func versionComponent(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private static func metadataFingerprint(_ item: RemoteItem) -> String {
        [
            capabilities(for: item).map(\.rawValue).sorted().joined(separator: ","),
            item.name,
            item.parentID ?? "",
            item.permissions ?? "",
            String(item.size ?? -1),
            item.contentType ?? "",
            item.createdAt?.timeIntervalSince1970.description ?? "",
            item.modifiedAt?.timeIntervalSince1970.description ?? "",
            item.etag ?? "",
            item.fileID ?? "",
            item.checksum ?? "",
            item.permissions ?? "",
            String(item.quotaUsedBytes ?? -1),
            String(item.quotaAvailableBytes ?? -1),
            item.privateLink?.absoluteString ?? "",
        ].joined(separator: "|")
    }

    private static func capabilities(for item: RemoteItem) -> Set<ProviderCapability> {
        var capabilities: Set<ProviderCapability> = []
        // ownCloud's R flag means sharing, not reading. Listed items are readable;
        // the server still authorizes each listing and download request.
        if item.kind == .folder && !item.name.isFinderPackageName {
            capabilities.insert(.enumerate)
        } else {
            capabilities.insert(.read)
        }
        if item.allowsWriting { capabilities.insert(.write) }
        if item.allowsRenaming { capabilities.insert(.rename) }
        if item.allowsMoving { capabilities.insert(.reparent) }
        if item.allowsDeleting { capabilities.insert(.delete) }
        if item.kind == .folder && !item.name.isFinderPackageName && item.allowsCreatingChildren {
            capabilities.insert(.addChildren)
        }
        return capabilities
    }
}

public enum ProviderCapability: String, Codable, Sendable {
    case read
    case write
    case rename
    case reparent
    case delete
    case enumerate
    case addChildren
}

public struct RemoteChangeSet: Equatable, Sendable {
    public var added: [ProviderItem]
    public var updated: [ProviderItem]
    public var deletedItems: [DeletedProviderItem]

    public var deleted: [String] {
        deletedItems.map(\.id)
    }

    public init(
        added: [ProviderItem] = [],
        updated: [ProviderItem] = [],
        deleted: [String] = [],
        deletedItems: [DeletedProviderItem] = []
    ) {
        self.added = added
        self.updated = updated
        self.deletedItems = deletedItems.isEmpty ? deleted.map { DeletedProviderItem(id: $0) } : deletedItems
    }

    public init(added: [ProviderItem], updated: [ProviderItem], deleted: [String]) {
        self.init(added: added, updated: updated, deleted: deleted, deletedItems: [])
    }
}

public struct DeletedProviderItem: Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var path: String?

    public init(id: String, parentID: String? = nil, path: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.path = path
    }

    public init(stored: StoredItem) {
        self.id = stored.remote.id
        self.parentID = stored.remote.parentID
        self.path = stored.remote.path
    }
}

public struct UploadConfiguration: Equatable, Sendable {
    public var chunkingThreshold: Int64
    public var chunkSize: Int

    public init(chunkingThreshold: Int64 = 100 * 1024 * 1024, chunkSize: Int = 10 * 1024 * 1024) {
        self.chunkingThreshold = chunkingThreshold
        self.chunkSize = chunkSize
    }
}

public struct TransferConfiguration: Equatable, Sendable {
    public var maximumConcurrentTransfers: Int

    public init(maximumConcurrentTransfers: Int = 3) {
        self.maximumConcurrentTransfers = Swift.max(1, maximumConcurrentTransfers)
    }
}

public struct ProviderContentRange: Equatable, Sendable {
    public var offset: Int64
    public var length: Int64

    public init(offset: Int64, length: Int64) {
        self.offset = Swift.max(0, offset)
        self.length = Swift.max(0, length)
    }

    public var endExclusive: Int64 { offset + length }
    public var endInclusive: Int64? { length > 0 ? endExclusive - 1 : nil }
}

public struct PartialProviderContent: Equatable, Sendable {
    public var url: URL
    public var item: ProviderItem
    public var retrievedRange: ProviderContentRange

    public init(url: URL, item: ProviderItem, retrievedRange: ProviderContentRange) {
        self.url = url
        self.item = item
        self.retrievedRange = retrievedRange
    }
}

public struct TransferProgressSummary: Equatable, Sendable {
    public var completedUnitCount: Int64
    public var totalUnitCount: Int64
    public var activeTransferCount: Int

    public init(completedUnitCount: Int64, totalUnitCount: Int64, activeTransferCount: Int) {
        self.completedUnitCount = Swift.max(0, completedUnitCount)
        self.totalUnitCount = Swift.max(0, totalUnitCount)
        self.activeTransferCount = Swift.max(0, activeTransferCount)
    }
}

public struct FileProviderPresentationPolicy: Equatable, Sendable {
    public var showHiddenFiles: Bool
    public var defaultAvailabilityIntent: AvailabilityIntent
    public var ignoredFilenamePatterns: [String]
    public var excludedRemotePaths: [String]

    public init(
        showHiddenFiles: Bool = false,
        defaultAvailabilityIntent: AvailabilityIntent = .onlineOnly,
        ignoredFilenamePatterns: [String] = [],
        excludedRemotePaths: [String] = []
    ) {
        self.showHiddenFiles = showHiddenFiles
        self.defaultAvailabilityIntent = defaultAvailabilityIntent
        self.ignoredFilenamePatterns = ignoredFilenamePatterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.excludedRemotePaths = excludedRemotePaths.normalizedRemotePaths
    }

    public func ignores(filename: String) -> Bool {
        ignoredFilenamePatterns.contains { filename.matchesWildcardPattern($0) }
    }

    public func excludes(remotePath: String) -> Bool {
        let path = remotePath.normalizedRemotePath
        return excludedRemotePaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/")
        }
    }
}

public actor FileProviderCoordinator {
    private let metadataID: UUID
    private let webDAV: WebDAVClient
    private let store: MetadataStore
    private let materializationDirectory: URL
    private let syncPolicy: SyncPolicy
    private let uploadConfiguration: UploadConfiguration
    private let presentationPolicy: FileProviderPresentationPolicy
    private let transferLimiter: TransferLimiter
    private var cancelledItemIDs: Set<String> = []
    private let logger = WesomeLogger(category: "Sync")

    public init(
        account: Account,
        metadataID: UUID? = nil,
        webDAV: WebDAVClient,
        store: MetadataStore,
        materializationDirectory: URL,
        syncPolicy: SyncPolicy = SyncPolicy(),
        uploadConfiguration: UploadConfiguration = UploadConfiguration(),
        presentationPolicy: FileProviderPresentationPolicy = FileProviderPresentationPolicy(),
        transferConfiguration: TransferConfiguration = TransferConfiguration()
    ) {
        self.metadataID = metadataID ?? account.id
        self.webDAV = webDAV
        self.store = store
        self.materializationDirectory = materializationDirectory
        self.syncPolicy = syncPolicy
        self.uploadConfiguration = uploadConfiguration
        self.presentationPolicy = presentationPolicy
        self.transferLimiter = TransferLimiter(limit: transferConfiguration.maximumConcurrentTransfers)
    }

    public func enumerate(parentID: String?, remotePath: String) async throws -> [ProviderItem] {
        do {
            let existingItems = try await store.items(accountID: metadataID)
            let existingIDs = Set(existingItems.map(\.remote.id))
            let fetched = try await webDAV.propfind(path: remotePath, depth: 1)
            let remoteItems = try await reconcileRemoteChildren(
                fetched,
                parentID: parentID,
                remotePath: remotePath,
                existingItems: existingItems
            )
            let sample = fetched.prefix(5).map { "\($0.path)<-\($0.parentID ?? "nil")" }.joined(separator: ", ")
            await logger.info("enumerate scope=\(metadataID) path=\(remotePath) parent=\(parentID ?? "root") fetched=\(fetched.count) children=\(remoteItems.count) sample=[\(sample)]")
            let remoteIDs = Set(remoteItems.map(\.id))
            let cached = try await store.children(accountID: metadataID, parentID: parentID)
            _ = try await removeRemotelyDeleted(cached.filter { !remoteIDs.contains($0.remote.id) })
            try await persistRemoteChanges(remoteItems, existingItems: existingItems)
            try await applyDefaultAvailabilityIntent(to: remoteItems, existingIDs: existingIDs)
        } catch {
            guard error.allowsCachedEnumerationFallback else { throw error }
            let cached = try await store.children(accountID: metadataID, parentID: parentID)
            if cached.isEmpty { throw error }
        }
        let transfers = try await latestTransferByItemID()
        return try await visibleChildren(parentID: parentID).map { stored in
            ProviderItem(stored: stored).applying(transfer: transfers[stored.remote.id])
        }
    }

    public func item(itemID: String) async throws -> ProviderItem? {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            return nil
        }
        guard !presentationPolicy.excludes(remotePath: stored.remote.path) else { return nil }
        return ProviderItem(stored: stored).applying(transfer: try await latestTransfer(for: itemID))
    }

    public func workingSetItems() async throws -> [ProviderItem] {
        let transfers = try await latestTransferByItemID()
        return try await store.items(accountID: metadataID)
            .filter { !presentationPolicy.excludes(remotePath: $0.remote.path) }
            .filter { presentationPolicy.showHiddenFiles || !$0.remote.name.isHiddenFileName }
            .filter { !presentationPolicy.ignores(filename: $0.remote.name) }
            .map { ProviderItem(stored: $0).applying(transfer: transfers[$0.remote.id]) }
    }

    public func fetchContents(itemID: String) async throws -> URL {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        guard stored.remote.kind == .file else {
            throw WesomeCloudError.unsupported("Folders do not have file contents")
        }
        try validateNotExcluded(stored.remote.path)
        try FileManager.default.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
        let destination = materializationDirectory.appending(path: stored.remote.id.sanitizedFilename)
        let partialDestination = destination.appendingPathExtension("part")
        var existingBytes = bytesTransferred(at: partialDestination)
        if let size = stored.remote.size, existingBytes > 0, existingBytes >= size {
            // A leftover as large as the whole file cannot be resumed (the server answers 416).
            try? FileManager.default.removeItem(at: partialDestination)
            existingBytes = 0
        }
        let transferID = UUID()
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: itemID,
                direction: .download,
                phase: .running,
                bytesTransferred: existingBytes,
                totalBytes: stored.remote.size,
                localURL: partialDestination,
                remotePath: stored.remote.path
            ),
            accountID: metadataID
        )
        try await prepareTransfer(itemID: itemID, transferID: transferID, direction: .download, localURL: partialDestination, remotePath: stored.remote.path, totalBytes: stored.remote.size)
        await transferLimiter.acquire()
        defer { Task { await transferLimiter.release() } }
        do {
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .download, localURL: partialDestination, remotePath: stored.remote.path, totalBytes: stored.remote.size)
            // If-Range makes the server send the full file instead of appending bytes of a newer version.
            let response = try await webDAV.downloadRange(
                path: stored.remote.path,
                startingAt: existingBytes,
                ifRange: existingBytes > 0 ? stored.remote.etag : nil
            )
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .download, localURL: partialDestination, remotePath: stored.remote.path, totalBytes: stored.remote.size)
            if existingBytes > 0 && response.statusCode == 206 {
                try validateResumedContentRange(response.contentRange, expectedOffset: existingBytes, expectedTotalBytes: stored.remote.size, remotePath: stored.remote.path)
                let handle = try FileHandle(forWritingTo: partialDestination)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: response.data)
            } else {
                try response.data.write(to: partialDestination, options: [.atomic])
            }
            try verifyDownloadedFile(at: partialDestination, for: stored.remote, responseETag: response.etag)
            let completedBytes = Int64((try? FileManager.default.attributesOfItem(atPath: partialDestination.path)[.size] as? NSNumber)?.int64Value ?? Int64(response.data.count))
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .download,
                    phase: .completed,
                    bytesTransferred: completedBytes,
                    totalBytes: stored.remote.size,
                    localURL: destination,
                    remotePath: stored.remote.path
                ),
                accountID: metadataID
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partialDestination, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failedBytes = bytesTransferred(at: partialDestination)
            if error.invalidatesPartialDownload {
                // Resuming from this .part would fail the same way forever; start over next time.
                try? FileManager.default.removeItem(at: partialDestination)
            }
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .download,
                    phase: .failed,
                    bytesTransferred: failedBytes,
                    totalBytes: stored.remote.size,
                    localURL: partialDestination,
                    remotePath: stored.remote.path,
                    lastErrorDescription: String(describing: error)
                ),
                accountID: metadataID
            )
            throw error
        }
        try await store.setMaterializedURL(destination, accountID: metadataID, itemID: itemID)
        return destination
    }

    public func fetchPartialContents(itemID: String, requestedRange: ProviderContentRange, alignment: Int64) async throws -> PartialProviderContent {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        guard stored.remote.kind == .file else {
            throw WesomeCloudError.unsupported("Folders do not have file contents")
        }
        try validateNotExcluded(stored.remote.path)
        let range = alignedRange(requestedRange, alignment: alignment, fileSize: stored.remote.size)
        guard let end = range.endInclusive else {
            throw WesomeCloudError.unsupported("Partial content range must not be empty")
        }

        try FileManager.default.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
        let destination = materializationDirectory
            .appending(path: "\(stored.remote.id.sanitizedFilename)-\(range.offset)-\(range.length)")
            .appendingPathExtension("partial")
        let transferID = UUID()
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: itemID,
                direction: .download,
                phase: .running,
                bytesTransferred: 0,
                totalBytes: range.length,
                localURL: destination,
                remotePath: stored.remote.path
            ),
            accountID: metadataID
        )
        await transferLimiter.acquire()
        defer { Task { await transferLimiter.release() } }
        do {
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .download, localURL: destination, remotePath: stored.remote.path, totalBytes: range.length)
            let response = try await webDAV.downloadRange(path: stored.remote.path, startingAt: range.offset, endingAt: end)
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .download, localURL: destination, remotePath: stored.remote.path, totalBytes: range.length)
            if response.statusCode == 206 {
                try validatePartialContentRange(response.contentRange, requestedRange: range, expectedTotalBytes: stored.remote.size, remotePath: stored.remote.path)
            }
            guard Int64(response.data.count) == range.length else {
                throw WesomeCloudError.transferIntegrityMismatch("Expected \(range.length) bytes for partial download of \(stored.remote.path), got \(response.data.count)")
            }
            try writeSparsePartialFile(data: response.data, to: destination, offset: range.offset, endExclusive: range.endExclusive)
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .download,
                    phase: .completed,
                    bytesTransferred: Int64(response.data.count),
                    totalBytes: range.length,
                    localURL: destination,
                    remotePath: stored.remote.path
                ),
                accountID: metadataID
            )
            let item = ProviderItem(stored: stored).applying(transfer: try await latestTransfer(for: itemID))
            return PartialProviderContent(url: destination, item: item, retrievedRange: range)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .download,
                    phase: .failed,
                    bytesTransferred: 0,
                    totalBytes: range.length,
                    localURL: destination,
                    remotePath: stored.remote.path,
                    lastErrorDescription: String(describing: error)
                ),
                accountID: metadataID
            )
            throw error
        }
    }

    public func transferProgress(direction: TransferDirection) async throws -> TransferProgressSummary {
        let active = try await store.transfers(accountID: metadataID)
            .filter { $0.direction == direction }
            .filter { [.queued, .running, .paused].contains($0.phase) }
        let completed = active.reduce(Int64(0)) { result, transfer in
            result + Swift.max(0, transfer.bytesTransferred)
        }
        let total = active.reduce(Int64(0)) { result, transfer in
            result + Swift.max(transfer.totalBytes ?? transfer.bytesTransferred, transfer.bytesTransferred)
        }
        return TransferProgressSummary(
            completedUnitCount: completed,
            totalUnitCount: total,
            activeTransferCount: active.count
        )
    }

    public func cancelTransfers(for itemID: String) {
        cancelledItemIDs.insert(itemID)
    }

    public func resumeTransfers(for itemID: String) {
        cancelledItemIDs.remove(itemID)
    }

    @discardableResult
    public func setAvailabilityIntent(_ intent: AvailabilityIntent, itemID: String, includeDescendants: Bool = true) async throws -> [String] {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        var affected = [stored]
        if includeDescendants, stored.remote.kind == .folder {
            affected += try await descendants(of: stored.remote)
        }

        for item in affected {
            try await store.setAvailabilityIntent(intent, accountID: metadataID, itemID: item.remote.id)
            if intent == .onlineOnly {
                try await evictMaterializedContent(for: item)
            }
        }
        return affected.map(\.remote.id)
    }

    @discardableResult
    public func evictMaterializedContentForDiskPressure() async throws -> [String] {
        let candidates = try await store.items(accountID: metadataID)
            .filter { $0.remote.kind == .file && $0.materializedURL != nil && $0.availabilityIntent != .alwaysLocal }
        for item in candidates {
            try await evictMaterializedContent(for: item)
        }
        return candidates.map(\.remote.id)
    }

    public func createFolder(named name: String, parentPath: String, parentID: String?) async throws -> ProviderItem {
        if let parentID {
            let parent = try await requireStoredItem(parentID)
            try validateNotExcluded(parent.remote.path)
            try requirePermission(parent.remote.allowsCreatingChildren, message: "Insufficient ownCloud permissions to create items in \(parent.remote.path)")
        }
        let siblings = try await store.children(accountID: metadataID, parentID: parentID).map(\.remote)
        do {
            try syncPolicy.validateNewName(name, siblings: siblings)
            try validateNotIgnored(name)
        } catch {
            try await recordConflictIfNeeded(error)
            throw error
        }
        let remotePath = parentPath.appendingPathComponent(name)
        try validateNotExcluded(remotePath)
        do {
            try await webDAV.createFolder(path: remotePath)
        } catch {
            try await enqueueRetryableMutationFailure(
                error,
                operation: PendingOperation(kind: .createFolder, itemID: remotePath, sourcePath: parentID, destinationPath: remotePath)
            )
            throw error
        }
        var item = await refreshedRemoteMetadataAfterCreateFolder(
            name: name,
            remotePath: remotePath,
            parentID: parentID
        )
        item.parentID = parentID
        try await store.upsert(accountID: metadataID, items: [item])
        return ProviderItem(stored: StoredItem(remote: item))
    }

    public func createFile(named name: String, contentsAt localURL: URL, parentPath: String, parentID: String?) async throws -> ProviderItem {
        if let parentID {
            let parent = try await requireStoredItem(parentID)
            try validateNotExcluded(parent.remote.path)
            try requirePermission(parent.remote.allowsCreatingChildren, message: "Insufficient ownCloud permissions to create items in \(parent.remote.path)")
        }
        let siblings = try await store.children(accountID: metadataID, parentID: parentID).map(\.remote)
        do {
            try syncPolicy.validateNewName(name, siblings: siblings)
            try validateNotIgnored(name)
        } catch {
            try await recordConflictIfNeeded(error)
            throw error
        }
        let remotePath = parentPath.appendingPathComponent(name)
        try validateNotExcluded(remotePath)
        let data = try Data(contentsOf: localURL)
        let transferID = UUID()
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: remotePath,
                direction: .upload,
                phase: .running,
                bytesTransferred: 0,
                totalBytes: Int64(data.count),
                localURL: localURL,
                remotePath: remotePath
            ),
            accountID: metadataID
        )
        try await prepareTransfer(itemID: remotePath, transferID: transferID, direction: .upload, localURL: localURL, remotePath: remotePath, totalBytes: Int64(data.count), bytesTransferredOverride: 0)
        await transferLimiter.acquire()
        defer { Task { await transferLimiter.release() } }
        do {
            try await checkTransferNotCancelled(itemID: remotePath, transferID: transferID, direction: .upload, localURL: localURL, remotePath: remotePath, totalBytes: Int64(data.count), bytesTransferredOverride: 0)
            if Int64(data.count) >= uploadConfiguration.chunkingThreshold {
                try await webDAV.uploadChunked(
                    data: data,
                    to: remotePath,
                    configuration: ChunkedUploadConfiguration(chunkSize: uploadConfiguration.chunkSize, transferID: transferID.uuidString),
                    progress: { uploadedBytes in
                        try await self.recordRunningTransferProgress(
                            itemID: remotePath,
                            transferID: transferID,
                            direction: .upload,
                            bytesTransferred: uploadedBytes,
                            totalBytes: Int64(data.count),
                            localURL: localURL,
                            remotePath: remotePath
                        )
                        try await self.checkTransferNotCancelled(itemID: remotePath, transferID: transferID, direction: .upload, localURL: localURL, remotePath: remotePath, totalBytes: Int64(data.count), bytesTransferredOverride: uploadedBytes)
                    }
                )
            } else {
                try await webDAV.upload(data: data, to: remotePath)
            }
            try await checkTransferNotCancelled(itemID: remotePath, transferID: transferID, direction: .upload, localURL: localURL, remotePath: remotePath, totalBytes: Int64(data.count), bytesTransferredOverride: Int64(data.count))
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: remotePath,
                    direction: .upload,
                    phase: .completed,
                    bytesTransferred: Int64(data.count),
                    totalBytes: Int64(data.count),
                    localURL: localURL,
                    remotePath: remotePath
                ),
                accountID: metadataID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: remotePath,
                    direction: .upload,
                    phase: .failed,
                    bytesTransferred: 0,
                    totalBytes: Int64(data.count),
                    localURL: localURL,
                    remotePath: remotePath,
                    lastErrorDescription: String(describing: error)
                ),
                accountID: metadataID
            )
            try await enqueueRetryableMutationFailure(
                error,
                operation: PendingOperation(kind: .createFile, itemID: parentID ?? parentPath, sourcePath: localURL.path, destinationPath: remotePath)
            )
            throw error
        }

        var remote = await refreshedRemoteMetadataAfterCreateFile(
            name: name,
            remotePath: remotePath,
            parentID: parentID,
            localURL: localURL,
            size: Int64(data.count)
        )
        remote.parentID = parentID
        try await store.upsert(accountID: metadataID, items: [remote])
        try await store.setMaterializedURL(localURL, accountID: metadataID, itemID: remote.id)
        guard let saved = try await store.item(accountID: metadataID, id: remote.id) else {
            throw WesomeCloudError.missingItem(remote.id)
        }
        return ProviderItem(stored: saved)
    }

    private func refreshedRemoteMetadataAfterCreateFolder(
        name: String,
        remotePath: String,
        parentID: String?
    ) async -> RemoteItem {
        do {
            if var remote = try await webDAV.propfind(path: remotePath, depth: 0).first {
                remote.parentID = parentID
                return remote
            }
        } catch {
            // The folder already exists remotely. Persist enough local metadata and let polling fill in server details.
        }
        return RemoteItem(
            id: remotePath,
            parentID: parentID,
            name: name,
            path: remotePath,
            kind: .folder
        )
    }

    private func refreshedRemoteMetadataAfterCreateFile(
        name: String,
        remotePath: String,
        parentID: String?,
        localURL: URL,
        size: Int64
    ) async -> RemoteItem {
        do {
            if var remote = try await webDAV.propfind(path: remotePath, depth: 0).first {
                remote.parentID = parentID
                return remote
            }
        } catch {
            // The upload has already succeeded. Persist usable local metadata and let the next poll reconcile server details.
        }
        return RemoteItem(
            id: remotePath,
            parentID: parentID,
            name: name,
            path: remotePath,
            kind: .file,
            size: size,
            modifiedAt: (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        )
    }

    public func delete(itemID: String) async throws {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        try validateNotExcluded(stored.remote.path)
        try requirePermission(stored.remote.allowsDeleting, message: "Insufficient ownCloud permissions to delete \(stored.remote.path)")
        do {
            try await webDAV.delete(path: stored.remote.path)
        } catch {
            try await enqueueRetryableMutationFailure(
                error,
                operation: PendingOperation(kind: .delete, itemID: itemID, sourcePath: stored.remote.path)
            )
            throw error
        }
        let affected = stored.remote.kind == .folder
            ? [stored] + (try await descendants(of: stored.remote))
            : [stored]
        for item in affected {
            try removeMaterializedContentIfPresent(for: item)
            try await store.remove(accountID: metadataID, itemID: item.remote.id)
        }
    }

    public func move(itemID: String, to destinationPath: String) async throws -> ProviderItem {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        try validateMovePermissions(for: stored.remote, destinationPath: destinationPath)
        try validateNotExcluded(stored.remote.path)
        let destinationParentPath = destinationPath.parentPath
        let allItems = try await store.items(accountID: metadataID)
        let destinationParentID = destinationParentPath.flatMap { parentPath in
            allItems.first { $0.remote.path == parentPath }?.remote.id ?? parentPath
        }
        let siblings = try await store.children(accountID: metadataID, parentID: destinationParentID).map(\.remote)
        do {
            try syncPolicy.validateMove(item: stored.remote, destinationPath: destinationPath, destinationSiblings: siblings)
            try validateNotIgnored(destinationPath.lastPathComponent)
            try validateNotExcluded(destinationPath)
        } catch {
            try await recordConflictIfNeeded(error)
            throw error
        }
        do {
            try await webDAV.move(from: stored.remote.path, to: destinationPath)
        } catch {
            try await enqueueRetryableMutationFailure(
                error,
                operation: PendingOperation(kind: .move, itemID: itemID, sourcePath: stored.remote.path, destinationPath: destinationPath)
            )
            throw error
        }

        let originalPath = stored.remote.path
        var updated = stored.remote
        updated.parentID = destinationParentID
        updated.name = destinationPath.lastPathComponent
        updated.path = destinationPath

        var changedItems = [updated]
        if stored.remote.kind == .folder {
            changedItems += descendantsMoved(from: originalPath, to: destinationPath, in: allItems)
                .filter { $0.id != itemID }
        }
        try await store.upsert(accountID: metadataID, items: changedItems)
        guard let saved = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        return ProviderItem(stored: saved)
    }

    public func uploadModifiedContents(itemID: String, contentsAt localURL: URL) async throws -> ProviderItem {
        guard let stored = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        guard stored.remote.kind == .file else {
            throw WesomeCloudError.unsupported("Folders cannot be uploaded as file contents")
        }
        try validateNotIgnored(stored.remote.name)
        try validateNotExcluded(stored.remote.path)
        try requirePermission(stored.remote.allowsWriting, message: "Insufficient ownCloud permissions to upload \(stored.remote.path)")
        let latestRemote: RemoteItem?
        do {
            latestRemote = try await webDAV.propfind(path: stored.remote.path, depth: 0).first
        } catch WesomeCloudError.httpFailure(let failure) where failure.kind == .notFound {
            latestRemote = nil
        }
        do {
            try syncPolicy.validateUpload(stored: stored.remote, latestRemote: latestRemote)
        } catch {
            try await recordConflictIfNeeded(error)
            throw error
        }
        let data = try Data(contentsOf: localURL)
        let transferID = UUID()
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: itemID,
                direction: .upload,
                phase: .running,
                bytesTransferred: 0,
                totalBytes: Int64(data.count),
                localURL: localURL,
                remotePath: stored.remote.path
            ),
            accountID: metadataID
        )
        try await prepareTransfer(itemID: itemID, transferID: transferID, direction: .upload, localURL: localURL, remotePath: stored.remote.path, totalBytes: Int64(data.count), bytesTransferredOverride: 0)
        await transferLimiter.acquire()
        defer { Task { await transferLimiter.release() } }
        do {
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .upload, localURL: localURL, remotePath: stored.remote.path, totalBytes: Int64(data.count), bytesTransferredOverride: 0)
            if Int64(data.count) >= uploadConfiguration.chunkingThreshold {
                try await webDAV.uploadChunked(
                    data: data,
                    to: stored.remote.path,
                    configuration: ChunkedUploadConfiguration(chunkSize: uploadConfiguration.chunkSize, transferID: transferID.uuidString),
                    ifMatch: stored.remote.etag,
                    progress: { uploadedBytes in
                        try await self.recordRunningTransferProgress(
                            itemID: itemID,
                            transferID: transferID,
                            direction: .upload,
                            bytesTransferred: uploadedBytes,
                            totalBytes: Int64(data.count),
                            localURL: localURL,
                            remotePath: stored.remote.path
                        )
                        try await self.checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .upload, localURL: localURL, remotePath: stored.remote.path, totalBytes: Int64(data.count), bytesTransferredOverride: uploadedBytes)
                    }
                )
            } else {
                try await webDAV.upload(data: data, to: stored.remote.path, ifMatch: stored.remote.etag)
            }
            try await checkTransferNotCancelled(itemID: itemID, transferID: transferID, direction: .upload, localURL: localURL, remotePath: stored.remote.path, totalBytes: Int64(data.count), bytesTransferredOverride: Int64(data.count))
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .upload,
                    phase: .completed,
                    bytesTransferred: Int64(data.count),
                    totalBytes: Int64(data.count),
                    localURL: localURL,
                    remotePath: stored.remote.path
                ),
                accountID: metadataID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await store.upsertTransfer(
                TransferRecord(
                    id: transferID,
                    itemID: itemID,
                    direction: .upload,
                    phase: .failed,
                    bytesTransferred: 0,
                    totalBytes: Int64(data.count),
                    localURL: localURL,
                    remotePath: stored.remote.path,
                    lastErrorDescription: String(describing: error)
                ),
                accountID: metadataID
            )
            // If-Match lost the race: the remote changed between the etag check and the PUT/MOVE.
            if case WesomeCloudError.httpFailure(let failure) = error, failure.statusCode == 412 {
                let conflict = syncPolicy.remoteChangedDuringLocalEdit(stored.remote, remotePath: stored.remote.path)
                try await recordConflictIfNeeded(conflict)
                throw conflict
            }
            try await enqueueRetryableMutationFailure(
                error,
                operation: PendingOperation(kind: .upload, itemID: itemID, sourcePath: localURL.path, destinationPath: stored.remote.path)
            )
            throw error
        }
        let values = try localURL.resourceValues(forKeys: [.contentModificationDateKey])
        let updated = await refreshedRemoteMetadataAfterUpload(
            stored: stored.remote,
            size: Int64(data.count),
            modifiedAt: values.contentModificationDate ?? Date()
        )
        try await store.upsert(accountID: metadataID, items: [updated])
        try await store.setMaterializedURL(localURL, accountID: metadataID, itemID: itemID)
        guard let saved = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        return ProviderItem(stored: saved)
    }

    private func refreshedRemoteMetadataAfterUpload(stored: RemoteItem, size: Int64, modifiedAt: Date) async -> RemoteItem {
        do {
            if var remote = try await webDAV.propfind(path: stored.path, depth: 0).first {
                remote.parentID = stored.parentID
                return remote
            }
        } catch {
            // The upload has already succeeded. Keep local metadata usable and let the next poll reconcile details.
        }
        var updated = stored
        updated.size = size
        updated.modifiedAt = modifiedAt
        return updated
    }

    @discardableResult
    public func resolveConflict(
        _ record: ConflictRecord,
        decision: ConflictResolutionDecision,
        resolvedName: String? = nil
    ) async throws -> ProviderItem? {
        switch decision {
        case .keepRemote:
            let item = try await resolveByKeepingRemote(record.conflict)
            try await markConflictResolved(record, decision: decision, resolvedName: resolvedName)
            return item
        case .keepLocal, .retry:
            let item = try await resolveByUploadingLocal(record.conflict, destinationPath: nil)
            try await markConflictResolved(record, decision: decision, resolvedName: resolvedName)
            return item
        case .renameLocal:
            let name = try requireResolvedName(resolvedName)
            let item = try await resolveByUploadingLocal(
                record.conflict,
                destinationPath: try await renamedPath(for: record.conflict, name: name)
            )
            try await markConflictResolved(record, decision: decision, resolvedName: name)
            return item
        }
    }

    public func pollRemoteChanges(parentID: String?, remotePath: String) async throws -> RemoteChangeSet {
        if let syncToken = try await store.syncCursor(accountID: metadataID, remotePath: remotePath) {
            do {
                return try await pollRemoteChangesWithSyncCollection(remotePath: remotePath, syncToken: syncToken)
            } catch WesomeCloudError.httpFailure(let failure) where Self.shouldFallbackFromSyncCollection(statusCode: failure.statusCode) {
                try await store.setSyncCursor(nil, accountID: metadataID, remotePath: remotePath)
            }
        }

        let existingItems = try await store.items(accountID: metadataID)
        let existingIDs = Set(existingItems.map(\.remote.id))
        let cached = try await store.children(accountID: metadataID, parentID: parentID)
        let cachedByID = Dictionary(cached.map { ($0.remote.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fetched = try await webDAV.propfind(path: remotePath, depth: 1)
        let remoteItems = try await reconcileRemoteChildren(
            fetched,
            parentID: parentID,
            remotePath: remotePath,
            existingItems: existingItems
        )
        let remoteIDs = Set(remoteItems.map(\.id))
        let sample = fetched.prefix(5).map { "\($0.path)<-\($0.parentID ?? "nil")" }.joined(separator: ", ")
        await logger.info("poll scope=\(metadataID) path=\(remotePath) parent=\(parentID ?? "root") fetched=\(fetched.count) children=\(remoteItems.count) sample=[\(sample)]")

        let deletedRoots = cached
            .filter { !remoteIDs.contains($0.remote.id) }
        let addedRemote = remoteItems
            .filter { cachedByID[$0.id] == nil }
        let updatedRemote = remoteItems
            .filter { remote in
                guard let cached = cachedByID[remote.id] else { return false }
                return cached.remote != remote
            }

        let deletedItemsByID = try await removeRemotelyDeleted(deletedRoots)
        try await persistRemoteChanges(addedRemote + updatedRemote, existingItems: existingItems)
        try await applyDefaultAvailabilityIntent(to: addedRemote, existingIDs: existingIDs)

        let added = try await providerItems(for: addedRemote.map(\.id))
        let updated = try await providerItems(for: updatedRemote.map(\.id))
        return RemoteChangeSet(added: added, updated: updated, deletedItems: deletedItemsByID.sortedByID)
    }

    private func pollRemoteChangesWithSyncCollection(remotePath: String, syncToken: String) async throws -> RemoteChangeSet {
        let existingItems = try await store.items(accountID: metadataID)
        let existingIDs = Set(existingItems.map(\.remote.id))
        let cachedByID = Dictionary(existingItems.map { ($0.remote.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cachedByPath = Dictionary(existingItems.map { ($0.remote.path.normalizedRemotePath, $0) }, uniquingKeysWith: { first, _ in first })
        let report = try await webDAV.syncCollection(path: remotePath, syncToken: syncToken, depth: 1)

        let changedRemoteItems = try await reconcileRemoteChildren(
            report.items,
            parentID: nil,
            remotePath: remotePath,
            existingItems: existingItems
        )
        let changedIDs = Set(changedRemoteItems.map(\.id))
        let addedRemote = changedRemoteItems.filter { cachedByID[$0.id] == nil }
        let updatedRemote = changedRemoteItems.filter { remote in
            guard let cached = cachedByID[remote.id] else { return false }
            return cached.remote != remote
        }

        // A rename shows up as a 404 for the old path plus the same id at the new path, so only ids
        // missing from the report are gone. A new id at a cached path replaced the old item.
        let deletedRoots = (report.deletedPaths.compactMap { cachedByPath[$0.normalizedRemotePath] }
            + addedRemote.compactMap { cachedByPath[$0.path.normalizedRemotePath] })
            .filter { !changedIDs.contains($0.remote.id) }
        let deletedItemsByID = try await removeRemotelyDeleted(deletedRoots)

        try await persistRemoteChanges(addedRemote + updatedRemote, existingItems: existingItems)
        try await applyDefaultAvailabilityIntent(to: addedRemote, existingIDs: existingIDs)
        if let nextToken = report.syncToken {
            try await store.setSyncCursor(nextToken, accountID: metadataID, remotePath: remotePath)
        }

        let added = try await providerItems(for: addedRemote.map(\.id))
        let updated = try await providerItems(for: updatedRemote.map(\.id))
        return RemoteChangeSet(added: added, updated: updated, deletedItems: deletedItemsByID.sortedByID)
    }

    private static func shouldFallbackFromSyncCollection(statusCode: Int) -> Bool {
        [400, 405, 409, 501].contains(statusCode)
    }

    /// Normalizes a PROPFIND/REPORT listing of `remotePath`: stable parent ids, preserved fallback
    /// identities, and without the folder's own entry (it would otherwise be stored as its own child).
    private func reconcileRemoteChildren(
        _ fetched: [RemoteItem],
        parentID: String?,
        remotePath: String,
        existingItems: [StoredItem]
    ) async throws -> [RemoteItem] {
        reconcileFallbackIdentities(
            try await resolveParentIDs(
                for: fetched,
                requestedParentID: parentID,
                requestedRemotePath: remotePath,
                existingItems: existingItems
            ),
            existingItems: existingItems
        )
        .filter { $0.path.normalizedRemotePath != remotePath.normalizedRemotePath }
    }

    /// Removes remotely deleted items and their descendants. Items with a queued upload or an
    /// unresolved conflict are kept so the local edit surfaces as a `remoteDeletedDuringLocalEdit`
    /// conflict on replay instead of vanishing (removing an item also drops its pending operations).
    private func removeRemotelyDeleted(_ roots: [StoredItem]) async throws -> [String: DeletedProviderItem] {
        let protectedIDs = try await itemIDsWithPendingLocalEdits()
            .union(store.conflicts(accountID: metadataID, state: .pending).map(\.conflict.itemID))
        var deletedItemsByID: [String: DeletedProviderItem] = [:]
        for item in roots {
            let affected = item.remote.kind == .folder
                ? [item] + (try await descendants(of: item.remote))
                : [item]
            for affectedItem in affected where !protectedIDs.contains(affectedItem.remote.id) {
                try removeMaterializedContentIfPresent(for: affectedItem)
                try await store.remove(accountID: metadataID, itemID: affectedItem.remote.id)
                deletedItemsByID[affectedItem.remote.id] = DeletedProviderItem(stored: affectedItem)
            }
        }
        return deletedItemsByID
    }

    /// Upserts remote changes, moving descendants of remotely renamed folders along with them.
    /// While an upload is queued the stored etag stays at the version the local edit was based on,
    /// so replay's conflict check (and If-Match) still detect the remote edit instead of overwriting it.
    private func persistRemoteChanges(_ changed: [RemoteItem], existingItems: [StoredItem]) async throws {
        let existingByID = Dictionary(existingItems.map { ($0.remote.id, $0.remote) }, uniquingKeysWith: { first, _ in first })
        let pendingEditIDs = try await itemIDsWithPendingLocalEdits()
        let changedIDs = Set(changed.map(\.id))
        var items: [RemoteItem] = []
        for var remote in changed {
            guard let existing = existingByID[remote.id] else {
                items.append(remote)
                continue
            }
            if pendingEditIDs.contains(remote.id) {
                remote.etag = existing.etag
            }
            items.append(remote)
            if existing.kind == .folder, existing.path != remote.path {
                items += descendantsMoved(from: existing.path, to: remote.path, in: existingItems)
                    .filter { !changedIDs.contains($0.id) }
            }
        }
        try await store.upsert(accountID: metadataID, items: items)
    }

    private func itemIDsWithPendingLocalEdits() async throws -> Set<String> {
        Set(try await store.pendingOperations(accountID: metadataID).filter { $0.kind == .upload }.map(\.itemID))
    }

    /// Rewrites the paths of everything below `originalPath` to live below `destinationPath`.
    private func descendantsMoved(from originalPath: String, to destinationPath: String, in items: [StoredItem]) -> [RemoteItem] {
        let originalPrefix = originalPath.hasSuffix("/") ? originalPath : originalPath + "/"
        let destinationPrefix = destinationPath.hasSuffix("/") ? destinationPath : destinationPath + "/"
        return items.compactMap { item in
            guard item.remote.path.hasPrefix(originalPrefix) else { return nil }
            var descendant = item.remote
            descendant.path = destinationPrefix + descendant.path.dropFirst(originalPrefix.count)
            return descendant
        }
    }

    private func resolveParentIDs(
        for remoteItems: [RemoteItem],
        requestedParentID: String?,
        requestedRemotePath: String,
        existingItems: [StoredItem]
    ) async throws -> [RemoteItem] {
        let existingByPath = existingItems.map(\.remote).byNormalizedPath
        let fetchedByPath = remoteItems.byNormalizedPath
        let requestedPath = requestedRemotePath.normalizedRemotePath

        return remoteItems.map { item in
            var resolved = item
            let itemPath = item.path.normalizedRemotePath
            guard itemPath != requestedPath else { return resolved }
            guard let parentPath = itemPath.parentPath else {
                resolved.parentID = nil
                return resolved
            }
            if parentPath == requestedPath {
                resolved.parentID = requestedParentID
            } else if let parent = existingByPath[parentPath] ?? fetchedByPath[parentPath] {
                resolved.parentID = parent.id
            } else if item.parentID?.hasPrefix("/") == true,
                      let parent = existingByPath[item.parentID!.normalizedRemotePath] {
                resolved.parentID = parent.id
            }
            return resolved
        }
    }

    private func reconcileFallbackIdentities(_ remoteItems: [RemoteItem], existingItems: [StoredItem]) -> [RemoteItem] {
        let existingIDs = Set(existingItems.map(\.remote.id))
        let existingByPath = existingItems.map(\.remote).byNormalizedPath
        let fallbackIDsByServerID = Dictionary(remoteItems.compactMap { item -> (String, String)? in
            guard existingIDs.contains(item.id) == false,
                  let fallback = existingByPath[item.path.normalizedRemotePath],
                  fallback.fileID?.isEmpty != false
            else { return nil }
            return (item.id, fallback.id)
        }, uniquingKeysWith: { first, _ in first })

        return remoteItems.map { item in
            var reconciled = item
            if let fallbackID = fallbackIDsByServerID[item.id] {
                reconciled.id = fallbackID
            }
            if let parentID = reconciled.parentID, let fallbackParentID = fallbackIDsByServerID[parentID] {
                reconciled.parentID = fallbackParentID
            }
            return reconciled
        }
    }

    private func providerItems(for itemIDs: [String]) async throws -> [ProviderItem] {
        var result: [ProviderItem] = []
        for itemID in itemIDs {
            if let stored = try await store.item(accountID: metadataID, id: itemID) {
                guard presentationPolicy.showHiddenFiles || !stored.remote.name.isHiddenFileName else { continue }
                guard !presentationPolicy.ignores(filename: stored.remote.name) else { continue }
                guard !presentationPolicy.excludes(remotePath: stored.remote.path) else { continue }
                result.append(ProviderItem(stored: stored))
            }
        }
        return result
    }

    private func requireStoredItem(_ itemID: String) async throws -> StoredItem {
        guard let item = try await store.item(accountID: metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        return item
    }

    private func visibleChildren(parentID: String?) async throws -> [StoredItem] {
        let children = try await store.children(accountID: metadataID, parentID: parentID)
        return children
            .filter { presentationPolicy.showHiddenFiles || !$0.remote.name.isHiddenFileName }
            .filter { !presentationPolicy.ignores(filename: $0.remote.name) }
            .filter { !presentationPolicy.excludes(remotePath: $0.remote.path) }
    }

    private func applyDefaultAvailabilityIntent(to remoteItems: [RemoteItem], existingIDs: Set<String>) async throws {
        guard presentationPolicy.defaultAvailabilityIntent != .unspecified else { return }
        for item in remoteItems where !existingIDs.contains(item.id) {
            try await store.setAvailabilityIntent(presentationPolicy.defaultAvailabilityIntent, accountID: metadataID, itemID: item.id)
        }
    }

    private func requirePermission(_ allowed: Bool, message: String) throws {
        guard allowed else {
            throw WesomeCloudError.unsupported(message)
        }
    }

    private func validateMovePermissions(for item: RemoteItem, destinationPath: String) throws {
        if item.name != destinationPath.lastPathComponent {
            try requirePermission(item.allowsRenaming, message: "Insufficient ownCloud permissions to rename \(item.path)")
        }
        if item.path.parentPath != destinationPath.parentPath {
            try requirePermission(item.allowsMoving, message: "Insufficient ownCloud permissions to move \(item.path)")
        }
    }

    private func validateNotIgnored(_ name: String) throws {
        if presentationPolicy.ignores(filename: name) {
            throw WesomeCloudError.invalidFilename(name, .ignoredPattern)
        }
    }

    private func validateNotExcluded(_ remotePath: String) throws {
        if presentationPolicy.excludes(remotePath: remotePath) {
            throw WesomeCloudError.unsupported("Path \(remotePath) is excluded from selective sync")
        }
    }

    private func recordConflictIfNeeded(_ error: Error) async throws {
        guard case WesomeCloudError.conflict(let conflict) = error else { return }
        let existing = try await store.conflicts(accountID: metadataID, state: .pending)
        guard !existing.contains(where: { $0.conflict.matches(conflict) }) else { return }
        try await store.recordConflict(ConflictRecord(conflict: conflict), accountID: metadataID)
    }

    private func enqueueRetryableMutationFailure(_ error: Error, operation: PendingOperation) async throws {
        guard error.allowsCachedEnumerationFallback else { return }
        var failedOperation = operation
        failedOperation.lastErrorDescription = String(describing: error)
        let pending = try await store.pendingOperations(accountID: metadataID)
        if var existing = pending.first(where: { $0.matchesMutation(failedOperation) }) {
            existing.lastErrorDescription = failedOperation.lastErrorDescription
            existing.nextAttemptAt = min(existing.nextAttemptAt, Date())
            try await store.updatePendingOperation(existing, accountID: metadataID)
        } else {
            try await store.enqueue(failedOperation, accountID: metadataID)
        }
    }

    private func resolveByKeepingRemote(_ conflict: SyncConflict) async throws -> ProviderItem? {
        let stored = try await requireStoredItem(conflict.itemID)
        do {
            var remote = try await webDAV.propfind(path: conflict.remotePath ?? stored.remote.path, depth: 0).first
                ?? stored.remote
            remote.parentID = stored.remote.parentID
            try removeMaterializedContentIfPresent(for: stored)
            try await store.upsert(accountID: metadataID, items: [remote])
            try await store.setMaterializedURL(nil, accountID: metadataID, itemID: remote.id)
            guard let saved = try await store.item(accountID: metadataID, id: remote.id) else {
                throw WesomeCloudError.missingItem(remote.id)
            }
            return ProviderItem(stored: saved)
        } catch WesomeCloudError.httpFailure(let failure) where failure.kind == .notFound {
            try removeMaterializedContentIfPresent(for: stored)
            try await store.remove(accountID: metadataID, itemID: stored.remote.id)
            return nil
        }
    }

    private func resolveByUploadingLocal(_ conflict: SyncConflict, destinationPath: String?) async throws -> ProviderItem {
        let stored = try await requireStoredItem(conflict.itemID)
        guard let localURL = stored.materializedURL else {
            throw WesomeCloudError.missingItem("materialized content for \(conflict.itemID)")
        }
        let data = try Data(contentsOf: localURL)
        let remotePath = destinationPath ?? conflict.remotePath ?? stored.remote.path
        try await webDAV.upload(data: data, to: remotePath)
        let parentPath = remotePath.parentPath
        let allItems = try await store.items(accountID: metadataID)
        let parentID = parentPath.flatMap { parentPath in
            allItems.first { $0.remote.path == parentPath }?.remote.id ?? parentPath
        }
        var remote = await refreshedRemoteMetadataAfterConflictUpload(
            stored: stored.remote,
            remotePath: remotePath,
            parentID: parentID,
            localURL: localURL,
            size: Int64(data.count)
        )
        remote.parentID = parentID
        try await store.upsert(accountID: metadataID, items: [remote])
        try await store.setMaterializedURL(localURL, accountID: metadataID, itemID: remote.id)
        guard let saved = try await store.item(accountID: metadataID, id: remote.id) else {
            throw WesomeCloudError.missingItem(remote.id)
        }
        return ProviderItem(stored: saved)
    }

    private func refreshedRemoteMetadataAfterConflictUpload(
        stored: RemoteItem,
        remotePath: String,
        parentID: String?,
        localURL: URL,
        size: Int64
    ) async -> RemoteItem {
        do {
            if var remote = try await webDAV.propfind(path: remotePath, depth: 0).first {
                remote.parentID = parentID
                return remote
            }
        } catch {
            // The conflict-resolution upload has already succeeded. Persist enough metadata and let polling reconcile details.
        }
        if stored.path.normalizedRemotePath == remotePath.normalizedRemotePath {
            var updated = stored
            updated.parentID = parentID
            updated.size = size
            updated.modifiedAt = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return updated
        }
        return RemoteItem(
            id: remotePath,
            parentID: parentID,
            name: remotePath.lastPathComponent,
            path: remotePath,
            kind: .file,
            size: size,
            modifiedAt: (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        )
    }

    private func renamedPath(for conflict: SyncConflict, name: String) async throws -> String {
        let stored = try await requireStoredItem(conflict.itemID)
        let basePath = conflict.remotePath ?? stored.remote.path
        let parentPath = basePath.parentPath ?? "/"
        let destinationPath = parentPath.appendingPathComponent(name)
        let allItems = try await store.items(accountID: metadataID)
        let parentID = allItems.first { $0.remote.path == parentPath }?.remote.id
        let siblings = try await store.children(accountID: metadataID, parentID: parentID).map(\.remote)
        try syncPolicy.validateNewName(name, siblings: siblings, excluding: conflict.itemID)
        return destinationPath
    }

    private func requireResolvedName(_ name: String?) throws -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw WesomeCloudError.invalidFilename("", .empty)
        }
        return name
    }

    private func markConflictResolved(
        _ record: ConflictRecord,
        decision: ConflictResolutionDecision,
        resolvedName: String?
    ) async throws {
        try await store.resolveConflict(
            id: record.id,
            accountID: metadataID,
            decision: decision,
            resolvedName: resolvedName,
            resolvedAt: Date()
        )
    }

    private func descendants(of remote: RemoteItem) async throws -> [StoredItem] {
        let allItems = try await store.items(accountID: metadataID)
        let basePath = remote.path.hasSuffix("/") ? remote.path : remote.path + "/"
        return allItems.filter { item in
            item.remote.id != remote.id && item.remote.path.hasPrefix(basePath)
        }
    }

    private func evictMaterializedContent(for item: StoredItem) async throws {
        guard let url = item.materializedURL else {
            try await store.setMaterializedURL(nil, accountID: metadataID, itemID: item.remote.id)
            return
        }
        try removeMaterializedFiles(at: url)
        try await store.setMaterializedURL(nil, accountID: metadataID, itemID: item.remote.id)
    }

    private func removeMaterializedContentIfPresent(for item: StoredItem) throws {
        guard let url = item.materializedURL else { return }
        try removeMaterializedFiles(at: url)
    }

    private func removeMaterializedFiles(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let partialURL = url.appendingPathExtension("part")
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try FileManager.default.removeItem(at: partialURL)
        }
    }

    private func prepareTransfer(
        itemID: String,
        transferID: UUID,
        direction: TransferDirection,
        localURL: URL?,
        remotePath: String,
        totalBytes: Int64?,
        bytesTransferredOverride: Int64? = nil
    ) async throws {
        if cancelledItemIDs.contains(itemID) {
            try await recordPausedTransfer(
                itemID: itemID,
                transferID: transferID,
                direction: direction,
                localURL: localURL,
                remotePath: remotePath,
                totalBytes: totalBytes,
                bytesTransferredOverride: bytesTransferredOverride
            )
            throw CancellationError()
        }
    }

    private func checkTransferNotCancelled(
        itemID: String,
        transferID: UUID,
        direction: TransferDirection,
        localURL: URL?,
        remotePath: String,
        totalBytes: Int64?,
        bytesTransferredOverride: Int64? = nil
    ) async throws {
        try await prepareTransfer(
            itemID: itemID,
            transferID: transferID,
            direction: direction,
            localURL: localURL,
            remotePath: remotePath,
            totalBytes: totalBytes,
            bytesTransferredOverride: bytesTransferredOverride
        )
    }

    private func recordPausedTransfer(
        itemID: String,
        transferID: UUID,
        direction: TransferDirection,
        localURL: URL?,
        remotePath: String,
        totalBytes: Int64?,
        bytesTransferredOverride: Int64? = nil
    ) async throws {
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: itemID,
                direction: direction,
                phase: .paused,
                bytesTransferred: bytesTransferredOverride ?? bytesTransferred(at: localURL),
                totalBytes: totalBytes,
                localURL: localURL,
                remotePath: remotePath,
                lastErrorDescription: "Transfer cancelled"
            ),
            accountID: metadataID
        )
    }

    private func recordRunningTransferProgress(
        itemID: String,
        transferID: UUID,
        direction: TransferDirection,
        bytesTransferred: Int64,
        totalBytes: Int64?,
        localURL: URL?,
        remotePath: String
    ) async throws {
        try await store.upsertTransfer(
            TransferRecord(
                id: transferID,
                itemID: itemID,
                direction: direction,
                phase: .running,
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes,
                localURL: localURL,
                remotePath: remotePath
            ),
            accountID: metadataID
        )
    }

    private func latestTransfer(for itemID: String) async throws -> TransferRecord? {
        try await latestTransferByItemID()[itemID]
    }

    private func latestTransferByItemID() async throws -> [String: TransferRecord] {
        let transfers = try await store.transfers(accountID: metadataID)
        return transfers.reduce(into: [String: TransferRecord]()) { result, transfer in
            guard let existing = result[transfer.itemID] else {
                result[transfer.itemID] = transfer
                return
            }
            if transfer.updatedAt > existing.updatedAt {
                result[transfer.itemID] = transfer
            }
        }
    }

    private func bytesTransferred(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        return Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private func verifyDownloadedFile(at url: URL, for remote: RemoteItem, responseETag: String?) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value
        if let expectedSize = remote.size, actualSize != expectedSize {
            throw WesomeCloudError.transferIntegrityMismatch("Expected \(expectedSize) bytes for \(remote.path), got \(actualSize ?? -1)")
        }
        if let expectedETag = remote.etag?.normalizedETag, let responseETag = responseETag?.normalizedETag, expectedETag != responseETag {
            throw WesomeCloudError.transferIntegrityMismatch("ETag mismatch for \(remote.path)")
        }

        let supported = ["SHA256", "SHA1", "MD5"]
        guard let checksum = remote.checksum?.normalizedChecksums.first(where: { supported.contains($0.algorithm) }) else { return }
        let data = try Data(contentsOf: url)
        let actualDigest = switch checksum.algorithm {
        case "SHA256": SHA256.hash(data: data).hexString
        case "SHA1": Insecure.SHA1.hash(data: data).hexString
        default: Insecure.MD5.hash(data: data).hexString
        }

        if actualDigest != checksum.digest {
            throw WesomeCloudError.transferIntegrityMismatch("Checksum mismatch for \(remote.path)")
        }
    }

    private func validateResumedContentRange(_ contentRange: String?, expectedOffset: Int64, expectedTotalBytes: Int64?, remotePath: String) throws {
        guard let contentRange = contentRange?.parsedHTTPContentRange else {
            throw WesomeCloudError.transferIntegrityMismatch("Missing Content-Range for resumed download of \(remotePath)")
        }
        guard contentRange.start == expectedOffset else {
            throw WesomeCloudError.transferIntegrityMismatch("Expected resumed download of \(remotePath) to start at byte \(expectedOffset), got \(contentRange.start)")
        }
        if let expectedTotalBytes, let total = contentRange.total, total != expectedTotalBytes {
            throw WesomeCloudError.transferIntegrityMismatch("Expected \(expectedTotalBytes) total bytes for resumed download of \(remotePath), got \(total)")
        }
    }

    private func validatePartialContentRange(_ contentRange: String?, requestedRange: ProviderContentRange, expectedTotalBytes: Int64?, remotePath: String) throws {
        guard let contentRange = contentRange?.parsedHTTPContentRange else {
            throw WesomeCloudError.transferIntegrityMismatch("Missing Content-Range for partial download of \(remotePath)")
        }
        guard contentRange.start == requestedRange.offset, contentRange.end == requestedRange.endInclusive else {
            throw WesomeCloudError.transferIntegrityMismatch("Expected partial download of \(remotePath) to return bytes \(requestedRange.offset)-\(requestedRange.endInclusive ?? requestedRange.offset), got \(contentRange.start)-\(contentRange.end)")
        }
        if let expectedTotalBytes, let total = contentRange.total, total != expectedTotalBytes {
            throw WesomeCloudError.transferIntegrityMismatch("Expected \(expectedTotalBytes) total bytes for partial download of \(remotePath), got \(total)")
        }
    }

    private func alignedRange(_ requestedRange: ProviderContentRange, alignment: Int64, fileSize: Int64?) -> ProviderContentRange {
        guard alignment > 1 else {
            return clampRange(requestedRange, fileSize: fileSize)
        }
        let start = (requestedRange.offset / alignment) * alignment
        let end = ((requestedRange.endExclusive + alignment - 1) / alignment) * alignment
        return clampRange(ProviderContentRange(offset: start, length: end - start), fileSize: fileSize)
    }

    private func clampRange(_ range: ProviderContentRange, fileSize: Int64?) -> ProviderContentRange {
        guard let fileSize else { return range }
        let offset = Swift.min(range.offset, fileSize)
        let end = Swift.min(range.endExclusive, fileSize)
        return ProviderContentRange(offset: offset, length: Swift.max(0, end - offset))
    }

    private func writeSparsePartialFile(data: Data, to url: URL, offset: Int64, endExclusive: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(endExclusive))
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }
}

private struct NormalizedChecksum {
    var algorithm: String
    var digest: String
}

private struct HTTPContentRange {
    var start: Int64
    var end: Int64
    var total: Int64?
}

private extension SyncConflict {
    func matches(_ other: SyncConflict) -> Bool {
        kind == other.kind
            && itemID == other.itemID
            && localPath == other.localPath
            && remotePath == other.remotePath
            && message == other.message
    }
}

private extension String {
    var normalizedRemotePath: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        var path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    var normalizedETag: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// ownCloud 10 can list several checksums in one value, e.g. "SHA1:abc MD5:def ADLER32:123".
    var normalizedChecksums: [NormalizedChecksum] {
        split(whereSeparator: \.isWhitespace).compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return NormalizedChecksum(algorithm: parts[0].uppercased(), digest: parts[1].lowercased())
        }
    }

    var parsedHTTPContentRange: HTTPContentRange? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let rangeAndTotal = trimmed.dropFirst(6).split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
        return HTTPContentRange(start: start, end: end, total: total)
    }
}

private extension Array where Element == String {
    var normalizedRemotePaths: [String] {
        var seen: Set<String> = []
        return compactMap { raw in
            let path = raw.normalizedRemotePath
            guard path != "/" else { return nil }
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

private extension Array where Element == RemoteItem {
    /// Keeps the first item per path; the store can briefly hold two ids for one path
    /// (remote delete and re-upload) until the stale one is pruned.
    var byNormalizedPath: [String: RemoteItem] {
        Dictionary(map { ($0.path.normalizedRemotePath, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private extension RemoteItem {
    var allowsWriting: Bool {
        guard let permissions, !permissions.isEmpty else { return true }
        return permissions.contains("W")
    }

    var allowsDeleting: Bool {
        guard let permissions, !permissions.isEmpty else { return true }
        return permissions.contains("D")
    }

    var allowsRenaming: Bool {
        guard let permissions, !permissions.isEmpty else { return true }
        return permissions.contains("N")
    }

    var allowsMoving: Bool {
        guard let permissions, !permissions.isEmpty else { return true }
        return permissions.contains("V")
    }

    var allowsCreatingChildren: Bool {
        guard let permissions, !permissions.isEmpty else { return true }
        return permissions.contains("C")
    }
}

private extension Error {
    var allowsCachedEnumerationFallback: Bool {
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if let error = self as? WesomeCloudError {
            if case .httpFailure(let failure) = error {
                return failure.isRetryable
            }
        }
        return false
    }

    var invalidatesPartialDownload: Bool {
        switch self as? WesomeCloudError {
        case .transferIntegrityMismatch: true
        case .httpFailure(let failure): failure.statusCode == 416
        default: false
        }
    }
}

private extension PendingOperation {
    func matchesMutation(_ other: PendingOperation) -> Bool {
        kind == other.kind &&
            itemID == other.itemID &&
            sourcePath == other.sourcePath &&
            destinationPath == other.destinationPath
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Dictionary where Key == String, Value == DeletedProviderItem {
    var sortedByID: [DeletedProviderItem] {
        values.sorted { $0.id < $1.id }
    }
}

private actor TransferLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = Swift.max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = Swift.max(0, active - 1)
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

private extension String {
    var sanitizedFilename: String {
        replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    var isHiddenFileName: Bool {
        hasPrefix(".") && self != "." && self != ".."
    }

    func matchesWildcardPattern(_ pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return range(of: "^\(escaped)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    var isFinderPackageName: Bool {
        let packageExtensions = ["app", "bundle", "framework", "key", "keynote", "numbers", "pages", "playground", "rtfd"]
        let pathExtension = URL(fileURLWithPath: self).pathExtension.lowercased()
        return !pathExtension.isEmpty && packageExtensions.contains(pathExtension)
    }

    func appendingPathComponent(_ component: String) -> String {
        let base = hasSuffix("/") ? String(dropLast()) : self
        return base + "/" + component
    }

    var parentPath: String? {
        let parts = split(separator: "/", omittingEmptySubsequences: true).dropLast()
        guard !parts.isEmpty else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    var lastPathComponent: String {
        split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? self
    }
}
