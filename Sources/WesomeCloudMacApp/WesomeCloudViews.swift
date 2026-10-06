import SwiftUI
import OwnCloudKit
import SyncStore
import WesomeCloudAppCore
import WesomeCloudShared

public struct WesomeCloudRootView: View {
    @Bindable private var viewModel: WesomeCloudViewModel
    private let oauthAuthenticator: (URL) -> OAuthAuthenticating
    private let settingsRequestCount: Int
    @State private var setupForm = AccountSetupFormModel()
    @State private var preferencesForm = PreferencesFormModel()
    @State private var reconnectPassword = ""
    @State private var reconnectingAccount: PersistedAccountRecord?
    @State private var spacePendingRemoval: AppSpace?
    @State private var accountPendingRemoval: PersistedAccountRecord?
    @State private var selectedAccountID: UUID?
    @State private var showingSetup = false
    @State private var showingSettings = false
    @State private var showingTrackingConsent = false

    public init(
        viewModel: WesomeCloudViewModel,
        settingsRequestCount: Int = 0,
        oauthAuthenticator: @escaping (URL) -> OAuthAuthenticating = { _ in
            ProductionOAuthAuthenticatorFactory().makeAuthenticator()
        }
    ) {
        self.viewModel = viewModel
        self.settingsRequestCount = settingsRequestCount
        self.oauthAuthenticator = oauthAuthenticator
    }

    public var body: some View {
        let dashboard = viewModel.dashboardContent(selectedAccountID: selectedAccountID)
        NavigationSplitView {
            List(selection: $selectedAccountID) {
                Text("All Accounts")
                    .tag(UUID?.none)
                ForEach(viewModel.accounts.map(\.rowViewModel)) { account in
                    AccountSidebarRow(account: account)
                        .tag(UUID?.some(account.id))
                }
            }
            .navigationTitle("WesomeCloud")
            .toolbar {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                Button {
                    showingSetup = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                Button {
                    preferencesForm.update(from: viewModel.preferences)
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    Task {
                        await viewModel.exportDiagnostics(to: FileManager.default.temporaryDirectory)
                    }
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await viewModel.checkForUpdates() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.down.circle")
                }
                .disabled(viewModel.isLoading)
            }
        } detail: {
            DashboardView(
                accounts: dashboard.accounts,
                spaces: dashboard.spaces,
                notifications: dashboard.notifications,
                storage: dashboard.storage,
                files: dashboard.files,
                diagnostics: dashboard.diagnostics,
                issues: dashboard.issues,
                conflicts: dashboard.conflicts,
                transfers: dashboard.transfers,
                publicLinks: dashboard.publicLinks,
                updateStatus: dashboard.updateStatus,
                errorMessage: dashboard.lastErrorMessage,
                diagnosticsExportURL: dashboard.lastDiagnosticsExportURL,
                lastCreatedShare: dashboard.lastCreatedShare,
                reconnectAccount: { account in
                    reconnectPassword = ""
                    reconnectingAccount = account
                },
                openServerInBrowser: { account in
                    viewModel.openServerInBrowser(account)
                },
                removeAccount: { account in
                    accountPendingRemoval = account
                },
                syncSpace: { space in
                    Task { await viewModel.syncSpace(space) }
                },
                removeSpace: { space in spacePendingRemoval = space },
                dismissNotification: { notification in
                    Task { await viewModel.dismissNotification(notification) }
                },
                clearIssue: { issue in
                    Task { await viewModel.clearIssue(issue) }
                },
                resolveConflict: { conflict, decision, resolvedName in
                    Task { await viewModel.resolveConflict(conflict, decision: decision, resolvedName: resolvedName) }
                },
                setAvailabilityIntent: { file, intent in
                    Task { await viewModel.setAvailabilityIntent(intent, for: file) }
                },
                createPublicLink: { file in
                    Task { await viewModel.createPublicLink(for: file) }
                },
                refreshPublicLinks: { file in
                    Task { await viewModel.refreshPublicLinks(for: file) }
                },
                copyPrivateLink: { file in
                    Task { await viewModel.copyPrivateLink(for: file) }
                },
                revealInFinder: { file in
                    viewModel.revealInFinder(file)
                },
                revealDiagnosticsExport: {
                    viewModel.revealDiagnosticsExport()
                },
                copyPublicLink: { link in
                    viewModel.copyPublicLink(link)
                },
                deletePublicLink: { link in
                    Task { await viewModel.deletePublicLink(link) }
                }
            )
        }
        .task {
            await viewModel.initializeTracking()
            showingTrackingConsent = viewModel.trackingPreferencesLoaded && viewModel.tracking.consent == .notAsked
            await viewModel.refresh()
        }
        .onChange(of: viewModel.accounts.map(\.id)) { _, accountIDs in
            if let selectedAccountID, !accountIDs.contains(selectedAccountID) {
                self.selectedAccountID = nil
            }
            if let accountPendingRemoval, !accountIDs.contains(accountPendingRemoval.id) {
                self.accountPendingRemoval = nil
            }
        }
        .onChange(of: settingsRequestCount) { _, _ in
            preferencesForm.update(from: viewModel.preferences)
            showingSettings = true
        }
        .sheet(isPresented: $showingTrackingConsent) {
            TrackingConsentView(
                isSaving: viewModel.isSavingTrackingConsent,
                errorMessage: viewModel.lastErrorMessage
            ) { consent in
                if await viewModel.setTrackingConsent(consent) { showingTrackingConsent = false }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingSetup) {
            AccountSetupView(form: setupForm) { input in
                switch input.mode {
                case .appPassword:
                    await viewModel.addAccount(
                        serverURL: input.serverURL,
                        username: input.username,
                        appPassword: input.appPassword
                    )
                case .oauth:
                    await viewModel.addOAuthAccount(
                        serverURL: input.serverURL,
                        authenticator: oauthAuthenticator(input.serverURL)
                    )
                }
                if viewModel.lastErrorMessage == nil {
                    setupForm.reset()
                    showingSetup = false
                }
            }
            .frame(width: 460)
        }
        .sheet(isPresented: $showingSettings) {
            PreferencesView(
                form: preferencesForm,
                trackingConsent: viewModel.tracking.consent,
                isSavingTrackingConsent: viewModel.isSavingTrackingConsent,
                trackingErrorMessage: viewModel.lastErrorMessage,
                changeTrackingConsent: { await viewModel.setTrackingConsent($0) }
            ) { preferences in
                await viewModel.savePreferences(preferences)
                if viewModel.lastErrorMessage == nil {
                    showingSettings = false
                }
            }
            .frame(width: 520)
        }
        .sheet(item: $reconnectingAccount) { account in
            ReconnectAccountView(account: account, appPassword: $reconnectPassword) {
                await viewModel.reconnectAccount(account.id, appPassword: reconnectPassword)
                if viewModel.lastErrorMessage == nil {
                    reconnectPassword = ""
                    reconnectingAccount = nil
                }
            }
            .frame(width: 420)
        }
        .confirmationDialog(
            "Remove \(spacePendingRemoval?.space.name ?? "Space") from Finder?",
            isPresented: Binding(
                get: { spacePendingRemoval != nil },
                set: { if !$0 { spacePendingRemoval = nil } }
            ),
            presenting: spacePendingRemoval
        ) { space in
            Button("Remove from Finder", role: .destructive) {
                Task { await viewModel.removeSpace(space) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removes this Space and its downloaded copies from this Mac. Files on ownCloud stay available. You can add it again later.")
        }
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.account.displayName ?? "Account")?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        accountPendingRemoval = nil
                    }
                }
            ),
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove Account", role: .destructive) {
                Task { await viewModel.removeAccount(account.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("This removes \(account.account.displayName) from WesomeCloud, unregisters its File Provider domains, deletes saved credentials, and removes local materialized files and transfer partials for this account.")
        }
    }
}

public struct AccountSidebarRow: View {
    public var account: AccountRowViewModel

