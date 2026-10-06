import Foundation
import WesomeCloudAppCore
import WesomeCloudShared

#if canImport(AuthenticationServices) && canImport(AppKit)
import AppKit
import AuthenticationServices
import Network

public struct ProductionOAuthAuthenticatorFactory: Sendable {
    public var configuration: OAuthAuthorizationConfiguration
    public var tokenExchanger: OAuthTokenExchanging
    public var discoveryClient: OAuthDiscoveryClient?
    public var stateProvider: @Sendable () -> String
    public var sessionPresenter: ASWebAuthenticationSessionPresenting

    @MainActor
    public init(
        configuration: OAuthAuthorizationConfiguration = OAuthAuthorizationConfiguration(),
        tokenExchanger: OAuthTokenExchanging = OwnCloudOAuthTokenExchanger(),
        discoveryClient: OAuthDiscoveryClient? = OAuthDiscoveryClient(),
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        sessionPresenter: ASWebAuthenticationSessionPresenting = ASWebAuthenticationSessionPresenter()
    ) {
        self.configuration = configuration
        self.tokenExchanger = tokenExchanger
        self.discoveryClient = discoveryClient
        self.stateProvider = stateProvider
        self.sessionPresenter = sessionPresenter
    }

    public func makeAuthenticator() -> OAuthAuthenticating {
        let loopbackHandler = LoopbackOAuthRedirectHandler()
        return BrowserOAuthAuthenticator(
            configuration: configuration,
            tokenExchanger: tokenExchanger,
            discoveryClient: discoveryClient,
            stateProvider: stateProvider,
            prepareRedirectURI: { redirectURI in
                guard redirectURI.scheme == "http" || redirectURI.scheme == "https" else { return redirectURI }
                return try await loopbackHandler.start(preferredRedirectURI: redirectURI)
            },
            openAuthorizationURL: { authorizationURL, redirectURI in
                guard let callbackScheme = redirectURI.scheme else {
                    throw WesomeCloudError.unsupported("OAuth redirect URI must include a callback scheme")
                }
                if callbackScheme == "http" || callbackScheme == "https" {
                    _ = await MainActor.run {
                        NSWorkspace.shared.open(authorizationURL)
                    }
                    return try await loopbackHandler.waitForCallback()
                }
                return try await sessionPresenter.openAuthorizationURL(authorizationURL, callbackScheme: callbackScheme)
            }
        )
    }
}

/// Receives the OAuth redirect on a one-shot HTTP listener bound to 127.0.0.1. Requests that
/// are not the redirect (browser preconnects, /favicon.ico) are answered with 404 and ignored.
final class LoopbackOAuthRedirectHandler: @unchecked Sendable {
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?
    private var redirectPath = "/"
    private var timeoutWorkItem: DispatchWorkItem?

    init(timeout: TimeInterval = 5 * 60) {
        self.timeout = timeout
    }

