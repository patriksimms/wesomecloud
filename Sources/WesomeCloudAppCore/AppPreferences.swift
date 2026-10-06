import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public var sync: SyncPreferences
    public var files: FilePreferences
    public var diagnostics: DiagnosticPreferences
    public var updates: UpdatePreferences

    public init(
        sync: SyncPreferences = SyncPreferences(),
        files: FilePreferences = FilePreferences(),
        diagnostics: DiagnosticPreferences = DiagnosticPreferences(),
        updates: UpdatePreferences = UpdatePreferences()
    ) {
        self.sync = sync
        self.files = files
        self.diagnostics = diagnostics
        self.updates = updates
    }

    private enum CodingKeys: String, CodingKey {
        case sync
        case files
        case diagnostics
        case updates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sync = try container.decodeIfPresent(SyncPreferences.self, forKey: .sync) ?? SyncPreferences()
        self.files = try container.decodeIfPresent(FilePreferences.self, forKey: .files) ?? FilePreferences()
        self.diagnostics = try container.decodeIfPresent(DiagnosticPreferences.self, forKey: .diagnostics) ?? DiagnosticPreferences()
        self.updates = try container.decodeIfPresent(UpdatePreferences.self, forKey: .updates) ?? UpdatePreferences()
    }
}

public struct SyncPreferences: Codable, Equatable, Sendable {
    public var isSyncPaused: Bool
    public var pollInterval: TimeInterval
    public var queueInterval: TimeInterval
    public var retryBaseDelay: TimeInterval
    public var retryMaximumDelay: TimeInterval
    public var retryMaximumAttempts: Int
    public var maximumConcurrentTransfers: Int

    public init(
        isSyncPaused: Bool = false,
        pollInterval: TimeInterval = 60,
        queueInterval: TimeInterval = 10,
        retryBaseDelay: TimeInterval = 2,
        retryMaximumDelay: TimeInterval = 300,
        retryMaximumAttempts: Int = 8,
        maximumConcurrentTransfers: Int = 3
    ) {
        self.isSyncPaused = isSyncPaused
        self.pollInterval = Self.clampedPollInterval(pollInterval)
        self.queueInterval = Self.clampQueueInterval(queueInterval)
        self.retryBaseDelay = Self.clampRetryBaseDelay(retryBaseDelay)
        self.retryMaximumDelay = Self.clampRetryMaximumDelay(retryMaximumDelay, baseDelay: self.retryBaseDelay)
        self.retryMaximumAttempts = Self.clampRetryMaximumAttempts(retryMaximumAttempts)
        self.maximumConcurrentTransfers = Swift.max(1, maximumConcurrentTransfers)
    }

    private enum CodingKeys: String, CodingKey {
        case isSyncPaused
        case pollInterval
        case queueInterval
        case retryBaseDelay
        case retryMaximumDelay
        case retryMaximumAttempts
        case maximumConcurrentTransfers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isSyncPaused = try container.decodeIfPresent(Bool.self, forKey: .isSyncPaused) ?? false
        self.pollInterval = Self.clampedPollInterval(try container.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 60)
        self.queueInterval = Self.clampQueueInterval(try container.decodeIfPresent(TimeInterval.self, forKey: .queueInterval) ?? 10)
        self.retryBaseDelay = Self.clampRetryBaseDelay(try container.decodeIfPresent(TimeInterval.self, forKey: .retryBaseDelay) ?? 2)
        self.retryMaximumDelay = Self.clampRetryMaximumDelay(
            try container.decodeIfPresent(TimeInterval.self, forKey: .retryMaximumDelay) ?? 300,
            baseDelay: self.retryBaseDelay
        )
        self.retryMaximumAttempts = Self.clampRetryMaximumAttempts(try container.decodeIfPresent(Int.self, forKey: .retryMaximumAttempts) ?? 8)
        self.maximumConcurrentTransfers = Swift.max(1, try container.decodeIfPresent(Int.self, forKey: .maximumConcurrentTransfers) ?? 3)
    }

    public var backgroundSyncConfiguration: BackgroundSyncConfiguration {
        BackgroundSyncConfiguration(pollInterval: pollInterval, minimumQueueInterval: queueInterval, isPaused: isSyncPaused)
    }

