import Foundation
import Observation
import OwnCloudKit
import SyncStore
import WesomeCloudAppCore
import WesomeCloudShared

#if canImport(AppKit)
import AppKit
#endif

public protocol ClipboardWriting: Sendable {
    func copy(_ string: String)
}

public protocol FileRevealing: Sendable {
    func reveal(_ url: URL)
}

public protocol URLOpening: Sendable {
    func open(_ url: URL)
}

public struct SystemClipboardWriter: ClipboardWriting {
    public init() {}

    public func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

public struct SystemFileRevealer: FileRevealing {
    public init() {}

    public func reveal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

public struct SystemURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

public protocol ManualSyncRunning: Sendable {
    func syncNow(accounts: [PersistedAccountRecord]) async throws
}

public struct DashboardContent: Equatable, Sendable {
    public var accounts: [PersistedAccountRecord]
    public var spaces: [AppSpace]
    public var notifications: [AppNotification]
    public var files: [AppFileItem]
    public var issues: [SyncIssue]
    public var conflicts: [AppConflict]
    public var transfers: [AppTransfer]
    public var storage: [AppAccountStorage]
    public var publicLinks: [AppPublicLink]
    public var diagnostics: [DiagnosticEvent]
    public var updateStatus: UpdateStatus?
    public var lastCreatedShare: PublicLinkShare?
    public var lastErrorMessage: String?
    public var lastDiagnosticsExportURL: URL?

    public init(
        accounts: [PersistedAccountRecord] = [],
        spaces: [AppSpace] = [],
        notifications: [AppNotification] = [],
        files: [AppFileItem] = [],
        issues: [SyncIssue] = [],
        conflicts: [AppConflict] = [],
        transfers: [AppTransfer] = [],
        storage: [AppAccountStorage] = [],
        publicLinks: [AppPublicLink] = [],
        diagnostics: [DiagnosticEvent] = [],
        updateStatus: UpdateStatus? = nil,
        lastCreatedShare: PublicLinkShare? = nil,
        lastErrorMessage: String? = nil,
        lastDiagnosticsExportURL: URL? = nil
    ) {
        self.accounts = accounts
        self.spaces = spaces
        self.notifications = notifications
        self.files = files
        self.issues = issues
        self.conflicts = conflicts
        self.transfers = transfers
        self.storage = storage
        self.publicLinks = publicLinks
        self.diagnostics = diagnostics
        self.updateStatus = updateStatus
        self.lastCreatedShare = lastCreatedShare
        self.lastErrorMessage = lastErrorMessage
        self.lastDiagnosticsExportURL = lastDiagnosticsExportURL
    }

    public func filtered(selectedAccountID: UUID?) -> DashboardContent {
        guard let selectedAccountID else { return self }
        return DashboardContent(
            accounts: accounts.filter { $0.id == selectedAccountID },
            spaces: spaces.filter { $0.accountID == selectedAccountID },
            notifications: notifications.filter { $0.accountID == selectedAccountID },
            files: files.filter { $0.accountID == selectedAccountID },
            issues: issues.filter { $0.accountID == selectedAccountID },
            conflicts: conflicts.filter { $0.accountID == selectedAccountID },
            transfers: transfers.filter { $0.accountID == selectedAccountID },
            storage: storage.filter { $0.accountID == selectedAccountID },
            publicLinks: publicLinks.filter { $0.accountID == selectedAccountID },
            diagnostics: diagnostics,
            updateStatus: updateStatus,
            lastCreatedShare: lastCreatedShare,
            lastErrorMessage: lastErrorMessage,
            lastDiagnosticsExportURL: lastDiagnosticsExportURL
        )
    }
}

@MainActor
@Observable
public final class WesomeCloudViewModel {
    public private(set) var accounts: [PersistedAccountRecord] = []
    public private(set) var spaces: [AppSpace] = []
    public private(set) var notifications: [AppNotification] = []
    public private(set) var diagnostics: [DiagnosticEvent] = []
    public private(set) var files: [AppFileItem] = []
    public private(set) var issues: [SyncIssue] = [] {
        didSet { tracking.captureSyncIssues(issues) }
    }
    public private(set) var conflicts: [AppConflict] = []
    public private(set) var transfers: [AppTransfer] = []
    public private(set) var storage: [AppAccountStorage] = []
    public private(set) var publicLinks: [AppPublicLink] = []
    public private(set) var updateStatus: UpdateStatus?
    public private(set) var lastCreatedShare: PublicLinkShare?
    public private(set) var lastCopiedPublicLink: PublicLinkShare?
    public private(set) var lastCopiedPrivateLink: URL?
    public private(set) var lastRevealedURL: URL?
    public private(set) var isLoading = false
    public private(set) var lastErrorMessage: String?
    public private(set) var preferences = AppPreferences()
    public private(set) var lastDiagnosticsExportURL: URL?

