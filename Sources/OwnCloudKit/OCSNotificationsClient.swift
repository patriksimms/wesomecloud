import Foundation
import WesomeCloudShared

public struct UserNotification: Equatable, Sendable, Identifiable {
    public var id: Int
    public var app: String
    public var user: String
    public var subject: String
    public var message: String
    public var objectID: String
    public var objectType: String
    public var link: URL?
    public var date: Date?
    public var actions: [UserNotificationAction]

    public init(
        id: Int,
        app: String,
        user: String,
        subject: String,
        message: String = "",
        objectID: String = "",
        objectType: String = "",
        link: URL? = nil,
        date: Date? = nil,
        actions: [UserNotificationAction] = []
    ) {
        self.id = id
        self.app = app
        self.user = user
        self.subject = subject
        self.message = message
        self.objectID = objectID
        self.objectType = objectType
        self.link = link
        self.date = date
        self.actions = actions
    }
}

public struct UserNotificationAction: Equatable, Sendable {
    public var label: String
    public var link: URL
    public var isPrimary: Bool
    public var method: String

    public init(label: String, link: URL, isPrimary: Bool = false, method: String = "GET") {
        self.label = label
        self.link = link
        self.isPrimary = isPrimary
        self.method = method
    }
}

public actor OCSNotificationsClient {
    private let serverURL: URL
    private let credentials: Credentials?
    private let transport: HTTPTransport

    public init(serverURL: URL, credentials: Credentials? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.transport = transport
    }

    public func notifications() async throws -> [UserNotification] {
        var request = makeRequest(url: notificationsURL())
        request.httpMethod = "GET"
        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 204 {
            return []
        }
        try validateHTTP(response)
        let payload = try JSONDecoder.ownCloudNotifications.decode(OCSNotificationListPayload.self, from: data)
        guard payload.ocs.meta.isSuccess else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Notifications request failed")
        }
        return payload.ocs.data.compactMap { $0.value?.notification }
    }

    public func deleteNotification(id: Int) async throws {
        var request = makeRequest(url: notificationURL(id: id))
        request.httpMethod = "DELETE"
        let (data, response) = try await transport.data(for: request)
        try validateHTTP(response)
        if data.isEmpty {
            return
        }
        let payload = try JSONDecoder().decode(OCSNotificationDeletePayload.self, from: data)
        guard payload.ocs.meta.isSuccess else {
            throw WesomeCloudError.unsupported(payload.ocs.meta.message ?? "Notifications request failed")
        }
    }

    private func notificationsURL() -> URL {
        var components = URLComponents(
            url: notificationsBaseURL(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url!
    }

    private func notificationURL(id: Int) -> URL {
        var components = URLComponents(
            url: notificationsBaseURL().appending(path: String(id)),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url!
    }

    private func notificationsBaseURL() -> URL {
        serverURL.appending(path: "ocs/v2.php/apps/notifications/api/v1/notifications")
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
}

private struct OCSNotificationListPayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: Meta
        var data: [Lossy<NotificationData>]

        enum CodingKeys: String, CodingKey {
            case meta
            case data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            meta = try container.decode(Meta.self, forKey: .meta)
            data = (try? container.decode([Lossy<NotificationData>].self, forKey: .data)) ?? []
        }
    }
}

private struct OCSNotificationDeletePayload: Decodable {
    var ocs: OCS

    struct OCS: Decodable {
        var meta: Meta
    }
}

/// Decodes one array element without failing the whole list when that element is malformed.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct Meta: Decodable {
    var statusCode: Int
    var message: String?

    /// OCS v1 reports success as 100, v2 (the endpoint used here) as 200.
    var isSuccess: Bool { statusCode == 100 || statusCode == 200 }

    enum CodingKeys: String, CodingKey {
        case statusCode = "statuscode"
        case message
    }
}

private struct NotificationData: Decodable {
    var notificationID: Int
    var app: String
    var user: String
    var subject: String
    var message: String
    var objectID: String
    var objectType: String
    var link: String
    var date: Date?
    var actions: [ActionData]

    enum CodingKeys: String, CodingKey {
        case notificationID = "notification_id"
        case app
        case user
        case subject
        case message
        case objectID = "object_id"
        case objectType = "object_type"
        case link
        case date = "datetime"
        case actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationID = try container.decode(Int.self, forKey: .notificationID)
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        objectID = try container.decodeIfPresent(String.self, forKey: .objectID) ?? ""
        objectType = try container.decodeIfPresent(String.self, forKey: .objectType) ?? ""
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        date = try? container.decodeIfPresent(Date.self, forKey: .date)
        actions = try container.decodeIfPresent([ActionData].self, forKey: .actions) ?? []
    }

    var notification: UserNotification? {
        UserNotification(
            id: notificationID,
            app: app,
            user: user,
            subject: subject,
            message: message,
            objectID: objectID,
            objectType: objectType,
            link: URL(string: link),
            date: date,
            actions: actions.compactMap(\.action)
        )
    }
}

private struct ActionData: Decodable {
    var label: String
    var link: String
    var primary: Bool
    var type: String

    enum CodingKeys: String, CodingKey {
        case label
        case link
        case primary
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "GET"
    }

    var action: UserNotificationAction? {
        guard let url = URL(string: link) else { return nil }
        return UserNotificationAction(label: label, link: url, isPrimary: primary, method: type)
    }
}

private extension JSONDecoder {
    static var ownCloudNotifications: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
