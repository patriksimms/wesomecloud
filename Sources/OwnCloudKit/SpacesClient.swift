import Foundation
import WesomeCloudShared

public struct OwnCloudSpace: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var driveType: String?
    public var driveAlias: String?
    public var webURL: URL?
    public var webDAVURL: URL
    public var rootETag: String?
    public var quota: SpaceQuota?

    public init(
        id: String,
        name: String,
        driveType: String? = nil,
        driveAlias: String? = nil,
        webURL: URL? = nil,
        webDAVURL: URL,
        rootETag: String? = nil,
        quota: SpaceQuota? = nil
    ) {
        self.id = id
        self.name = name
        self.driveType = driveType
        self.driveAlias = driveAlias
        self.webURL = webURL
        self.webDAVURL = webDAVURL
        self.rootETag = rootETag
        self.quota = quota
    }
}

public struct SpaceQuota: Equatable, Sendable {
    public var used: Int64?
    public var remaining: Int64?
    public var total: Int64?
    public var state: String?

    public init(used: Int64? = nil, remaining: Int64? = nil, total: Int64? = nil, state: String? = nil) {
        self.used = used
        self.remaining = remaining
        self.total = total
        self.state = state
    }
}

public actor SpacesClient {
    private let serverURL: URL
    private let credentials: Credentials?
    private let transport: HTTPTransport
    private let decoder: JSONDecoder

    public init(serverURL: URL, credentials: Credentials? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    public func listSpaces() async throws -> [OwnCloudSpace] {
        var request = URLRequest(url: serverURL.appending(path: "graph").appending(path: "v1.0").appending(path: "me").appending(path: "drives"))
        request.httpMethod = "GET"
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

        let payload = try decoder.decode(GraphDrivesPayload.self, from: data)
        return payload.value.compactMap(\.space)
    }
}

private struct GraphDrivesPayload: Decodable {
    var value: [GraphDrive]
}

private struct GraphDrive: Decodable {
    var id: String
    var name: String?
    var driveType: String?
    var driveAlias: String?
    var webUrl: URL?
    var root: Root?
    var quota: Quota?

    var space: OwnCloudSpace? {
        guard let webDAVURL = root?.webDavUrl else { return nil }
        return OwnCloudSpace(
            id: id,
            name: name ?? id,
            driveType: driveType,
            driveAlias: driveAlias,
            webURL: webUrl,
            webDAVURL: webDAVURL,
            rootETag: root?.eTag,
            quota: quota?.spaceQuota
        )
    }

    struct Root: Decodable {
        var eTag: String?
        var webDavUrl: URL?
    }

    struct Quota: Decodable {
        var used: Int64?
        var remaining: Int64?
        var total: Int64?
        var state: String?

        var spaceQuota: SpaceQuota {
            SpaceQuota(used: used, remaining: remaining, total: total, state: state)
        }
    }
}