    private let model: WesomeCloudAppModel
    private let clipboard: ClipboardWriting
    private let fileRevealer: FileRevealing
    private let urlOpener: URLOpening
    private let manualSync: ManualSyncRunning?
    public let tracking: PostHogTracking
    public private(set) var trackingPreferencesLoaded = false
    public private(set) var isSavingTrackingConsent = false
    private var isSavingPreferences = false
    private var trackingConsentSaveWaiter: CheckedContinuation<Void, Never>?
    private var isInitializingTracking = false

    public init(
        model: WesomeCloudAppModel,
        clipboard: ClipboardWriting = SystemClipboardWriter(),
        fileRevealer: FileRevealing = SystemFileRevealer(),
        urlOpener: URLOpening = SystemURLOpener(),
        manualSync: ManualSyncRunning? = nil,
        tracking: PostHogTracking = PostHogTracking()
    ) {
        self.model = model
        self.clipboard = clipboard
        self.fileRevealer = fileRevealer
        self.urlOpener = urlOpener
        self.manualSync = manualSync
        self.tracking = tracking
    }

    public func initializeTracking() async {
        guard !trackingPreferencesLoaded, !isInitializingTracking else { return }
        isInitializingTracking = true
        defer { isInitializingTracking = false }
        do {
            preferences = try await model.loadPreferences()
            tracking.setConsent(preferences.trackingConsent)
            trackingPreferencesLoaded = true
            tracking.capture(.appOpened)
        } catch {
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func setTrackingConsent(_ consent: TrackingConsent) async -> Bool {
        guard consent != .notAsked, !isSavingTrackingConsent else { return false }
        // Revocation takes effect before disk I/O, including when persistence fails.
        if consent != .allowed { tracking.setConsent(consent) }
        isSavingTrackingConsent = true
        defer { isSavingTrackingConsent = false }
        if isSavingPreferences {
            await withCheckedContinuation { trackingConsentSaveWaiter = $0 }
        }
        do {
            var updated = try await model.loadPreferences()
            updated.trackingConsent = consent
            try await model.savePreferences(updated)
            preferences = updated
            tracking.setConsent(consent)
            trackingPreferencesLoaded = true
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
            return false
        }
    }

    public func dashboardContent(selectedAccountID: UUID?) -> DashboardContent {
        DashboardContent(
            accounts: accounts,
            spaces: spaces,
            notifications: notifications,
            files: files,
            issues: issues,
            conflicts: conflicts,
            transfers: transfers,
            storage: storage,
            publicLinks: publicLinks,
            diagnostics: diagnostics,
            updateStatus: updateStatus,
            lastCreatedShare: lastCreatedShare,
            lastErrorMessage: lastErrorMessage,
            lastDiagnosticsExportURL: lastDiagnosticsExportURL
        ).filtered(selectedAccountID: selectedAccountID)
    }

    public func restoreFinderLocations() async {
        let trackingSession = tracking.sessionID
        tracking.capture(.restoreFinderLocations)
        do {
            try await model.restoreFinderLocations()
        } catch {
            tracking.captureError(error, operation: .restoreFinderLocations, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func refresh() async {
        let trackingSession = tracking.sessionID
        tracking.capture(.refresh)
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .refresh, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func syncNow() async {
        let trackingSession = tracking.sessionID
        tracking.capture(.syncNow)
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await model.loadSnapshot()
            if let manualSync {
                try await manualSync.syncNow(accounts: snapshot.accounts)
            }
            let refreshed = try await model.loadSnapshot()
            accounts = refreshed.accounts
            spaces = refreshed.spaces
            notifications = refreshed.notifications
            files = refreshed.files
            diagnostics = refreshed.diagnostics
            issues = refreshed.issues
            conflicts = refreshed.conflicts
            transfers = refreshed.transfers
            storage = refreshed.storage
            publicLinks = refreshed.publicLinks
            updateStatus = refreshed.updateStatus
            lastCreatedShare = refreshed.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .syncNow, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func addAccount(serverURL: URL, username: String, appPassword: String) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.addAccount)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await model.addAccount(serverURL: serverURL, username: username, appPassword: appPassword)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .addAccount, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func addOAuthAccount(serverURL: URL, authenticator: OAuthAuthenticating) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.addOAuthAccount)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await model.addOAuthAccount(serverURL: serverURL, authenticator: authenticator)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .addOAuthAccount, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func reconnectAccount(_ accountID: UUID, appPassword: String) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.reconnectAccount)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await model.reconnectAccount(accountID: accountID, appPassword: appPassword)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .reconnectAccount, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func syncSpace(_ space: AppSpace) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.syncSpace)
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await model.syncSpace(space)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .syncSpace, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func removeSpace(_ space: AppSpace) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.removeSpace)
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.removeSpace(space)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .removeSpace, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func dismissNotification(_ notification: AppNotification) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.dismissNotification)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.dismissNotification(notification)
            let snapshot = try await model.loadSnapshot()
            notifications = snapshot.notifications
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .dismissNotification, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func removeAccount(_ accountID: UUID) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.removeAccount)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.removeAccount(accountID: accountID)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            preferences = try await model.loadPreferences()
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .removeAccount, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func savePreferences(_ preferences: AppPreferences) async {
        guard !isSavingTrackingConsent, !isSavingPreferences else { return }
        isSavingPreferences = true
        defer {
            isSavingPreferences = false
            trackingConsentSaveWaiter?.resume()
            trackingConsentSaveWaiter = nil
        }
        let trackingSession = tracking.sessionID
        isLoading = true
        defer { isLoading = false }
        do {
            var preferences = preferences
            preferences.trackingConsent = try await model.loadPreferences().trackingConsent
            try await model.savePreferences(preferences)
            self.preferences = preferences
            tracking.capture(.savePreferences)
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .savePreferences, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func setSyncPaused(_ isPaused: Bool) async {
        var updated = preferences
        updated.sync.isSyncPaused = isPaused
        await savePreferences(updated)
    }

    public func toggleSyncPaused() async {
        await setSyncPaused(!preferences.sync.isSyncPaused)
    }

    public func exportDiagnostics(to directory: URL) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.exportDiagnostics)
        isLoading = true
        defer { isLoading = false }
        do {
            lastDiagnosticsExportURL = try await model.exportDiagnostics(to: directory)
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .exportDiagnostics, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func revealDiagnosticsExport() {
        guard let lastDiagnosticsExportURL else {
            lastErrorMessage = "No diagnostics export is available."
            return
        }
        fileRevealer.reveal(lastDiagnosticsExportURL)
        lastRevealedURL = lastDiagnosticsExportURL
        lastErrorMessage = nil
    }

    public func clearIssue(_ issue: SyncIssue) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.clearIssue)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.clearIssue(issue.id, accountID: issue.accountID, domainID: issue.domainID)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .clearIssue, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func resolveConflict(_ conflict: AppConflict, decision: ConflictResolutionDecision, resolvedName: String? = nil) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.resolveConflict)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.resolveConflict(conflict.id, accountID: conflict.accountID, domainID: conflict.domainID, decision: decision, resolvedName: resolvedName)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .resolveConflict, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func checkForUpdates() async {
        let trackingSession = tracking.sessionID
        tracking.capture(.checkForUpdates)
        isLoading = true
        defer { isLoading = false }
        do {
            updateStatus = try await model.checkForUpdates()
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            diagnostics = snapshot.diagnostics
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .checkForUpdates, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func setAvailabilityIntent(_ intent: AvailabilityIntent, for file: AppFileItem) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.setAvailabilityIntent)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.setAvailabilityIntent(intent, accountID: file.accountID, itemID: file.item.remote.id, domainID: file.domainID)
            let snapshot = try await model.loadSnapshot()
            accounts = snapshot.accounts
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            files = snapshot.files
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastCreatedShare = snapshot.lastCreatedShare
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .setAvailabilityIntent, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func createPublicLink(for file: AppFileItem) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.createPublicLink)
        isLoading = true
        defer { isLoading = false }
        do {
            lastCreatedShare = try await model.createPublicLink(accountID: file.accountID, itemID: file.item.remote.id, domainID: file.domainID)
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            diagnostics = snapshot.diagnostics
            lastCreatedShare = snapshot.lastCreatedShare
            publicLinks = snapshot.publicLinks
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            updateStatus = snapshot.updateStatus
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .createPublicLink, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func refreshPublicLinks(for file: AppFileItem) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.refreshPublicLinks)
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await model.refreshPublicLinks(accountID: file.accountID, itemID: file.item.remote.id, domainID: file.domainID)
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            publicLinks = snapshot.publicLinks
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            updateStatus = snapshot.updateStatus
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .refreshPublicLinks, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func deletePublicLink(_ link: AppPublicLink) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.deletePublicLink)
        isLoading = true
        defer { isLoading = false }
        do {
            try await model.deletePublicLink(link)
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            publicLinks = snapshot.publicLinks
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            updateStatus = snapshot.updateStatus
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .deletePublicLink, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

    public func copyPublicLink(_ link: AppPublicLink) {
        tracking.capture(.copyPublicLink)
        clipboard.copy(link.share.url.absoluteString)
        lastCopiedPublicLink = link.share
        lastErrorMessage = nil
    }

    public func revealInFinder(_ file: AppFileItem) {
        tracking.capture(.revealInFinder)
        guard let url = file.item.materializedURL else {
            lastErrorMessage = "File is not downloaded yet."
            return
        }
        fileRevealer.reveal(url)
        lastRevealedURL = url
        lastErrorMessage = nil
    }

    public func openServerInBrowser(_ account: PersistedAccountRecord) {
        tracking.capture(.openServerInBrowser)
        urlOpener.open(account.account.serverURL)
        lastErrorMessage = nil
    }

    public func copyPrivateLink(for file: AppFileItem) async {
        let trackingSession = tracking.sessionID
        tracking.capture(.copyPrivateLink)
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await model.privateLink(accountID: file.accountID, itemID: file.item.remote.id, domainID: file.domainID)
            clipboard.copy(url.absoluteString)
            lastCopiedPrivateLink = url
            let snapshot = try await model.loadSnapshot()
            spaces = snapshot.spaces
            notifications = snapshot.notifications
            diagnostics = snapshot.diagnostics
            issues = snapshot.issues
            conflicts = snapshot.conflicts
            transfers = snapshot.transfers
            storage = snapshot.storage
            publicLinks = snapshot.publicLinks
            updateStatus = snapshot.updateStatus
            lastErrorMessage = nil
        } catch {
            tracking.captureError(error, operation: .copyPrivateLink, sessionID: trackingSession)
            lastErrorMessage = UserFacingErrorFormatter.message(for: error)
        }
    }

}

public struct SyncIssueRowViewModel: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountName: String
    public var title: String
    public var detail: String
    public var isRecoverable: Bool

