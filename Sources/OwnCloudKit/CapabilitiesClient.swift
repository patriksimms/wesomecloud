import Foundation
import WesomeCloudShared

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public var versionString: String?
    public var edition: String?
    public var supportsChunking: Bool
    public var supportsPrivateLinks: Bool
    public var supportsNotifications: Bool
    public var remotePollInterval: TimeInterval?
    public var raw: [String: JSONValue]

    public init(
        versionString: String? = nil,
        edition: String? = nil,
        supportsChunking: Bool = false,
        supportsPrivateLinks: Bool = false,
        supportsNotifications: Bool = false,
        remotePollInterval: TimeInterval? = nil,
        raw: [String: JSONValue] = [:]
    ) {
        self.versionString = versionString
        self.edition = edition
        self.supportsChunking = supportsChunking
        self.supportsPrivateLinks = supportsPrivateLinks
        self.supportsNotifications = supportsNotifications
        self.remotePollInterval = remotePollInterval
        self.raw = raw
    }

    public init(
        versionString: String? = nil,
        edition: String? = nil,
        supportsChunking: Bool = false,
        supportsPrivateLinks: Bool = false,
        raw: [String: JSONValue] = [:]
    ) {
        self.init(
            versionString: versionString,
            edition: edition,
            supportsChunking: supportsChunking,
            supportsPrivateLinks: supportsPrivateLinks,
            supportsNotifications: false,
            remotePollInterval: nil,
            raw: raw
        )
    }
}

public actor CapabilitiesClient {
    private let serverURL: URL
    private let credentials: Credentials?
    private let transport: HTTPTransport

    public init(serverURL: URL, credentials: Credentials? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.transport = transport
    }

    public func fetchCapabilities() async throws -> ServerCapabilities {
        var components = URLComponents(url: serverURL.appending(path: "ocs/v2.php/cloud/capabilities"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw WesomeCloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw WesomeCloudError.httpFailure(
                HTTPFailure.classify(
                    statusCode: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        let payload: OCSCapabilitiesPayload
        do {
            payload = try JSONDecoder().decode(OCSCapabilitiesPayload.self, from: data)
        } catch {
            throw WesomeCloudError.unsupported(
                "Capabilities request returned an unexpected response. \(Self.decodingSummary(error)) \(Self.responseSnippet(data))"
            )
        }
        guard payload.ocs.meta.isSuccess else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Capabilities request failed")
        }
        let capabilities = payload.ocs.data.capabilities
        return ServerCapabilities(
            versionString: capabilities.core?.versionstring?.stringValue,
            edition: capabilities.core?.edition?.stringValue,
            supportsChunking: capabilities.files?.bigfilechunking?.boolValue ?? false,
            supportsPrivateLinks: capabilities.filesSharing?.privateLinks?.boolValue ?? false,
            supportsNotifications: capabilities.notifications != nil,
            remotePollInterval: capabilities.core?.pollinterval?.timeIntervalValue,
            raw: capabilities.raw
        )
    }

    /// The server's id for the authenticated user (`ocs/v2.php/cloud/user`). OIDC token responses
    /// (oCIS, ownCloud with openidconnect) carry no `user_id`, but WebDAV paths need it.
    public func fetchCurrentUserID() async throws -> String {
        var components = URLComponents(url: serverURL.appending(path: "ocs/v2.php/cloud/user"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw WesomeCloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw WesomeCloudError.httpFailure(
                HTTPFailure.classify(statusCode: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            )
        }
        guard let payload = try? JSONDecoder().decode(OCSUserPayload.self, from: data),
              payload.ocs.meta.isSuccess,
              let id = payload.ocs.data.id, !id.isEmpty
        else {
            throw WesomeCloudError.unsupported("Current user request returned an unexpected response. \(Self.responseSnippet(data))")
        }
        return id
    }

    private static func responseSnippet(_ data: Data) -> String {
        guard !data.isEmpty else { return "The response body was empty." }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? "<non-UTF-8 response>"
        return "Response: \(text.replacingOccurrences(of: "\n", with: " "))"
    }

    private static func decodingSummary(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "" }
        return decodingError.ownCloudSummary
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var timeIntervalValue: TimeInterval? {
        if let numberValue { return numberValue }
        if let stringValue { return TimeInterval(stringValue) }
        return nil
    }
}

private struct OCSUserPayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: OCSCapabilitiesPayload.Meta
        var data: User
    }

    struct User: Decodable {
        var id: String?
    }
}

private struct OCSCapabilitiesPayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: Meta
        var data: DataNode
    }

    struct Meta: Decodable {
        var status: String?
        var statusCode: Int?
        var message: String?

        var isSuccess: Bool {
            if let status, status.caseInsensitiveCompare("ok") == .orderedSame {
                return true
            }
            return statusCode == 100 || statusCode == 200
        }

        enum CodingKeys: String, CodingKey {
            case status
            case statusCode = "statuscode"
            case message
        }
    }

    struct DataNode: Decodable {
        var capabilities: CapabilitiesNode
    }
}

private struct CapabilitiesNode: Decodable {
    var raw: [String: JSONValue]

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    var core: [String: JSONValue]? {
        object("core")
    }

    var files: [String: JSONValue]? {
        object("files")
    }

    var filesSharing: [String: JSONValue]? {
        object("files_sharing")
    }

    var notifications: [String: JSONValue]? {
        object("notifications")
    }

    private func object(_ key: String) -> [String: JSONValue]? {
        guard case .object(let object) = raw[key] else { return nil }
        return object
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var versionstring: JSONValue? { self["versionstring"] }
    var edition: JSONValue? { self["edition"] }
    var pollinterval: JSONValue? { self["pollinterval"] }
    var bigfilechunking: JSONValue? { self["bigfilechunking"] }
    var privateLinks: JSONValue? { self["private_links"] }
}

private extension DecodingError {
    var ownCloudSummary: String {
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
