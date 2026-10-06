import Foundation
import OSLog

public struct AppGroupConfiguration: Equatable, Sendable {
    public var identifier: String
    public var fallbackDirectory: URL

    public init(
        identifier: String = Bundle.main.object(forInfoDictionaryKey: "WesomeCloudAppGroupIdentifier") as? String
            ?? "group.cloud.wesome.wesomecloud",
        fallbackDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/WesomeCloud")
    ) {
        self.identifier = identifier
        self.fallbackDirectory = fallbackDirectory
    }
}

public struct WesomeCloudPaths: Equatable, Sendable {
    public var root: URL
    public var database: URL
    public var accountDatabase: URL
    public var accounts: URL
    public var preferences: URL
    public var materializedFiles: URL
    public var logs: URL
    public var crashReports: URL

    public init(root: URL) {
        self.root = root
        self.database = root.appending(path: "SyncStore.sqlite")
        self.accountDatabase = root.appending(path: "Accounts.sqlite")
        self.accounts = root.appending(path: "Accounts.json")
        self.preferences = root.appending(path: "Preferences.json")
        self.materializedFiles = root.appending(path: "MaterializedFiles")
        self.logs = root.appending(path: "Logs")
        self.crashReports = root.appending(path: "CrashReports")
    }

    public static func resolve(configuration: AppGroupConfiguration = AppGroupConfiguration()) -> WesomeCloudPaths {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: configuration.identifier)
            ?? configuration.fallbackDirectory
        return WesomeCloudPaths(root: root)
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materializedFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashReports, withIntermediateDirectories: true)
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var subsystem: String
    public var category: String
    public var level: DiagnosticLevel
    public var message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        subsystem: String = "WesomeCloud",
        category: String,
        level: DiagnosticLevel,
        message: String
    ) {
        self.id = id
        self.date = date
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
    }
}

public enum DiagnosticLevel: String, Codable, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol DiagnosticSink: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public actor MemoryDiagnosticSink: DiagnosticSink {
    public private(set) var events: [DiagnosticEvent] = []

    public init() {}

    public func record(_ event: DiagnosticEvent) async {
        events.append(event)
    }
}

public struct WesomeLogger: Sendable {
    private let sink: DiagnosticSink?
    private let logger: Logger
    private let category: String

    public init(category: String, sink: DiagnosticSink? = nil) {
        self.sink = sink
        self.category = category
        self.logger = Logger(subsystem: "WesomeCloud", category: category)
    }

    public func info(_ message: String) async {
        logger.info("\(message, privacy: .public)")
        await sink?.record(DiagnosticEvent(category: category, level: .info, message: message))
    }

    public func warning(_ message: String) async {
        logger.warning("\(message, privacy: .public)")
        await sink?.record(DiagnosticEvent(category: category, level: .warning, message: message))
    }

    public func error(_ message: String) async {
        logger.error("\(message, privacy: .public)")
        await sink?.record(DiagnosticEvent(category: category, level: .error, message: message))
    }
}
