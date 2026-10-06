import Foundation
import Testing
@testable import OwnCloudKit
import WesomeCloudShared

private actor RecordingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Data, Int, [String: String]?)] = []

    init(_ responses: [(Data, Int)]) {
        self.responses = responses.map { ($0.0, $0.1, nil) }
    }

    init(_ responses: [(Data, Int, [String: String]?)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.1,
            httpVersion: nil,
            headerFields: next.2
        )!
        return (next.0, response)
    }
}

private actor RecordingProgress {
    private var values: [Int64] = []

    func record(_ value: Int64) {
        values.append(value)
    }

    var recordedValues: [Int64] {
        values
    }
}

@Test
func propfindParsesOwnCloudMetadata() async throws {
    let xml = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/</d:href>
        <d:propstat><d:prop>
          <d:resourcetype><d:collection/></d:resourcetype>
          <d:getetag>"folder-etag"</d:getetag>
          <oc:fileid>10</oc:fileid>
          <oc:permissions>RDNVCK</oc:permissions>
          <oc:quota-used-bytes>1048576</oc:quota-used-bytes>
          <oc:quota-available-bytes>2097152</oc:quota-available-bytes>
          <oc:privatelink>https://cloud.example/index.php/f/10</oc:privatelink>
        </d:prop></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/report.txt</d:href>
        <d:propstat><d:prop>
          <d:resourcetype/>
          <d:getcontentlength>42</d:getcontentlength>
          <d:getetag>"file-etag"</d:getetag>
          <d:getcontenttype>text/plain</d:getcontenttype>
          <d:creationdate>2015-10-20T07:28:00Z</d:creationdate>
          <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
          <oc:fileid>11</oc:fileid>
          <oc:checksum>SHA1:abcdef</oc:checksum>
        </d:prop></d:propstat>
      </d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    let items = try await client.propfind(path: "/Documents", depth: 1)

    #expect(items.count == 2)
    #expect(items[0].id == "10")
    #expect(items[0].kind == .folder)
    #expect(items[0].quotaUsedBytes == 1_048_576)
    #expect(items[0].quotaAvailableBytes == 2_097_152)
    #expect(items[0].privateLink?.absoluteString == "https://cloud.example/index.php/f/10")
    #expect(items[1].name == "report.txt")
    #expect(items[1].size == 42)
    #expect(items[1].etag == "file-etag")
    #expect(items[1].checksum == "SHA1:abcdef")
    #expect(items[1].createdAt == Date(timeIntervalSince1970: 1_445_326_080))
    #expect(items[1].modifiedAt == Date(timeIntervalSince1970: 1_445_412_480))
    let requests = await transport.requests
    #expect(requests.first?.httpMethod == "PROPFIND")
    #expect(requests.first?.value(forHTTPHeaderField: "Depth") == "1")
    let body = String(data: try #require(requests.first?.httpBody), encoding: .utf8)
    #expect(body?.contains("creationdate") == true)
}

@Test
func propfindParsesInfiniteScaleSpaceRelativePaths() async throws {
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response><d:href>/dav/spaces/storage-users-1$space/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype><oc:fileid>space-root</oc:fileid>
      </d:prop></d:propstat></d:response>
      <d:response><d:href>/dav/spaces/storage-users-1$space/Root.txt</d:href><d:propstat><d:prop>
        <d:resourcetype/><d:getcontentlength>4</d:getcontentlength><d:getetag>"etag"</d:getetag><oc:fileid>root-file</oc:fileid>
      </d:prop></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$space/")!, transport: transport)

    let items = try await client.propfind(path: "/")

    #expect(items.map(\.path) == ["/", "/Root.txt"])
    #expect(items.map(\.id) == ["space-root", "root-file"])
}

@Test
func webDAVClientFetchesPrivateLinkWithDepthZeroPropfind() async throws {
    let xml = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/report.txt</d:href>
        <d:propstat><d:prop>
          <oc:privatelink>https://cloud.example/index.php/f/11</oc:privatelink>
        </d:prop></d:propstat>
      </d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    let url = try await client.privateLink(path: "/Documents/report.txt")

    #expect(url.absoluteString == "https://cloud.example/index.php/f/11")
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "PROPFIND")
    #expect(request.value(forHTTPHeaderField: "Depth") == "0")
    #expect(String(data: try #require(request.httpBody), encoding: .utf8)?.contains("privatelink") == true)
}

@Test
func webDAVMutationsUseExpectedMethods() async throws {
    let transport = RecordingTransport([
        (Data(), 201),
        (Data(), 204),
        (Data(), 204),
        (Data(), 201),
    ])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    try await client.upload(data: Data("hello".utf8), to: "/note.txt")
    try await client.delete(path: "/note.txt")
    try await client.move(from: "/old.txt", to: "/new.txt")
    try await client.createFolder(path: "/Archive")

    let methods = await transport.requests.map(\.httpMethod)
    #expect(methods == ["PUT", "DELETE", "MOVE", "MKCOL"])
}

