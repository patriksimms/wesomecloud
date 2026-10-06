import Foundation

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var serverURL: URL
    public var username: String
    public var displayName: String

    public init(id: UUID = UUID(), serverURL: URL, username: String, displayName: String? = nil) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.displayName = displayName ?? username
    }
}

public enum AvailabilityIntent: String, Codable, Equatable, Sendable {
    case inherited
    case unspecified
    case alwaysLocal
    case onlineOnly
}

public enum RemoteItemKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

public struct RemoteItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var parentID: String?
    public var name: String
    public var path: String
    public var kind: RemoteItemKind
    public var size: Int64?
    public var etag: String?
    public var fileID: String?
    public var checksum: String?
    public var permissions: String?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var contentType: String?
    public var quotaUsedBytes: Int64?
    public var quotaAvailableBytes: Int64?
    public var privateLink: URL?

    public init(
        id: String,
        parentID: String?,
        name: String,
        path: String,
        kind: RemoteItemKind,
        size: Int64? = nil,
        etag: String? = nil,
        fileID: String? = nil,
        checksum: String? = nil,
        permissions: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        contentType: String? = nil,
        quotaUsedBytes: Int64?,
        quotaAvailableBytes: Int64?,
        privateLink: URL? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.etag = etag
        self.fileID = fileID
        self.checksum = checksum
        self.permissions = permissions
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.quotaUsedBytes = quotaUsedBytes
        self.quotaAvailableBytes = quotaAvailableBytes
        self.privateLink = privateLink
    }

    public init(
        id: String,
        parentID: String?,
        name: String,
        path: String,
        kind: RemoteItemKind,
        size: Int64? = nil,
        etag: String? = nil,
        fileID: String? = nil,
        checksum: String? = nil,
        permissions: String? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        contentType: String? = nil
    ) {
        self.init(
            id: id,
            parentID: parentID,
            name: name,
            path: path,
            kind: kind,
            size: size,
            etag: etag,
            fileID: fileID,
            checksum: checksum,
            permissions: permissions,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contentType: contentType,
            quotaUsedBytes: nil,
            quotaAvailableBytes: nil,
            privateLink: nil
        )
    }
}

public enum WesomeCloudError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case httpFailure(HTTPFailure)
    case missingItem(String)
    case unsupported(String)
    case transferIntegrityMismatch(String)
    case invalidFilename(String, FilenameViolation)
    case conflict(SyncConflict)
}

public enum HTTPFailureKind: String, Codable, Equatable, Sendable {
    case authentication
    case authorization
    case notFound
    case conflict
    case quotaExceeded
    case rateLimited
    case server
    case unavailable
    case client
    case unexpected
}

public struct HTTPFailure: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var kind: HTTPFailureKind
    public var retryAfterSeconds: TimeInterval?

    public init(statusCode: Int, kind: HTTPFailureKind, retryAfterSeconds: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.kind = kind
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var isRetryable: Bool {
        switch kind {
        case .rateLimited, .server, .unavailable:
            true
        case .authentication, .authorization, .notFound, .conflict, .quotaExceeded, .client, .unexpected:
            false
        }
    }

    public static func classify(statusCode: Int, retryAfter: String? = nil) -> HTTPFailure {
        HTTPFailure(
            statusCode: statusCode,
            kind: kind(for: statusCode),
            retryAfterSeconds: parseRetryAfter(retryAfter)
        )
    }

    private static func kind(for statusCode: Int) -> HTTPFailureKind {
        switch statusCode {
        case 401:
            .authentication
        case 403:
            .authorization
        case 404, 410:
            .notFound
        case 409, 412, 423:
            .conflict
        case 507:
            .quotaExceeded
        case 429:
            .rateLimited
        case 500, 502:
            .server
        case 503, 504:
            .unavailable
        case 400..<500:
            .client
        default:
            .unexpected
        }
    }

    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

public enum FilenameViolation: String, Codable, Equatable, Sendable {
    case empty
    case containsSlash
    case containsColon
    case reservedName
    case trailingWhitespaceOrPeriod
    case ignoredPattern
}

public enum SyncConflictKind: String, Codable, Equatable, Sendable {
    case remoteChangedDuringLocalEdit
    case remoteDeletedDuringLocalEdit
    case nameCollision
    case caseOnlyRename
    case unicodeNormalization
    case typeChanged
}

public struct SyncConflict: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SyncConflictKind
    public var itemID: String
    public var localPath: String?
    public var remotePath: String?
    public var message: String

    public init(
        id: UUID = UUID(),
        kind: SyncConflictKind,
        itemID: String,
        localPath: String? = nil,
        remotePath: String? = nil,
        message: String
    ) {
        self.id = id
        self.kind = kind
        self.itemID = itemID
        self.localPath = localPath
        self.remotePath = remotePath
        self.message = message
    }
}