    public init(issue: SyncIssue) {
        self.id = issue.id
        self.accountName = issue.accountName
        self.title = switch issue.scope {
        case .account: "Account issue"
        case .item: "File issue"
        case .operation: "Queued operation issue"
        }
        var components = [issue.message]
        if let itemID = issue.itemID {
            components.append("Item \(itemID)")
        }
        if let operationID = issue.operationID {
            components.append("Operation \(operationID.uuidString)")
        }
        self.detail = components.joined(separator: " • ")
        self.isRecoverable = issue.isRecoverable
    }
}

public extension SyncIssue {
    var rowViewModel: SyncIssueRowViewModel {
        SyncIssueRowViewModel(issue: self)
    }
}

public struct ConflictRowViewModel: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountName: String
    public var title: String
    public var detail: String
    public var suggestedRename: String

    public init(conflict: AppConflict) {
        self.id = conflict.id
        self.accountName = conflict.accountName
        self.title = switch conflict.conflict.kind {
        case .remoteChangedDuringLocalEdit: "Remote changed"
        case .remoteDeletedDuringLocalEdit: "Remote deleted"
        case .nameCollision: "Name collision"
        case .caseOnlyRename: "Case-only rename"
        case .unicodeNormalization: "Unicode normalization"
        case .typeChanged: "Type changed"
        }
        var components = [conflict.conflict.message]
        if let localPath = conflict.conflict.localPath {
            components.append("Local \(localPath)")
        }
        if let remotePath = conflict.conflict.remotePath {
            components.append("Remote \(remotePath)")
        }
        self.detail = components.joined(separator: " • ")
        self.suggestedRename = "\(conflict.conflict.itemID)-local"
    }
}