@Test
func webDAVClientUsesBearerCredentialHeader() async throws {
    let xml = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:"/>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(
        baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!,
        credentials: Credentials(accessToken: "oauth-access"),
        transport: transport
    )

    _ = try await client.propfind(path: "/", depth: 1)

    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
}

@Test
func syncCollectionReportsTokenChangedItemsAndDeletedPaths() async throws {
    let xml = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:sync-token>https://cloud.example/sync/43</d:sync-token>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/report.txt</d:href>
        <d:propstat><d:prop>
          <d:resourcetype/>
          <d:getcontentlength>42</d:getcontentlength>
          <d:getetag>"file-etag"</d:getetag>
          <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
          <oc:fileid>11</oc:fileid>
          <oc:checksum>SHA1:abcdef</oc:checksum>
        </d:prop></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/Documents/Old.txt</d:href>
        <d:status>HTTP/1.1 404 Not Found</d:status>
      </d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(
        baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!,
        credentials: Credentials(accessToken: "oauth-access"),
        transport: transport
    )

    let report = try await client.syncCollection(path: "/Documents", syncToken: "https://cloud.example/sync/42", depth: 1)

    #expect(report.syncToken == "https://cloud.example/sync/43")
    #expect(report.items.count == 1)
    #expect(report.items.first?.id == "11")
    #expect(report.items.first?.path == "/Documents/report.txt")
    #expect(report.items.first?.etag == "file-etag")
    #expect(report.deletedPaths == ["/Documents/Old.txt"])
    let request = await transport.requests.first
    #expect(request?.httpMethod == "REPORT")
    #expect(request?.value(forHTTPHeaderField: "Depth") == "1")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
    let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(body.contains("<d:sync-token>https://cloud.example/sync/42</d:sync-token>"))
    #expect(body.contains("<d:sync-level>1</d:sync-level>"))
}

