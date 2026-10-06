import Foundation
import OwnCloudKit
import Testing
@testable import WesomeCloudAppCore
import WesomeCloudShared

private struct StubCapabilitiesFetcher: CapabilitiesFetching {
    var capabilities: ServerCapabilities

    func fetchCapabilities(serverURL _: URL, credentials _: Credentials) async throws -> ServerCapabilities {
        capabilities
    }
}

private actor RecordingCapabilitiesFetcher: CapabilitiesFetching {
    var requestedCredentials: Credentials?
    var capabilities: ServerCapabilities

    init(capabilities: ServerCapabilities) {
        self.capabilities = capabilities
    }

    func fetchCapabilities(serverURL _: URL, credentials: Credentials) async throws -> ServerCapabilities {
        requestedCredentials = credentials
        return capabilities
    }
}

private actor RecordingSpacesFetcher: SpacesFetching {
    var requestedCredentials: Credentials?
    var spaces: [OwnCloudSpace]

    init(spaces: [OwnCloudSpace]) {
        self.spaces = spaces
    }

    func fetchSpaces(serverURL _: URL, credentials: Credentials) async throws -> [OwnCloudSpace] {
        requestedCredentials = credentials
        return spaces
    }
}

private actor RecordingNotificationsFetcher: NotificationsFetching {
    var requestedCredentials: Credentials?
    var deletedID: Int?
    var notifications: [UserNotification]

    init(notifications: [UserNotification]) {
        self.notifications = notifications
    }

    func fetchNotifications(serverURL _: URL, credentials: Credentials) async throws -> [UserNotification] {
        requestedCredentials = credentials
        return notifications
    }

    func deleteNotification(id: Int, serverURL _: URL, credentials: Credentials) async throws {
        requestedCredentials = credentials
        deletedID = id
    }
}

private struct StubOAuthAuthenticator: OAuthAuthenticating {
    var tokenSet: OAuthTokenSet

    func authenticate(serverURL _: URL) async throws -> OAuthTokenSet {
        tokenSet
    }
}

private actor StubRefreshExchanger: OAuthRefreshTokenExchanging {
    var requestedRefreshToken: String?
    var requestedConfiguration: OAuthAuthorizationConfiguration?
    var tokenSet: OAuthTokenSet

    init(tokenSet: OAuthTokenSet) {
        self.tokenSet = tokenSet
    }

    func refreshAccessToken(_ refreshToken: String, serverURL _: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        requestedRefreshToken = refreshToken
        requestedConfiguration = configuration
        return tokenSet
    }
}

private actor OpenedURLRecorder {
    var url: URL?

    func record(_ url: URL) {
        self.url = url
    }
}

private actor TokenTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Data, Int)]

    init(data: Data, status: Int = 200) {
        self.responses = [(data, status)]
    }

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    var request: URLRequest? {
        requests.last
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty ? (Data(), 500) : responses.removeFirst()
        return (
            response.0,
            HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Test
func accountSessionServiceValidatesCapabilitiesThenStoresCredential() async throws {
    let credentials = MemoryCredentialStore()
    let diagnostics = MemoryDiagnosticSink()
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: StubCapabilitiesFetcher(
            capabilities: ServerCapabilities(versionString: "10.15.0", edition: "Community", remotePollInterval: 45)
        ),
        diagnostics: diagnostics
    )

    let session = try await service.addAccount(
        serverURL: URL(string: "https://cloud.example/")!,
        username: "alice",
        appPassword: "app-password"
    )

    #expect(session.account.username == "alice")
    #expect(session.serverVersion == "10.15.0")
    #expect(session.serverPollInterval == 45)
    let stored = try await credentials.credential(accountID: session.account.id)
    #expect(stored?.secret == "app-password")
    #expect(stored?.kind == .appPassword)
    #expect(await diagnostics.events.first?.category == "Account")
}

@Test
func accountSessionServiceReconnectsExistingAccountIDWithNewCredential() async throws {
    let credentials = MemoryCredentialStore()
    let diagnostics = MemoryDiagnosticSink()
    let capabilities = RecordingCapabilitiesFetcher(
        capabilities: ServerCapabilities(versionString: "10.15.1", edition: "Community")
    )
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: capabilities,
        diagnostics: diagnostics
    )
    let account = Account(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        serverURL: URL(string: "https://cloud.example")!,
        username: "alice",
        displayName: "Alice Cloud"
    )

    let session = try await service.reconnectAccount(account, appPassword: "new-secret")

    #expect(session.account.id == account.id)
    #expect(session.account.displayName == "Alice Cloud")
    #expect(session.account.serverURL.absoluteString == "https://cloud.example/")
    #expect(session.serverVersion == "10.15.1")
    #expect(await capabilities.requestedCredentials?.authorizationHeader == "Basic YWxpY2U6bmV3LXNlY3JldA==")
    let stored = try await credentials.credential(accountID: account.id)
    #expect(stored?.username == "alice")
    #expect(stored?.secret == "new-secret")
    #expect(stored?.kind == .appPassword)
    #expect(await diagnostics.events.first?.message == "Reconnected account alice")
}

