import Foundation
import Darwin
import OSLog

/// A shared journal for the app and extension. The lock covers append, rotation and reads
/// across processes; each segment is at most 1 MiB and the journal is at most 10 MiB.
public struct PersistentDiagnosticLog: DiagnosticSink, Sendable {
    public static let defaultRetention: TimeInterval = 7 * 86_400
    public let directory: URL
    private let maximumBytes: Int
    private let retention: TimeInterval
    private let clock: @Sendable () -> Date

    public init(directory: URL, maximumBytes: Int = 10 * 1_024 * 1_024,
                retention: TimeInterval = PersistentDiagnosticLog.defaultRetention, clock: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maximumBytes = max(1_024, maximumBytes)
        self.retention = retention
        self.clock = clock
    }

    public func record(_ event: DiagnosticEvent) async {
        do { try append(event) }
        catch { Logger(subsystem: "WesomeCloud", category: "Diagnostics").error("Diagnostic journal write failed: \(String(describing: error), privacy: .private)") }
    }

    public func append(_ event: DiagnosticEvent) throws {
        try locked {
            let now = clock()
            var event = event
            event.message = DiagnosticRedactor.redact(event.message)
            event.context = event.context?.mapValues(DiagnosticRedactor.redact) ?? [:]
            event.context?["process"] = ProcessInfo.processInfo.processName
            event.context?["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            // Bound individual messages too, including unexpectedly large server errors.
            event.message = String(event.message.prefix(8_192))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Separate a truncated record left by a terminated writer from this record.
            var line = Data([10])
            line.append(try encoder.encode(event))
            line.append(10)
            var segments = try retainedSegments(now: now)
            let day = String(format: "%010d", Int(now.timeIntervalSince1970 / 86_400))
            let destination: URL
            if let last = segments.last,
               last.lastPathComponent.hasPrefix(day + "-"),
               try (last.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) + line.count <= min(1_024 * 1_024, maximumBytes) {
                destination = last
            } else {
                let previousSequence = segments.last?.deletingPathExtension().lastPathComponent.split(separator: "-").last.flatMap { Int($0) } ?? 0
                destination = directory.appending(path: "\(day)-\(String(format: "%020lld", previousSequence + 1)).jsonl")
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                segments.append(destination)
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            var total = try segments.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            while total > maximumBytes, let oldest = segments.first {
                total -= try oldest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try FileManager.default.removeItem(at: oldest)
                segments.removeFirst()
            }
        }
    }

    public func events() throws -> [DiagnosticEvent] {
        try locked {
            let now = clock()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try retainedSegments(now: now).flatMap { url in
                // A killed writer may leave a partial final line. Other lines remain useful.
                try Data(contentsOf: url).split(separator: 10).compactMap {
                    try? decoder.decode(DiagnosticEvent.self, from: Data($0))
                }
            }.filter { $0.date >= now.addingTimeInterval(-retention) }.sorted { $0.date < $1.date }
        }
    }

    private func retainedSegments(now: Date) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var retained: [URL] = []
        for file in files {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if modified < now.addingTimeInterval(-retention) { try FileManager.default.removeItem(at: file) }
            else { retained.append(file) }
        }
        return retained
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appending(path: "journal.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