public extension AppConflict {
    var rowViewModel: ConflictRowViewModel {
        ConflictRowViewModel(conflict: self)
    }
}

public struct FileItemRowViewModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var accountName: String
    public var filename: String
    public var path: String
    public var kind: RemoteItemKind
    public var availabilityText: String
    public var materializationText: String
    public var isDownloaded: Bool

    public init(file: AppFileItem) {
        self.id = file.id
        self.accountName = file.accountName
        self.filename = file.item.remote.name
        self.path = file.item.remote.path
        self.kind = file.item.remote.kind
        self.availabilityText = switch file.item.availabilityIntent {
        case .inherited: "Inherited"
        case .unspecified: "System Managed"
        case .alwaysLocal: "Keep Downloaded"
        case .onlineOnly: "Online Only"
        }
        self.isDownloaded = file.item.materializedURL != nil
        self.materializationText = isDownloaded ? "Downloaded" : "Dataless"
    }
}

public extension AppFileItem {
    var rowViewModel: FileItemRowViewModel {
        FileItemRowViewModel(file: self)
    }
}

public struct PublicLinkRowViewModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var accountName: String
    public var filePath: String
    public var urlText: String

    public init(link: AppPublicLink) {
        self.id = link.id
        self.accountName = link.accountName
        self.filePath = link.filePath
        self.urlText = link.share.url.absoluteString
    }
}