@Test
func accountSessionServiceListsSpacesWithStoredCredentials() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let spaces = RecordingSpacesFetcher(spaces: [
        OwnCloudSpace(
            id: "space-1",
            name: "Marketing",
            webDAVURL: URL(string: "https://cloud.example/dav/spaces/space-1")!
        ),
    ])
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: StubCapabilitiesFetcher(capabilities: ServerCapabilities()),
        spacesFetcher: spaces
    )

    let listed = try await service.spaces(for: account)

    #expect(listed.map(\.name) == ["Marketing"])
    #expect(await spaces.requestedCredentials?.authorizationHeader.hasPrefix("Basic ") == true)
}

@Test
func accountSessionServiceListsAndDeletesNotificationsWithStoredCredentials() async throws {
    let credentials = MemoryCredentialStore()
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    try await credentials.save(Credential(accountID: account.id, username: "alice", secret: "secret", kind: .appPassword))
    let notifications = RecordingNotificationsFetcher(notifications: [
        UserNotification(id: 42, app: "files_sharing", user: "alice", subject: "Share request"),
    ])
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: StubCapabilitiesFetcher(capabilities: ServerCapabilities()),
        notificationsFetcher: notifications
    )

    let listed = try await service.notifications(for: account)
    try await service.deleteNotification(id: 42, for: account)

    #expect(listed.map(\.id) == [42])
    #expect(await notifications.requestedCredentials?.authorizationHeader.hasPrefix("Basic ") == true)
    #expect(await notifications.deletedID == 42)
}

private actor RecordingCurrentUserFetcher: CurrentUserFetching {
    let userID: String
    var requestedAuthorization: String?

    init(userID: String) {
        self.userID = userID
    }

    func fetchCurrentUserID(serverURL _: URL, credentials: Credentials) async throws -> String {
        requestedAuthorization = credentials.authorizationHeader
        return userID
    }
}

@Test
func accountSessionServiceLooksUpUserIDWhenOIDCTokenResponseOmitsIt() async throws {
    let credentials = MemoryCredentialStore()
    let currentUser = RecordingCurrentUserFetcher(userID: "patrik.simms")
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: StubCapabilitiesFetcher(capabilities: ServerCapabilities()),
        currentUserFetcher: currentUser
    )

    let session = try await service.addOAuthAccount(
        serverURL: URL(string: "https://cloud.example")!,
        authenticator: StubOAuthAuthenticator(
            tokenSet: OAuthTokenSet(username: "", accessToken: "access-token", refreshToken: "refresh-token")
        )
    )

    // The username feeds the WebDAV root (/remote.php/dav/files/<user>/), so it must be the server's id.
    #expect(session.account.username == "patrik.simms")
    #expect(await currentUser.requestedAuthorization == "Bearer access-token")
    #expect(try await credentials.credential(accountID: session.account.id)?.username == "patrik.simms")
}

