import Foundation
import WesomeFileProviderCore
import WesomeCloudShared

#if canImport(FileProvider)
@preconcurrency import FileProvider
import UniformTypeIdentifiers

public final class WesomeFileProviderItem: NSObject, NSFileProviderItem {
    private let item: ProviderItem

    public init(item: ProviderItem) {
        self.item = item
        super.init()
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(item.id)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        if let parentID = item.parentID {
            return NSFileProviderItemIdentifier(parentID)
        }
        return .rootContainer
    }

    public var filename: String {
        item.filename
    }

    public var contentType: UTType {
        if item.kind == .folder {
            return item.filename.fileProviderContentType ?? .folder
        }
        if let contentType = item.contentType.flatMap({ UTType(tag: $0, tagClass: .mimeType, conformingTo: nil) }) {
            return contentType
        }
        return item.filename.fileProviderContentType ?? .data
    }

    public var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = []
        if item.capabilities.contains(.read) { capabilities.insert(.allowsReading) }
        if item.capabilities.contains(.write) { capabilities.insert(.allowsWriting) }
        if item.capabilities.contains(.rename) { capabilities.insert(.allowsRenaming) }
        if item.capabilities.contains(.delete) {
            capabilities.insert(.allowsDeleting)
            capabilities.insert(.allowsTrashing)
        }
        if item.capabilities.contains(.enumerate) { capabilities.insert(.allowsContentEnumerating) }
        if item.capabilities.contains(.addChildren) { capabilities.insert(.allowsAddingSubItems) }
        if item.capabilities.contains(.reparent) { capabilities.insert(.allowsReparenting) }
        return capabilities
    }

    public var documentSize: NSNumber? {
        item.size.map(NSNumber.init(value:))
    }

    public var creationDate: Date? {
        item.createdAt
    }

    public var contentModificationDate: Date? {
        item.modifiedAt
    }

    public var lastUsedDate: Date? {
        item.modifiedAt
    }

    public var isDownloaded: Bool {
        item.isMaterialized
    }

    public var isDownloading: Bool {
        item.isDownloading
    }

    public var downloadingError: (any Error)? {
        item.downloadErrorDescription.map { NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue, userInfo: [NSLocalizedDescriptionKey: $0]) }
    }

    public var isMostRecentVersionDownloaded: Bool {
        item.isMaterialized
    }

    public var isUploaded: Bool {
        item.isUploaded
    }

    public var isUploading: Bool {
        item.isUploading
    }

    public var uploadingError: (any Error)? {
        item.uploadErrorDescription.map { NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue, userInfo: [NSLocalizedDescriptionKey: $0]) }
    }

    public var contentPolicy: NSFileProviderContentPolicy {
        switch item.availabilityIntent {
        case .alwaysLocal:
            return .downloadEagerlyAndKeepDownloaded
        case .inherited:
            return .inherited
        case .onlineOnly, .unspecified:
            return .downloadLazily
        }
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: item.contentVersion, metadataVersion: item.metadataVersion)
    }
}

@available(macOS 26.0, *)
extension WesomeFileProviderItem: NSFileProviderSearchResult {}

@available(macOS 26.0, *)
public final class WesomeFileProviderSearchEnumerator: NSObject, NSFileProviderSearchEnumerator, @unchecked Sendable {
    private let runtimeProvider: @Sendable () async throws -> FileProviderExtensionRuntime
    private let query: String
    private let desiredNumberOfResults: Int
    private let taskRegistry = EnumeratorTaskRegistry()

    public init(
        runtimeProvider: @escaping @Sendable () async throws -> FileProviderExtensionRuntime,
        query: String,
        desiredNumberOfResults: Int
    ) {
        self.runtimeProvider = runtimeProvider
        self.query = query
        self.desiredNumberOfResults = desiredNumberOfResults
        super.init()
    }

    public func invalidate() {
        taskRegistry.cancelAll()
    }

