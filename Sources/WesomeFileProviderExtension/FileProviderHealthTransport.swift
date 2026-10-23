import Foundation
import OwnCloudKit
import WesomeCloudShared

/// Only authenticated WebDAV responses establish that the extension recovered.
/// Local metadata reads and successful sync in the main app cannot do that.
struct FileProviderHealthTransport: HTTPTransport {
    let transport: any HTTPTransport
    let health: FileProviderHealthStore
    let accountID: UUID

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.data(for: request)
        do {
            if result.1.statusCode == 401 {
                try await health.report(.authentication, accountID: accountID)
            } else if (200..<300).contains(result.1.statusCode) {
                try await health.clear(accountID: accountID)
            }
        } catch {
            await WesomeLogger(category: "FileProvider").error("Could not save Finder authentication health: \(error)")
        }
        return result
    }
}