@Test
func accountSessionServiceStoresOAuthRefreshTokenAfterBearerCapabilityValidation() async throws {
    let credentials = MemoryCredentialStore()
    let diagnostics = MemoryDiagnosticSink()
    let capabilities = RecordingCapabilitiesFetcher(
        capabilities: ServerCapabilities(versionString: "11.0.0", edition: "Enterprise")
    )
    let service = AccountSessionService(
        credentialStore: credentials,
        capabilitiesFetcher: capabilities,
        diagnostics: diagnostics
    )

    let session = try await service.addOAuthAccount(
        serverURL: URL(string: "https://cloud.example")!,
        authenticator: StubOAuthAuthenticator(
            tokenSet: OAuthTokenSet(
                username: "oauth-user",
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
    )

    #expect(session.account.username == "oauth-user")
    #expect(session.account.serverURL.absoluteString == "https://cloud.example/")
    #expect(session.credentialKind == .oauthRefreshToken)
    #expect(session.serverEdition == "Enterprise")
    #expect(await capabilities.requestedCredentials?.authorizationHeader == "Bearer access-token")
    let stored = try await credentials.credential(accountID: session.account.id)
    #expect(stored?.secret == "refresh-token")
    #expect(stored?.kind == .oauthRefreshToken)
    #expect(await diagnostics.events.first?.message == "Added OAuth account oauth-user")
}

@Test
func oauthAuthorizationConfigurationBuildsURLAndParsesCallback() throws {
    let configuration = OAuthAuthorizationConfiguration(
        clientID: "client-1",
        redirectURI: URL(string: "wesomecloud://callback")!,
        scopes: ["openid", "offline_access"],
        usesPKCE: false
    )

    let url = configuration.authorizationURL(serverURL: URL(string: "https://cloud.example/")!, state: "state-1")
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    #expect(url.absoluteString.hasPrefix("https://cloud.example/index.php/apps/oauth2/authorize?"))
    #expect(query["response_type"] == "code")
    #expect(query["client_id"] == "client-1")
    #expect(query["redirect_uri"] == "wesomecloud://callback")
    #expect(query["scope"] == "openid offline_access")
    #expect(query["state"] == "state-1")
    #expect(try OAuthCallbackParser.authorizationCode(from: URL(string: "wesomecloud://callback?code=abc&state=state-1")!, expectedState: "state-1") == "abc")
}

@Test
func oauthAuthorizationConfigurationNormalizesLoopbackRootRedirectForKeycloak() throws {
    let configuration = OAuthAuthorizationConfiguration(
        redirectURI: URL(string: "http://127.0.0.1:49152/")!
    )

    let url = configuration.authorizationURL(serverURL: URL(string: "https://cloud.example/")!, state: "state-1")
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

    #expect(query["redirect_uri"] == "http://127.0.0.1:49152")
    #expect(configuration.redirectURIOAuthParameter == "http://127.0.0.1:49152")
}

@Test
func oauthAuthorizationConfigurationPreservesNonRootRedirectPaths() throws {
    let configuration = OAuthAuthorizationConfiguration(
        redirectURI: URL(string: "http://127.0.0.1:49152/callback")!
    )

    #expect(configuration.redirectURIOAuthParameter == "http://127.0.0.1:49152/callback")
}

@Test
func browserOAuthAuthenticatorOpensAuthorizationURLAndExchangesCallbackCode() async throws {
    let recorder = OpenedURLRecorder()
    let transport = TokenTransport(data: Data("""
    {
      "access_token": "access-token",
      "refresh_token": "refresh-token",
      "expires_in": 3600,
      "user_id": "alice"
    }
    """.utf8))
    let authenticator = BrowserOAuthAuthenticator(
        configuration: OAuthAuthorizationConfiguration(
            clientID: "client-1",
            clientSecret: "secret",
            redirectURI: URL(string: "wesomecloud://oauth/callback")!,
            usesPKCE: true
        ),
        tokenExchanger: OwnCloudOAuthTokenExchanger(
            transport: transport,
            now: { Date(timeIntervalSince1970: 100) }
        ),
        discoveryClient: nil,
        stateProvider: { "state-1" },
        pkceVerifierProvider: { "test-verifier" },
        openAuthorizationURL: { url, _ in
            await recorder.record(url)
            return URL(string: "wesomecloud://oauth/callback?code=abc&state=state-1")!
        }
    )

    let tokenSet = try await authenticator.authenticate(serverURL: URL(string: "https://cloud.example/")!)

    #expect(await recorder.url?.absoluteString.contains("client_id=client-1") == true)
    #expect(await recorder.url?.absoluteString.contains("code_challenge=") == true)
    #expect(await recorder.url?.absoluteString.contains("code_challenge_method=S256") == true)
    #expect(tokenSet == OAuthTokenSet(username: "alice", accessToken: "access-token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 3700)))
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://cloud.example/index.php/apps/oauth2/api/v1/token")
    #expect(request?.httpMethod == "POST")
    #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
    let body = String(data: request?.httpBody ?? Data(), encoding: .utf8)
    #expect(body?.contains("client_id=client-1") == true)
    #expect(body?.contains("client_secret=secret") == false)
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Basic Y2xpZW50LTE6c2VjcmV0")
    #expect(body?.contains("code=abc") == true)
    #expect(body?.contains("grant_type=authorization_code") == true)
    #expect(body?.contains("redirect_uri=wesomecloud%3A%2F%2Foauth%2Fcallback") == true)
    #expect(body?.contains("code_verifier=test-verifier") == true)
}

@Test
func browserOAuthAuthenticatorDiscoversOIDCEndpointsAndPreparesRedirectURI() async throws {
    let recorder = OpenedURLRecorder()
    let transport = TokenTransport(responses: [
        (Data("""
        {
          "authorization_endpoint": "https://sso.example/auth",
          "token_endpoint": "https://sso.example/token",
          "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
        }
        """.utf8), 200),
        (Data("""
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token",
          "user_id": "alice"
        }
        """.utf8), 200),
    ])
    let authenticator = BrowserOAuthAuthenticator(
        configuration: OAuthAuthorizationConfiguration(clientID: "client-1", clientSecret: "secret"),
        tokenExchanger: OwnCloudOAuthTokenExchanger(transport: transport),
        discoveryClient: OAuthDiscoveryClient(transport: transport),
        stateProvider: { "state-1" },
        pkceVerifierProvider: { "test-verifier" },
        prepareRedirectURI: { _ in URL(string: "http://127.0.0.1:49152")! },
        openAuthorizationURL: { url, redirectURI in
            await recorder.record(url)
            return URL(string: "\(redirectURI.absoluteString)/?code=abc&state=state-1")!
        }
    )

    let tokenSet = try await authenticator.authenticate(serverURL: URL(string: "https://cloud.example/")!)

    #expect(tokenSet.username == "alice")
    #expect(await recorder.url?.absoluteString.hasPrefix("https://sso.example/auth?") == true)
    #expect(await recorder.url?.absoluteString.contains("redirect_uri=http://127.0.0.1:49152") == true)
    let requests = await transport.requests
    #expect(requests.first?.url?.absoluteString == "https://cloud.example/.well-known/openid-configuration")
    #expect(requests.last?.url?.absoluteString == "https://sso.example/token")
    let body = String(data: requests.last?.httpBody ?? Data(), encoding: .utf8)
    #expect(body?.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152") == true)
    #expect(body?.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2F") == false)
    #expect(body?.contains("code_verifier=test-verifier") == true)
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic Y2xpZW50LTE6c2VjcmV0")
}

@Test
func oauthTokenExchangerRefreshesAccessTokensWithRefreshGrant() async throws {
    let transport = TokenTransport(data: Data("""
    {
      "access_token": "new-access",
      "refresh_token": "new-refresh",
      "expires_in": 1800,
      "user_id": "alice"
    }
    """.utf8))
    let exchanger = OwnCloudOAuthTokenExchanger(
        transport: transport,
        now: { Date(timeIntervalSince1970: 200) }
    )

    let tokenSet = try await exchanger.refreshAccessToken(
        "old-refresh",
        serverURL: URL(string: "https://cloud.example/")!,
        configuration: OAuthAuthorizationConfiguration(clientID: "client-1", clientSecret: "secret")
    )

    #expect(tokenSet == OAuthTokenSet(username: "alice", accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date(timeIntervalSince1970: 2000)))
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://cloud.example/index.php/apps/oauth2/api/v1/token")
    #expect(request?.httpMethod == "POST")
    let body = String(data: request?.httpBody ?? Data(), encoding: .utf8)
    #expect(body?.contains("grant_type=refresh_token") == true)
    #expect(body?.contains("refresh_token=old-refresh") == true)
    #expect(body?.contains("client_id=client-1") == true)
    #expect(body?.contains("client_secret=secret") == false)
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Basic Y2xpZW50LTE6c2VjcmV0")
}

@Test
func oauthTokenExchangerSurfacesOAuthErrorPayloads() async throws {
    let transport = TokenTransport(data: Data("""
    {
      "error": "invalid_grant",
      "error_description": "Code not valid"
    }
    """.utf8), status: 400)
    let exchanger = OwnCloudOAuthTokenExchanger(transport: transport)

    do {
        _ = try await exchanger.exchangeAuthorizationCode(
            "bad-code",
            serverURL: URL(string: "https://cloud.example/")!,
            configuration: OAuthAuthorizationConfiguration(clientID: "client-1", clientSecret: "secret")
        )
        Issue.record("Expected token exchange to fail")
    } catch WesomeCloudError.unsupported(let message) {
        #expect(message == "OAuth token exchange failed: Code not valid")
    }
}

@Test
func oauthTokenExchangerReportsMissingRefreshToken() async throws {
    let transport = TokenTransport(data: Data("""
    {
      "access_token": "access-token",
      "expires_in": 300
    }
    """.utf8))
    let exchanger = OwnCloudOAuthTokenExchanger(transport: transport)

    do {
        _ = try await exchanger.exchangeAuthorizationCode(
            "code",
            serverURL: URL(string: "https://cloud.example/")!,
            configuration: OAuthAuthorizationConfiguration(clientID: "client-1", clientSecret: "secret")
        )
        Issue.record("Expected token exchange to fail")
    } catch WesomeCloudError.unsupported(let message) {
        #expect(message == "OAuth token exchange did not return a refresh token.")
    }
}

@Test
func oauthTokenExchangerKeepsRefreshTokenWhenRefreshResponseOmitsIt() async throws {
    let transport = TokenTransport(data: Data("""
    {
      "access_token": "new-access",
      "expires_in": 300,
      "user_id": "alice"
    }
    """.utf8))
    let exchanger = OwnCloudOAuthTokenExchanger(transport: transport)

    let tokenSet = try await exchanger.refreshAccessToken(
        "old-refresh",
        serverURL: URL(string: "https://cloud.example/")!,
        configuration: OAuthAuthorizationConfiguration(clientID: "client-1")
    )

    #expect(tokenSet.accessToken == "new-access")
    #expect(tokenSet.refreshToken == "old-refresh")
}

@Test
func oauthTokenExchangerReportsRejectedRefreshTokenAsAuthenticationFailure() async throws {
    let transport = TokenTransport(data: Data("""
    { "error": "invalid_grant", "error_description": "Token expired" }
    """.utf8), status: 400)
    let exchanger = OwnCloudOAuthTokenExchanger(transport: transport)

    do {
        _ = try await exchanger.refreshAccessToken(
            "revoked-refresh",
            serverURL: URL(string: "https://cloud.example/")!,
            configuration: OAuthAuthorizationConfiguration(clientID: "client-1")
        )
        Issue.record("Expected refresh to fail")
    } catch WesomeCloudError.httpFailure(let failure) {
        #expect(failure.kind == .authentication)
    }
}

@Test
func accountCredentialResolverExchangesRefreshTokensAndReturnsBearerCredentials() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "old-refresh", kind: .oauthRefreshToken)
    let exchanger = StubRefreshExchanger(
        tokenSet: OAuthTokenSet(username: "alice", accessToken: "new-access", refreshToken: "new-refresh")
    )
    let resolver = AccountCredentialResolver(discoveryClient: nil, refreshExchanger: exchanger)

    let resolved = try await resolver.resolve(account: account, credential: credential)

    #expect(resolved.credentials.authorizationHeader == "Bearer new-access")
    #expect(resolved.updatedCredential == Credential(accountID: account.id, username: "alice", secret: "new-refresh", kind: .oauthRefreshToken))
    #expect(await exchanger.requestedRefreshToken == "old-refresh")
}

@Test
func accountCredentialResolverDiscoversOAuthTokenEndpointBeforeRefreshing() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let credential = Credential(accountID: account.id, username: "alice", secret: "old-refresh", kind: .oauthRefreshToken)
    let discovery = Data("""
    {
      "authorization_endpoint": "https://id.example/oauth/authorize",
      "token_endpoint": "https://id.example/oauth/token",
      "token_endpoint_auth_methods_supported": ["client_secret_post"]
    }
    """.utf8)
    let transport = TokenTransport(data: discovery)
    let exchanger = StubRefreshExchanger(
        tokenSet: OAuthTokenSet(username: "alice", accessToken: "new-access", refreshToken: "new-refresh")
    )
    let resolver = AccountCredentialResolver(
        discoveryClient: OAuthDiscoveryClient(transport: transport),
        refreshExchanger: exchanger
    )

    _ = try await resolver.resolve(account: account, credential: credential)

    #expect(await transport.request?.url?.absoluteString == "https://cloud.example/.well-known/openid-configuration")
    #expect(await exchanger.requestedConfiguration?.tokenEndpoint == URL(string: "https://id.example/oauth/token")!)
    #expect(await exchanger.requestedConfiguration?.tokenEndpointAuthMethod == .clientSecretPost)
}