public extension AppPublicLink {
    var rowViewModel: PublicLinkRowViewModel {
        PublicLinkRowViewModel(link: self)
    }
}

public struct NotificationRowViewModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var accountName: String
    public var subject: String
    public var detail: String
    public var dateText: String

    public init(notification: AppNotification) {
        self.id = notification.id
        self.accountName = notification.accountName
        let userNotification = notification.notification
        self.subject = userNotification.subject.isEmpty ? "Server notification" : userNotification.subject
        var components: [String] = []
        if !userNotification.message.isEmpty {
            components.append(userNotification.message)
        }
        if !userNotification.app.isEmpty {
            components.append(userNotification.app)
        }
        if !userNotification.objectType.isEmpty {
            components.append(userNotification.objectType)
        }
        self.detail = components.isEmpty ? "No details" : components.joined(separator: " • ")
        if let date = userNotification.date {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            self.dateText = formatter.localizedString(for: date, relativeTo: Date())
        } else {
            self.dateText = ""
        }
    }
}

public extension AppNotification {
    var rowViewModel: NotificationRowViewModel {
        NotificationRowViewModel(notification: self)
    }
}

public struct SpaceRowViewModel: Equatable, Identifiable, Sendable {
    public var id: String
    public var accountName: String
    public var name: String
    public var detail: String
    public var quotaText: String
    public var isSelected: Bool

    public init(space: AppSpace) {
        self.id = space.id
        self.isSelected = space.isSelected
        self.accountName = space.accountName
        self.name = space.space.name
        let type = space.space.driveType ?? "space"
        if let alias = space.space.driveAlias, !alias.isEmpty {
            self.detail = "\(type) • \(alias)"
        } else {
            self.detail = type
        }
        if let quota = space.space.quota, let used = quota.used, let total = quota.total, total > 0 {
            self.quotaText = "\(Self.format(bytes: used)) of \(Self.format(bytes: total))"
        } else if let state = space.space.quota?.state {
            self.quotaText = state
        } else {
            self.quotaText = "Unknown"
        }
    }

    private static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension AppSpace {
    public var rowViewModel: SpaceRowViewModel {
        SpaceRowViewModel(space: self)
    }
}

public struct TransferRowViewModel: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountName: String
    public var title: String
    public var detail: String
    public var phaseText: String
    public var progress: Double?

