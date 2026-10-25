import Foundation

public struct FileProviderAccountIssue: Codable, Equatable, Sendable {
    public enum Reason: Codable, Equatable, Sendable {
        case authentication
        case keychain(Int32)
    }

    public var reason: Reason
    public var occurredAt: Date

    public init(reason: Reason, occurredAt: Date = Date()) {
        self.reason = reason
        self.occurredAt = occurredAt
    }

    public var message: String {
        switch reason {
        case .authentication:
            "Finder: Sign in to reconnect this account."
        case .keychain(let status):
            "Finder cannot access saved credentials (Keychain \(status))."
        }
    }
}

/// The extension owns these files. App sync must not clear an error that only
/// the extension can prove has recovered. No credentials or server payloads are stored.
public actor FileProviderHealthStore {
    private let directory: URL

    public init(paths: WesomeCloudPaths) {
        directory = paths.root.appending(path: "FileProviderHealth")
    }

    public func issue(accountID: UUID) throws -> FileProviderAccountIssue? {
        do {
            return try JSONDecoder().decode(FileProviderAccountIssue.self, from: Data(contentsOf: file(accountID)))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch is DecodingError {
            // Advisory data from a different app/extension version must not block credentials.
            return nil
        }
    }

    public func report(_ reason: FileProviderAccountIssue.Reason, accountID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(FileProviderAccountIssue(reason: reason)).write(to: file(accountID), options: .atomic)
    }

    public func clear(accountID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: file(accountID))
        } catch CocoaError.fileNoSuchFile {}
    }

    private func file(_ accountID: UUID) -> URL {
        directory.appending(path: accountID.uuidString + ".json")
    }
}

public enum FinderRecovery {
    public static let url = URL(string: "wesomecloud://recover-finder")!
}
