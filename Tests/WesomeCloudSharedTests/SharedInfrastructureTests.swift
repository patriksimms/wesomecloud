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