    public init(transfer: AppTransfer) {
        let record = transfer.transfer
        self.id = record.id
        self.accountName = transfer.accountName
        self.title = "\(record.direction.displayName) \(record.remotePath)"
        self.phaseText = record.phase.displayName
        self.progress = Self.progress(bytesTransferred: record.bytesTransferred, totalBytes: record.totalBytes)
        var components = [Self.byteSummary(bytesTransferred: record.bytesTransferred, totalBytes: record.totalBytes)]
        if let lastError = record.lastErrorDescription, !lastError.isEmpty {
            components.append(lastError)
        }
        self.detail = components.joined(separator: " • ")
    }

    private static func progress(bytesTransferred: Int64, totalBytes: Int64?) -> Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }

    private static func byteSummary(bytesTransferred: Int64, totalBytes: Int64?) -> String {
        let transferred = byteText(bytesTransferred)
        guard let totalBytes else { return transferred }
        return "\(transferred) of \(byteText(totalBytes))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private extension TransferDirection {
    var displayName: String {
        switch self {
        case .download: "Downloading"
        case .upload: "Uploading"
        }
    }
}

private extension TransferPhase {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

public extension AppTransfer {
    var rowViewModel: TransferRowViewModel {
        TransferRowViewModel(transfer: self)
    }
}

public struct AccountStorageRowViewModel: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var summaryText: String
    public var progress: Double?

    public init(storage: AppAccountStorage) {
        self.id = storage.accountID
        if let available = storage.availableBytes, available >= 0 {
            let total = storage.usedBytes + available
            self.summaryText = "\(Self.byteText(storage.usedBytes)) of \(Self.byteText(total))"
            self.progress = total > 0 ? min(1, max(0, Double(storage.usedBytes) / Double(total))) : nil
        } else {
            self.summaryText = "\(Self.byteText(storage.usedBytes)) used"
            self.progress = nil
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

public extension AppAccountStorage {
    var rowViewModel: AccountStorageRowViewModel {
        AccountStorageRowViewModel(storage: self)
    }
}

public struct AccountRowViewModel: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var subtitle: String
    public var statusText: String
    public var statusState: SyncStatusState

    public init(record: PersistedAccountRecord) {
        self.id = record.id
        self.title = record.account.displayName
        self.subtitle = "\(record.account.username) • \(record.account.serverURL.host() ?? record.account.serverURL.absoluteString)"
        self.statusText = record.lastSyncStatus.message
        self.statusState = record.lastSyncStatus.state
    }
}

public extension PersistedAccountRecord {
    var rowViewModel: AccountRowViewModel {
        AccountRowViewModel(record: self)
    }
}

@MainActor
@Observable
public final class AccountSetupFormModel {
    public var mode = AccountSetupMode.appPassword
    public var serverURLText = ""
    public var username = ""
    public var appPassword = ""
    public private(set) var validationMessage: String?

    public init() {}

    public var canSubmit: Bool {
        validatedInput() != nil
    }

    public func validatedInput() -> AccountSetupInput? {
        let trimmedURL = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            return nil
        }
        if mode == .oauth {
            return AccountSetupInput(mode: mode, serverURL: url, username: "", appPassword: "")
        }
        guard !trimmedUsername.isEmpty else { return nil }
        guard !appPassword.isEmpty else { return nil }
        return AccountSetupInput(mode: mode, serverURL: url, username: trimmedUsername, appPassword: appPassword)
    }

    public func validateForSubmit() -> AccountSetupInput? {
        guard let input = validatedInput() else {
            validationMessage = mode == .oauth
                ? "Enter a valid server URL."
                : "Enter a valid server URL, username, and app password."
            return nil
        }
        validationMessage = nil
        return input
    }

    public func reset() {
        serverURLText = ""
        username = ""
        appPassword = ""
        mode = .appPassword
        validationMessage = nil
    }
}

public enum AccountSetupMode: String, Equatable, Sendable, CaseIterable {
    case appPassword
    case oauth
}

public struct AccountSetupInput: Equatable, Sendable {
    public var mode: AccountSetupMode
    public var serverURL: URL
    public var username: String
    public var appPassword: String

