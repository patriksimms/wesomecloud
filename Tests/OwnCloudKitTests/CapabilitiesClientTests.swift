import Foundation
import Testing
import OwnCloudKit
import WesomeCloudShared

private actor CapabilityTransport: HTTPTransport {
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
func capabilitiesClientParsesOwnCloudCapabilities() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": "OK" },
        "data": {
          "capabilities": {
            "core": { "versionstring": "10.15.0", "edition": "Community", "pollinterval": 45 },
            "files": { "bigfilechunking": true },
            "files_sharing": { "private_links": true },
            "notifications": { "ocs-endpoints": ["list", "get", "delete"] }
          }
        }
      }
    }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(username: "alice", password: "secret"),
        transport: transport
    )

    let capabilities = try await client.fetchCapabilities()

    #expect(capabilities.versionString == "10.15.0")
    #expect(capabilities.edition == "Community")
    #expect(capabilities.supportsChunking)
    #expect(capabilities.supportsPrivateLinks)
    #expect(capabilities.supportsNotifications)
    #expect(capabilities.remotePollInterval == 45)
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://cloud.example/ocs/v2.php/cloud/capabilities?format=json")
    #expect(request?.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
    #expect(request?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
}

@Test
func capabilitiesClientUsesBearerCredentialHeader() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": "OK" },
        "data": { "capabilities": {} }
      }
    }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(accessToken: "oauth-access"),
        transport: transport
    )

    _ = try await client.fetchCapabilities()

    #expect(await transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
}

@Test
func capabilitiesClientAcceptsOCSV2StatusCodeTwoHundred() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 200, "message": "OK" },
        "data": { "capabilities": {} }
      }
    }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(accessToken: "oauth-access"),
        transport: transport
    )

    _ = try await client.fetchCapabilities()

    #expect(await transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
}

@Test
func capabilitiesClientAcceptsOCSOkStatusWithoutStatusCode() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "message": "OK" },
        "data": { "capabilities": {} }
      }
    }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    _ = try await client.fetchCapabilities()
}

@Test
func capabilitiesClientClassifiesAuthenticationAndRateLimitFailures() async throws {
    let unauthorized = CapabilityTransport(data: Data(), status: 401)
    let unauthorizedClient = CapabilitiesClient(serverURL: URL(string: "https://cloud.example/")!, transport: unauthorized)

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 401, kind: .authentication))) {
        _ = try await unauthorizedClient.fetchCapabilities()
    }

    let rateLimited = CapabilityTransport(data: Data(), status: 429, headers: ["Retry-After": "30"])
    let rateLimitedClient = CapabilitiesClient(serverURL: URL(string: "https://cloud.example/")!, transport: rateLimited)

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 429, kind: .rateLimited, retryAfterSeconds: 30))) {
        _ = try await rateLimitedClient.fetchCapabilities()
    }
}

@Test
func capabilitiesClientRejectsOCSFailurePayloads() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "failure", "statuscode": 997, "message": "Current user is not logged in" },
        "data": { "capabilities": {} }
      }
    }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    await #expect(throws: WesomeCloudError.unsupported("Current user is not logged in")) {
        _ = try await client.fetchCapabilities()
    }
}

@Test
func capabilitiesClientSurfacesUnexpectedPayloads() async throws {
    let transport = CapabilityTransport(data: Data("""
    {
      "message": "not an ocs payload"
    }
    """.utf8))
    let client = CapabilitiesClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    do {
        _ = try await client.fetchCapabilities()
        Issue.record("Expected capabilities parsing to fail")
    } catch WesomeCloudError.unsupported(let message) {
        #expect(message.contains("Capabilities request returned an unexpected response."))
        #expect(message.contains("No value associated with key"))
        #expect(message.contains("Response:"))
    }
}

@Test
func capabilitiesClientFetchesCurrentUserIDFromOCSUserEndpoint() async throws {
    let payload = Data("""
    { "ocs": { "meta": { "status": "ok", "statuscode": 200 }, "data": { "id": "patrik.simms", "display-name": "Patrik" } } }
    """.utf8)
    let transport = CapabilityTransport(data: payload)
    let client = CapabilitiesClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(accessToken: "access"),
        transport: transport
    )

    #expect(try await client.fetchCurrentUserID() == "patrik.simms")
    let request = await transport.request
    #expect(request?.url?.absoluteString == "https://cloud.example/ocs/v2.php/cloud/user?format=json")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
}
