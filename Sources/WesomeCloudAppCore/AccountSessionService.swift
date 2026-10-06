import Foundation
import CryptoKit
import OwnCloudKit
import WesomeCloudShared

public protocol CapabilitiesFetching: Sendable {
    func fetchCapabilities(serverURL: URL, credentials: Credentials) async throws -> ServerCapabilities
}

public protocol CurrentUserFetching: Sendable {
    func fetchCurrentUserID(serverURL: URL, credentials: Credentials) async throws -> String
}

public protocol SpacesFetching: Sendable {
    func fetchSpaces(serverURL: URL, credentials: Credentials) async throws -> [OwnCloudSpace]
}

public protocol NotificationsFetching: Sendable {
    func fetchNotifications(serverURL: URL, credentials: Credentials) async throws -> [UserNotification]
    func deleteNotification(id: Int, serverURL: URL, credentials: Credentials) async throws
}

public struct OAuthTokenSet: Equatable, Sendable {
    /// `user_id`/`username` from the token response; empty when the server doesn't send one (OIDC).
    public var username: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date?

    public init(username: String, accessToken: String, refreshToken: String, expiresAt: Date? = nil) {
        self.username = username
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol OAuthAuthenticating: Sendable {
    func authenticate(serverURL: URL) async throws -> OAuthTokenSet
}

public struct OAuthAuthorizationConfiguration: Equatable, Sendable {
    public enum TokenEndpointAuthMethod: String, Sendable {
        case clientSecretBasic = "client_secret_basic"
        case clientSecretPost = "client_secret_post"
    }

    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: URL
    public var scopes: [String]
    public var authorizationEndpoint: URL?
    public var tokenEndpoint: URL?
    public var authorizationPath: String
    public var tokenPath: String
    public var usesPKCE: Bool
    public var pkceCodeVerifier: String?
    public var tokenEndpointAuthMethod: TokenEndpointAuthMethod

    public init(
        clientID: String = "xdXOt13JKxym1B1QcEncf2XDkLAexMBFwiT9j6EfhhHFJhs2KM9jbjTmf8JBXE69",
        clientSecret: String? = "UBntmLjC2yYCeHwsyj73Uwo9TAaecAetRwMw0xYcvNL9yRdLSUi0hUAHfvCHFeFh",
        redirectURI: URL = URL(string: "http://127.0.0.1")!,
        scopes: [String] = ["openid", "offline_access", "email", "profile"],
        authorizationEndpoint: URL? = nil,
        tokenEndpoint: URL? = nil,
        authorizationPath: String = "index.php/apps/oauth2/authorize",
        tokenPath: String = "index.php/apps/oauth2/api/v1/token",
        usesPKCE: Bool = true,
        pkceCodeVerifier: String? = nil,
        tokenEndpointAuthMethod: TokenEndpointAuthMethod = .clientSecretBasic
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.authorizationPath = authorizationPath
        self.tokenPath = tokenPath
        self.usesPKCE = usesPKCE
        self.pkceCodeVerifier = pkceCodeVerifier
        self.tokenEndpointAuthMethod = tokenEndpointAuthMethod
    }

    public func authorizationURL(serverURL: URL, state: String, pkceChallenge: String? = nil) -> URL {
        var components = URLComponents(url: authorizationEndpoint ?? serverURL.appending(path: authorizationPath), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURIOAuthParameter),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        if let pkceChallenge {
            components.queryItems?.append(URLQueryItem(name: "code_challenge", value: pkceChallenge))
            components.queryItems?.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        return components.url!
    }

    public func tokenURL(serverURL: URL) -> URL {
        tokenEndpoint ?? serverURL.appending(path: tokenPath)
    }

    public var redirectURIOAuthParameter: String {
        guard
            (redirectURI.scheme == "http" || redirectURI.scheme == "https"),
            redirectURI.host == "127.0.0.1" || redirectURI.host == "localhost",
            redirectURI.path == "/",
            redirectURI.query == nil,
            redirectURI.fragment == nil
        else {
            return redirectURI.absoluteString
        }
        return String(redirectURI.absoluteString.dropLast())
    }
}

public struct OAuthDiscoveryDocument: Decodable, Sendable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var tokenEndpointAuthMethodsSupported: [String]

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationEndpoint = try container.decode(URL.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try container.decode(URL.self, forKey: .tokenEndpoint)
        tokenEndpointAuthMethodsSupported = try container.decodeIfPresent([String].self, forKey: .tokenEndpointAuthMethodsSupported) ?? []
    }
}

public struct OAuthDiscoveryClient: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func discover(serverURL: URL) async throws -> OAuthDiscoveryDocument {
        let request = URLRequest(url: serverURL.appending(path: ".well-known/openid-configuration"))
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw WesomeCloudError.unsupported(
                "OAuth discovery failed with HTTP \(response.statusCode). \(Self.responseSnippet(data))"
            )
        }
        do {
            return try JSONDecoder().decode(OAuthDiscoveryDocument.self, from: data)
        } catch {
            throw WesomeCloudError.unsupported(
                "OAuth discovery returned an unexpected response. \(Self.decodingSummary(error)) \(Self.responseSnippet(data))"
            )
        }
    }