    public init(mode: AccountSetupMode = .appPassword, serverURL: URL, username: String, appPassword: String) {
        self.mode = mode
        self.serverURL = serverURL
        self.username = username
        self.appPassword = appPassword
    }
}

@MainActor
@Observable
public final class PreferencesFormModel {
    public var isSyncPaused: Bool
    public var pollInterval: Double
    public var queueInterval: Double
    public var retryMaximumAttempts: Int
    public var maximumConcurrentTransfers: Int
    public var defaultAvailability: DefaultAvailability
    public var showHiddenFiles: Bool
    public var ignoredFilenamePatternsText: String
    public var excludedRemotePathsText: String
    public var retainEventLimit: Int
    public var includeDebugEvents: Bool
    public var automaticallyCheckForUpdates: Bool
    public var appcastURLText: String
    public var updateCheckInterval: Double

    public init(preferences: AppPreferences = AppPreferences()) {
        self.isSyncPaused = preferences.sync.isSyncPaused
        self.pollInterval = preferences.sync.pollInterval
        self.queueInterval = preferences.sync.queueInterval
        self.retryMaximumAttempts = preferences.sync.retryMaximumAttempts
        self.maximumConcurrentTransfers = preferences.sync.maximumConcurrentTransfers
        self.defaultAvailability = preferences.files.defaultAvailability
        self.showHiddenFiles = preferences.files.showHiddenFiles
        self.ignoredFilenamePatternsText = preferences.files.ignoredFilenamePatterns.joined(separator: "\n")
        self.excludedRemotePathsText = preferences.files.excludedRemotePaths.joined(separator: "\n")
        self.retainEventLimit = preferences.diagnostics.retainEventLimit
        self.includeDebugEvents = preferences.diagnostics.includeDebugEvents
        self.automaticallyCheckForUpdates = preferences.updates.automaticallyCheckForUpdates
        self.appcastURLText = preferences.updates.appcastURL?.absoluteString ?? ""
        self.updateCheckInterval = preferences.updates.checkInterval
    }

    public func update(from preferences: AppPreferences) {
        isSyncPaused = preferences.sync.isSyncPaused
        pollInterval = preferences.sync.pollInterval
        queueInterval = preferences.sync.queueInterval
        retryMaximumAttempts = preferences.sync.retryMaximumAttempts
        maximumConcurrentTransfers = preferences.sync.maximumConcurrentTransfers
        defaultAvailability = preferences.files.defaultAvailability
        showHiddenFiles = preferences.files.showHiddenFiles
        ignoredFilenamePatternsText = preferences.files.ignoredFilenamePatterns.joined(separator: "\n")
        excludedRemotePathsText = preferences.files.excludedRemotePaths.joined(separator: "\n")
        retainEventLimit = preferences.diagnostics.retainEventLimit
        includeDebugEvents = preferences.diagnostics.includeDebugEvents
        automaticallyCheckForUpdates = preferences.updates.automaticallyCheckForUpdates
        appcastURLText = preferences.updates.appcastURL?.absoluteString ?? ""
        updateCheckInterval = preferences.updates.checkInterval
    }

    public var preferences: AppPreferences {
        AppPreferences(
            sync: SyncPreferences(
                isSyncPaused: isSyncPaused,
                pollInterval: max(15, pollInterval),
                queueInterval: max(5, queueInterval),
                retryMaximumAttempts: max(1, retryMaximumAttempts),
                maximumConcurrentTransfers: max(1, maximumConcurrentTransfers)
            ),
            files: FilePreferences(
                defaultAvailability: defaultAvailability,
                showHiddenFiles: showHiddenFiles,
                ignoredFilenamePatterns: ignoredFilenamePatterns,
                excludedRemotePaths: excludedRemotePaths
            ),
            diagnostics: DiagnosticPreferences(retainEventLimit: max(50, retainEventLimit), includeDebugEvents: includeDebugEvents),
            updates: UpdatePreferences(
                automaticallyCheckForUpdates: automaticallyCheckForUpdates,
                appcastURL: URL(string: appcastURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
                checkInterval: max(3600, updateCheckInterval)
            )
        )
    }

    private var ignoredFilenamePatterns: [String] {
        ignoredFilenamePatternsText
            .split { $0 == "\n" || $0 == "," || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var excludedRemotePaths: [String] {
        excludedRemotePathsText
            .split { $0 == "\n" || $0 == "," || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