    public init(account: AccountRowViewModel) {
        self.account = account
    }

    public var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                    .font(.body)
                    .lineLimit(1)
                Text(account.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .accessibilityLabel(account.statusText)
    }

    private var iconName: String {
        switch account.statusState {
        case .idle: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath.circle.fill"
        case .paused: "pause.circle.fill"
        case .offline: "wifi.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch account.statusState {
        case .idle: .green
        case .syncing: .blue
        case .paused: .orange
        case .offline: .secondary
        case .error: .red
        }
    }
}

public struct DashboardView: View {
    public var accounts: [PersistedAccountRecord]
    public var spaces: [AppSpace]
    public var notifications: [AppNotification]
    public var storage: [AppAccountStorage]
    public var files: [AppFileItem]
    public var diagnostics: [DiagnosticEvent]
    public var issues: [SyncIssue]
    public var conflicts: [AppConflict]
    public var transfers: [AppTransfer]
    public var publicLinks: [AppPublicLink]
    public var updateStatus: UpdateStatus?
    public var errorMessage: String?
    public var diagnosticsExportURL: URL?
    public var lastCreatedShare: PublicLinkShare?
    public var reconnectAccount: (PersistedAccountRecord) -> Void
    public var openServerInBrowser: (PersistedAccountRecord) -> Void
    public var removeAccount: (PersistedAccountRecord) -> Void
    public var syncSpace: (AppSpace) -> Void
    public var removeSpace: (AppSpace) -> Void
    public var dismissNotification: (AppNotification) -> Void
    public var clearIssue: (SyncIssue) -> Void
    public var resolveConflict: (AppConflict, ConflictResolutionDecision, String?) -> Void
    public var setAvailabilityIntent: (AppFileItem, AvailabilityIntent) -> Void
    public var createPublicLink: (AppFileItem) -> Void
    public var refreshPublicLinks: (AppFileItem) -> Void
    public var copyPrivateLink: (AppFileItem) -> Void
    public var revealInFinder: (AppFileItem) -> Void
    public var revealDiagnosticsExport: () -> Void
    public var copyPublicLink: (AppPublicLink) -> Void
    public var deletePublicLink: (AppPublicLink) -> Void

