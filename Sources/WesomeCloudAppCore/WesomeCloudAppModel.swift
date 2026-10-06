import Foundation
import OwnCloudKit
import SyncStore
import WesomeCloudShared

public protocol AppConflictResolving: Sendable {
    func resolveConflict(
        _ record: ConflictRecord,
        account: PersistedAccountRecord,
        decision: ConflictResolutionDecision,
        resolvedName: String?
    ) async throws
}

public protocol AppAvailabilityResolving: Sendable {
    @discardableResult
    func setAvailabilityIntent(
        _ intent: AvailabilityIntent,
        itemID: String,
        account: PersistedAccountRecord
    ) async throws -> [String]
}

public protocol AppPublicLinkCreating: Sendable {
    func createPublicLink(for file: AppFileItem) async throws -> PublicLinkShare
    func publicLinks(for file: AppFileItem) async throws -> [PublicLinkShare]
    func deletePublicLink(_ share: PublicLinkShare, for file: AppFileItem) async throws
    func privateLink(for file: AppFileItem) async throws -> URL
}

public struct AppSnapshot: Equatable, Sendable {
    public var accounts: [PersistedAccountRecord]
    public var spaces: [AppSpace]
    public var notifications: [AppNotification]
    public var files: [AppFileItem]
    public var diagnostics: [DiagnosticEvent]
    public var issues: [SyncIssue]
    public var conflicts: [AppConflict]
    public var transfers: [AppTransfer]
    public var storage: [AppAccountStorage]
    public var crashReports: [CrashReport]
    public var updateStatus: UpdateStatus?
    public var lastCreatedShare: PublicLinkShare?
    public var publicLinks: [AppPublicLink]

    public init(
        accounts: [PersistedAccountRecord] = [],
        spaces: [AppSpace] = [],
        notifications: [AppNotification] = [],
        files: [AppFileItem] = [],
        diagnostics: [DiagnosticEvent] = [],
        issues: [SyncIssue] = [],
        conflicts: [AppConflict] = [],
        transfers: [AppTransfer] = [],
        storage: [AppAccountStorage] = [],
        crashReports: [CrashReport] = [],
        updateStatus: UpdateStatus? = nil,
        lastCreatedShare: PublicLinkShare? = nil,
        publicLinks: [AppPublicLink] = []
    ) {
        self.accounts = accounts
        self.spaces = spaces
        self.notifications = notifications
        self.files = files
        self.diagnostics = diagnostics
        self.issues = issues
        self.conflicts = conflicts
        self.transfers = transfers
        self.storage = storage
        self.crashReports = crashReports
        self.updateStatus = updateStatus
        self.lastCreatedShare = lastCreatedShare
        self.publicLinks = publicLinks
    }
}

public struct AppNotification: Equatable, Identifiable, Sendable {
    public var id: String { "\(accountID.uuidString):\(notification.id)" }
    public var accountID: UUID
    public var accountName: String
    public var notification: UserNotification

    public init(accountID: UUID, accountName: String, notification: UserNotification) {
        self.accountID = accountID
        self.accountName = accountName
        self.notification = notification
    }
}

public struct AppSpace: Equatable, Identifiable, Sendable {
    public var id: String { "\(accountID.uuidString):\(space.id)" }
    public var accountID: UUID
    public var accountName: String
    public var space: OwnCloudSpace
    public var isSelected: Bool

    public init(accountID: UUID, accountName: String, space: OwnCloudSpace, isSelected: Bool = false) {
        self.accountID = accountID
        self.accountName = accountName
        self.space = space
        self.isSelected = isSelected
    }
}

public struct AppPublicLink: Equatable, Identifiable, Sendable {
    public var id: String { "\(domainID ?? accountID.uuidString):\(fileID):\(share.id)" }
    public var accountID: UUID
    public var domainID: String? = nil
    public var fileID: String
    public var filePath: String
    public var accountName: String
    public var share: PublicLinkShare