    func start(preferredRedirectURI: URL) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(with: .failure(WesomeCloudError.unsupported("OAuth sign-in timed out. Try again.")))
        }
        lock.withLock {
            self.listener = listener
            self.pendingResult = nil
            self.redirectPath = preferredRedirectURI.path.isEmpty ? "/" : preferredRedirectURI.path
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = timeoutWorkItem
        }
        let port = try await assignedPort(for: listener)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        var components = URLComponents(url: preferredRedirectURI, resolvingAgainstBaseURL: false)!
        components.host = preferredRedirectURI.host ?? "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = preferredRedirectURI.path
        return components.url!
    }

    private func assignedPort(for listener: NWListener) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = PortResolver(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port, port.rawValue != 0 else {
                        resolver.resume(.failure(WesomeCloudError.unsupported("Could not allocate OAuth callback port")))
                        return
                    }
                    resolver.resume(.success(port))
                case .failed(let error):
                    resolver.resume(.failure(error))
                case .cancelled:
                    resolver.resume(.failure(WesomeCloudError.unsupported("OAuth callback listener was cancelled")))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private final class PortResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NWEndpoint.Port, Error>?

        init(continuation: CheckedContinuation<NWEndpoint.Port, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<NWEndpoint.Port, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            switch result {
            case .success(let port):
                continuation?.resume(returning: port)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                switch pendingResult {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let callbackURL = data.flatMap({ Self.requestURL(from: $0) }), self.isRedirect(callbackURL) else {
                Self.respond(on: connection, status: "404 Not Found", body: "Not found.")
                return
            }
            Self.respond(on: connection, status: "200 OK", body: "You can return to WesomeCloud.")
            self.finish(with: .success(callbackURL))
        }
    }

    private static func requestURL(from data: Data) -> URL? {
        guard
            let request = String(data: data, encoding: .utf8),
            let firstLine = request.components(separatedBy: "\r\n").first,
            let target = firstLine.split(separator: " ").dropFirst().first
        else { return nil }
        return URL(string: "http://127.0.0.1\(target)")
    }

    /// The redirect carries `state` plus either `code` or an OAuth `error` on the configured path.
    private func isRedirect(_ url: URL) -> Bool {
        let expectedPath = lock.withLock { redirectPath }
        let queryNames = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        let path = url.path.isEmpty ? "/" : url.path
        return path == expectedPath && queryNames.contains("state") && !queryNames.isDisjoint(with: ["code", "error"])
    }

    private static func respond(on connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        guard listener != nil else {
            // Already finished (e.g. timeout firing after the redirect arrived).
            lock.unlock()
            return
        }
        let continuation = self.continuation
        self.continuation = nil
        listener?.cancel()
        listener = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()

        guard let continuation else { return }

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

public struct CustomSchemeOAuthAuthenticatorFactory: Sendable {
    public var configuration: OAuthAuthorizationConfiguration
    public var tokenExchanger: OAuthTokenExchanging
    public var discoveryClient: OAuthDiscoveryClient?
    public var stateProvider: @Sendable () -> String
    public var sessionPresenter: ASWebAuthenticationSessionPresenting

    @MainActor
    public init(
        configuration: OAuthAuthorizationConfiguration,
        tokenExchanger: OAuthTokenExchanging = OwnCloudOAuthTokenExchanger(),
        discoveryClient: OAuthDiscoveryClient? = OAuthDiscoveryClient(),
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        sessionPresenter: ASWebAuthenticationSessionPresenting = ASWebAuthenticationSessionPresenter()
    ) {
        self.configuration = configuration
        self.tokenExchanger = tokenExchanger
        self.discoveryClient = discoveryClient
        self.stateProvider = stateProvider
        self.sessionPresenter = sessionPresenter
    }

    public func makeAuthenticator() -> OAuthAuthenticating {
        BrowserOAuthAuthenticator(configuration: configuration, tokenExchanger: tokenExchanger, discoveryClient: discoveryClient, stateProvider: stateProvider) { authorizationURL, redirectURI in
            guard let callbackScheme = redirectURI.scheme else {
                throw WesomeCloudError.unsupported("OAuth redirect URI must include a callback scheme")
            }
            return try await sessionPresenter.openAuthorizationURL(authorizationURL, callbackScheme: callbackScheme)
        }
    }
}

public protocol ASWebAuthenticationSessionPresenting: Sendable {
    func openAuthorizationURL(_ authorizationURL: URL, callbackScheme: String) async throws -> URL
}

public final class ASWebAuthenticationSessionPresenter: NSObject, ASWebAuthenticationSessionPresenting, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private var session: ASWebAuthenticationSession?

    public override init() {
        super.init()
    }

    public func openAuthorizationURL(_ authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? WesomeCloudError.unsupported("OAuth browser session did not return a callback URL"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: WesomeCloudError.unsupported("Could not start OAuth browser session"))
            }
        }
    }

    public func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
#else
public struct ProductionOAuthAuthenticatorFactory: Sendable {
    public var configuration: OAuthAuthorizationConfiguration
    public var tokenExchanger: OAuthTokenExchanging
    public var discoveryClient: OAuthDiscoveryClient?
    public var stateProvider: @Sendable () -> String

    public init(
        configuration: OAuthAuthorizationConfiguration = OAuthAuthorizationConfiguration(),
        tokenExchanger: OAuthTokenExchanging = OwnCloudOAuthTokenExchanger(),
        discoveryClient: OAuthDiscoveryClient? = OAuthDiscoveryClient(),
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.tokenExchanger = tokenExchanger
        self.discoveryClient = discoveryClient
        self.stateProvider = stateProvider
    }

    public func makeAuthenticator() -> OAuthAuthenticating {
        BrowserOAuthAuthenticator(configuration: configuration, tokenExchanger: tokenExchanger, discoveryClient: discoveryClient, stateProvider: stateProvider) { _, _ in
            throw WesomeCloudError.unsupported("ASWebAuthenticationSession is unavailable on this platform")
        }
    }
}
#endif