    public static func clampedPollInterval(_ value: TimeInterval) -> TimeInterval {
        max(15, value)
    }

    private static func clampQueueInterval(_ value: TimeInterval) -> TimeInterval {
        max(5, value)
    }

    private static func clampRetryBaseDelay(_ value: TimeInterval) -> TimeInterval {
        max(1, value)
    }

    private static func clampRetryMaximumDelay(_ value: TimeInterval, baseDelay: TimeInterval) -> TimeInterval {
        max(baseDelay, value)
    }

    private static func clampRetryMaximumAttempts(_ value: Int) -> Int {
        max(1, value)
    }
}

public struct FilePreferences: Codable, Equatable, Sendable {
    public var defaultAvailability: DefaultAvailability
    public var showHiddenFiles: Bool
    public var ignoredFilenamePatterns: [String]
    public var excludedRemotePaths: [String]

    public init(
        defaultAvailability: DefaultAvailability = .onlineOnly,
        showHiddenFiles: Bool = false,
        ignoredFilenamePatterns: [String] = Self.defaultIgnoredFilenamePatterns,
        excludedRemotePaths: [String] = []
    ) {
        self.defaultAvailability = defaultAvailability
        self.showHiddenFiles = showHiddenFiles
        self.ignoredFilenamePatterns = ignoredFilenamePatterns
        self.excludedRemotePaths = excludedRemotePaths.normalizedRemotePaths
    }

    public static let defaultIgnoredFilenamePatterns = ["~$*", "*.tmp", "*.swp", ".~lock.*"]

    private enum CodingKeys: String, CodingKey {
        case defaultAvailability
        case showHiddenFiles
        case ignoredFilenamePatterns
        case excludedRemotePaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultAvailability = try container.decodeIfPresent(DefaultAvailability.self, forKey: .defaultAvailability) ?? .onlineOnly
        self.showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        self.ignoredFilenamePatterns = try container.decodeIfPresent([String].self, forKey: .ignoredFilenamePatterns) ?? Self.defaultIgnoredFilenamePatterns
        self.excludedRemotePaths = (try container.decodeIfPresent([String].self, forKey: .excludedRemotePaths) ?? []).normalizedRemotePaths
    }
}

private extension Array where Element == String {
    var normalizedRemotePaths: [String] {
        var seen: Set<String> = []
        return compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            var path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            guard path != "/" else { return nil }
            guard seen.insert(path).inserted else { return nil }
            return path
        }
    }
}

public enum DefaultAvailability: String, Codable, Equatable, Sendable, CaseIterable {
    case onlineOnly
    case alwaysLocal
    case systemManaged
}

public struct DiagnosticPreferences: Codable, Equatable, Sendable {
    public var retainEventLimit: Int
    public var includeDebugEvents: Bool

    public init(retainEventLimit: Int = 200, includeDebugEvents: Bool = false) {
        self.retainEventLimit = retainEventLimit
        self.includeDebugEvents = includeDebugEvents
    }
}

public struct UpdatePreferences: Codable, Equatable, Sendable {
    public var automaticallyCheckForUpdates: Bool
    public var appcastURL: URL?
    public var checkInterval: TimeInterval

    public init(
        automaticallyCheckForUpdates: Bool = true,
        appcastURL: URL? = nil,
        checkInterval: TimeInterval = 86_400
    ) {
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
        self.appcastURL = appcastURL
        self.checkInterval = checkInterval
    }
}

public protocol PreferencesRepository: Sendable {
    func load() async throws -> AppPreferences
    func save(_ preferences: AppPreferences) async throws
}

public actor MemoryPreferencesRepository: PreferencesRepository {
    private var preferences: AppPreferences

    public init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
    }

    public func load() async throws -> AppPreferences {
        preferences
    }

    public func save(_ preferences: AppPreferences) async throws {
        self.preferences = preferences
    }
}

public actor JSONPreferencesRepository: PreferencesRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() async throws -> AppPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppPreferences() }
        return try decoder.decode(AppPreferences.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ preferences: AppPreferences) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(preferences).write(to: fileURL, options: [.atomic])
    }
}
