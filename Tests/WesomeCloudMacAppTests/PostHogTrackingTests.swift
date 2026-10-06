import Foundation
import Synchronization
import Testing
import WesomeCloudAppCore
import WesomeCloudMacApp
import WesomeCloudShared

private final class TrackingURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = []
        var stopped = 0
        var holdRequests = false
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let hold = Self.state.withLock { state in
            state.requests.append(captured)
            return state.holdRequests
        }
        guard !hold else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.state.withLock { $0.stopped += 1 }
    }
}

private actor FailingTrackingPreferences: PreferencesRepository {
    var preferences = AppPreferences()
    var failSave = false
    func load() -> AppPreferences { preferences }
    func save(_ preferences: AppPreferences) throws {
        if failSave { throw WesomeCloudError.unsupported("private.server/secret/file.txt") }
        self.preferences = preferences
    }
    func setFailSave(_ fail: Bool) { failSave = fail }
}

@Suite(.serialized)
struct PostHogTrackingTests {
    @MainActor
    private func makeTracking() throws -> (PostHogTracking, UserDefaults) {
        TrackingURLProtocol.state.withLock { $0 = .init() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrackingURLProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "tracking-tests-\(UUID().uuidString)"))
        return (PostHogTracking(
            configuration: PostHogConfiguration(projectToken: "phc_test", host: "https://eu.i.posthog.com"),
            sessionConfiguration: config,
            defaults: defaults
        ), defaults)
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the HTTP boundary")
    }

    @Test @MainActor
    func consentGatesRequestsCancelsPendingAndNeverReplaysHistory() async throws {
        let (tracking, _) = try makeTracking()
        defer { tracking.setConsent(.declined) }
        let beforeApproval = tracking.sessionID
        tracking.capture(.addAccount)
        tracking.captureError(WesomeCloudError.missingItem("/private/file"), operation: .addAccount, sessionID: beforeApproval)
        tracking.setConsent(.declined)
        tracking.capture(.syncNow)
        tracking.setConsent(.allowed)
        tracking.captureError(WesomeCloudError.missingItem("/private/file"), operation: .addAccount, sessionID: beforeApproval)
        tracking.capture(.syncNow)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.requests.count == 1 } }
        let first = try #require(TrackingURLProtocol.state.withLock { $0.requests.first })
        let payload = try JSONDecoder().decode(CapturedEvent.self, from: try #require(first.httpBody))
        #expect(first.url?.absoluteString == "https://eu.i.posthog.com/i/v0/e/")
        #expect(first.httpMethod == "POST")
        #expect(payload.event == "sync_requested")
        #expect(payload.apiKey == "phc_test")
        #expect(payload.properties.processPersonProfile == false)

        TrackingURLProtocol.state.withLock { $0.holdRequests = true }
        let approvedSession = tracking.sessionID
        tracking.capture(.refresh)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.requests.count == 2 } }
        let stoppedBeforeRevocation = TrackingURLProtocol.state.withLock { $0.stopped }
        tracking.setConsent(.declined)
        tracking.capture(.removeAccount)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.stopped > stoppedBeforeRevocation } }
        tracking.setConsent(.allowed)
        tracking.captureError(WesomeCloudError.missingItem("/private/file"), operation: .refresh, sessionID: approvedSession)
        TrackingURLProtocol.state.withLock { $0.holdRequests = false }
        tracking.capture(.appOpened)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.requests.count == 3 } }
        let last = try #require(TrackingURLProtocol.state.withLock { $0.requests.last?.httpBody })
        let reenabled = try JSONDecoder().decode(CapturedEvent.self, from: last)
        #expect(reenabled.event == "app_opened")
        #expect(reenabled.distinctID != payload.distinctID)
    }

    @Test @MainActor
    func errorsUsePostHogExceptionEnvelopeWithoutPrivateMessages() async throws {
        let (tracking, defaults) = try makeTracking()
        tracking.setConsent(.allowed)
        let id = defaults.string(forKey: "WesomeCloud.tracking.anonymousID")
        tracking.captureError(WesomeCloudError.missingItem("https://alice:password@private.server/secret.txt"), operation: .syncNow, sessionID: tracking.sessionID)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.requests.count == 1 } }
        let body = try #require(TrackingURLProtocol.state.withLock { $0.requests.first?.httpBody })
        let payload = try JSONDecoder().decode(CapturedEvent.self, from: body)
        #expect(payload.event == "$exception")
        #expect(payload.distinctID == id)
        #expect(payload.properties.operation == "sync_requested")
        #expect(payload.properties.exceptionList?.first?.type == "missing_item")
        #expect(payload.properties.exceptionList?.first?.value == "missing_item")
        let serialized = String(decoding: body, as: UTF8.self)
        #expect(!serialized.contains("alice"))
        #expect(!serialized.contains("password"))
        #expect(!serialized.contains("secret.txt"))
        // A new app instance restores the installation identity while consent remains allowed.
        let resumed = PostHogTracking(configuration: PostHogConfiguration(projectToken: "phc_test", host: "https://eu.i.posthog.com"), defaults: defaults)
        resumed.setConsent(.allowed)
        #expect(defaults.string(forKey: "WesomeCloud.tracking.anonymousID") == id)
        resumed.setConsent(.declined)
        tracking.setConsent(.declined)
    }

    @Test @MainActor
    func approvalMustPersistAndStaleSettingsCannotChangeConsent() async throws {
        let (tracking, _) = try makeTracking()
        let repository = FailingTrackingPreferences()
        let model = WesomeCloudAppModel(
            accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
            domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
            repository: MemoryAccountRepository(),
            preferencesRepository: repository
        )
        let viewModel = WesomeCloudViewModel(model: model, tracking: tracking)
        await viewModel.initializeTracking()
        #expect(tracking.consent == .notAsked)
        await repository.setFailSave(true)
        #expect(await viewModel.setTrackingConsent(.allowed) == false)
        #expect(tracking.sessionID == nil)
        await repository.setFailSave(false)
        #expect(await viewModel.setTrackingConsent(.allowed))
        var staleSettings = AppPreferences()
        staleSettings.sync.pollInterval = 180
        await viewModel.savePreferences(staleSettings)
        #expect(await repository.load().trackingConsent == .allowed)
        #expect(await viewModel.setTrackingConsent(.declined))
        staleSettings.trackingConsent = .allowed
        await viewModel.savePreferences(staleSettings)
        #expect(await repository.load().trackingConsent == .declined)
        #expect(tracking.sessionID == nil)
        #expect(await viewModel.setTrackingConsent(.allowed))
        await repository.setFailSave(true)
        #expect(await viewModel.setTrackingConsent(.declined) == false)
        #expect(tracking.sessionID == nil)
        #expect(viewModel.lastErrorMessage != nil)
    }

    @Test @MainActor
    func syncIssuesExcludeHistoryAndReportNewFailuresOnlyOnce() async throws {
        let (tracking, _) = try makeTracking()
        defer { tracking.setConsent(.declined) }
        let historical = SyncIssue(
            id: UUID(), accountID: UUID(), accountName: "private-account", scope: .item,
            itemID: "/private/secret.txt", message: "private error detail", isRecoverable: true,
            occurredAt: Date().addingTimeInterval(-60)
        )
        tracking.captureSyncIssues([historical])
        tracking.setConsent(.allowed)
        var fresh = historical
        fresh.id = UUID()
        fresh.occurredAt = Date()
        tracking.captureSyncIssues([historical, fresh])
        tracking.captureSyncIssues([historical, fresh])
        tracking.capture(.refresh)
        try await waitFor { TrackingURLProtocol.state.withLock { $0.requests.count == 2 } }
        let bodies = TrackingURLProtocol.state.withLock { $0.requests.compactMap(\.httpBody) }
        let events = try bodies.map { try JSONDecoder().decode(CapturedEvent.self, from: $0) }
        #expect(events.filter { $0.event == "$exception" }.count == 1)
        #expect(events.first { $0.event == "$exception" }?.properties.operation == "background_sync")
        for body in bodies {
            #expect(!String(decoding: body, as: UTF8.self).contains("private"))
        }
    }

    @Test
    func existingPreferencesRequireANewConsentChoice() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        #expect(preferences.trackingConsent == .notAsked)
    }
}

private struct CapturedEvent: Decodable {
    var apiKey: String
    var event: String
    var distinctID: String
    var properties: Properties
    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case distinctID = "distinct_id"
        case event, properties
    }
    struct Properties: Decodable {
        var operation: String
        var processPersonProfile: Bool
        var exceptionList: [ExceptionItem]?
        enum CodingKeys: String, CodingKey {
            case operation
            case processPersonProfile = "$process_person_profile"
            case exceptionList = "$exception_list"
        }
    }
    struct ExceptionItem: Decodable {
        var type: String
        var value: String
    }
}
