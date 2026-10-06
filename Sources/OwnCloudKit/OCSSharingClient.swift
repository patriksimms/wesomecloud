import Foundation
import WesomeCloudShared

public struct PublicLinkShare: Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var url: URL
    public var token: String?
    public var permissions: Int

    public init(id: String, path: String, url: URL, token: String? = nil, permissions: Int = 1) {
        self.id = id
        self.path = path
        self.url = url
        self.token = token
        self.permissions = permissions
    }
}

public actor OCSSharingClient {
    private let serverURL: URL
    private let credentials: Credentials?
    private let transport: HTTPTransport
    private let resourceReference: String?

    public init(serverURL: URL, credentials: Credentials? = nil, resourceReference: String? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.transport = transport
        self.resourceReference = resourceReference
    }

    public func createPublicLink(path: String, name: String? = nil, permissions: Int = 1) async throws -> PublicLinkShare {
        var request = makeRequest(queryItems: [URLQueryItem(name: "format", value: "json")])
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([
            ("path", normalizedPath(path)),
            ("space_ref", resourceReference),
            ("shareType", "3"),
            ("permissions", String(permissions)),
            ("name", name),
        ])
        let (data, response) = try await transport.data(for: request)
        try validateHTTP(response)
        let payload = try JSONDecoder().decode(OCSSharePayload.self, from: data)
        guard payload.ocs.meta.statusCode == 100 else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Share request failed")
        }
        guard let data = payload.ocs.data else {
            throw WesomeCloudError.invalidResponse
        }
        guard let shareURL = URL(string: data.url) else {
            throw WesomeCloudError.invalidResponse
        }
        return PublicLinkShare(
            id: data.id,
            path: data.path,
            url: shareURL,
            token: data.token,
            permissions: data.permissions
        )
    }

    public func publicLinks(path: String) async throws -> [PublicLinkShare] {
        var query = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "path", value: normalizedPath(path))]
        if let resourceReference { query.append(URLQueryItem(name: "space_ref", value: resourceReference)) }
        var request = makeRequest(queryItems: query)
        request.httpMethod = "GET"
        let (data, response) = try await transport.data(for: request)
        try validateHTTP(response)
        let payload = try JSONDecoder().decode(OCSShareListPayload.self, from: data)
        guard payload.ocs.meta.statusCode == 100 else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Share request failed")
        }
        return payload.ocs.data
            .filter { $0.shareType == 3 }
            .compactMap(\.publicLinkShare)
    }

    public func deleteShare(id: String) async throws {
        var components = URLComponents(url: sharesURL().appending(path: id), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw WesomeCloudError.invalidResponse }
        var request = makeRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await transport.data(for: request)
        try validateHTTP(response)
        let payload = try JSONDecoder().decode(OCSDeleteSharePayload.self, from: data)
        guard payload.ocs.meta.statusCode == 100 else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Share request failed")
        }
    }

    private func makeRequest(queryItems: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: sharesURL(), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        return makeRequest(url: components.url!)
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sharesURL() -> URL {
        serverURL.appending(path: "ocs/v1.php/apps/files_sharing/api/v1/shares")
    }

    private func validateHTTP(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw WesomeCloudError.httpFailure(
                HTTPFailure.classify(
                    statusCode: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/\(trimmed)"
    }

    private func formEncoded(_ fields: [(String, String?)]) -> Data {
        fields
            .compactMap { key, value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    private func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct OCSSharePayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: Meta
        var data: ShareData?

        enum CodingKeys: String, CodingKey {
            case meta
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meta = try container.decode(Meta.self, forKey: .meta)
            data = try? container.decode(ShareData.self, forKey: .data)
        }
    }

    struct Meta: Decodable {
        var statusCode: Int
        var message: String?

        enum CodingKeys: String, CodingKey {
            case statusCode = "statuscode"
            case message
        }
    }

    struct ShareData: Decodable {
        var id: String
        var path: String
        var url: String
        var token: String?
        var permissions: Int

        enum CodingKeys: String, CodingKey {
            case id
            case path
            case url
            case token
            case permissions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(FlexibleString.self, forKey: .id).value
            path = try container.decode(String.self, forKey: .path)
            url = try container.decode(String.self, forKey: .url)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            permissions = try container.decodeIfPresent(Int.self, forKey: .permissions) ?? 1
        }
    }
}

private struct OCSShareListPayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: OCSSharePayload.Meta
        var data: [ShareData]

        enum CodingKeys: String, CodingKey {
            case meta
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meta = try container.decode(OCSSharePayload.Meta.self, forKey: .meta)
            data = (try? container.decode([ShareData].self, forKey: .data)) ?? []
        }
    }

    struct ShareData: Decodable {
        var id: String
        var shareType: Int
        var path: String
        var url: String?
        var token: String?
        var permissions: Int

        enum CodingKeys: String, CodingKey {
            case id
            case shareType = "share_type"
            case path
            case url
            case token
            case permissions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(FlexibleString.self, forKey: .id).value
            shareType = try container.decodeIfPresent(Int.self, forKey: .shareType) ?? -1
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            permissions = try container.decodeIfPresent(Int.self, forKey: .permissions) ?? 1
        }

        var publicLinkShare: PublicLinkShare? {
            guard let url, let shareURL = URL(string: url) else { return nil }
            return PublicLinkShare(id: id, path: path, url: shareURL, token: token, permissions: permissions)
        }
    }
}

private struct OCSDeleteSharePayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: OCSSharePayload.Meta
    }
}

private struct FlexibleString: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}