    private static func responseSnippet(_ data: Data) -> String {
        guard !data.isEmpty else { return "The response body was empty." }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? "<non-UTF-8 response>"
        return "Response: \(text.replacingOccurrences(of: "\n", with: " "))"
    }

    private static func decodingSummary(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "" }
        return decodingError.oauthSummary
    }
}

public protocol OAuthTokenExchanging: Sendable {
    func exchangeAuthorizationCode(_ code: String, serverURL: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet
}

public protocol OAuthRefreshTokenExchanging: Sendable {
    func refreshAccessToken(_ refreshToken: String, serverURL: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet
}

public enum OAuthCallbackParser {
    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw WesomeCloudError.unsupported("OAuth authorization failed: \(error)")
        }
        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw WesomeCloudError.unsupported("OAuth state mismatch")
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw WesomeCloudError.unsupported("OAuth callback missing authorization code")
        }
        return code
    }
}

public enum OAuthPKCE {
    public static func randomVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

public struct BrowserOAuthAuthenticator: OAuthAuthenticating {
    public var configuration: OAuthAuthorizationConfiguration
    public var tokenExchanger: OAuthTokenExchanging
    public var discoveryClient: OAuthDiscoveryClient?
    public var stateProvider: @Sendable () -> String
    public var pkceVerifierProvider: @Sendable () -> String
    public var prepareRedirectURI: @Sendable (URL) async throws -> URL
    public var openAuthorizationURL: @Sendable (URL, URL) async throws -> URL

    public init(
        configuration: OAuthAuthorizationConfiguration = OAuthAuthorizationConfiguration(),
        tokenExchanger: OAuthTokenExchanging = OwnCloudOAuthTokenExchanger(),
        discoveryClient: OAuthDiscoveryClient? = OAuthDiscoveryClient(),
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        pkceVerifierProvider: @escaping @Sendable () -> String = { OAuthPKCE.randomVerifier() },
        prepareRedirectURI: @escaping @Sendable (URL) async throws -> URL = { $0 },
        openAuthorizationURL: @escaping @Sendable (URL, URL) async throws -> URL
    ) {
        self.configuration = configuration
        self.tokenExchanger = tokenExchanger
        self.discoveryClient = discoveryClient
        self.stateProvider = stateProvider
        self.pkceVerifierProvider = pkceVerifierProvider
        self.prepareRedirectURI = prepareRedirectURI
        self.openAuthorizationURL = openAuthorizationURL
    }

