import Foundation
import Testing
import OwnCloudKit
import WesomeCloudShared

private actor SharingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Data, Int, [String: String]?)]

    init(data: Data, status: Int = 200, headers: [String: String]? = nil) {
        self.responses = [(data, status, headers)]
    }

    init(responses: [(Data, Int)]) {
        self.responses = responses.map { ($0.0, $0.1, nil) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (
            response.0,
            HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: response.2)!
        )
    }
}

@Test(arguments: [nil, "storage$space!file"] as [String?])
func ocsSharingClientCreatesPublicLinkShare(resourceReference: String?) async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": null },
        "data": {
          "id": 115468,
          "share_type": 3,
          "permissions": 1,
          "token": "MMqyHrR0GTepo4B",
          "path": "/Photos/Paris.jpg",
          "url": "https://cloud.example/index.php/s/MMqyHrR0GTepo4B"
        }
      }
    }
    """.utf8)
    let transport = SharingTransport(data: payload)
    let client = OCSSharingClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(username: "alice", password: "secret"),
        resourceReference: resourceReference,
        transport: transport
    )

    let share = try await client.createPublicLink(path: "Photos/Paris.jpg", name: "Paris")

    #expect(share.id == "115468")
    #expect(share.path == "/Photos/Paris.jpg")
    #expect(share.url.absoluteString == "https://cloud.example/index.php/s/MMqyHrR0GTepo4B")
    #expect(share.token == "MMqyHrR0GTepo4B")
    let request = await transport.requests.first
    #expect(request?.httpMethod == "POST")
    #expect(request?.url?.absoluteString == "https://cloud.example/ocs/v1.php/apps/files_sharing/api/v1/shares?format=json")
    #expect(request?.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
    #expect(request?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    let body = String(data: try #require(request?.httpBody), encoding: .utf8)
    #expect(body?.contains("path=%2FPhotos%2FParis.jpg") == true)
    #expect(body?.contains("shareType=3") == true)
    #expect(body?.contains("permissions=1") == true)
    #expect(body?.contains("name=Paris") == true)
    let form = URLComponents(string: "https://example.test/?" + (body ?? ""))
    #expect(form?.queryItems?.first { $0.name == "space_ref" }?.value == resourceReference)
}

@Test(arguments: [nil, "storage$space!file"] as [String?])
func ocsSharingClientListsAndDeletesPublicLinks(resourceReference: String?) async throws {
    let listPayload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": null },
        "data": [
          {
            "id": "1",
            "share_type": 3,
            "permissions": 1,
            "token": "public-token",
            "path": "/Photos/Paris.jpg",
            "url": "https://cloud.example/index.php/s/public-token"
          },
          {
            "id": "2",
            "share_type": 0,
            "permissions": 19,
            "path": "/Photos/Paris.jpg"
          }
        ]
      }
    }
    """.utf8)
    let deletePayload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": null },
        "data": []
      }
    }
    """.utf8)
    let transport = SharingTransport(responses: [(listPayload, 200), (deletePayload, 200)])
    let client = OCSSharingClient(serverURL: URL(string: "https://cloud.example/")!, resourceReference: resourceReference, transport: transport)

    let shares = try await client.publicLinks(path: "/Photos/Paris.jpg")
    try await client.deleteShare(id: shares[0].id)

    #expect(shares == [
        PublicLinkShare(
            id: "1",
            path: "/Photos/Paris.jpg",
            url: URL(string: "https://cloud.example/index.php/s/public-token")!,
            token: "public-token",
            permissions: 1
        )
    ])
    let requests = await transport.requests
    #expect(requests[0].httpMethod == "GET")
    let listURL = try #require(requests[0].url)
    let query = try #require(URLComponents(url: listURL, resolvingAgainstBaseURL: false))
    #expect(query.path == "/ocs/v1.php/apps/files_sharing/api/v1/shares")
    #expect(query.queryItems?.first { $0.name == "path" }?.value == "/Photos/Paris.jpg")
    #expect(query.queryItems?.first { $0.name == "space_ref" }?.value == resourceReference)
    #expect(requests[1].httpMethod == "DELETE")
    #expect(requests[1].url?.absoluteString == "https://cloud.example/ocs/v1.php/apps/files_sharing/api/v1/shares/1?format=json")
}

@Test
func ocsSharingClientClassifiesHTTPAndOCSFailures() async throws {
    let unauthorized = SharingTransport(data: Data(), status: 401)
    let unauthorizedClient = OCSSharingClient(serverURL: URL(string: "https://cloud.example/")!, transport: unauthorized)
    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 401, kind: .authentication))) {
        _ = try await unauthorizedClient.createPublicLink(path: "/Nope.txt")
    }

    let ocsFailure = SharingTransport(data: Data("""
    {
      "ocs": {
        "meta": { "status": "failure", "statuscode": 404, "message": "File could not be shared" },
        "data": {}
      }
    }
    """.utf8))
    let ocsClient = OCSSharingClient(serverURL: URL(string: "https://cloud.example/")!, transport: ocsFailure)
    await #expect(throws: WesomeCloudError.unsupported("File could not be shared")) {
        _ = try await ocsClient.createPublicLink(path: "/Nope.txt")
    }
}
