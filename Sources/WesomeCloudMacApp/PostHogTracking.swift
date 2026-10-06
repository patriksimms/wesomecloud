import Foundation
import Observation
import WesomeCloudAppCore
import WesomeCloudShared

public struct PostHogConfiguration: Sendable {
    public let projectToken: String
    public let host: URL

    public init?(projectToken: String, host: String) {
        let token = projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("$("),
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        self.projectToken = token
        self.host = url
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> Self? {
        Self(
            projectToken: bundle.object(forInfoDictionaryKey: "WesomeCloudPostHogProjectToken") as? String ?? "",
            host: bundle.object(forInfoDictionaryKey: "WesomeCloudPostHogHost") as? String ?? ""
        )
    }
}

/// Explicit capture only. Nothing is queued on disk or replayed after consent changes.
@MainActor
@Observable
public final class PostHogTracking {
    public private(set) var consent: TrackingConsent = .notAsked
    public private(set) var sessionID: UUID?
    public var isConfigured: Bool { configuration != nil }

    private let configuration: PostHogConfiguration?
    private let sessionConfiguration: URLSessionConfiguration
    private let defaults: UserDefaults
    private var session: URLSession?
    private var distinctID: String?
    private var consentStartedAt: Date?
    private var reportedSyncIssues: Set<UUID> = []
    private static let identityKey = "WesomeCloud.tracking.anonymousID"

    public init(
        configuration: PostHogConfiguration? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        defaults: UserDefaults = .standard
    ) {
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
        self.defaults = defaults
    }

    public func setConsent(_ consent: TrackingConsent) {
        guard consent != self.consent else { return }
        self.consent = consent
        sessionID = nil
        session?.invalidateAndCancel()
        session = nil
        distinctID = nil
        consentStartedAt = nil
        reportedSyncIssues.removeAll()
        if consent == .allowed, configuration != nil {
            let id = defaults.string(forKey: Self.identityKey) ?? UUID().uuidString
            defaults.set(id, forKey: Self.identityKey)
            distinctID = id
            sessionID = UUID()
            consentStartedAt = Date()
            session = URLSession(configuration: sessionConfiguration, delegate: TrackingRedirectDelegate(), delegateQueue: nil)
        } else {
            defaults.removeObject(forKey: Self.identityKey)
        }
    }

    public func capture(_ event: TrackingEvent) {
        send(event: event.rawValue, properties: Properties(operation: event.rawValue))
    }

    /// A consent generation prevents work begun before approval or revocation from being reported later.
    public func captureError(_ error: Error, operation: TrackingEvent, sessionID: UUID?) {
        guard let sessionID, sessionID == self.sessionID else { return }
        let category = Self.errorCategory(error)
        send(event: "$exception", properties: Properties(
            operation: operation.rawValue,
            exceptionList: [ExceptionItem(type: category, value: category)]
        ))
    }

    public func captureSyncIssues(_ issues: [SyncIssue]) {
        guard consent == .allowed, let consentStartedAt else { return }
        for issue in issues where issue.occurredAt >= consentStartedAt {
            guard reportedSyncIssues.insert(issue.id).inserted else { continue }
            let category = "sync_\(issue.scope.rawValue)"
            send(event: "$exception", properties: Properties(
                operation: "background_sync",
                exceptionList: [ExceptionItem(type: category, value: category)]
            ))
        }
    }

    private func send(event: String, properties: Properties) {
        guard consent == .allowed, let configuration, let session, let distinctID else { return }
        let payload = CapturePayload(
            apiKey: configuration.projectToken,
            event: event,
            distinctID: distinctID,
            properties: properties,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: configuration.host.appendingPathComponent("i/v0/e/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 10
        // Best effort: failed sends are discarded, never retried under a later consent state.
        session.dataTask(with: request).resume()
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case let error as WesomeCloudError:
            switch error {
            case .invalidResponse: "invalid_response"
            case .httpStatus(let status): "http_\(status)"
            case .httpFailure(let failure): "http_\(failure.kind.rawValue)"
            case .missingItem: "missing_item"
            case .unsupported: "unsupported"
            case .transferIntegrityMismatch: "transfer_integrity_mismatch"
            case .invalidFilename(_, let violation): "invalid_filename_\(violation.rawValue)"
            case .conflict(let conflict): "conflict_\(conflict.kind.rawValue)"
            }
        case let error as URLError: "network_\(error.code.rawValue)"
        default: "app_error"
        }
    }

    private struct CapturePayload: Encodable {
        var apiKey: String
        var event: String
        var distinctID: String
        var properties: Properties
        var timestamp: String

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case event
            case distinctID = "distinct_id"
            case properties, timestamp
        }
    }

    private struct Properties: Encodable {
        var operation: String
        var exceptionList: [ExceptionItem]? = nil
        var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        var appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        var osName = "macOS"
        var processPersonProfile = false
        var geoIPDisable = true

        enum CodingKeys: String, CodingKey {
            case operation
            case exceptionList = "$exception_list"
            case appVersion = "$app_version"
            case appBuild = "$app_build"
            case osName = "$os_name"
            case processPersonProfile = "$process_person_profile"
            case geoIPDisable = "$geoip_disable"
        }
    }

    private struct ExceptionItem: Encodable {
        var type: String
        var value: String
        var mechanism = Mechanism()
    }

    private struct Mechanism: Encodable {
        var type = "generic"
        var handled = true
        var synthetic = true
    }
}

// Never forward the project token or event body to a redirect destination.
private final class TrackingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum TrackingEvent: String, Sendable {
    case appOpened = "app_opened"
    case refresh = "dashboard_refreshed"
    case restoreFinderLocations = "finder_locations_restored"
    case syncNow = "sync_requested"
    case addAccount = "account_connection_requested"
    case addOAuthAccount = "oauth_connection_requested"
    case reconnectAccount = "account_reconnection_requested"
    case syncSpace = "space_sync_requested"
    case removeSpace = "space_removal_requested"
    case dismissNotification = "notification_dismissed"
    case removeAccount = "account_removal_requested"
    case savePreferences = "preferences_saved"
    case exportDiagnostics = "diagnostics_export_requested"
    case clearIssue = "issue_clear_requested"
    case resolveConflict = "conflict_resolution_requested"
    case checkForUpdates = "update_check_requested"
    case setAvailabilityIntent = "file_availability_change_requested"
    case createPublicLink = "public_link_creation_requested"
    case refreshPublicLinks = "public_links_refreshed"
    case deletePublicLink = "public_link_deletion_requested"
    case copyPublicLink = "public_link_copied"
    case revealInFinder = "file_revealed"
    case openServerInBrowser = "server_opened"
    case copyPrivateLink = "private_link_copy_requested"
}
