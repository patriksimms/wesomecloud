import Foundation
import Testing
import WesomeCloudShared

@Test
func pathsCreateExpectedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let paths = WesomeCloudPaths(root: root)

    try paths.ensureDirectories()

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: paths.materializedFiles.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(FileManager.default.fileExists(atPath: paths.logs.path, isDirectory: &isDirectory))
}

@Test
func diagnosticsSinkReceivesLoggerEvents() async {
    let sink = MemoryDiagnosticSink()
    let logger = WesomeLogger(category: "Tests", sink: sink)

    await logger.info("Started")
    await logger.error("Failed")

    let events = await sink.events
    #expect(events.map(\.level) == [.info, .error])
    #expect(events.map(\.message) == ["Started", "Failed"])
}

@Test(arguments: ["not json", #"{"reason":{"futureReason":{}},"occurredAt":1}"#])
func advisoryFinderHealthIgnoresUnknownOrMalformedData(contents: String) async throws {
    let paths = WesomeCloudPaths(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = FileProviderHealthStore(paths: paths)
    let accountID = UUID()
    try await store.report(.authentication, accountID: accountID)
    let file = paths.root.appending(path: "FileProviderHealth/" + accountID.uuidString + ".json")
    try Data(contents.utf8).write(to: file)
    #expect(try await store.issue(accountID: accountID) == nil)

    // Unrelated storage errors must still be available to diagnostics.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await #expect(throws: Error.self) { try await store.issue(accountID: accountID) }
}
