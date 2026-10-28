import Foundation
import Testing
import WesomeCloudShared

@Test
func diagnosticJournalSurvivesConcurrentWritersAndRestartWithoutPrivateValues() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<80 {
            group.addTask {
                let writer = PersistentDiagnosticLog(directory: directory)
                try writer.append(DiagnosticEvent(category: "Test", level: .info,
                                                   message: "download /Clients/Private Client/image.png",
                                                   context: ["sequence": String(index), "error": "Authorization: Bearer private-token"]))
            }
        }
        try await group.waitForAll()
    }
    let reopened = PersistentDiagnosticLog(directory: directory)
    let events = try reopened.events()
    #expect(events.count == 80)
    #expect(Set(events.compactMap { $0.context?["sequence"] }).count == 80)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    let last = try #require(files.last)
    let handle = try FileHandle(forWritingTo: last)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{truncated".utf8))
    try handle.close()
    try reopened.append(DiagnosticEvent(category: "Test", level: .info, message: "after restart"))
    #expect(try reopened.events().count == 81)
    let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    for value in ["Private Client", "image.png", "private-token"] { #expect(!contents.contains(value)) }
}

@Test
func diagnosticJournalExpiresOldSegmentsAndBoundsDiskUsage() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let expired = now.addingTimeInterval(-8 * 86_400)
    let old = PersistentDiagnosticLog(directory: directory, clock: { expired })
    try old.append(DiagnosticEvent(date: expired, category: "Test", level: .info, message: "expired"))
    let staleFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    for file in staleFiles { try FileManager.default.setAttributes([.modificationDate: expired], ofItemAtPath: file.path) }
    let journal = PersistentDiagnosticLog(directory: directory, maximumBytes: 2_048, clock: { now })
    for index in 0..<20 {
        try journal.append(DiagnosticEvent(date: now, category: "Test", level: .info, message: "event \(index) " + String(repeating: "x", count: 500)))
    }
    let events = try journal.events()
    #expect(!events.contains { $0.message == "expired" })
    #expect(events.last?.message.hasPrefix("event 19 ") == true)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "jsonl" }
    let size = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    #expect(size <= 2_048)
    #expect(staleFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
}

@Test(arguments: [
    "Authorization: Bearer abc.def.ghi", "access_token=abc123", "password: abc123",
    "URL https://example.test/download?secret=abc123", "file /Users/private/Client Report.xlsx",
    "Error Domain=Test UserInfo={NSFilePath=\"Client Report.xlsx\"}",
    "The file “Client Report.xlsx” couldn’t be opened.",
    "Die Datei „Client Report.xlsx“ konnte nicht geöffnet werden.",
    "The file “Client “private” Report.xlsx” couldn’t be opened.",
    String(describing: WesomeCloudError.invalidFilename("prefix\"Client Report.xlsx.", .trailingWhitespaceOrPeriod)),
])
func diagnosticRedactionRemovesPrivateValues(_ message: String) {
    let redacted = DiagnosticRedactor.redact(message)
    for value in ["abc", "private", "Client Report", "example.test"] { #expect(!redacted.contains(value)) }
    #expect(DiagnosticRedactor.redact(redacted) == redacted)
}
