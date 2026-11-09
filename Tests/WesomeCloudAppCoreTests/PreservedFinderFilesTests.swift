import Foundation
import Testing
@testable import WesomeCloudAppCore

@Test
func preservedFinderLocationsRemainReadableAndPrivateAcrossRetirements() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let locations = ["/Users/alice/Cloud (Recovered)", "/Users/alice/Other Space (Recovered)"]
    for path in locations {
        try PreservedFinderFiles.record(URL(fileURLWithPath: path), in: directory)
    }
    let notes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(notes.count == 2)
    let contents = try notes.map { try String(contentsOf: $0, encoding: .utf8) }
    for path in locations {
        #expect(contents.contains { $0.contains("\n\(path)\n") })
    }
    for url in [directory] + notes {
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == (url == directory ? 0o700 : 0o600))
    }
}
