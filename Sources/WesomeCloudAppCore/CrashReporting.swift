import Foundation

public struct CrashReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var processName: String
    public var reason: String
    public var details: String?
    public var appVersion: String?
    public var buildNumber: String?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        processName: String,
        reason: String,
        details: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.processName = processName
        self.reason = reason
        self.details = details
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }
}

public protocol CrashReportRepository: Sendable {
    func reports() async throws -> [CrashReport]
    func save(_ report: CrashReport) async throws
    func delete(id: UUID) async throws
}

public protocol CrashReportImporting: Sendable {
    func importReports(into repository: CrashReportRepository) async throws -> Int
}

public actor MemoryCrashReportRepository: CrashReportRepository {
    private var storage: [CrashReport] = []

    public init() {}

    public func reports() async throws -> [CrashReport] {
        storage.sorted { $0.occurredAt > $1.occurredAt }
    }

    public func save(_ report: CrashReport) async throws {
        storage.removeAll { $0.id == report.id }
        storage.append(report)
    }

    public func delete(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }
}

public actor JSONCrashReportRepository: CrashReportRepository {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func reports() async throws -> [CrashReport] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var reports: [CrashReport] = []
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            reports.append(try decoder.decode(CrashReport.self, from: data))
        }
        return reports.sorted { $0.occurredAt > $1.occurredAt }
    }

    public func save(_ report: CrashReport) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(report.id.uuidString).json")
        try encoder.encode(report).write(to: destination, options: [.atomic])
    }

    public func delete(id: UUID) async throws {
        let destination = directory.appending(path: "\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.removeItem(at: destination)
    }
}

public struct DiagnosticReportsCrashImporter: CrashReportImporting {
    public var directories: [URL]
    public var processNames: Set<String>
    public var appVersion: String?
    public var buildNumber: String?

    public init(
        directories: [URL] = Self.defaultDirectories(),
        processNames: Set<String> = ["WesomeCloud", "WesomeFileProviderExtension"],
        appVersion: String? = nil,
        buildNumber: String? = nil
    ) {
        self.directories = directories
        self.processNames = processNames
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    public func importReports(into repository: CrashReportRepository) async throws -> Int {
        var knownIDs = Set(try await repository.reports().map(\.id))
        var imported = 0
        for url in reportURLs() {
            guard
                let report = try? Self.parseReport(
                    at: url,
                    processNames: processNames,
                    appVersion: appVersion,
                    buildNumber: buildNumber
                )
            else {
                continue
            }
            guard !knownIDs.contains(report.id) else { continue }
            try await repository.save(report)
            knownIDs.insert(report.id)
            imported += 1
        }
        return imported
    }

    public static func defaultDirectories() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library")
                .appending(path: "Logs")
                .appending(path: "DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
    }

    private func reportURLs() -> [URL] {
        var urls: [URL] = []
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let directoryURLs = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            urls.append(contentsOf: directoryURLs.filter { ["ips", "crash"].contains($0.pathExtension.lowercased()) })
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func parseReport(
        at url: URL,
        processNames: Set<String>,
        appVersion: String?,
        buildNumber: String?
    ) throws -> CrashReport? {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let fallbackProcessName = url.lastPathComponent.split(separator: "_").first.map(String.init)
        let parsed = parseIPSReport(data: data) ?? parseTextCrashReport(text)
        let processName = parsed?.processName ?? fallbackProcessName
        guard let processName, processNames.contains(processName) else { return nil }

        return CrashReport(
            id: stableID(for: url),
            occurredAt: parsed?.occurredAt ?? Date(timeIntervalSince1970: 0),
            processName: processName,
            reason: parsed?.reason ?? "Imported macOS crash report \(url.lastPathComponent)",
            details: details(from: text),
            appVersion: appVersion,
            buildNumber: buildNumber
        )
    }

    private static func parseIPSReport(data: Data) -> ParsedCrashReport? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let processName = (object["procName"] ?? object["process"]) as? String
        let reason = [
            object["exception"] as? String,
            object["termination"] as? String,
            object["bug_type"] as? String,
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let occurredAt = date(from: object["captureTime"] as? String)
            ?? date(from: object["timestamp"] as? String)
        return ParsedCrashReport(
            processName: processName,
            reason: reason.isEmpty ? nil : reason,
            occurredAt: occurredAt
        )
    }

    private static func parseTextCrashReport(_ text: String) -> ParsedCrashReport? {
        let lines = text.components(separatedBy: .newlines)
        let processName = value(in: lines, prefix: "Process:")
            .flatMap { $0.split(separator: " ").first.map(String.init) }
        let exception = value(in: lines, prefix: "Exception Type:")
        let termination = value(in: lines, prefix: "Termination Reason:")
        let date = value(in: lines, prefix: "Date/Time:").flatMap(date(from:))
        let reason = [exception, termination]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return ParsedCrashReport(
            processName: processName,
            reason: reason.isEmpty ? nil : reason,
            occurredAt: date
        )
    }

    private static func value(in lines: [String], prefix: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return formatter.date(from: value)
    }

    private static func details(from text: String) -> String {
        let limit = 16_384
        guard text.utf8.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index])
    }

    private static func stableID(for url: URL) -> UUID {
        UUID(uuid: FNV1A128.hash(url.path))
    }

    private struct ParsedCrashReport {
        var processName: String?
        var reason: String?
        var occurredAt: Date?
    }
}

private enum FNV1A128 {
    static func hash(_ value: String) -> uuid_t {
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            high ^= UInt64(byte)
            high &*= 0x100000001b3
            low ^= UInt64(byte)
            low &*= 0x100000001b3
        }
        return uuid_t(
            UInt8((high >> 56) & 0xff),
            UInt8((high >> 48) & 0xff),
            UInt8((high >> 40) & 0xff),
            UInt8((high >> 32) & 0xff),
            UInt8((high >> 24) & 0xff),
            UInt8((high >> 16) & 0xff),
            UInt8((high >> 8) & 0xff),
            UInt8(high & 0xff),
            UInt8((low >> 56) & 0xff),
            UInt8((low >> 48) & 0xff),
            UInt8((low >> 40) & 0xff),
            UInt8((low >> 32) & 0xff),
            UInt8((low >> 24) & 0xff),
            UInt8((low >> 16) & 0xff),
            UInt8((low >> 8) & 0xff),
            UInt8(low & 0xff)
        )
    }
}
