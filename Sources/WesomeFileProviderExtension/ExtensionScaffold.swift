import Foundation
import SyncStore
import WesomeFileProviderCore
import WesomeCloudShared

public struct FileProviderExtensionRuntime: Sendable {
    public var adapter: FileProviderAdapter
    public var itemCache: ExtensionItemCache

    public init(adapter: FileProviderAdapter, itemCache: ExtensionItemCache = ExtensionItemCache()) {
        self.adapter = adapter
        self.itemCache = itemCache
    }
}

public typealias FileProviderExtensionRuntimeResolving = @Sendable (String) async throws -> FileProviderExtensionRuntime

private actor ExtensionRuntimeBox {
    private var runtime: FileProviderExtensionRuntime?
    private let domainIdentifier: String?
    private let resolver: FileProviderExtensionRuntimeResolving?

    init(
        runtime: FileProviderExtensionRuntime?,
        domainIdentifier: String?,
        resolver: FileProviderExtensionRuntimeResolving?
    ) {
        self.runtime = runtime
        self.domainIdentifier = domainIdentifier
        self.resolver = resolver
    }

    func resolve() async throws -> FileProviderExtensionRuntime {
        if let runtime { return runtime }
        guard let domainIdentifier, let resolver else {
            throw WesomeFileProviderExtensionError.runtimeUnavailable.asNSError
        }
        let resolved = try await resolver(domainIdentifier)
        runtime = resolved
        return resolved
    }
}

#if canImport(FileProvider)
@preconcurrency import FileProvider
import UniformTypeIdentifiers

open class WesomeFileProviderReplicatedExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching, NSFileProviderIncrementalContentFetching, @unchecked Sendable {
    private let runtimeBox: ExtensionRuntimeBox
    private let domainIdentifier: String?
    private let logger: WesomeLogger

    public init(
        runtime: FileProviderExtensionRuntime? = nil,
        domainIdentifier: String? = nil,
        runtimeResolver: FileProviderExtensionRuntimeResolving? = nil,
        diagnostics: DiagnosticSink? = nil
    ) {
        self.runtimeBox = ExtensionRuntimeBox(
            runtime: runtime,
            domainIdentifier: domainIdentifier,
            resolver: runtimeResolver
        )
        self.domainIdentifier = domainIdentifier
        self.logger = WesomeLogger(category: "FileProvider", sink: diagnostics)
        super.init()
    }

    public required convenience init(domain: NSFileProviderDomain) {
        let domainIdentifier = domain.identifier.rawValue
        let productionResolver: FileProviderExtensionRuntimeResolving = { domainIdentifier in
            try await ProductionDomainRuntimeResolver.production().makeRuntime(domainID: domainIdentifier)
        }
        self.init(
            runtime: nil,
            domainIdentifier: domainIdentifier,
            runtimeResolver: productionResolver
        )
    }

    public func invalidate() {
        Task { await logger.info("invalidate domain=\(domainIdentifier ?? "in-memory")") }
    }