    public init(accountID: UUID, domainID: String? = nil, fileID: String, filePath: String, accountName: String, share: PublicLinkShare) {
        self.accountID = accountID
        self.domainID = domainID
        self.fileID = fileID
        self.filePath = filePath
        self.accountName = accountName
        self.share = share
    }
}

public struct AppTransfer: Equatable, Identifiable, Sendable {
    public var id: UUID { transfer.id }
    public var accountID: UUID
    public var accountName: String
    public var transfer: TransferRecord

    public init(accountID: UUID, accountName: String, transfer: TransferRecord) {
        self.accountID = accountID
        self.accountName = accountName
        self.transfer = transfer
    }
}

public struct AppAccountStorage: Equatable, Identifiable, Sendable {
    public var id: String { domainID ?? accountID.uuidString }
    public var domainID: String?
    public var accountID: UUID
    public var accountName: String
    public var usedBytes: Int64
    public var availableBytes: Int64?

    public init(accountID: UUID, domainID: String? = nil, accountName: String, usedBytes: Int64, availableBytes: Int64?) {
        self.accountID = accountID
        self.domainID = domainID
        self.accountName = accountName
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}

public struct AppFileItem: Equatable, Identifiable, Sendable {
    public var id: String { "\(domainID ?? accountID.uuidString):\(item.remote.id)" }
    public var accountID: UUID
    public var domainID: String? = nil
    public var accountName: String
    public var serverURL: URL
    public var accountUsername: String
    public var webDAVRootURL: URL?
    public var item: StoredItem

    public init(accountID: UUID, domainID: String? = nil, accountName: String, serverURL: URL, accountUsername: String? = nil, webDAVRootURL: URL? = nil, item: StoredItem) {
        self.accountID = accountID
        self.domainID = domainID
        self.accountName = accountName
        self.serverURL = serverURL
        self.accountUsername = accountUsername ?? accountName
        self.webDAVRootURL = webDAVRootURL
        self.item = item
    }
}

public struct SyncIssue: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var domainID: String? = nil
    public var accountName: String
    public var scope: SyncErrorScope
    public var itemID: String?
    public var operationID: UUID?
    public var message: String
    public var isRecoverable: Bool
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        accountName: String,
        scope: SyncErrorScope,
        itemID: String? = nil,
        operationID: UUID? = nil,
        message: String,
        isRecoverable: Bool,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.accountName = accountName
        self.scope = scope
        self.itemID = itemID
        self.operationID = operationID
        self.message = message
        self.isRecoverable = isRecoverable
        self.occurredAt = occurredAt
    }

    public init(record: SyncErrorRecord, account: PersistedAccountRecord) {
        self.id = record.id
        self.accountID = account.id
        self.domainID = account.domain?.id
        self.accountName = account.locationName
        self.scope = record.scope
        self.itemID = record.itemID
        self.operationID = record.operationID
        self.message = record.message
        self.isRecoverable = record.isRecoverable
        self.occurredAt = record.occurredAt
    }
}

public struct AppConflict: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var domainID: String? = nil
    public var accountName: String
    public var conflict: SyncConflict
    public var createdAt: Date

    public init(record: ConflictRecord, account: PersistedAccountRecord) {
        self.id = record.id
        self.accountID = account.id
        self.domainID = account.domain?.id
        self.accountName = account.locationName
        self.conflict = record.conflict
        self.createdAt = record.createdAt
    }
}

public actor AppDiagnosticBuffer: DiagnosticSink {
    private var storage: [DiagnosticEvent] = []
    private let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public func record(_ event: DiagnosticEvent) async {
        storage.append(event)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
    }

    public func events() async -> [DiagnosticEvent] {
        storage
    }
}