    public func enumerateSearchResults(for observer: NSFileProviderSearchEnumerationObserver, startingAt page: NSFileProviderPage?) {
        let task = Task<Void, Never> {
            do {
                let runtime = try await runtimeProvider()
                let pageSize = min(max(1, desiredNumberOfResults), max(1, observer.maximumNumberOfResultsPerPage))
                let providerPage = try await runtime.adapter.search(
                    query: query,
                    pageToken: page?.providerPageToken,
                    pageSize: pageSize
                )
                await runtime.itemCache.register(providerPage, container: .workingSet)
                observer.didEnumerate(providerPage.items.map(WesomeFileProviderItem.init))
                observer.finishEnumerating(upTo: providerPage.nextPageToken.map(NSFileProviderPage.providerPage))
            } catch {
                observer.finishEnumeratingWithError(error.asFileProviderNSError)
            }
        }
        taskRegistry.insert(task)
    }
}

public final class WesomeFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let runtimeProvider: @Sendable () async throws -> FileProviderExtensionRuntime
    private let container: ProviderContainerReference?
    private let containerIdentifier: String?
    private let anchorState = SyncAnchorState()
    private let taskRegistry = EnumeratorTaskRegistry()
    private let logger = WesomeLogger(category: "FileProvider")

    public init(adapter: FileProviderAdapter, itemCache: ExtensionItemCache? = nil, container: ProviderContainerReference) {
        self.runtimeProvider = { FileProviderExtensionRuntime(adapter: adapter, itemCache: itemCache ?? ExtensionItemCache()) }
        self.container = container
        self.containerIdentifier = nil
        super.init()
    }

    public init(adapter: FileProviderAdapter, itemCache: ExtensionItemCache, containerIdentifier: String) {
        self.runtimeProvider = { FileProviderExtensionRuntime(adapter: adapter, itemCache: itemCache) }
        self.container = nil
        self.containerIdentifier = containerIdentifier
        super.init()
    }

    public init(
        runtimeProvider: @escaping @Sendable () async throws -> FileProviderExtensionRuntime,
        containerIdentifier: String
    ) {
        self.runtimeProvider = runtimeProvider
        self.container = nil
        self.containerIdentifier = containerIdentifier
        super.init()
    }

    public func invalidate() {
        taskRegistry.cancelAll()
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let task = Task<Void, Never> {
            do {
                let runtime = try await runtimeProvider()
                let container = await resolvedContainer(itemCache: runtime.itemCache)
                let providerPage = try await runtime.adapter.enumerate(container: container, pageToken: page.providerPageToken)
                await runtime.itemCache.register(providerPage, container: container)
                observer.didEnumerate(providerPage.items.map(WesomeFileProviderItem.init))
                observer.finishEnumerating(upTo: providerPage.nextPageToken.map(NSFileProviderPage.providerPage))
            } catch {
                await logger.error("enumerateItems failed container=\(containerIdentifier ?? "adapter") error=\(String(describing: error))")
                observer.finishEnumeratingWithError(error.asFileProviderNSError)
            }
        }
        taskRegistry.insert(task)
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let task = Task<Void, Never> {
            do {
                let runtime = try await runtimeProvider()
                let container = await resolvedContainer(itemCache: runtime.itemCache)
                let changes = try await runtime.adapter.changes(in: container)
                await runtime.itemCache.register(ProviderPage(items: changes.added + changes.updated), container: container)
                observer.didUpdate(changes.added.map(WesomeFileProviderItem.init) + changes.updated.map(WesomeFileProviderItem.init))
                observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier($0) })
                observer.finishEnumeratingChanges(upTo: anchorState.advance(), moreComing: false)
            } catch {
                await logger.error("enumerateChanges failed container=\(containerIdentifier ?? "adapter") error=\(String(describing: error))")
                observer.finishEnumeratingWithError(error.asFileProviderNSError)
            }
        }
        taskRegistry.insert(task)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorState.current())
    }

    private func resolvedContainer(itemCache: ExtensionItemCache) async -> ProviderContainerReference {
        if let container { return container }
        guard let containerIdentifier else { return .root }
        if containerIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
            return .root
        }
        if containerIdentifier == NSFileProviderItemIdentifier.workingSet.rawValue {
            return .workingSet
        }
        return await itemCache.containerReference(for: containerIdentifier)
    }
}