    public init(
        accounts: [PersistedAccountRecord],
        spaces: [AppSpace] = [],
        notifications: [AppNotification] = [],
        storage: [AppAccountStorage] = [],
        files: [AppFileItem] = [],
        diagnostics: [DiagnosticEvent],
        issues: [SyncIssue] = [],
        conflicts: [AppConflict] = [],
        transfers: [AppTransfer] = [],
        publicLinks: [AppPublicLink] = [],
        updateStatus: UpdateStatus? = nil,
        errorMessage: String? = nil,
        diagnosticsExportURL: URL? = nil,
        lastCreatedShare: PublicLinkShare? = nil,
        reconnectAccount: @escaping (PersistedAccountRecord) -> Void = { _ in },
        openServerInBrowser: @escaping (PersistedAccountRecord) -> Void = { _ in },
        removeAccount: @escaping (PersistedAccountRecord) -> Void = { _ in },
        syncSpace: @escaping (AppSpace) -> Void = { _ in },
        removeSpace: @escaping (AppSpace) -> Void = { _ in },
        dismissNotification: @escaping (AppNotification) -> Void = { _ in },
        clearIssue: @escaping (SyncIssue) -> Void = { _ in },
        resolveConflict: @escaping (AppConflict, ConflictResolutionDecision, String?) -> Void = { _, _, _ in },
        setAvailabilityIntent: @escaping (AppFileItem, AvailabilityIntent) -> Void = { _, _ in },
        createPublicLink: @escaping (AppFileItem) -> Void = { _ in },
        refreshPublicLinks: @escaping (AppFileItem) -> Void = { _ in },
        copyPrivateLink: @escaping (AppFileItem) -> Void = { _ in },
        revealInFinder: @escaping (AppFileItem) -> Void = { _ in },
        revealDiagnosticsExport: @escaping () -> Void = {},
        copyPublicLink: @escaping (AppPublicLink) -> Void = { _ in },
        deletePublicLink: @escaping (AppPublicLink) -> Void = { _ in }
    ) {
        self.accounts = accounts
        self.spaces = spaces
        self.notifications = notifications
        self.storage = storage
        self.files = files
        self.diagnostics = diagnostics
        self.issues = issues
        self.conflicts = conflicts
        self.transfers = transfers
        self.publicLinks = publicLinks
        self.updateStatus = updateStatus
        self.errorMessage = errorMessage
        self.diagnosticsExportURL = diagnosticsExportURL
        self.lastCreatedShare = lastCreatedShare
        self.reconnectAccount = reconnectAccount
        self.openServerInBrowser = openServerInBrowser
        self.removeAccount = removeAccount
        self.syncSpace = syncSpace
        self.removeSpace = removeSpace
        self.dismissNotification = dismissNotification
        self.clearIssue = clearIssue
        self.resolveConflict = resolveConflict
        self.setAvailabilityIntent = setAvailabilityIntent
        self.createPublicLink = createPublicLink
        self.refreshPublicLinks = refreshPublicLinks
        self.copyPrivateLink = copyPrivateLink
        self.revealInFinder = revealInFinder
        self.revealDiagnosticsExport = revealDiagnosticsExport
        self.copyPublicLink = copyPublicLink
        self.deletePublicLink = deletePublicLink
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                if let diagnosticsExportURL {
                    HStack(spacing: 8) {
                        Text("Diagnostics exported: \(diagnosticsExportURL.lastPathComponent)")
                            .foregroundStyle(.secondary)
                        Button(action: revealDiagnosticsExport) {
                            Label("Reveal Diagnostics Export", systemImage: "folder")
                        }
                        .labelStyle(.iconOnly)
                        .help("Reveal diagnostics export in Finder")
                    }
                }
                if let lastCreatedShare {
                    Text("Public link: \(lastCreatedShare.url.absoluteString)")
                        .foregroundStyle(.secondary)
                }
                if let updateStatus {
                    Text(updateStatus.message)
                        .foregroundStyle(updateStatus.availableUpdate == nil ? Color.secondary : Color.orange)
                }
                AccountStatusTable(accounts: accounts, storage: storage, reconnectAccount: reconnectAccount, openServerInBrowser: openServerInBrowser, removeAccount: removeAccount)
                SpaceList(spaces: spaces, syncSpace: syncSpace, removeSpace: removeSpace)
                NotificationList(notifications: notifications, dismissNotification: dismissNotification)
                TransferActivityList(transfers: transfers)
                FileAvailabilityList(
                    files: files,
                    setAvailabilityIntent: setAvailabilityIntent,
                    createPublicLink: createPublicLink,
                    refreshPublicLinks: refreshPublicLinks,
                    copyPrivateLink: copyPrivateLink,
                    revealInFinder: revealInFinder
                )
                PublicLinkList(links: publicLinks, copyPublicLink: copyPublicLink, deletePublicLink: deletePublicLink)
                ConflictResolutionList(conflicts: conflicts, resolveConflict: resolveConflict)
                SyncIssueList(issues: issues, clearIssue: clearIssue)
                DiagnosticsList(events: diagnostics)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 720, minHeight: 460, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync Status")
                .font(.title2.weight(.semibold))
            Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") configured")
                .foregroundStyle(.secondary)
        }
    }
}