public actor WesomeCloudAppModel {
    private let accountSessions: AccountSessionService
    private let domains: FileProviderDomainService
    private let repository: AccountRepository
    private let preferencesRepository: PreferencesRepository
    private let metadataStore: MetadataStore?
    private let diagnostics: AppDiagnosticBuffer
    private let crashReports: CrashReportRepository?
    private let crashReportImporter: CrashReportImporting?
    private let updateChecker: UpdateCheckingService?
    private let conflictResolver: AppConflictResolving?
    private let availabilityResolver: AppAvailabilityResolving?
    private let publicLinkCreator: AppPublicLinkCreating?
    private var updateStatus: UpdateStatus?
    private var lastCreatedShare: PublicLinkShare?
    private var publicLinks: [AppPublicLink] = []

    public init(
        accountSessions: AccountSessionService,
        domains: FileProviderDomainService,
        repository: AccountRepository,
        preferencesRepository: PreferencesRepository = MemoryPreferencesRepository(),
        metadataStore: MetadataStore? = nil,
        crashReports: CrashReportRepository? = nil,
        crashReportImporter: CrashReportImporting? = nil,
        updateChecker: UpdateCheckingService? = nil,
        conflictResolver: AppConflictResolving? = nil,
        availabilityResolver: AppAvailabilityResolving? = nil,
        publicLinkCreator: AppPublicLinkCreating? = nil,
        diagnostics: AppDiagnosticBuffer = AppDiagnosticBuffer()
    ) {
        self.accountSessions = accountSessions
        self.domains = domains
        self.repository = repository
        self.preferencesRepository = preferencesRepository
        self.metadataStore = metadataStore
        self.crashReports = crashReports
        self.crashReportImporter = crashReportImporter
        self.updateChecker = updateChecker
        self.conflictResolver = conflictResolver
        self.availabilityResolver = availabilityResolver
        self.publicLinkCreator = publicLinkCreator
        self.diagnostics = diagnostics
    }

    public init(
        accountSessions: AccountSessionService,
        domains: FileProviderDomainService,
        repository: AccountRepository,
        preferencesRepository: PreferencesRepository = MemoryPreferencesRepository(),
        metadataStore: MetadataStore? = nil,
        diagnostics: AppDiagnosticBuffer = AppDiagnosticBuffer()
    ) {
        self.init(
            accountSessions: accountSessions,
            domains: domains,
            repository: repository,
            preferencesRepository: preferencesRepository,
            metadataStore: metadataStore,
            crashReports: nil,
            crashReportImporter: nil,
            updateChecker: nil,
            conflictResolver: nil,
            availabilityResolver: nil,
            diagnostics: diagnostics
        )
    }

    public func restoreFinderLocations() async throws {
        let accounts = try await repository.records()
        try await domains.restore(accounts.flatMap(\.domains))
    }

    public func loadSnapshot() async throws -> AppSnapshot {
        try await importCrashReportsIfAvailable()
        let spaces = await loadSpaces(for: try await repository.records())
        let accounts = try await repository.records()
        return try await AppSnapshot(
            accounts: accounts,
            spaces: spaces,
            notifications: await loadNotifications(for: accounts),
            files: loadFiles(for: accounts),
            diagnostics: diagnostics.events(),
            issues: loadIssues(for: accounts),
            conflicts: loadConflicts(for: accounts),
            transfers: loadTransfers(for: accounts),
            storage: loadStorage(for: accounts),
            crashReports: crashReports?.reports() ?? [],
            updateStatus: updateStatus,
            lastCreatedShare: lastCreatedShare,
            publicLinks: publicLinks
        )
    }

    private func loadSpaces(for accounts: [PersistedAccountRecord]) async -> [AppSpace] {
        var spaces: [AppSpace] = []
        for record in accounts {
            do {
                let accountSpaces = try await accountSessions.spaces(for: record.account)
                var renamed = record
                for index in renamed.domains.indices {
                    guard let space = accountSpaces.first(where: { renamed.domains[index].represents($0) }),
                          renamed.domains[index].displayName != space.name else { continue }
                    var domain = renamed.domains[index]
                    domain.displayName = space.name
                    try await domains.updateDomain(domain)
                    renamed.domains[index] = domain
                }
                if renamed != record { try await repository.save(renamed) }
                spaces.append(contentsOf: accountSpaces.map { space in
                    AppSpace(accountID: record.id, accountName: record.account.displayName, space: space,
                             isSelected: record.domains.contains { $0.represents(space) })
                })
            } catch {
                await diagnostics.record(DiagnosticEvent(category: "Spaces", level: .debug, message: "Spaces unavailable for \(record.account.displayName): \(UserFacingErrorFormatter.message(for: error))"))
            }
        }
        return spaces.sorted {
            if $0.accountName == $1.accountName {
                $0.space.name.localizedStandardCompare($1.space.name) == .orderedAscending
            } else {
                $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
            }
        }
    }

    private func loadNotifications(for accounts: [PersistedAccountRecord]) async -> [AppNotification] {
        var notifications: [AppNotification] = []
        for record in accounts {
            do {
                let accountNotifications = try await accountSessions.notifications(for: record.account)
                notifications.append(contentsOf: accountNotifications.map {
                    AppNotification(accountID: record.id, accountName: record.account.displayName, notification: $0)
                })
            } catch {
                await diagnostics.record(DiagnosticEvent(category: "Notifications", level: .debug, message: "Notifications unavailable for \(record.account.displayName): \(UserFacingErrorFormatter.message(for: error))"))
            }
        }
        return notifications.sorted {
            if $0.notification.date == $1.notification.date {
                $0.notification.subject.localizedStandardCompare($1.notification.subject) == .orderedAscending
            } else {
                ($0.notification.date ?? .distantPast) > ($1.notification.date ?? .distantPast)
            }
        }
    }

    public func addAccount(serverURL: URL, username: String, appPassword: String) async throws -> PersistedAccountRecord {
        let session = try await accountSessions.addAccount(serverURL: serverURL, username: username, appPassword: appPassword)
        return try await persist(session: session, readyMessageName: username)
    }

    public func addOAuthAccount(serverURL: URL, authenticator: OAuthAuthenticating) async throws -> PersistedAccountRecord {
        let session = try await accountSessions.addOAuthAccount(serverURL: serverURL, authenticator: authenticator)
        return try await persist(session: session, readyMessageName: session.account.username)
    }

    public func reconnectAccount(accountID: UUID, appPassword: String) async throws -> PersistedAccountRecord {
        guard let existing = try await repository.records().first(where: { $0.id == accountID }) else {
            throw WesomeCloudError.missingItem(accountID.uuidString)
        }
        let session = try await accountSessions.reconnectAccount(existing.account, appPassword: appPassword)
        // Preserve all selected Spaces when reconnecting. Legacy imports without a
        // domain get the default account location.
        return try await persist(session: session, selectedDomains: existing.domains.isEmpty && !existing.syncLocations.isEmpty ? nil : existing.domains, readyMessageName: session.account.username)
    }

    public func syncSpace(_ space: AppSpace) async throws -> PersistedAccountRecord {
        guard var record = try await repository.records().first(where: { $0.id == space.accountID }) else {
            throw WesomeCloudError.missingItem(space.accountID.uuidString)
        }
        if record.domains.contains(where: { $0.represents(space.space) }) {
            try await domains.restore(record.domains)
            return record
        }
        let domain = try await domains.registerDomain(for: record.account, space: space.space)
        record.domains.append(domain)
        record.lastSyncStatus = SyncStatusSnapshot(state: .idle, message: "Connected to \(space.space.name)")
        try await repository.save(record)
        await diagnostics.record(DiagnosticEvent(category: "Spaces", level: .info, message: "Syncing space \(space.space.name) for \(record.account.displayName)"))
        return record
    }

    public func removeSpace(_ space: AppSpace) async throws {
        guard var record = try await repository.records().first(where: { $0.id == space.accountID }),
              let domain = record.domains.first(where: { $0.represents(space.space) }) else { return }
        let pending = try await metadataStore?.pendingOperations(accountID: domain.metadataID) ?? []
        let conflicts = try await metadataStore?.conflicts(accountID: domain.metadataID, state: .pending) ?? []
        guard pending.isEmpty && conflicts.isEmpty else {
            throw WesomeCloudError.unsupported("Finish syncing changes and resolve conflicts in \(space.space.name) before removing it from Finder.")
        }
        try await domains.removeDomain(domain)
        record.domains.removeAll { $0.id == domain.id }
        record.lastSyncStatus = SyncStatusSnapshot(state: .idle, message: "Removed \(space.space.name) from Finder")
        try await repository.save(record)
        try await removeLocalContent(for: domain.metadataID)
        try await metadataStore?.removeAll(accountID: domain.metadataID)
        publicLinks.removeAll { $0.accountID == record.id && $0.domainID == domain.id }
    }

    public func dismissNotification(_ notification: AppNotification) async throws {
        guard let record = try await repository.records().first(where: { $0.id == notification.accountID }) else {
            throw WesomeCloudError.unsupported("Unknown account \(notification.accountID.uuidString)")
        }
        try await accountSessions.deleteNotification(id: notification.notification.id, for: record.account)
        await diagnostics.record(DiagnosticEvent(category: "Notifications", level: .info, message: "Dismissed notification \(notification.notification.id)"))
    }

    private func persist(session: AccountSession, selectedDomains: [CloudDomain]? = nil, readyMessageName: String) async throws -> PersistedAccountRecord {
        let selections: [CloudDomain]
        if let selectedDomains {
            selections = selectedDomains
        } else {
            selections = [try await domains.registerDomain(for: session)]
        }
        var record = PersistedAccountRecord(
            account: session.account,
            domain: selections.first,
            serverVersion: session.serverVersion,
            serverEdition: session.serverEdition,
            serverPollInterval: session.serverPollInterval,
            lastSyncStatus: SyncStatusSnapshot(state: .idle, message: "Connected")
        )
        record.domains = selections
        try await repository.save(record)
        await diagnostics.record(DiagnosticEvent(category: "App", level: .info, message: "Account \(readyMessageName) is ready"))
        return record
    }

    public func removeAccount(accountID: UUID) async throws {
        let record = try await repository.records().first { $0.id == accountID }
        try await domains.removeDomains(for: accountID, including: record?.domain?.id)
        try await accountSessions.removeCredentials(for: accountID)
        let metadataIDs = Set((record?.domains.map(\.metadataID) ?? []) + [accountID])
        for metadataID in metadataIDs {
            try await removeLocalContent(for: metadataID)
            try await metadataStore?.removeAll(accountID: metadataID)
        }
        try await repository.delete(accountID: accountID)
        await diagnostics.record(DiagnosticEvent(category: "App", level: .info, message: "Removed account \(accountID.uuidString)"))
    }

    public func updateSyncStatus(_ status: SyncStatusSnapshot, accountID: UUID) async throws {
        try await repository.updateStatus(status, accountID: accountID)
        await diagnostics.record(DiagnosticEvent(category: "SyncStatus", level: status.state == .error ? .error : .info, message: status.message))
    }

    public func loadPreferences() async throws -> AppPreferences {
        try await preferencesRepository.load()
    }

    public func savePreferences(_ preferences: AppPreferences) async throws {
        try await preferencesRepository.save(preferences)
        await diagnostics.record(DiagnosticEvent(category: "Preferences", level: .info, message: "Saved preferences"))
    }

    public func exportDiagnostics(to directory: URL, exporter: DiagnosticsExporter = DiagnosticsExporter()) async throws -> URL {
        let snapshot = try await loadSnapshot()
        let preferences = try await loadPreferences()
        let url = try exporter.export(snapshot: snapshot, preferences: preferences, to: directory)
        await diagnostics.record(DiagnosticEvent(category: "Diagnostics", level: .info, message: "Exported diagnostics to \(url.path)"))
        return url
    }

    public func recordCrashReport(_ report: CrashReport) async throws {
        try await crashReports?.save(report)
        await diagnostics.record(DiagnosticEvent(category: "Crash", level: .error, message: "Recorded crash report \(report.id.uuidString) for \(report.processName)"))
    }

    private func importCrashReportsIfAvailable() async throws {
        guard let crashReports, let crashReportImporter else { return }
        let imported = try await crashReportImporter.importReports(into: crashReports)
        if imported > 0 {
            await diagnostics.record(DiagnosticEvent(category: "Crash", level: .warning, message: "Imported \(imported) macOS crash report\(imported == 1 ? "" : "s")"))
        }
    }

    public func checkForUpdates() async throws -> UpdateStatus {
        guard let updateChecker else {
            let status = UpdateStatus(currentVersion: "unknown", message: "No update checker configured")
            updateStatus = status
            return status
        }
        let preferences = try await loadPreferences()
        let status = try await updateChecker.check(appcastURL: preferences.updates.appcastURL)
        updateStatus = status
        await diagnostics.record(DiagnosticEvent(category: "Updates", level: status.availableUpdate == nil ? .info : .warning, message: status.message))
        return status
    }

    public func clearIssue(_ issueID: UUID, accountID: UUID, domainID: String? = nil) async throws {
        let account = try await requireAccount(accountID, domainID: domainID)
        try await metadataStore?.clearSyncError(id: issueID, accountID: account.metadataID)
        await diagnostics.record(DiagnosticEvent(category: "SyncIssue", level: .info, message: "Cleared sync issue \(issueID.uuidString)"))
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, accountID: UUID, itemID: String, domainID: String? = nil) async throws {
        guard metadataStore != nil else {
            throw WesomeCloudError.unsupported("Availability controls require metadata storage")
        }
        let account = try await requireAccount(accountID, domainID: domainID)
        let affected: [String]
        if let availabilityResolver {
            affected = try await availabilityResolver.setAvailabilityIntent(intent, itemID: itemID, account: account)
        } else {
            try await metadataStore?.setAvailabilityIntent(intent, accountID: account.metadataID, itemID: itemID)
            affected = [itemID]
        }
        await diagnostics.record(DiagnosticEvent(category: "Files", level: .info, message: "Set \(itemID) availability to \(intent.rawValue) for \(affected.count) item\(affected.count == 1 ? "" : "s")"))
    }

    public func createPublicLink(accountID: UUID, itemID: String, domainID: String? = nil) async throws -> PublicLinkShare {
        guard let publicLinkCreator else {
            throw WesomeCloudError.unsupported("Public link creation is not configured")
        }
        let file = try await requireFile(accountID: accountID, itemID: itemID, domainID: domainID)
        let share = try await publicLinkCreator.createPublicLink(for: file)
        lastCreatedShare = share
        publicLinks.removeAll { $0.accountID == accountID && $0.domainID == domainID && $0.fileID == itemID && $0.share.id == share.id }
        publicLinks.append(AppPublicLink(accountID: accountID, domainID: domainID, fileID: itemID, filePath: file.item.remote.path, accountName: file.accountName, share: share))
        await diagnostics.record(DiagnosticEvent(category: "Sharing", level: .info, message: "Created public link for \(file.item.remote.path)"))
        return share
    }

    public func refreshPublicLinks(accountID: UUID, itemID: String, domainID: String? = nil) async throws -> [AppPublicLink] {
        guard let publicLinkCreator else {
            throw WesomeCloudError.unsupported("Public link management is not configured")
        }
        let file = try await requireFile(accountID: accountID, itemID: itemID, domainID: domainID)
        let shares = try await publicLinkCreator.publicLinks(for: file)
        let links = shares.map {
            AppPublicLink(accountID: accountID, domainID: domainID, fileID: itemID, filePath: file.item.remote.path, accountName: file.accountName, share: $0)
        }
        publicLinks.removeAll { $0.accountID == accountID && $0.domainID == domainID && $0.fileID == itemID }
        publicLinks.append(contentsOf: links)
        await diagnostics.record(DiagnosticEvent(category: "Sharing", level: .info, message: "Loaded \(links.count) public link\(links.count == 1 ? "" : "s") for \(file.item.remote.path)"))
        return links
    }

    public func deletePublicLink(_ link: AppPublicLink) async throws {
        guard let publicLinkCreator else {
            throw WesomeCloudError.unsupported("Public link management is not configured")
        }
        let file = try await requireFile(accountID: link.accountID, itemID: link.fileID, domainID: link.domainID)
        try await publicLinkCreator.deletePublicLink(link.share, for: file)
        publicLinks.removeAll { $0.id == link.id }
        await diagnostics.record(DiagnosticEvent(category: "Sharing", level: .info, message: "Deleted public link \(link.share.id) for \(file.item.remote.path)"))
    }

    public func privateLink(accountID: UUID, itemID: String, domainID: String? = nil) async throws -> URL {
        guard let publicLinkCreator else {
            throw WesomeCloudError.unsupported("Private link management is not configured")
        }
        let file = try await requireFile(accountID: accountID, itemID: itemID, domainID: domainID)
        if let privateLink = file.item.remote.privateLink {
            return privateLink
        }
        let url = try await publicLinkCreator.privateLink(for: file)
        await diagnostics.record(DiagnosticEvent(category: "Sharing", level: .info, message: "Loaded private link for \(file.item.remote.path)"))
        return url
    }

    public func resolveConflict(
        _ conflictID: UUID,
        accountID: UUID,
        domainID: String? = nil,
        decision: ConflictResolutionDecision,
        resolvedName: String? = nil
    ) async throws {
        try validateConflictResolution(decision: decision, resolvedName: resolvedName)
        let account = try await requireAccount(accountID, domainID: domainID)
        if let conflictResolver {
            let conflict = try await requireConflict(conflictID, accountID: account.metadataID)
            try await conflictResolver.resolveConflict(
                conflict,
                account: account,
                decision: decision,
                resolvedName: resolvedName
            )
        } else {
            try await metadataStore?.resolveConflict(
                id: conflictID,
                accountID: account.metadataID,
                decision: decision,
                resolvedName: resolvedName,
                resolvedAt: Date()
            )
        }
        await diagnostics.record(DiagnosticEvent(category: "Conflict", level: .info, message: "Resolved conflict \(conflictID.uuidString) using \(decision.rawValue)"))
    }

    private func validateConflictResolution(decision: ConflictResolutionDecision, resolvedName: String?) throws {
        guard decision == .renameLocal else { return }
        let name = resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            throw WesomeCloudError.invalidFilename(name, .empty)
        }
        if name.contains("/") {
            throw WesomeCloudError.invalidFilename(name, .containsSlash)
        }
        if name.contains(":") {
            throw WesomeCloudError.invalidFilename(name, .containsColon)
        }
        if name.last?.isWhitespace == true || name.hasSuffix(".") {
            throw WesomeCloudError.invalidFilename(name, .trailingWhitespaceOrPeriod)
        }
        if [".", "..", ".DS_Store"].contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw WesomeCloudError.invalidFilename(name, .reservedName)
        }
    }

    private func loadIssues(for accounts: [PersistedAccountRecord]) async throws -> [SyncIssue] {
        guard let metadataStore else { return [] }
        var issues: [SyncIssue] = []
        for account in accounts.flatMap(\.syncLocations) {
            let errors = try await metadataStore.syncErrors(accountID: account.metadataID)
            issues.append(contentsOf: errors.map { SyncIssue(record: $0, account: account) })
        }
        return issues.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func loadFiles(for accounts: [PersistedAccountRecord]) async throws -> [AppFileItem] {
        guard let metadataStore else { return [] }
        var files: [AppFileItem] = []
        for account in accounts.flatMap(\.syncLocations) {
            let items = try await metadataStore.items(accountID: account.metadataID)
            files.append(contentsOf: items.map {
                AppFileItem(
                    accountID: account.id,
                    domainID: account.domain?.id,
                    accountName: account.locationName,
                    serverURL: account.account.serverURL,
                    accountUsername: account.account.username,
                    webDAVRootURL: account.domain?.webDAVRootURL,
                    item: $0
                )
            })
        }
        return files.sorted {
            if $0.accountName != $1.accountName {
                return $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
            }
            return $0.item.remote.path.localizedStandardCompare($1.item.remote.path) == .orderedAscending
        }
    }

    private func loadConflicts(for accounts: [PersistedAccountRecord]) async throws -> [AppConflict] {
        guard let metadataStore else { return [] }
        var conflicts: [AppConflict] = []
        for account in accounts.flatMap(\.syncLocations) {
            let records = try await metadataStore.conflicts(accountID: account.metadataID, state: .pending)
            conflicts.append(contentsOf: records.map { AppConflict(record: $0, account: account) })
        }
        return conflicts.sorted { $0.createdAt > $1.createdAt }
    }

    private func loadTransfers(for accounts: [PersistedAccountRecord]) async throws -> [AppTransfer] {
        guard let metadataStore else { return [] }
        var transfers: [AppTransfer] = []
        for account in accounts.flatMap(\.syncLocations) {
            let records = try await metadataStore.transfers(accountID: account.metadataID)
            transfers.append(contentsOf: records.map {
                AppTransfer(accountID: account.id, accountName: account.locationName, transfer: $0)
            })
        }
        return transfers.sorted { $0.transfer.updatedAt > $1.transfer.updatedAt }
    }

    private func loadStorage(for accounts: [PersistedAccountRecord]) async throws -> [AppAccountStorage] {
        guard let metadataStore else { return [] }
        var storage: [AppAccountStorage] = []
        for account in accounts.flatMap(\.syncLocations) {
            let root = try await metadataStore.items(accountID: account.metadataID).first {
                $0.remote.path == "/" || $0.remote.parentID == nil && $0.remote.name == "Root"
            }
            guard let usedBytes = root?.remote.quotaUsedBytes else { continue }
            storage.append(AppAccountStorage(
                accountID: account.id,
                domainID: account.domain?.id,
                accountName: account.locationName,
                usedBytes: usedBytes,
                availableBytes: root?.remote.quotaAvailableBytes
            ))
        }
        return storage.sorted { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }
    }

    private func removeLocalContent(for accountID: UUID) async throws {
        guard let metadataStore else { return }
        let items = try await metadataStore.items(accountID: accountID)
        let transfers = try await metadataStore.transfers(accountID: accountID)
        var urls = Set<URL>()
        for item in items {
            guard let materializedURL = item.materializedURL else { continue }
            urls.insert(materializedURL)
            urls.insert(materializedURL.appendingPathExtension("part"))
        }
        for transfer in transfers {
            if let localURL = transfer.localURL {
                urls.insert(localURL)
            }
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func requireAccount(_ accountID: UUID, domainID: String? = nil) async throws -> PersistedAccountRecord {
        let accounts = try await repository.records()
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw WesomeCloudError.missingItem(accountID.uuidString)
        }
        guard let domainID else { return account }
        guard let domain = account.domains.first(where: { $0.id == domainID }) else {
            throw WesomeCloudError.missingItem(domainID)
        }
        return account.selecting(domain)
    }

    private func requireFile(accountID: UUID, itemID: String, domainID: String? = nil) async throws -> AppFileItem {
        guard let metadataStore else { throw WesomeCloudError.missingItem(itemID) }
        let account = try await requireAccount(accountID, domainID: domainID)
        guard let item = try await metadataStore.item(accountID: account.metadataID, id: itemID) else {
            throw WesomeCloudError.missingItem(itemID)
        }
        return AppFileItem(
            accountID: accountID,
            domainID: domainID,
            accountName: account.locationName,
            serverURL: account.account.serverURL,
            accountUsername: account.account.username,
            webDAVRootURL: account.domain?.webDAVRootURL,
            item: item
        )
    }

    private func requireConflict(_ conflictID: UUID, accountID: UUID) async throws -> ConflictRecord {
        guard let metadataStore else { throw WesomeCloudError.missingItem(conflictID.uuidString) }
        let conflicts = try await metadataStore.conflicts(accountID: accountID, state: .pending)
        guard let conflict = conflicts.first(where: { $0.id == conflictID }) else {
            throw WesomeCloudError.missingItem(conflictID.uuidString)
        }
        return conflict
    }
}
