import Foundation
import Testing
import OwnCloudKit
import WesomeCloudShared

private actor NotificationsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let responses: [(Data, Int, [String: String]?)]

    init(responses: [(Data, Int, [String: String]?)] = []) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let index = max(0, min(requests.count - 1, responses.count - 1))
        let response = responses[index]
        return (
            response.0,
            HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: response.2)!
        )
    }
}

@Test
func notificationsClientListsUserNotificationsFromOCSV2AndSkipsMalformedEntries() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 200, "message": "OK" },
        "data": [
          { "notification_id": "not-a-number", "subject": "malformed entries are skipped" },
          {
            "notification_id": 42,
            "app": "files_sharing",
            "user": "alice",
            "datetime": "2026-05-27T14:45:00Z",
            "object_type": "remote_share",
            "object_id": "share-1",
            "subject": "Bob shared Project Plan",
            "message": "A federated share needs your approval.",
            "link": "https://cloud.example/f/42",
            "actions": [
              {
                "label": "Accept",
                "link": "https://cloud.example/ocs/v2.php/apps/files_sharing/api/v1/remote_shares/pending/42",
                "primary": true,
                "type": "POST"
              }
            ]
          }
        ]
      }
    }
    """.utf8)
    let transport = NotificationsTransport(responses: [(payload, 200, nil)])
    let client = OCSNotificationsClient(
        serverURL: URL(string: "https://cloud.example/")!,
        credentials: Credentials(accessToken: "access-token"),
        transport: transport
    )

    let notifications = try await client.notifications()

    #expect(notifications.count == 1)
    #expect(notifications.first?.id == 42)
    #expect(notifications.first?.app == "files_sharing")
    #expect(notifications.first?.subject == "Bob shared Project Plan")
    #expect(notifications.first?.link?.absoluteString == "https://cloud.example/f/42")
    #expect(notifications.first?.actions.first?.isPrimary == true)
    #expect(notifications.first?.actions.first?.method == "POST")
    let request = await transport.requests.first
    #expect(request?.url?.absoluteString == "https://cloud.example/ocs/v2.php/apps/notifications/api/v1/notifications?format=json")
    #expect(request?.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
}

@Test
func notificationsClientTreatsNoContentAsNoNotifications() async throws {
    let transport = NotificationsTransport(responses: [(Data(), 204, nil)])
    let client = OCSNotificationsClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    let notifications = try await client.notifications()

    #expect(notifications.isEmpty)
}

@Test
func notificationsClientDeletesNotificationByID() async throws {
    let payload = Data("""
    {
      "ocs": {
        "meta": { "status": "ok", "statuscode": 100, "message": "OK" },
        "data": []
      }
    }
    """.utf8)
    let transport = NotificationsTransport(responses: [(payload, 200, nil)])
    let client = OCSNotificationsClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    try await client.deleteNotification(id: 42)

    let request = await transport.requests.first
    #expect(request?.httpMethod == "DELETE")
    #expect(request?.url?.absoluteString == "https://cloud.example/ocs/v2.php/apps/notifications/api/v1/notifications/42?format=json")
}

@Test
func notificationsClientClassifiesHTTPFailures() async throws {
    let transport = NotificationsTransport(responses: [(Data(), 503, ["Retry-After": "15"])])
    let client = OCSNotificationsClient(serverURL: URL(string: "https://cloud.example/")!, transport: transport)

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable, retryAfterSeconds: 15))) {
        _ = try await client.notifications()
    }
}