    public func authenticate(serverURL: URL) async throws -> OAuthTokenSet {
        let state = stateProvider()
        var resolvedConfiguration = configuration
        if let discoveryClient {
            let discovery = try await discoveryClient.discover(serverURL: serverURL)
            resolvedConfiguration.authorizationEndpoint = discovery.authorizationEndpoint
            resolvedConfiguration.tokenEndpoint = discovery.tokenEndpoint
            if discovery.tokenEndpointAuthMethodsSupported.contains(OAuthAuthorizationConfiguration.TokenEndpointAuthMethod.clientSecretBasic.rawValue) {
                resolvedConfiguration.tokenEndpointAuthMethod = .clientSecretBasic
            } else if discovery.tokenEndpointAuthMethodsSupported.contains(OAuthAuthorizationConfiguration.TokenEndpointAuthMethod.clientSecretPost.rawValue) {
                resolvedConfiguration.tokenEndpointAuthMethod = .clientSecretPost
            }
        }
        resolvedConfiguration.redirectURI = try await prepareRedirectURI(resolvedConfiguration.redirectURI)
        let verifier = resolvedConfiguration.usesPKCE ? pkceVerifierProvider() : nil
        resolvedConfiguration.pkceCodeVerifier = verifier
        let authorizationURL = resolvedConfiguration.authorizationURL(
            serverURL: serverURL,
            state: state,
            pkceChallenge: verifier.map { OAuthPKCE.challenge(for: $0) }
        )
        let callbackURL = try await openAuthorizationURL(authorizationURL, resolvedConfiguration.redirectURI)
        let code = try OAuthCallbackParser.authorizationCode(from: callbackURL, expectedState: state)
        return try await tokenExchanger.exchangeAuthorizationCode(code, serverURL: serverURL, configuration: resolvedConfiguration)
    }
}

public struct OwnCloudOAuthTokenExchanger: OAuthTokenExchanging, OAuthRefreshTokenExchanging {
    private let transport: HTTPTransport
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date

    public init(transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.decoder = JSONDecoder()
        self.now = now
    }

    public func exchangeAuthorizationCode(_ code: String, serverURL: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        var fields: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURIOAuthParameter,
            "client_id": configuration.clientID,
        ]
        if configuration.usesPKCE, let codeVerifier = configuration.pkceCodeVerifier {
            fields["code_verifier"] = codeVerifier
        }
        return try await requestToken(fields: fields, serverURL: serverURL, configuration: configuration)
    }