public struct TransferActivityList: View {
    public var transfers: [AppTransfer]

    public init(transfers: [AppTransfer]) {
        self.transfers = transfers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transfer Activity")
                .font(.headline)
            if transfers.isEmpty {
                Text("No recent transfers")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transfers.prefix(10)) { transfer in
                    TransferActivityRow(transfer: transfer.rowViewModel)
                }
            }
        }
    }
}

public struct TransferActivityRow: View {
    public var transfer: TransferRowViewModel

    public init(transfer: TransferRowViewModel) {
        self.transfer = transfer
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(transfer.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(transfer.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(transfer.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let progress = transfer.progress {
                        ProgressView(value: progress)
                            .frame(width: 96)
                    }
                }
            }
            Spacer()
            Text(transfer.phaseText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch transfer.phaseText {
        case "Completed": "checkmark.circle.fill"
        case "Failed": "exclamationmark.triangle.fill"
        case "Paused": "pause.circle.fill"
        case "Queued": "clock"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch transfer.phaseText {
        case "Completed": .green
        case "Failed": .red
        case "Paused": .orange
        case "Queued": .secondary
        default: .blue
        }
    }
}

public struct FileAvailabilityList: View {
    public var files: [AppFileItem]
    public var setAvailabilityIntent: (AppFileItem, AvailabilityIntent) -> Void
    public var createPublicLink: (AppFileItem) -> Void
    public var refreshPublicLinks: (AppFileItem) -> Void
    public var copyPrivateLink: (AppFileItem) -> Void
    public var revealInFinder: (AppFileItem) -> Void

    public init(
        files: [AppFileItem],
        setAvailabilityIntent: @escaping (AppFileItem, AvailabilityIntent) -> Void,
        createPublicLink: @escaping (AppFileItem) -> Void = { _ in },
        refreshPublicLinks: @escaping (AppFileItem) -> Void = { _ in },
        copyPrivateLink: @escaping (AppFileItem) -> Void = { _ in },
        revealInFinder: @escaping (AppFileItem) -> Void = { _ in }
    ) {
        self.files = files
        self.setAvailabilityIntent = setAvailabilityIntent
        self.createPublicLink = createPublicLink
        self.refreshPublicLinks = refreshPublicLinks
        self.copyPrivateLink = copyPrivateLink
        self.revealInFinder = revealInFinder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.headline)
            if files.isEmpty {
                Text("No synced files yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files.prefix(30)) { file in
                    FileAvailabilityRow(file: file.rowViewModel, setAvailabilityIntent: { intent in
                        setAvailabilityIntent(file, intent)
                    }, createPublicLink: {
                        createPublicLink(file)
                    }, refreshPublicLinks: {
                        refreshPublicLinks(file)
                    }, copyPrivateLink: {
                        copyPrivateLink(file)
                    }, revealInFinder: {
                        revealInFinder(file)
                    })
                }
            }
        }
    }
}

public struct FileAvailabilityRow: View {
    public var file: FileItemRowViewModel
    public var setAvailabilityIntent: (AvailabilityIntent) -> Void
    public var createPublicLink: () -> Void
    public var refreshPublicLinks: () -> Void
    public var copyPrivateLink: () -> Void
    public var revealInFinder: () -> Void