@Test
func syncCollectionEscapesTokenAndAllowsInitialEmptyToken() async throws {
    let xml = Data("""
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:">
      <d:sync-token>token-1</d:sync-token>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207), (xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    _ = try await client.syncCollection(path: "/", syncToken: nil)
    _ = try await client.syncCollection(path: "/", syncToken: "token&<\"'>")

    let requests = await transport.requests
    let initialBody = String(data: requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
    let escapedBody = String(data: requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(initialBody.contains("<d:sync-token/>"))
    #expect(escapedBody.contains("<d:sync-token>token&amp;&lt;&quot;&apos;&gt;</d:sync-token>"))
}

@Test
func webDAVDownloadRangeUsesRangeHeaderAndReturnsContentRange() async throws {
    let transport = RecordingTransport([
        (Data("tail".utf8), 206, ["Content-Range": "bytes 4-7/8", "ETag": "\"etag-1\""])
    ])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    let response = try await client.downloadRange(path: "/Readme.md", startingAt: 4)

    #expect(response.data == Data("tail".utf8))
    #expect(response.statusCode == 206)
    #expect(response.contentRange == "bytes 4-7/8")
    #expect(response.etag == "etag-1")
    let request = await transport.requests.first
    #expect(request?.httpMethod == "GET")
    #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=4-")
}

@Test
func webDAVDownloadRangeCanRequestClosedByteRange() async throws {
    let transport = RecordingTransport([
        (Data("tail".utf8), 206, ["Content-Range": "bytes 4-7/8"])
    ])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    let response = try await client.downloadRange(path: "/Readme.md", startingAt: 4, endingAt: 7)

    #expect(response.data == Data("tail".utf8))
    #expect(response.contentRange == "bytes 4-7/8")
    let request = await transport.requests.first
    #expect(request?.value(forHTTPHeaderField: "Range") == "bytes=4-7")
}

@Test
func webDAVErrorsAreClassifiedForRetryAndConflictPolicy() async throws {
    let transport = RecordingTransport([
        (Data(), 503, ["Retry-After": "12"]),
        (Data(), 412, nil),
        (Data(), 507, nil),
    ])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 503, kind: .unavailable, retryAfterSeconds: 12))) {
        _ = try await client.download(path: "/Readme.md")
    }
    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 412, kind: .conflict))) {
        try await client.upload(data: Data("updated".utf8), to: "/Readme.md", ifMatch: "old-etag")
    }
    await #expect(throws: WesomeCloudError.httpFailure(HTTPFailure(statusCode: 507, kind: .quotaExceeded))) {
        try await client.upload(data: Data("too large".utf8), to: "/Large.bin")
    }
}

@Test
func webDAVChunkedUploadCreatesTransferFolderPutsChunksThenMovesAssemblyToDestination() async throws {
    let transport = RecordingTransport([
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
    ])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    try await client.uploadChunked(
        data: Data("abcdef".utf8),
        to: "/Documents/report.txt",
        configuration: ChunkedUploadConfiguration(chunkSize: 3, transferID: "transfer-1"),
        ifMatch: "etag-1"
    )

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["MKCOL", "PUT", "PUT", "MOVE"])
    #expect(requests[0].url?.absoluteString == "https://cloud.example/remote.php/dav/uploads/alice/transfer-1")
    #expect(requests[1].url?.absoluteString == "https://cloud.example/remote.php/dav/uploads/alice/transfer-1/00000")
    #expect(requests[2].url?.absoluteString == "https://cloud.example/remote.php/dav/uploads/alice/transfer-1/00001")
    #expect(requests[1].httpBody == Data("abc".utf8))
    #expect(requests[2].httpBody == Data("def".utf8))
    #expect(requests[1...].allSatisfy { $0.value(forHTTPHeaderField: "OC-Total-Length") == "6" })
    let commit = requests[3]
    let destination = "https://cloud.example/remote.php/dav/files/alice/Documents/report.txt"
    #expect(commit.url?.absoluteString == "https://cloud.example/remote.php/dav/uploads/alice/transfer-1/.file")
    #expect(commit.value(forHTTPHeaderField: "Destination") == destination)
    #expect(commit.value(forHTTPHeaderField: "Overwrite") == "T")
    #expect(commit.value(forHTTPHeaderField: "If-Match") == nil)
    #expect(commit.value(forHTTPHeaderField: "If") == "<\(destination)> ([\"etag-1\"])")
}

@Test
func webDAVChunkedUploadReportsProgressAfterEachChunk() async throws {
    let transport = RecordingTransport([
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
        (Data(), 201),
    ])
    let progress = RecordingProgress()
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    try await client.uploadChunked(
        data: Data("abcdef".utf8),
        to: "/Documents/report.txt",
        configuration: ChunkedUploadConfiguration(chunkSize: 3, transferID: "transfer-1"),
        progress: { uploadedBytes in
            await progress.record(uploadedBytes)
        }
    )

    #expect(await progress.recordedValues == [3, 6])
}

@Test
func webDAVChunkedUploadOnSpacesBaseFallsBackToSinglePut() async throws {
    let transport = RecordingTransport([(Data(), 201)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$space/")!, transport: transport)

    try await client.uploadChunked(
        data: Data("abcdef".utf8),
        to: "/report.txt",
        configuration: ChunkedUploadConfiguration(chunkSize: 3, transferID: "transfer-1"),
        ifMatch: "etag-1"
    )

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["PUT"])
    #expect(requests[0].url?.absoluteString == "https://cloud.example/dav/spaces/storage-users-1$space/report.txt")
    #expect(requests[0].httpBody == Data("abcdef".utf8))
}

@Test
func webDAVUploadSendsQuotedIfMatchForStoredEtag() async throws {
    let transport = RecordingTransport([(Data(), 204), (Data(), 204)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    try await client.upload(data: Data("x".utf8), to: "/a.txt", ifMatch: "abc")
    try await client.upload(data: Data("x".utf8), to: "/a.txt", ifMatch: "\"already-quoted\"")

    let headers = await transport.requests.map { $0.value(forHTTPHeaderField: "If-Match") }
    #expect(headers == ["\"abc\"", "\"already-quoted\""])
}

@Test
func propfindIgnoresPropertiesReportedInNotFoundPropstat() async throws {
    // Sabre returns unknown props (quota on files, privatelink, ...) in a second 404 propstat.
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/alice/Docs/a.txt</d:href>
        <d:propstat>
          <d:prop><d:resourcetype/><d:getetag>"e1"</d:getetag><oc:fileid>7</oc:fileid><d:getcontentlength>3</d:getcontentlength></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop><oc:quota-used-bytes/><oc:privatelink/><d:getcontentlength/></d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207), (xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    let items = try await client.propfind(path: "/Docs")
    let report = try await client.syncCollection(path: "/Docs", syncToken: "t")

    #expect(items.map(\.path) == ["/Docs/a.txt"])
    #expect(items.first?.size == 3)
    #expect(items.first?.etag == "e1")
    #expect(report.items.map(\.id) == ["7"])
    #expect(report.deletedPaths.isEmpty)
}

@Test
func propfindMapsHrefsRelativeToBaseEvenWhenFoldersAreNamedLikeDavMarkers() async throws {
    let xml = Data("""
    <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/spaces/sid/Projects/files/report%20%2B%20notes.pdf</d:href><d:propstat><d:prop>
        <d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/dav/spaces/sid/spaces/</d:href><d:propstat><d:prop>
        <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>
    """.utf8)
    let transport = RecordingTransport([(xml, 207)])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/dav/spaces/sid/")!, transport: transport)

    let items = try await client.propfind(path: "/Projects")

    #expect(items.map(\.path) == ["/Projects/files/report + notes.pdf", "/spaces"])
    #expect(items.first?.parentID == "/Projects/files")
    #expect(items.last?.kind == .folder)
}

@Test
func downloadRangeWithOnlyEndRequestsFromStart() async throws {
    let transport = RecordingTransport([(Data("ab".utf8), 206, ["Content-Range": "bytes 0-1/8"])])
    let client = WebDAVClient(baseURL: URL(string: "https://cloud.example/remote.php/dav/files/alice/")!, transport: transport)

    _ = try await client.downloadRange(path: "/a.bin", startingAt: nil, endingAt: 1)

    #expect(await transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=0-1")
}