    public func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        completionHandler()
        Task {
            await logger.info("materializedItemsDidChange domain=\(domainIdentifier ?? "in-memory")")
        }
    }

    public func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        completionHandler()
        Task {
            await logger.info("pendingItemsDidChange domain=\(domainIdentifier ?? "in-memory")")
        }
    }

    public func globalProgress(for kind: Progress.FileOperationKind) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        progress.fileOperationKind = kind
        guard let direction = Self.transferDirection(for: kind) else {
            return progress
        }
        Task<Void, Never> {
            do {
                let runtime = try await runtimeBox.resolve()
                let summary = try await runtime.adapter.transferProgress(direction: direction)
                progress.totalUnitCount = summary.totalUnitCount
                progress.completedUnitCount = Swift.min(summary.completedUnitCount, summary.totalUnitCount)
                await logger.info("globalProgress kind=\(kind.rawValue) active=\(summary.activeTransferCount) completed=\(summary.completedUnitCount) total=\(summary.totalUnitCount)")
            } catch {
                await logger.error("globalProgress failed kind=\(kind.rawValue) error=\(String(describing: error))")
            }
        }
        return progress
    }

    private static func transferDirection(for kind: Progress.FileOperationKind) -> TransferDirection? {
        switch kind {
        case .downloading:
            .download
        case .uploading:
            .upload
        default:
            nil
        }
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Task { await logger.info("enumerator container=\(containerItemIdentifier.rawValue)") }
        if containerItemIdentifier == .trashContainer {
            return WesomeFileProviderEmptyEnumerator()
        }
        return WesomeFileProviderEnumerator(
            runtimeProvider: { try await self.runtimeBox.resolve() },
            containerIdentifier: String(containerItemIdentifier.rawValue)
        )
    }

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ItemCompletionBox(completionHandler)
        let task = Task<Void, Never> {
            let itemID = String(identifier.rawValue)
            await logger.info("item requested id=\(itemID)")
            do {
                let runtime = try await runtimeBox.resolve()
                if identifier == .rootContainer {
                    await logger.info("item completed id=\(itemID)")
                    completion.call(WesomeFileProviderItem(item: ProviderItem.root), nil)
                } else {
                    let parentPath = await runtime.itemCache.parentPath(for: itemID)
                    let item = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath)
                    if let item { await runtime.itemCache.register(item, parentPath: parentPath) }
                    await logger.info("item completed id=\(itemID)")
                    completion.call(item.map(WesomeFileProviderItem.init), item == nil ? WesomeFileProviderExtensionError.itemNotFound.asNSError : nil)
                }
                progress.completedUnitCount = 1
            } catch {
                await logger.error("item failed id=\(itemID) error=\(String(describing: error))")
                completion.call(nil, error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = FetchCompletionBox(completionHandler)
        let requestedVersion = requestedVersion.map(RequestedProviderVersion.init)
        let task = Task<Void, Never> {
            let itemID = String(itemIdentifier.rawValue)
            await logger.info("fetchContents requested id=\(itemID)")
            do {
                let runtime = try await runtimeBox.resolve()
                let parentPath = await runtime.itemCache.parentPath(for: itemID)
                try await Self.validateRequestedVersionIfNeeded(
                    requestedVersion,
                    itemID: itemID,
                    parentPath: parentPath,
                    runtime: runtime
                )
                let url = try await runtime.adapter.fetchContents(for: itemID)
                let item = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath)
                if let item { await runtime.itemCache.register(item, parentPath: parentPath) }
                completion.call(url, item.map(WesomeFileProviderItem.init), nil)
                await logger.info("fetchContents completed id=\(itemID)")
                progress.completedUnitCount = 1
            } catch {
                await logger.error("fetchContents failed id=\(itemID) error=\(String(describing: error))")
                completion.call(nil, nil, error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    public func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion, request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int, options: NSFileProviderFetchContentsOptions = [], completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = PartialFetchCompletionBox(completionHandler)
        let requestedVersion = RequestedProviderVersion(requestedVersion)
        let task = Task<Void, Never> {
            let itemID = String(itemIdentifier.rawValue)
            await logger.info("fetchPartialContents requested id=\(itemID) range=\(requestedRange.location)..<\(requestedRange.location + requestedRange.length)")
            do {
                let runtime = try await runtimeBox.resolve()
                let parentPath = await runtime.itemCache.parentPath(for: itemID)
                try await Self.validateRequestedVersionIfNeeded(
                    requestedVersion,
                    itemID: itemID,
                    parentPath: parentPath,
                    runtime: runtime
                )
                let partial = try await runtime.adapter.fetchPartialContents(
                    for: itemID,
                    requestedRange: ProviderContentRange(offset: Int64(requestedRange.location), length: Int64(requestedRange.length)),
                    alignment: Int64(alignment)
                )
                await runtime.itemCache.register(partial.item, parentPath: parentPath)
                let range = NSRange(location: Int(partial.retrievedRange.offset), length: Int(partial.retrievedRange.length))
                completion.call(partial.url, WesomeFileProviderItem(item: partial.item), range, [], nil)
                await logger.info("fetchPartialContents completed id=\(itemID)")
                progress.completedUnitCount = 1
            } catch {
                await logger.error("fetchPartialContents failed id=\(itemID) error=\(String(describing: error))")
                completion.call(nil, nil, requestedRange, [], error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, usingExistingContentsAt existingContents: URL, existingVersion: NSFileProviderItemVersion, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = FetchCompletionBox(completionHandler)
        let requestedVersion = requestedVersion.map(RequestedProviderVersion.init)
        let task = Task<Void, Never> {
            let itemID = String(itemIdentifier.rawValue)
            await logger.info("fetchIncrementalContents requested id=\(itemID) existing=\(existingContents.lastPathComponent)")
            do {
                let runtime = try await runtimeBox.resolve()
                let parentPath = await runtime.itemCache.parentPath(for: itemID)
                guard let current = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath) else {
                    throw WesomeFileProviderExtensionError.itemNotFound.asNSError
                }
                try Self.validateRequestedVersionIfNeeded(
                    requestedVersion,
                    current: current
                )
                let existingVersion = RequestedProviderVersion(existingVersion)
                if existingVersion.exactlyMatches(current) {
                    await runtime.itemCache.register(current, parentPath: parentPath)
                    completion.call(existingContents, WesomeFileProviderItem(item: current), nil)
                    await logger.info("fetchIncrementalContents reused existing id=\(itemID)")
                    progress.completedUnitCount = 1
                    return
                }
                let url = try await runtime.adapter.fetchContents(for: itemID)
                let item = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath)
                if let item { await runtime.itemCache.register(item, parentPath: parentPath) }
                completion.call(url, item.map(WesomeFileProviderItem.init), nil)
                await logger.info("fetchIncrementalContents completed id=\(itemID)")
                progress.completedUnitCount = 1
            } catch {
                await logger.error("fetchIncrementalContents failed id=\(itemID) error=\(String(describing: error))")
                completion.call(nil, nil, error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    private static func validateRequestedVersionIfNeeded(
        _ requestedVersion: RequestedProviderVersion?,
        itemID: String,
        parentPath: String,
        runtime: FileProviderExtensionRuntime
    ) async throws {
        guard let requestedVersion else { return }
        guard let current = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath) else {
            throw WesomeFileProviderExtensionError.itemNotFound.asNSError
        }
        guard requestedVersion.matches(current) else {
            throw NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.versionNoLongerAvailable.rawValue
            )
        }
    }

    private static func validateRequestedVersionIfNeeded(
        _ requestedVersion: RequestedProviderVersion?,
        current: ProviderItem
    ) throws {
        guard let requestedVersion else { return }
        guard requestedVersion.matches(current) else {
            throw NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.versionNoLongerAvailable.rawValue
            )
        }
    }

    private struct RequestedProviderVersion: Sendable {
        var contentVersion: Data
        var metadataVersion: Data

        init(_ version: NSFileProviderItemVersion) {
            self.contentVersion = version.contentVersion
            self.metadataVersion = version.metadataVersion
        }

        var isMeaningful: Bool {
            !contentVersion.isEmpty || !metadataVersion.isEmpty
        }

        func matches(_ current: ProviderItem) -> Bool {
            let beforeFirstSync = NSFileProviderItemVersion.beforeFirstSyncComponent
            let contentMatches = contentVersion == beforeFirstSync || contentVersion == current.contentVersion
            let metadataMatches = metadataVersion == beforeFirstSync || metadataVersion == current.metadataVersion
            return contentMatches && metadataMatches
        }

        func exactlyMatches(_ current: ProviderItem) -> Bool {
            contentVersion == current.contentVersion && metadataVersion == current.metadataVersion
        }
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = MutationCompletionBox(completionHandler)
        let task = Task<Void, Never> {
            await logger.info("createItem requested filename=\(itemTemplate.filename)")
            do {
                let runtime = try await runtimeBox.resolve()
                let parentID = itemTemplate.parentItemIdentifier == .rootContainer ? nil : String(itemTemplate.parentItemIdentifier.rawValue)
                let parent: ProviderContainerReference
                let parentPath: String
                if let parentID {
                    parent = await runtime.itemCache.containerReference(for: parentID)
                    parentPath = (await runtime.itemCache.cachedItem(id: parentID))?.path ?? "/"
                } else {
                    parent = .root
                    parentPath = "/"
                }
                let created: ProviderItem
                if itemTemplate.contentType?.conforms(to: .directory) == true {
                    created = try await runtime.adapter.createFolder(named: itemTemplate.filename, in: parent)
                    // Packages (.app, .pages, .rtfd) arrive as one item with a directory URL and are
                    // stored as remote folders, so their contents have to be uploaded here. Plain
                    // folders have no URL; the system creates their children separately.
                    if let url, itemTemplate.contentType?.conforms(to: .package) == true {
                        await runtime.itemCache.register(created, parentPath: parentPath)
                        try await Self.uploadPackageContents(at: url, into: created.id, runtime: runtime)
                    }
                } else {
                    let contents = try Self.contentsURLForCreatedFile(url)
                    defer {
                        if contents.isTemporary {
                            try? FileManager.default.removeItem(at: contents.url)
                        }
                    }
                    created = try await runtime.adapter.createFile(named: itemTemplate.filename, contentsAt: contents.url, in: parent)
                }
                await runtime.itemCache.register(created, parentPath: parentPath)
                completion.call(WesomeFileProviderItem(item: created), [], false, nil)
                await logger.info("createItem completed id=\(created.id)")
                progress.completedUnitCount = 1
            } catch {
                await logger.error("createItem failed filename=\(itemTemplate.filename) error=\(String(describing: error))")
                completion.call(nil, [], false, error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    private static func uploadPackageContents(at directory: URL, into folderID: String, runtime: FileProviderExtensionRuntime) async throws {
        let container = await runtime.itemCache.containerReference(for: folderID)
        let folderPath = await runtime.itemCache.cachedItem(id: folderID)?.path
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            do {
                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    let folder = try await runtime.adapter.createFolder(named: child.lastPathComponent, in: container)
                    await runtime.itemCache.register(folder, parentPath: folderPath)
                    try await uploadPackageContents(at: child, into: folder.id, runtime: runtime)
                } else {
                    let file = try await runtime.adapter.createFile(named: child.lastPathComponent, contentsAt: child, in: container)
                    await runtime.itemCache.register(file, parentPath: folderPath)
                }
            } catch WesomeCloudError.invalidFilename(_, .ignoredPattern) {
                // Ignored names such as .DS_Store are skipped instead of failing the whole package.
                continue
            }
        }
    }

    private static func contentsURLForCreatedFile(_ url: URL?) throws -> (url: URL, isTemporary: Bool) {
        if let url {
            return (url, false)
        }
        let emptyFile = FileManager.default.temporaryDirectory.appending(path: "WesomeCloudEmpty-\(UUID().uuidString)")
        try Data().write(to: emptyFile)
        return (emptyFile, true)
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = MutationCompletionBox(completionHandler)
        let task = Task<Void, Never> {
            let itemID = String(item.itemIdentifier.rawValue)
            await logger.info("modifyItem requested id=\(itemID)")
            do {
                let runtime = try await runtimeBox.resolve()
                let providerItem: ProviderItem
                let registrationParentPath: String?
                let currentParentPath = await runtime.itemCache.parentPath(for: itemID)
                try await Self.validateBaseVersionIfNeeded(
                    version,
                    options: options,
                    itemID: itemID,
                    parentPath: currentParentPath,
                    runtime: runtime
                )
                if changedFields.contains(.parentItemIdentifier),
                   item.parentItemIdentifier == .trashContainer {
                    try await runtime.adapter.deleteItem(itemID)
                    await runtime.itemCache.remove(id: itemID)
                    completion.call(nil, [], false, nil)
                    await logger.info("modifyItem trashed id=\(itemID)")
                    progress.completedUnitCount = 1
                    return
                }
                let hasLocationChange = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
                if let newContents {
                    if hasLocationChange {
                        let parentID = item.parentItemIdentifier == .rootContainer ? nil : String(item.parentItemIdentifier.rawValue)
                        let destination = await runtime.itemCache.destinationPath(parentID: parentID, filename: item.filename)
                        _ = try await runtime.adapter.moveItem(itemID, to: destination)
                        if let parentID {
                            registrationParentPath = await runtime.itemCache.cachedItem(id: parentID)?.path ?? "/"
                        } else {
                            registrationParentPath = "/"
                        }
                    } else {
                        registrationParentPath = currentParentPath
                    }
                    providerItem = try await runtime.adapter.modifyItem(itemID, contentsAt: newContents)
                } else {
                    if hasLocationChange {
                        let parentID = item.parentItemIdentifier == .rootContainer ? nil : String(item.parentItemIdentifier.rawValue)
                        let destination = await runtime.itemCache.destinationPath(parentID: parentID, filename: item.filename)
                        providerItem = try await runtime.adapter.moveItem(itemID, to: destination)
                        if let parentID {
                            registrationParentPath = await runtime.itemCache.cachedItem(id: parentID)?.path ?? "/"
                        } else {
                            registrationParentPath = "/"
                        }
                    } else {
                        guard let existingItem = try await runtime.adapter.itemForIdentifier(itemID, parentPath: currentParentPath) else {
                            throw WesomeFileProviderExtensionError.itemNotFound.asNSError
                        }
                        providerItem = existingItem
                        registrationParentPath = currentParentPath
                    }
                }
                await runtime.itemCache.register(providerItem, parentPath: registrationParentPath)
                completion.call(WesomeFileProviderItem(item: providerItem), [], false, nil)
                await logger.info("modifyItem completed id=\(itemID)")
                progress.completedUnitCount = 1
            } catch {
                await logger.error("modifyItem failed id=\(itemID) error=\(String(describing: error))")
                completion.call(nil, [], false, error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    private static func validateBaseVersionIfNeeded(
        _ baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderModifyItemOptions,
        itemID: String,
        parentPath: String,
        runtime: FileProviderExtensionRuntime
    ) async throws {
        guard options.contains(Self.failOnConflictModifyOption) else { return }
        guard let current = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath) else {
            throw WesomeFileProviderExtensionError.itemNotFound.asNSError
        }
        guard version(baseVersion, matches: current) else {
            throw NSError(
                domain: NSFileProviderErrorDomain,
                code: Self.localVersionConflictingWithServerErrorCode
            )
        }
    }

    private static var failOnConflictModifyOption: NSFileProviderModifyItemOptions {
        NSFileProviderModifyItemOptions(rawValue: 1 << 1)
    }

    private static var localVersionConflictingWithServerErrorCode: Int {
        -2015
    }

    private static func version(_ baseVersion: NSFileProviderItemVersion, matches current: ProviderItem) -> Bool {
        let beforeFirstSync = NSFileProviderItemVersion.beforeFirstSyncComponent
        let contentMatches = baseVersion.contentVersion == beforeFirstSync || baseVersion.contentVersion == current.contentVersion
        let metadataMatches = baseVersion.metadataVersion == beforeFirstSync || baseVersion.metadataVersion == current.metadataVersion
        return contentMatches && metadataMatches
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = DeleteCompletionBox(completionHandler)
        let baseVersion = RequestedProviderVersion(version)
        let isRecursiveDelete = options.contains(Self.recursiveDeleteOption)
        let task = Task<Void, Never> {
            var resolvedRuntime: FileProviderExtensionRuntime?
            let itemID = String(identifier.rawValue)
            await logger.info("deleteItem requested id=\(itemID)")
            do {
                let runtime = try await runtimeBox.resolve()
                resolvedRuntime = runtime
                try await Self.validateDeleteBaseVersionIfNeeded(
                    baseVersion,
                    itemID: itemID,
                    runtime: runtime
                )
                try await Self.validateDirectoryDeleteOptions(
                    isRecursive: isRecursiveDelete,
                    itemID: itemID,
                    runtime: runtime
                )
                try await runtime.adapter.deleteItem(itemID)
                await runtime.itemCache.remove(id: itemID)
                completion.call(nil)
                await logger.info("deleteItem completed id=\(itemID)")
                progress.completedUnitCount = 1
            } catch {
                if Self.isAlreadyDeleted(error) {
                    if let resolvedRuntime {
                        await resolvedRuntime.itemCache.remove(id: itemID)
                    }
                    completion.call(nil)
                    await logger.info("deleteItem already-deleted id=\(itemID)")
                    progress.completedUnitCount = 1
                    return
                }
                await logger.error("deleteItem failed id=\(itemID) error=\(String(describing: error))")
                completion.call(error.asFileProviderNSError)
            }
        }
        Self.makeCancellable(progress, cancelling: task)
        return progress
    }

    private static func validateDirectoryDeleteOptions(
        isRecursive: Bool,
        itemID: String,
        runtime: FileProviderExtensionRuntime
    ) async throws {
        guard !isRecursive else { return }
        let parentPath = await runtime.itemCache.parentPath(for: itemID)
        guard let current = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath),
              current.kind == .folder else {
            return
        }
        guard await runtime.itemCache.hasCachedDescendants(id: itemID) else { return }
        throw NSError(
            domain: NSFileProviderErrorDomain,
            code: Self.directoryNotEmptyErrorCode
        )
    }

    private static func validateDeleteBaseVersionIfNeeded(
        _ baseVersion: RequestedProviderVersion,
        itemID: String,
        runtime: FileProviderExtensionRuntime
    ) async throws {
        guard baseVersion.isMeaningful else { return }
        let parentPath = await runtime.itemCache.parentPath(for: itemID)
        guard let current = try await runtime.adapter.itemForIdentifier(itemID, parentPath: parentPath) else {
            return
        }
        guard baseVersion.matches(current) else {
            throw NSError(
                domain: NSFileProviderErrorDomain,
                code: Self.deletionRejectedErrorCode
            )
        }
    }

    private static func isAlreadyDeleted(_ error: Error) -> Bool {
        if let cloudError = error as? WesomeCloudError, case .missingItem = cloudError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSFileProviderErrorDomain &&
            nsError.code == NSFileProviderError.noSuchItem.rawValue
    }

    private static var deletionRejectedErrorCode: Int {
        -1006
    }

    private static var directoryNotEmptyErrorCode: Int {
        -1007
    }

    private static var recursiveDeleteOption: NSFileProviderDeleteItemOptions {
        NSFileProviderDeleteItemOptions(rawValue: 1 << 0)
    }

    private static func makeCancellable(_ progress: Progress, cancelling task: Task<Void, Never>) {
        progress.isCancellable = true
        progress.cancellationHandler = {
            task.cancel()
        }
    }

    public func enumerateRootForTestingBridge() async throws -> [ProviderItem] {
        let runtime = try await runtimeBox.resolve()
        return try await runtime.adapter.enumerate(container: .root).items
    }

    public func domainIdentifierForTesting() -> String? {
        domainIdentifier
    }
}
#else
public final class WesomeFileProviderReplicatedExtension: NSObject {
    private let runtimeBox: ExtensionRuntimeBox
    private let domainIdentifier: String?

    public init(
        runtime: FileProviderExtensionRuntime? = nil,
        domainIdentifier: String? = nil,
        runtimeResolver: FileProviderExtensionRuntimeResolving? = nil
    ) {
        self.runtimeBox = ExtensionRuntimeBox(
            runtime: runtime,
            domainIdentifier: domainIdentifier,
            resolver: runtimeResolver
        )
        self.domainIdentifier = domainIdentifier
        super.init()
    }

    public func enumerateRootForTestingBridge() async throws -> [ProviderItem] {
        let runtime = try await runtimeBox.resolve()
        return try await runtime.adapter.enumerate(container: .root).items
    }

    public func domainIdentifierForTesting() -> String? {
        domainIdentifier
    }
}
#endif

#if canImport(FileProvider)
@available(macOS 26.0, *)
extension WesomeFileProviderReplicatedExtension: NSFileProviderSearching {
    public func searchEnumerator(for request: NSFileProviderStringSearchRequest) -> NSFileProviderSearchEnumerator {
        Task { await logger.info("searchEnumerator query=\(request.query)") }
        return WesomeFileProviderSearchEnumerator(
            runtimeProvider: { try await self.runtimeBox.resolve() },
            query: request.query,
            desiredNumberOfResults: request.desiredNumberOfResults
        )
    }
}

private final class ItemCompletionBox: @unchecked Sendable {
    private let completion: (NSFileProviderItem?, Error?) -> Void

    init(_ completion: @escaping (NSFileProviderItem?, Error?) -> Void) {
        self.completion = completion
    }

    func call(_ item: NSFileProviderItem?, _ error: Error?) {
        completion(item, error)
    }
}

private final class FetchCompletionBox: @unchecked Sendable {
    private let completion: (URL?, NSFileProviderItem?, Error?) -> Void

    init(_ completion: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) {
        self.completion = completion
    }

    func call(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) {
        completion(url, item, error)
    }
}

private final class PartialFetchCompletionBox: @unchecked Sendable {
    private let completion: (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void

    init(_ completion: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) {
        self.completion = completion
    }

    func call(_ url: URL?, _ item: NSFileProviderItem?, _ range: NSRange, _ flags: NSFileProviderMaterializationFlags, _ error: Error?) {
        completion(url, item, range, flags, error)
    }
}

private final class MutationCompletionBox: @unchecked Sendable {
    private let completion: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void

    init(_ completion: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) {
        self.completion = completion
    }

    func call(_ item: NSFileProviderItem?, _ fields: NSFileProviderItemFields, _ shouldFetch: Bool, _ error: Error?) {
        completion(item, fields, shouldFetch, error)
    }
}

private final class DeleteCompletionBox: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func call(_ error: Error?) {
        completion(error)
    }
}
#endif

private enum WesomeFileProviderExtensionError: Error {
    case runtimeUnavailable
    case itemNotFound

    var asNSError: NSError {
        switch self {
        case .runtimeUnavailable:
            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue)
        case .itemNotFound:
            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)
        }
    }
}

private extension ProviderItem {
    static var root: ProviderItem {
        ProviderItem(
            id: NSFileProviderItemIdentifier.rootContainer.rawValue,
            parentID: nil,
            filename: "WesomeCloud",
            kind: .folder,
            size: nil,
            contentVersion: Data("root".utf8),
            metadataVersion: Data("root".utf8),
            availabilityIntent: .unspecified,
            capabilities: [.enumerate, .addChildren]
        )
    }
}