    public init(
        file: FileItemRowViewModel,
        setAvailabilityIntent: @escaping (AvailabilityIntent) -> Void,
        createPublicLink: @escaping () -> Void = {},
        refreshPublicLinks: @escaping () -> Void = {},
        copyPrivateLink: @escaping () -> Void = {},
        revealInFinder: @escaping () -> Void = {}
    ) {
        self.file = file
        self.setAvailabilityIntent = setAvailabilityIntent
        self.createPublicLink = createPublicLink
        self.refreshPublicLinks = refreshPublicLinks
        self.copyPrivateLink = copyPrivateLink
        self.revealInFinder = revealInFinder
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind == .folder ? "folder" : "doc")
                .foregroundStyle(file.kind == .folder ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(file.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(file.materializationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Menu {
                Button {
                    createPublicLink()
                } label: {
                    Label("Create Link", systemImage: "link")
                }
                Button {
                    copyPrivateLink()
                } label: {
                    Label("Copy Private Link", systemImage: "doc.on.doc")
                }
                Button {
                    refreshPublicLinks()
                } label: {
                    Label("Show Links", systemImage: "list.bullet")
                }
                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!file.isDownloaded)
                Divider()
                Button {
                    setAvailabilityIntent(.alwaysLocal)
                } label: {
                    Label("Keep Downloaded", systemImage: "arrow.down.circle")
                }
                Button {
                    setAvailabilityIntent(.onlineOnly)
                } label: {
                    Label("Free Up Space", systemImage: "icloud")
                }
                Button {
                    setAvailabilityIntent(.unspecified)
                } label: {
                    Label("System Managed", systemImage: "gearshape.2")
                }
            } label: {
                Label(file.availabilityText, systemImage: "externaldrive.badge.icloud")
            }
            .menuStyle(.button)
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

public struct PublicLinkList: View {
    public var links: [AppPublicLink]
    public var copyPublicLink: (AppPublicLink) -> Void
    public var deletePublicLink: (AppPublicLink) -> Void

    public init(
        links: [AppPublicLink],
        copyPublicLink: @escaping (AppPublicLink) -> Void = { _ in },
        deletePublicLink: @escaping (AppPublicLink) -> Void
    ) {
        self.links = links
        self.copyPublicLink = copyPublicLink
        self.deletePublicLink = deletePublicLink
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Public Links")
                .font(.headline)
            if links.isEmpty {
                Text("No public links loaded")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(links) { link in
                    PublicLinkRow(link: link.rowViewModel, copyPublicLink: {
                        copyPublicLink(link)
                    }, deletePublicLink: {
                        deletePublicLink(link)
                    })
                }
            }
        }
    }
}

public struct PublicLinkRow: View {
    public var link: PublicLinkRowViewModel
    public var copyPublicLink: () -> Void
    public var deletePublicLink: () -> Void

    public init(
        link: PublicLinkRowViewModel,
        copyPublicLink: @escaping () -> Void = {},
        deletePublicLink: @escaping () -> Void
    ) {
        self.link = link
        self.copyPublicLink = copyPublicLink
        self.deletePublicLink = deletePublicLink
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(link.filePath)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(link.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(link.urlText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                copyPublicLink()
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .help("Copy public link")
            Button {
                deletePublicLink()
            } label: {
                Label("Revoke Link", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Revoke public link")
        }
        .padding(.vertical, 3)
    }
}

public struct ConflictResolutionList: View {
    public var conflicts: [AppConflict]
    public var resolveConflict: (AppConflict, ConflictResolutionDecision, String?) -> Void

    public init(conflicts: [AppConflict], resolveConflict: @escaping (AppConflict, ConflictResolutionDecision, String?) -> Void) {
        self.conflicts = conflicts
        self.resolveConflict = resolveConflict
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conflicts")
                .font(.headline)
            if conflicts.isEmpty {
                Text("No conflicts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conflicts) { conflict in
                    ConflictResolutionRow(conflict: conflict.rowViewModel) { decision, name in
                        resolveConflict(conflict, decision, name)
                    }
                }
            }
        }
    }
}

public struct ConflictResolutionRow: View {
    public var conflict: ConflictRowViewModel
    public var resolve: (ConflictResolutionDecision, String?) -> Void
    @State private var renameText: String

    public init(conflict: ConflictRowViewModel, resolve: @escaping (ConflictResolutionDecision, String?) -> Void) {
        self.conflict = conflict
        self.resolve = resolve
        self._renameText = State(initialValue: conflict.suggestedRename)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(conflict.title)
                            .font(.subheadline.weight(.semibold))
                        Text(conflict.accountName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(conflict.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Button {
                    resolve(.keepLocal, nil)
                } label: {
                    Label("Keep Local", systemImage: "arrow.up.doc")
                }
                Button {
                    resolve(.keepRemote, nil)
                } label: {
                    Label("Keep Remote", systemImage: "arrow.down.doc")
                }
                Button {
                    resolve(.retry, nil)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                TextField("Rename", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    resolve(.renameLocal, renameText)
                } label: {
                    Label("Rename Local", systemImage: "pencil")
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 5)
    }
}

public struct SyncIssueList: View {
    public var issues: [SyncIssue]
    public var clearIssue: (SyncIssue) -> Void

    public init(issues: [SyncIssue], clearIssue: @escaping (SyncIssue) -> Void) {
        self.issues = issues
        self.clearIssue = clearIssue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Issues")
                .font(.headline)
            if issues.isEmpty {
                Text("No sync issues")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(issues) { issue in
                    SyncIssueRow(issue: issue.rowViewModel) {
                        clearIssue(issue)
                    }
                }
            }
        }
    }
}

public struct SyncIssueRow: View {
    public var issue: SyncIssueRowViewModel
    public var clear: () -> Void

    public init(issue: SyncIssueRowViewModel, clear: @escaping () -> Void) {
        self.issue = issue
        self.clear = clear
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: issue.isRecoverable ? "exclamationmark.arrow.triangle.2.circlepath" : "exclamationmark.octagon.fill")
                .foregroundStyle(issue.isRecoverable ? .orange : .red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(issue.title)
                        .font(.subheadline.weight(.semibold))
                    Text(issue.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                clear()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Clear resolved issue")
        }
        .padding(.vertical, 3)
    }
}

public struct AccountStatusTable: View {
    public var accounts: [PersistedAccountRecord]
    public var storage: [AppAccountStorage]
    public var reconnectAccount: (PersistedAccountRecord) -> Void
    public var openServerInBrowser: (PersistedAccountRecord) -> Void
    public var removeAccount: (PersistedAccountRecord) -> Void

    public init(
        accounts: [PersistedAccountRecord],
        storage: [AppAccountStorage] = [],
        reconnectAccount: @escaping (PersistedAccountRecord) -> Void = { _ in },
        openServerInBrowser: @escaping (PersistedAccountRecord) -> Void = { _ in },
        removeAccount: @escaping (PersistedAccountRecord) -> Void = { _ in }
    ) {
        self.accounts = accounts
        self.storage = storage
        self.reconnectAccount = reconnectAccount
        self.openServerInBrowser = openServerInBrowser
        self.removeAccount = removeAccount
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Text("Account").font(.caption.weight(.semibold))
                Text("Server").font(.caption.weight(.semibold))
                Text("Status").font(.caption.weight(.semibold))
                Text("Storage").font(.caption.weight(.semibold))
                Text("").font(.caption.weight(.semibold))
                Text("").font(.caption.weight(.semibold))
                Text("").font(.caption.weight(.semibold))
            }
            Divider().gridCellColumns(7)
            ForEach(accounts) { record in
                GridRow {
                    Text(record.account.displayName)
                    Text(record.account.serverURL.host() ?? record.account.serverURL.absoluteString)
                        .foregroundStyle(.secondary)
                    Text(record.lastSyncStatus.message)
                        .foregroundStyle(record.lastSyncStatus.state == .error ? .red : .primary)
                    storageCell(for: record.id)
                    Button {
                        reconnectAccount(record)
                    } label: {
                        Label("Reconnect", systemImage: "key")
                    }
                    .labelStyle(.iconOnly)
                    .help("Reconnect account")
                    .disabled(record.lastSyncStatus.state != .error)
                    Button {
                        openServerInBrowser(record)
                    } label: {
                        Label("Open Server in Browser", systemImage: "safari")
                    }
                    .labelStyle(.iconOnly)
                    .help("Open server in browser")
                    Button(role: .destructive) {
                        removeAccount(record)
                    } label: {
                        Label("Remove Account", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove account")
                }
            }
        }
    }

    @ViewBuilder
    private func storageCell(for accountID: UUID) -> some View {
        if let storage = storage.first(where: { $0.accountID == accountID })?.rowViewModel {
            HStack(spacing: 8) {
                Text(storage.summaryText)
                    .foregroundStyle(.secondary)
                if let progress = storage.progress {
                    ProgressView(value: progress)
                        .frame(width: 72)
                }
            }
        } else {
            Text("Unknown")
                .foregroundStyle(.secondary)
        }
    }
}

public struct SpaceList: View {
    public var spaces: [AppSpace]
    public var syncSpace: (AppSpace) -> Void
    public var removeSpace: (AppSpace) -> Void

    public init(spaces: [AppSpace], syncSpace: @escaping (AppSpace) -> Void = { _ in }, removeSpace: @escaping (AppSpace) -> Void = { _ in }) {
        self.spaces = spaces
        self.syncSpace = syncSpace
        self.removeSpace = removeSpace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spaces")
                .font(.headline)
            if spaces.isEmpty {
                Text("No spaces discovered")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spaces) { space in
                    SpaceRow(space: space.rowViewModel, syncSpace: {
                        syncSpace(space)
                    }, removeSpace: {
                        removeSpace(space)
                    })
                }
            }
        }
    }
}

public struct SpaceRow: View {
    public var space: SpaceRowViewModel
    public var syncSpace: () -> Void
    public var removeSpace: () -> Void

    public init(space: SpaceRowViewModel, syncSpace: @escaping () -> Void = {}, removeSpace: @escaping () -> Void = {}) {
        self.space = space
        self.syncSpace = syncSpace
        self.removeSpace = removeSpace
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(space.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(space.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(space.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(space.quotaText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            Button {
                if space.isSelected { removeSpace() } else { syncSpace() }
            } label: {
                Label(space.isSelected ? "Remove from Finder" : "Add to Finder", systemImage: space.isSelected ? "minus" : "plus")
            }
            .help(space.isSelected ? "Remove this Space from Finder" : "Add this space alongside your other Finder locations")
        }
        .padding(.vertical, 3)
    }
}

public struct NotificationList: View {
    public var notifications: [AppNotification]
    public var dismissNotification: (AppNotification) -> Void

    public init(
        notifications: [AppNotification],
        dismissNotification: @escaping (AppNotification) -> Void = { _ in }
    ) {
        self.notifications = notifications
        self.dismissNotification = dismissNotification
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Notifications")
                .font(.headline)
            if notifications.isEmpty {
                Text("No server notifications")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(notifications) { notification in
                    NotificationRow(notification: notification.rowViewModel) {
                        dismissNotification(notification)
                    }
                }
            }
        }
    }
}

public struct NotificationRow: View {
    public var notification: NotificationRowViewModel
    public var dismiss: () -> Void

    public init(notification: NotificationRowViewModel, dismiss: @escaping () -> Void = {}) {
        self.notification = notification
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(notification.subject)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(notification.accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(notification.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(notification.dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Button {
                dismiss()
            } label: {
                Label("Dismiss", systemImage: "checkmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Dismiss notification")
        }
        .padding(.vertical, 3)
    }
}

public struct ReconnectAccountView: View {
    public var account: PersistedAccountRecord
    @Binding public var appPassword: String
    public var submit: () async -> Void

    public init(account: PersistedAccountRecord, appPassword: Binding<String>, submit: @escaping () async -> Void) {
        self.account = account
        self._appPassword = appPassword
        self.submit = submit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reconnect Account")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(account.account.displayName)
                    .font(.headline)
                Text(account.account.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(account.account.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SecureField("App password", text: $appPassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    Label("Reconnect", systemImage: "key")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appPassword.isEmpty)
            }
        }
        .padding(24)
    }
}

public struct DiagnosticsList: View {
    public var events: [DiagnosticEvent]

    public init(events: [DiagnosticEvent]) {
        self.events = events
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            if events.isEmpty {
                Text("No diagnostics yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events.suffix(20)) { event in
                    HStack {
                        Text(event.category)
                            .font(.caption.weight(.semibold))
                            .frame(width: 120, alignment: .leading)
                        Text(event.message)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

public struct AccountSetupView: View {
    @Bindable private var form: AccountSetupFormModel
    private let submit: (AccountSetupInput) async -> Void

    public init(form: AccountSetupFormModel, submit: @escaping (AccountSetupInput) async -> Void) {
        self.form = form
        self.submit = submit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add ownCloud Account")
                .font(.title3.weight(.semibold))
            Picker("Login method", selection: $form.mode) {
                Text("App Password").tag(AccountSetupMode.appPassword)
                Text("Browser OAuth").tag(AccountSetupMode.oauth)
            }
            .pickerStyle(.segmented)
            TextField("https://cloud.example.com", text: $form.serverURLText)
                .textFieldStyle(.roundedBorder)
            if form.mode == .appPassword {
                TextField("Username", text: $form.username)
                    .textFieldStyle(.roundedBorder)
                SecureField("App password", text: $form.appPassword)
                    .textFieldStyle(.roundedBorder)
            }
            if let validationMessage = form.validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button {
                    Task {
                        guard let input = form.validateForSubmit() else { return }
                        await submit(input)
                    }
                } label: {
                    Label(form.mode == .oauth ? "Continue in Browser" : "Connect", systemImage: form.mode == .oauth ? "safari" : "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canSubmit)
            }
        }
        .padding(24)
    }
}

public struct WesomeCloudMenuBarView: View {
    public var accounts: [PersistedAccountRecord]
    public var isSyncPaused: Bool
    public var updateStatus: UpdateStatus?
    public var syncNow: () async -> Void
    public var toggleSyncPaused: () async -> Void
    public var checkForUpdates: () async -> Void
    public var openApp: () -> Void
    public var openSettings: () -> Void
    public var quitApp: () -> Void

    public init(
        accounts: [PersistedAccountRecord],
        isSyncPaused: Bool = false,
        updateStatus: UpdateStatus? = nil,
        syncNow: @escaping () async -> Void,
        toggleSyncPaused: @escaping () async -> Void = {},
        checkForUpdates: @escaping () async -> Void = {},
        openApp: @escaping () -> Void = {},
        openSettings: @escaping () -> Void,
        quitApp: @escaping () -> Void = {}
    ) {
        self.accounts = accounts
        self.isSyncPaused = isSyncPaused
        self.updateStatus = updateStatus
        self.syncNow = syncNow
        self.toggleSyncPaused = toggleSyncPaused
        self.checkForUpdates = checkForUpdates
        self.openApp = openApp
        self.openSettings = openSettings
        self.quitApp = quitApp
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if accounts.isEmpty {
                Text("No accounts configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { record in
                    HStack {
                        Text(record.account.displayName)
                        Spacer()
                        Text(record.lastSyncStatus.message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let updateStatus {
                Text(updateStatus.message)
                    .font(.caption)
                    .foregroundStyle(updateStatus.availableUpdate == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Divider()
            Button {
                openApp()
            } label: {
                Label("Open WesomeCloud", systemImage: "macwindow")
            }
            Button {
                Task {
                    await syncNow()
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(isSyncPaused)
            Button {
                Task {
                    await toggleSyncPaused()
                }
            } label: {
                Label(isSyncPaused ? "Resume Sync" : "Pause Sync", systemImage: isSyncPaused ? "play.circle" : "pause.circle")
            }
            Button {
                Task {
                    await checkForUpdates()
                }
            } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
            }
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button {
                quitApp()
            } label: {
                Label("Quit WesomeCloud", systemImage: "power")
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

public struct PreferencesView: View {
    @Bindable private var form: PreferencesFormModel
    private let save: (AppPreferences) async -> Void
    private let trackingConsent: TrackingConsent
    private let isSavingTrackingConsent: Bool
    private let trackingErrorMessage: String?
    private let changeTrackingConsent: (TrackingConsent) async -> Bool
    @State private var showingTrackingConsent = false

    public init(
        form: PreferencesFormModel,
        trackingConsent: TrackingConsent = .notAsked,
        isSavingTrackingConsent: Bool = false,
        trackingErrorMessage: String? = nil,
        changeTrackingConsent: @escaping (TrackingConsent) async -> Bool = { _ in false },
        save: @escaping (AppPreferences) async -> Void
    ) {
        self.form = form
        self.trackingConsent = trackingConsent
        self.isSavingTrackingConsent = isSavingTrackingConsent
        self.trackingErrorMessage = trackingErrorMessage
        self.changeTrackingConsent = changeTrackingConsent
        self.save = save
    }

    public var body: some View {
        ScrollView {
            Form {
                Section("Sync") {
                    Toggle("Pause sync", isOn: $form.isSyncPaused)
                    LabeledContent("Remote poll interval") {
                        Stepper("\(Int(form.pollInterval)) seconds", value: $form.pollInterval, in: 15...3600, step: 15)
                    }
                    LabeledContent("Queue retry interval") {
                        Stepper("\(Int(form.queueInterval)) seconds", value: $form.queueInterval, in: 5...600, step: 5)
                    }
                    LabeledContent("Retry attempts") {
                        Stepper("\(form.retryMaximumAttempts)", value: $form.retryMaximumAttempts, in: 1...20)
                    }
                    LabeledContent("Concurrent transfers") {
                        Stepper("\(form.maximumConcurrentTransfers)", value: $form.maximumConcurrentTransfers, in: 1...12)
                    }
                }

                Section("Files") {
                    Picker("Default availability", selection: $form.defaultAvailability) {
                        Text("Online Only").tag(DefaultAvailability.onlineOnly)
                        Text("Keep Downloaded").tag(DefaultAvailability.alwaysLocal)
                        Text("System Managed").tag(DefaultAvailability.systemManaged)
                    }
                    Toggle("Show hidden files", isOn: $form.showHiddenFiles)
                    TextField("Ignored filename patterns", text: $form.ignoredFilenamePatternsText, axis: .vertical)
                        .lineLimit(3...5)
                    TextField("Excluded remote paths", text: $form.excludedRemotePathsText, axis: .vertical)
                        .lineLimit(3...5)
                }

                Section("Diagnostics") {
                    LabeledContent("Retained events") {
                        Stepper("\(form.retainEventLimit)", value: $form.retainEventLimit, in: 50...2000, step: 50)
                    }
                    Toggle("Include debug events", isOn: $form.includeDebugEvents)
                }

                Section("Privacy") {
                    Toggle("Share usage and errors with PostHog", isOn: Binding(
                        get: { trackingConsent == .allowed },
                        set: { allowed in
                            if allowed {
                                showingTrackingConsent = true
                            } else {
                                Task { await changeTrackingConsent(.declined) }
                            }
                        }
                    ))
                    .disabled(isSavingTrackingConsent)
                    Text(TrackingConsentView.disclosure)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Changes apply immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let trackingErrorMessage {
                        Text(trackingErrorMessage).foregroundStyle(.red)
                    }
                }

                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: $form.automaticallyCheckForUpdates)
                    TextField("Appcast URL", text: $form.appcastURLText)
                    LabeledContent("Check interval") {
                        Stepper("\(Int(form.updateCheckInterval / 3600)) hours", value: $form.updateCheckInterval, in: 3600...604_800, step: 3600)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await save(form.preferences) }
                    } label: {
                        Label("Save", systemImage: "checkmark.circle")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(maxHeight: 720)
        .sheet(isPresented: $showingTrackingConsent) {
            TrackingConsentView(isSaving: isSavingTrackingConsent, errorMessage: trackingErrorMessage) { consent in
                if await changeTrackingConsent(consent) { showingTrackingConsent = false }
            }
            .interactiveDismissDisabled()
        }
    }
}

public struct TrackingConsentView: View {
    public static let disclosure = "Share feature usage and error categories to help improve WesomeCloud. PostHog receives a random installation ID and app version. No account details, filenames, paths, file contents, or session recordings are sent."
    private let isSaving: Bool
    private let errorMessage: String?
    private let decide: (TrackingConsent) async -> Void

    public init(
        isSaving: Bool = false,
        errorMessage: String? = nil,
        decide: @escaping (TrackingConsent) async -> Void
    ) {
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.decide = decide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share usage and errors?").font(.title2).fontWeight(.semibold)
            Text(Self.disclosure)
            Text("Tracking stays off unless you allow it. You can change this anytime in Settings.")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Button("Don't Allow") { Task { await decide(.declined) } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow Tracking") { Task { await decide(.allowed) } }
            }
            .disabled(isSaving)
        }
        .padding(24)
        .frame(width: 460)
    }
}