/// Trashing is translated into a remote delete (see modifyItem), so nothing ever lives in
/// the trash container. The system still enumerates it and must not see an error.
public final class WesomeFileProviderEmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = Data("empty".utf8) as NSData as NSFileProviderSyncAnchor

    public func invalidate() {}

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt _: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from _: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}

private final class EnumeratorTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func insert(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }
}

private final class SyncAnchorState: @unchecked Sendable {
    private let lock = NSLock()
    private var version = 0

    func current() -> NSFileProviderSyncAnchor {
        lock.lock()
        defer { lock.unlock() }
        return anchor(for: version)
    }

    func advance() -> NSFileProviderSyncAnchor {
        lock.lock()
        defer { lock.unlock() }
        version += 1
        return anchor(for: version)
    }

    private func anchor(for version: Int) -> NSFileProviderSyncAnchor {
        Data("v\(version)".utf8) as NSData as NSFileProviderSyncAnchor
    }
}

extension Error {
    var asFileProviderNSError: NSError {
        if self is CancellationError {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
        if self is KeychainError {
            return .fileProvider(.notAuthenticated, underlying: self)
        }
        guard let cloudError = self as? WesomeCloudError else {
            return (self as NSError).fileProviderCompatible
        }
        switch cloudError {
        case .missingItem:
            return .fileProvider(.noSuchItem)
        case .conflict(let conflict):
            switch conflict.kind {
            case .nameCollision, .caseOnlyRename, .unicodeNormalization:
                return .fileProvider(.filenameCollision)
            case .remoteChangedDuringLocalEdit, .remoteDeletedDuringLocalEdit, .typeChanged:
                // The coordinator records these for the conflict UI; filenameCollision would make
                // the system rename the user's file to "name 2".
                return .fileProvider(.cannotSynchronize)
            }
        case .invalidFilename(_, .ignoredPattern):
            return .fileProvider(.excludedFromSync)
        case .invalidFilename:
            return .fileProvider(.filenameCollision)
        case .unsupported(let message):
            if message.localizedCaseInsensitiveContains("excluded from selective sync") {
                return .fileProvider(.excludedFromSync)
            }
            // Thrown by the domain runtime resolver when the keychain has no credential.
            if message.hasPrefix("Missing credential for account") {
                return .fileProvider(.notAuthenticated)
            }
            return .fileProvider(.cannotSynchronize)
        case .httpFailure(let failure):
            switch failure.kind {
            case .authentication:
                return .fileProvider(.notAuthenticated)
            case .authorization:
                // notAuthenticated would put the whole domain into a sign-in state for a per-item denial.
                return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            case .rateLimited, .server, .unavailable:
                return .fileProvider(.serverUnreachable)
            case .quotaExceeded:
                return .fileProvider(.insufficientQuota)
            case .conflict:
                // 409 (missing parent), 412 (etag precondition) and 423 (locked) are retryable states,
                // not name collisions.
                return .fileProvider(.cannotSynchronize)
            case .notFound:
                return .fileProvider(.noSuchItem)
            case .client, .unexpected:
                return .fileProvider(.cannotSynchronize, underlying: cloudError)
            }
        case .invalidResponse, .httpStatus, .transferIntegrityMismatch:
            return .fileProvider(.cannotSynchronize, underlying: cloudError)
        }
    }
}

private extension NSError {
    static func fileProvider(_ code: NSFileProviderError.Code, underlying: Error? = nil) -> NSError {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: code.rawValue,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0 as NSError] } ?? [:]
        )
    }

    /// The system rejects errors outside the Cocoa and File Provider domains and logs them as unsupported.
    var fileProviderCompatible: NSError {
        domain == NSCocoaErrorDomain || domain == NSFileProviderErrorDomain ? self : .fileProvider(.cannotSynchronize, underlying: self)
    }
}

private extension NSFileProviderPage {
    var providerPageToken: String? {
        let data = rawValue
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func providerPage(_ token: String) -> NSFileProviderPage {
        NSFileProviderPage(Data(token.utf8))
    }
}

private extension String {
    var fileProviderContentType: UTType? {
        guard let pathExtension = split(separator: ".").last.map(String.init), pathExtension != self else {
            return nil
        }
        return UTType(filenameExtension: pathExtension)
    }
}
#endif
