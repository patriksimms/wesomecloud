import Foundation
import Testing
import OwnCloudKit
import WesomeCloudShared

private actor SpacesTransport: HTTPTransport {
    var request: URLRequest?
    let data: Data
    let status: Int
    let headers: [String: String]?

    init(data: Data, status: Int = 200, headers: [String: String]? = nil) {
        self.data = data
        self.status = status
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }
}

@Test
func spacesClientListsGraphDrivesWithWebDAVRoots() async throws {
    let payload = Data("""
    {
      "value": [
        {
          "description": "Marketing team resources",
          "driveAlias": "project/marketing",
          "driveType": "project",
          "id": "storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff",
          "name": "Marketing",
          "quota": {
            "remaining": 5368709120,
            "state": "normal",
            "total": 5368709120,
            "used": 1024
          },
          "root": {
            "eTag": "\\"f91e56554fd9305db81a93778c0fae96\\"",
            "id": "storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff",
            "webDavUrl": "https://cloud.example/dav/spaces/storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff"
          },
          "webUrl": "https://cloud.example/f/storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff"
        },
        {
          "id": "hidden-without-webdav",
          "name": "No root"
        }
      ]
    }
    """.utf8)
    let transport = SpacesTransport(data: payload)
    let client = SpacesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(accessToken: "oauth-access"),
        transport: transport
    )

    let spaces = try await client.listSpaces()

    #expect(spaces == [
        OwnCloudSpace(
            id: "storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff",
            name: "Marketing",
            driveType: "project",
            driveAlias: "project/marketing",
            webURL: URL(string: "https://cloud.example/f/storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff")!,
            webDAVURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$535aa42d-a3c7-4329-9eba-5ef48fcaa3ff")!,
            rootETag: "\"f91e56554fd9305db81a93778c0fae96\"",
            quota: SpaceQuota(used: 1024, remaining: 5368709120, total: 5368709120, state: "normal")
        ),
    ])
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://cloud.example/graph/v1.0/me/drives")
    #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
}

@Test
func spacesClientClassifiesHTTPFailures() async throws {
    let transport = SpacesTransport(data: Data("{}".utf8), status: 429, headers: ["Retry-After": "12"])
    let client = SpacesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(username: "alice", password: "secret"),
        transport: transport
    )

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 429, kind: .rateLimited, retryAfterSeconds: 12))) {
        _ = try await client.listSpaces()
    }
    #expect(await transport.request?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}