    public func refreshAccessToken(_ refreshToken: String, serverURL: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        let fields: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ]
        return try await requestToken(fields: fields, serverURL: serverURL, configuration: configuration)
    }

    private func requestToken(fields inputFields: [String: String], serverURL: URL, configuration: OAuthAuthorizationConfiguration) async throws -> OAuthTokenSet {
        var request = URLRequest(url: configuration.tokenURL(serverURL: serverURL))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = inputFields
        if let clientSecret = configuration.clientSecret, configuration.tokenEndpointAuthMethod == .clientSecretPost {
            fields["client_secret"] = clientSecret
        } else if let clientSecret = configuration.clientSecret, configuration.tokenEndpointAuthMethod == .clientSecretBasic {
            let credentials = "\(configuration.clientID):\(clientSecret)"
            request.setValue("Basic \(Data(credentials.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await transport.data(for: request)
        let previousRefreshToken = fields["grant_type"] == "refresh_token" ? fields["refresh_token"] : nil
        if let error = try? decoder.decode(OAuthErrorPayload.self, from: data), error.hasError {
            // A rejected refresh token means the user has to sign in again.
            if previousRefreshToken != nil, error.error == "invalid_grant" {
                throw WesomeCloudError.httpFailure(HTTPFailure(statusCode: response.statusCode, kind: .authentication))
            }
            throw WesomeCloudError.unsupported("OAuth token exchange failed: \(error.message)")
        }
        guard response.statusCode == 200 else {
            throw WesomeCloudError.httpFailure(
                HTTPFailure.classify(
                    statusCode: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        let payload: OAuthTokenPayload
        do {
            payload = try decoder.decode(OAuthTokenPayload.self, from: data)
        } catch {
            throw WesomeCloudError.unsupported(
                "OAuth token exchange returned an unexpected response. \(Self.decodingSummary(error)) \(Self.responseSnippet(data))"
            )
        }
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw WesomeCloudError.unsupported("OAuth token exchange did not return an access token.")
        }
        // Refresh responses may omit refresh_token (RFC 6749 section 6); the old one stays valid then.
        let refreshToken = payload.refreshToken?.isEmpty == false ? payload.refreshToken : previousRefreshToken
        guard let refreshToken else {
            throw WesomeCloudError.unsupported("OAuth token exchange did not return a refresh token.")
        }
        return OAuthTokenSet(
            username: payload.username,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: payload.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    private static func responseSnippet(_ data: Data) -> String {
        guard !data.isEmpty else { return "The response body was empty." }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? "<non-UTF-8 response>"
        return "Response: \(text.replacingOccurrences(of: "\n", with: " "))"
    }

    private static func decodingSummary(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "" }
        return decodingError.oauthSummary
    }
}

public struct ResolvedAccountCredentials: Equatable, Sendable {
    public var credentials: Credentials
    public var updatedCredential: Credential?

    public init(credentials: Credentials, updatedCredential: Credential? = nil) {
        self.credentials = credentials
        self.updatedCredential = updatedCredential
    }
}

public struct AccountCredentialResolver: Sendable {
    public var configuration: OAuthAuthorizationConfiguration
    public var discoveryClient: OAuthDiscoveryClient?
    public var refreshExchanger: OAuthRefreshTokenExchanging

    public init(
        configuration: OAuthAuthorizationConfiguration = OAuthAuthorizationConfiguration(),
        discoveryClient: OAuthDiscoveryClient? = OAuthDiscoveryClient(),
        refreshExchanger: OAuthRefreshTokenExchanging = OwnCloudOAuthTokenExchanger()
    ) {
        self.configuration = configuration
        self.discoveryClient = discoveryClient
        self.refreshExchanger = refreshExchanger
    }

    public func resolve(account: Account, credential: Credential) async throws -> ResolvedAccountCredentials {
        switch credential.kind {
        case .appPassword, .basicPassword:
            ResolvedAccountCredentials(credentials: Credentials(username: credential.username, password: credential.secret))
        case .oauthRefreshToken:
            try await resolveOAuth(account: account, credential: credential)
        }
    }

    private func resolveOAuth(account: Account, credential: Credential) async throws -> ResolvedAccountCredentials {
        var resolvedConfiguration = configuration
        if let discoveryClient {
            let discovery = try await discoveryClient.discover(serverURL: account.serverURL)
            resolvedConfiguration.authorizationEndpoint = discovery.authorizationEndpoint
            resolvedConfiguration.tokenEndpoint = discovery.tokenEndpoint
            if discovery.tokenEndpointAuthMethodsSupported.contains(OAuthAuthorizationConfiguration.TokenEndpointAuthMethod.clientSecretBasic.rawValue) {
                resolvedConfiguration.tokenEndpointAuthMethod = .clientSecretBasic
            } else if discovery.tokenEndpointAuthMethodsSupported.contains(OAuthAuthorizationConfiguration.TokenEndpointAuthMethod.clientSecretPost.rawValue) {
                resolvedConfiguration.tokenEndpointAuthMethod = .clientSecretPost
            }
        }
        let tokenSet = try await refreshExchanger.refreshAccessToken(
            credential.secret,
            serverURL: account.serverURL,
            configuration: resolvedConfiguration
        )
        let updatedCredential = Credential(
            accountID: credential.accountID,
            username: tokenSet.username.isEmpty ? credential.username : tokenSet.username,
            secret: tokenSet.refreshToken,
            kind: .oauthRefreshToken
        )
        return ResolvedAccountCredentials(
            credentials: Credentials(accessToken: tokenSet.accessToken),
            updatedCredential: updatedCredential == credential ? nil : updatedCredential
        )
    }
}

private struct OAuthTokenPayload: Decodable {
    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Int?
    var userID: String?
    var usernameClaim: String?

    var username: String {
        userID ?? usernameClaim ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userID = "user_id"
        case usernameClaim = "username"
    }
}

private struct OAuthErrorPayload: Decodable {
    var error: String?
    var errorDescription: String?

    var hasError: Bool {
        error?.isEmpty == false || errorDescription?.isEmpty == false
    }

    var message: String {
        errorDescription ?? error ?? "Unknown OAuth error"
    }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .oauthFormAllowed) ?? self
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static var oauthFormAllowed: CharacterSet {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }
}

private extension DecodingError {
    var oauthSummary: String {
        let context: DecodingError.Context
        switch self {
        case .typeMismatch(_, let value),
             .valueNotFound(_, let value),
             .keyNotFound(_, let value),
             .dataCorrupted(let value):
            context = value
        @unknown default:
            return ""
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let suffix = path.isEmpty ? "" : " at \(path)"
        return "\(context.debugDescription)\(suffix)."
    }
}

public struct OwnCloudCapabilitiesFetcher: CapabilitiesFetching {
    public init() {}

    public func fetchCapabilities(serverURL: URL, credentials: Credentials) async throws -> ServerCapabilities {
        try await CapabilitiesClient(serverURL: serverURL, credentials: credentials).fetchCapabilities()
    }
}

public struct OwnCloudCurrentUserFetcher: CurrentUserFetching {
    public init() {}

    public func fetchCurrentUserID(serverURL: URL, credentials: Credentials) async throws -> String {
        try await CapabilitiesClient(serverURL: serverURL, credentials: credentials).fetchCurrentUserID()
    }
}

public struct OwnCloudSpacesFetcher: SpacesFetching {
    public init() {}

    public func fetchSpaces(serverURL: URL, credentials: Credentials) async throws -> [OwnCloudSpace] {
        try await SpacesClient(serverURL: serverURL, credentials: credentials).listSpaces()
    }
}

public struct OwnCloudNotificationsFetcher: NotificationsFetching {
    public init() {}

    public func fetchNotifications(serverURL: URL, credentials: Credentials) async throws -> [UserNotification] {
        try await OCSNotificationsClient(serverURL: serverURL, credentials: credentials).notifications()
    }

    public func deleteNotification(id: Int, serverURL: URL, credentials: Credentials) async throws {
        try await OCSNotificationsClient(serverURL: serverURL, credentials: credentials).deleteNotification(id: id)
    }
}

public actor AccountSessionService {
    private let credentialStore: CredentialStore
    private let capabilitiesFetcher: CapabilitiesFetching
    private let currentUserFetcher: CurrentUserFetching
    private let spacesFetcher: SpacesFetching?
    private let notificationsFetcher: NotificationsFetching?
    private let credentialResolver: AccountCredentialResolver
    private let diagnostics: DiagnosticSink?

    public init(
        credentialStore: CredentialStore,
        capabilitiesFetcher: CapabilitiesFetching = OwnCloudCapabilitiesFetcher(),
        currentUserFetcher: CurrentUserFetching = OwnCloudCurrentUserFetcher(),
        spacesFetcher: SpacesFetching? = nil,
        notificationsFetcher: NotificationsFetching? = nil,
        credentialResolver: AccountCredentialResolver = AccountCredentialResolver(),
        diagnostics: DiagnosticSink? = nil
    ) {
        self.credentialStore = credentialStore
        self.capabilitiesFetcher = capabilitiesFetcher
        self.currentUserFetcher = currentUserFetcher
        self.spacesFetcher = spacesFetcher
        self.notificationsFetcher = notificationsFetcher
        self.credentialResolver = credentialResolver
        self.diagnostics = diagnostics
    }

    public func addAccount(serverURL: URL, username: String, appPassword: String) async throws -> AccountSession {
        let normalizedURL = serverURL.absoluteString.hasSuffix("/") ? serverURL : serverURL.appending(path: "")
        let account = Account(serverURL: normalizedURL, username: username)
        return try await validateAppPasswordAccount(account: account, appPassword: appPassword, diagnosticVerb: "Added")
    }

    public func reconnectAccount(_ account: Account, appPassword: String) async throws -> AccountSession {
        let normalizedURL = account.serverURL.absoluteString.hasSuffix("/") ? account.serverURL : account.serverURL.appending(path: "")
        let normalizedAccount = Account(
            id: account.id,
            serverURL: normalizedURL,
            username: account.username,
            displayName: account.displayName
        )
        return try await validateAppPasswordAccount(account: normalizedAccount, appPassword: appPassword, diagnosticVerb: "Reconnected")
    }

    private func validateAppPasswordAccount(account: Account, appPassword: String, diagnosticVerb: String) async throws -> AccountSession {
        let credential = Credential(
            accountID: account.id,
            username: account.username,
            secret: appPassword,
            kind: .appPassword
        )
        let capabilities = try await capabilitiesFetcher.fetchCapabilities(
            serverURL: account.serverURL,
            credentials: Credentials(username: account.username, password: appPassword)
        )
        try await credentialStore.save(credential)
        let session = AccountSession(
            account: account,
            credentialKind: credential.kind,
            serverVersion: capabilities.versionString,
            serverEdition: capabilities.edition,
            serverPollInterval: capabilities.remotePollInterval
        )
        await diagnostics?.record(DiagnosticEvent(category: "Account", level: .info, message: "\(diagnosticVerb) account \(account.username)"))
        return session
    }

    public func spaces(for account: Account) async throws -> [OwnCloudSpace] {
        guard let spacesFetcher else { return [] }
        let resolved = try await resolveCredentials(for: account)
        return try await spacesFetcher.fetchSpaces(serverURL: account.serverURL, credentials: resolved)
    }

    public func notifications(for account: Account) async throws -> [UserNotification] {
        guard let notificationsFetcher else { return [] }
        let resolved = try await resolveCredentials(for: account)
        return try await notificationsFetcher.fetchNotifications(serverURL: account.serverURL, credentials: resolved)
    }

    public func deleteNotification(id: Int, for account: Account) async throws {
        guard let notificationsFetcher else { return }
        let resolved = try await resolveCredentials(for: account)
        try await notificationsFetcher.deleteNotification(id: id, serverURL: account.serverURL, credentials: resolved)
    }

    public func removeCredentials(for accountID: UUID) async throws {
        try await credentialStore.delete(accountID: accountID)
    }

    private func resolveCredentials(for account: Account) async throws -> Credentials {
        guard let credential = try await credentialStore.credential(accountID: account.id) else {
            throw WesomeCloudError.unsupported("Missing credential for account \(account.id.uuidString)")
        }
        let resolved = try await credentialResolver.resolve(account: account, credential: credential)
        if let updatedCredential = resolved.updatedCredential {
            try await credentialStore.save(updatedCredential)
        }
        return resolved.credentials
    }

    public func addOAuthAccount(serverURL: URL, authenticator: OAuthAuthenticating) async throws -> AccountSession {
        let normalizedURL = serverURL.absoluteString.hasSuffix("/") ? serverURL : serverURL.appending(path: "")
        let tokenSet = try await authenticator.authenticate(serverURL: normalizedURL)
        let accessCredentials = Credentials(accessToken: tokenSet.accessToken)
        let username = tokenSet.username.isEmpty
            ? try await currentUserFetcher.fetchCurrentUserID(serverURL: normalizedURL, credentials: accessCredentials)
            : tokenSet.username
        let account = Account(serverURL: normalizedURL, username: username)
        let capabilities = try await capabilitiesFetcher.fetchCapabilities(
            serverURL: normalizedURL,
            credentials: accessCredentials
        )
        try await credentialStore.save(
            Credential(
                accountID: account.id,
                username: username,
                secret: tokenSet.refreshToken,
                kind: .oauthRefreshToken
            )
        )
        let session = AccountSession(
            account: account,
            credentialKind: .oauthRefreshToken,
            serverVersion: capabilities.versionString,
            serverEdition: capabilities.edition,
            serverPollInterval: capabilities.remotePollInterval
        )
        await diagnostics?.record(DiagnosticEvent(category: "Account", level: .info, message: "Added OAuth account \(username)"))
        return session
    }

}
