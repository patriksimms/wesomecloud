import Foundation
import WesomeCloudShared

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WesomeCloudError.invalidResponse }
        return (data, http)
    }
}

public struct Credentials: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case basic(username: String, password: String)
        case bearerToken(String)
    }

    public var kind: Kind
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.kind = .basic(username: username, password: password)
        self.username = username
        self.password = password
    }

    public init(accessToken: String) {
        self.kind = .bearerToken(accessToken)
        self.username = ""
        self.password = accessToken
    }

    public var authorizationHeader: String {
        switch kind {
        case .basic(let username, let password):
            let token = "\(username):\(password)".data(using: .utf8)!.base64EncodedString()
            return "Basic \(token)"
        case .bearerToken(let token):
            return "Bearer \(token)"
        }
    }
}

public struct DownloadResponse: Equatable, Sendable {
    public var data: Data
    public var statusCode: Int
    public var contentRange: String?
    public var etag: String?

    public init(data: Data, statusCode: Int, contentRange: String? = nil, etag: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.contentRange = contentRange
        self.etag = etag
    }
}

public struct ChunkedUploadConfiguration: Equatable, Sendable {
    public var chunkSize: Int
    public var transferID: String

    public init(chunkSize: Int = 10 * 1024 * 1024, transferID: String = UUID().uuidString) {
        self.chunkSize = chunkSize
        self.transferID = transferID
    }
}

public struct WebDAVSyncReport: Equatable, Sendable {
    public var syncToken: String?
    public var items: [RemoteItem]
    public var deletedPaths: [String]

    public init(syncToken: String? = nil, items: [RemoteItem] = [], deletedPaths: [String] = []) {
        self.syncToken = syncToken
        self.items = items
        self.deletedPaths = deletedPaths
    }
}

public actor WebDAVClient {
    private let baseURL: URL
    private let credentials: Credentials?
    private let transport: HTTPTransport

    public init(baseURL: URL, credentials: Credentials? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
    }

    public func propfind(path: String, depth: Int = 1) async throws -> [RemoteItem] {
        var request = makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = propfindBody
        let (data, response) = try await transport.data(for: request)
        try validate(response, allowed: [207])
        return try WebDAVParser.parseMultiStatus(data: data, requestedPath: normalizedPath(path), basePath: baseURL.path)
    }

    public func privateLink(path: String) async throws -> URL {
        var request = makeRequest(path: path)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = privateLinkPropfindBody
        let (data, response) = try await transport.data(for: request)
        try validate(response, allowed: [207])
        guard let item = try WebDAVParser.parseMultiStatus(data: data, requestedPath: normalizedPath(path), basePath: baseURL.path).first,
              let url = item.privateLink
        else {
            throw WesomeCloudError.invalidResponse
        }
        return url
    }

    public func syncCollection(path: String, syncToken: String?, depth: Int = 1) async throws -> WebDAVSyncReport {
        var request = makeRequest(path: path)
        request.httpMethod = "REPORT"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = syncCollectionBody(syncToken: syncToken)
        let (data, response) = try await transport.data(for: request)
        try validate(response, allowed: [207])
        return try WebDAVParser.parseSyncReport(data: data, requestedPath: normalizedPath(path), basePath: baseURL.path)
    }

    public func download(path: String) async throws -> Data {
        try await downloadRange(path: path).data
    }

    /// `ifRange` (an etag) makes the server ignore `Range` and send the full body if the file changed.
    public func downloadRange(path: String, startingAt offset: Int64? = nil, endingAt end: Int64? = nil, ifRange etag: String? = nil) async throws -> DownloadResponse {
        var request = makeRequest(path: path)
        request.httpMethod = "GET"
        let start = offset ?? 0
        if start > 0 || end != nil {
            let suffix = end.map { String($0) } ?? ""
            request.setValue("bytes=\(start)-\(suffix)", forHTTPHeaderField: "Range")
            if let etag { request.setValue(etag.quotedETag, forHTTPHeaderField: "If-Range") }
        }
        let (data, response) = try await transport.data(for: request)
        try validate(response, allowed: [200, 206])
        return DownloadResponse(
            data: data,
            statusCode: response.statusCode,
            contentRange: response.value(forHTTPHeaderField: "Content-Range"),
            etag: response.value(forHTTPHeaderField: "ETag")?.normalizedETag
        )
    }

    public func upload(data: Data, to path: String, ifMatch etag: String? = nil) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = "PUT"
        request.httpBody = data
        if let etag { request.setValue(etag.quotedETag, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await transport.data(for: request)
        try validate(response, allowed: [200, 201, 204])
    }

    /// Uploads through ownCloud 10 chunking NG (MKCOL transfer folder, PUT chunks, MOVE `.file`).
    /// Bases without a `/remote.php/dav/files/<user>/` prefix (oCIS spaces) have no NG uploads
    /// endpoint, so they fall back to a single PUT until TUS is implemented.
    public func uploadChunked(
        data: Data,
        to path: String,
        configuration: ChunkedUploadConfiguration = ChunkedUploadConfiguration(),
        ifMatch etag: String? = nil,
        progress: (@Sendable (Int64) async throws -> Void)? = nil
    ) async throws {
        guard configuration.chunkSize > 0 else { throw WesomeCloudError.unsupported("Chunk size must be greater than zero") }
        guard let uploadBase = chunkingUploadBaseURL() else {
            try await upload(data: data, to: path, ifMatch: etag)
            try await progress?(Int64(data.count))
            return
        }
        let transferURL = uploadBase.appending(path: configuration.transferID)
        let totalLength = String(data.count)

        var mkcol = makeRequest(url: transferURL)
        mkcol.httpMethod = "MKCOL"
        let (_, mkcolResponse) = try await transport.data(for: mkcol)
        try validate(mkcolResponse, allowed: [201])

        let chunks = data.chunked(into: configuration.chunkSize)
        var uploadedBytes: Int64 = 0
        for (index, chunk) in chunks.enumerated() {
            var request = makeRequest(url: transferURL.appending(path: Self.chunkName(index)))
            request.httpMethod = "PUT"
            request.setValue(totalLength, forHTTPHeaderField: "OC-Total-Length")
            request.httpBody = chunk
            let (_, response) = try await transport.data(for: request)
            try validate(response, allowed: [200, 201, 204])
            uploadedBytes += Int64(chunk.count)
            try await progress?(uploadedBytes)
        }

        let destination = makeURL(path: path).absoluteString
        var commit = makeRequest(url: transferURL.appending(path: ".file"))
        commit.httpMethod = "MOVE"
        commit.setValue(destination, forHTTPHeaderField: "Destination")
        commit.setValue("T", forHTTPHeaderField: "Overwrite")
        commit.setValue(totalLength, forHTTPHeaderField: "OC-Total-Length")
        // If-Match on the MOVE would be checked against the `.file` source, so the destination
        // etag goes into a tagged `If` header instead.
        if let etag { commit.setValue("<\(destination)> ([\(etag.quotedETag)])", forHTTPHeaderField: "If") }
        let (_, response) = try await transport.data(for: commit)
        try validate(response, allowed: [200, 201, 204])
    }

    public func createFolder(path: String) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = "MKCOL"
        let (_, response) = try await transport.data(for: request)
        try validate(response, allowed: [201, 405])
    }

    public func move(from sourcePath: String, to destinationPath: String, overwrite: Bool = false) async throws {
        var request = makeRequest(path: sourcePath)
        request.httpMethod = "MOVE"
        request.setValue(makeURL(path: destinationPath).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await transport.data(for: request)
        try validate(response, allowed: [201, 204])
    }

    public func delete(path: String) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = "DELETE"
        let (_, response) = try await transport.data(for: request)
        try validate(response, allowed: [200, 202, 204, 404])
    }

    private func makeRequest(path: String) -> URLRequest {
        makeRequest(url: makeURL(path: path))
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let credentials {
            request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeURL(path: String) -> URL {
        baseURL.appending(path: normalizedPath(path).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// `https://host/remote.php/dav/uploads/<user>/` for a `/remote.php/dav/files/<user>/` base, else nil.
    private func chunkingUploadBaseURL() -> URL? {
        let absolute = baseURL.absoluteString
        guard let range = absolute.range(of: "/remote.php/dav/files/") else { return nil }
        let username = absolute[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !username.isEmpty else { return nil }
        return URL(string: absolute[..<range.lowerBound] + "/remote.php/dav/uploads/" + username + "/")
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }

    private func validate(_ response: HTTPURLResponse, allowed: Set<Int>) throws {
        guard allowed.contains(response.statusCode) else {
            throw WesomeCloudError.httpFailure(
                HTTPFailure.classify(
                    statusCode: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
    }

    private static func chunkName(_ index: Int) -> String {
        String(format: "%05d", index)
    }

    private var propfindBody: Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getetag/>
            <d:creationdate/>
            <d:getlastmodified/>
            <d:getcontenttype/>
            <oc:fileid/>
            <oc:permissions/>
            <oc:checksum/>
            <oc:quota-used-bytes/>
            <oc:quota-available-bytes/>
            <oc:privatelink/>
          </d:prop>
        </d:propfind>
        """.utf8)
    }

    private func syncCollectionBody(syncToken: String?) -> Data {
        let tokenElement = syncToken.map { "<d:sync-token>\($0.xmlEscaped)</d:sync-token>" } ?? "<d:sync-token/>"
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:sync-collection xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          \(tokenElement)
          <d:sync-level>1</d:sync-level>
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getetag/>
            <d:creationdate/>
            <d:getlastmodified/>
            <d:getcontenttype/>
            <oc:fileid/>
            <oc:permissions/>
            <oc:checksum/>
            <oc:quota-used-bytes/>
            <oc:quota-available-bytes/>
            <oc:privatelink/>
          </d:prop>
        </d:sync-collection>
        """.utf8)
    }

    private var privateLinkPropfindBody: Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop>
            <oc:privatelink/>
          </d:prop>
        </d:propfind>
        """.utf8)
    }
}

public enum WebDAVParser {
    /// `basePath` is the (decoded) path of the WebDAV root URL; hrefs are made relative to it.
    public static func parseMultiStatus(data: Data, requestedPath: String, basePath: String? = nil) throws -> [RemoteItem] {
        let delegate = MultiStatusDelegate(requestedPath: requestedPath, basePath: basePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? WesomeCloudError.invalidResponse }
        return delegate.items
    }

    public static func parseSyncReport(data: Data, requestedPath: String, basePath: String? = nil) throws -> WebDAVSyncReport {
        let delegate = MultiStatusDelegate(requestedPath: requestedPath, basePath: basePath)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? WesomeCloudError.invalidResponse }
        return WebDAVSyncReport(
            syncToken: delegate.syncToken,
            items: delegate.items,
            deletedPaths: delegate.deletedPaths
        )
    }
}

private final class MultiStatusDelegate: NSObject, XMLParserDelegate {
    private let requestedPath: String
    private let basePath: String?
    private var text = ""
    private var response = Response()
    private var inResponse = false
    // Sabre answers each PROPFIND with one <propstat> per status (200 for found props, 404 for
    // unknown ones). Props are buffered per propstat and only applied when its status is 2xx;
    // only a <status> directly under <response> marks the resource itself (e.g. deleted).
    private var inPropstat = false
    private var propstatStatus: Int?
    private var propstatProps: [(name: String, value: String)] = []
    private var propstatIsCollection = false
    var items: [RemoteItem] = []
    var deletedPaths: [String] = []
    var syncToken: String?

    init(requestedPath: String, basePath: String?) {
        self.requestedPath = requestedPath
        self.basePath = basePath
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        text = ""
        switch elementName.localXMLName {
        case "response": inResponse = true; response = Response(basePath: basePath)
        case "propstat": inPropstat = true; propstatStatus = nil; propstatProps = []; propstatIsCollection = false
        case "collection": propstatIsCollection = true
        default: break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName.localXMLName == "sync-token" {
            syncToken = value.isEmpty ? nil : value
            return
        }
        guard inResponse else { return }
        let name = elementName.localXMLName
        if inPropstat {
            switch name {
            case "status": propstatStatus = Self.statusCode(from: value)
            case "propstat":
                // A propstat without <status> is malformed but harmless; treat it as found.
                if propstatStatus.map({ (200..<300).contains($0) }) ?? true {
                    if propstatIsCollection { response.isCollection = true }
                    for prop in propstatProps { response.apply(prop: prop.name, value: prop.value) }
                }
                inPropstat = false
            default: propstatProps.append((name, value))
            }
            return
        }
        switch name {
        case "href": response.href = value.removingPercentEncoding ?? value
        case "status": response.statusCode = Self.statusCode(from: value)
        case "response":
            if response.statusCode == 404 {
                if let path = response.remotePath(requestedPath: requestedPath) {
                    deletedPaths.append(path)
                }
            } else if let item = response.item(requestedPath: requestedPath) {
                items.append(item)
            }
            inResponse = false
        default: break
        }
    }

    private static func statusCode(from statusLine: String) -> Int? {
        let parts = statusLine.split(separator: " ")
        return parts.compactMap { Int($0) }.first
    }

    private struct Response {
        var basePath: String?
        var href = ""
        var statusCode: Int?
        var isCollection = false
        var size: Int64?
        var etag: String?
        var fileID: String?
        var permissions: String?
        var checksum: String?
        var modifiedAt: Date?
        var createdAt: Date?
        var contentType: String?
        var quotaUsedBytes: Int64?
        var quotaAvailableBytes: Int64?
        var privateLink: URL?

        mutating func apply(prop name: String, value: String) {
            switch name {
            case "getcontentlength": size = Int64(value)
            case "getetag": etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "fileid": fileID = value
            case "permissions": permissions = value
            case "checksum": checksum = value
            case "quota-used-bytes": quotaUsedBytes = Int64(value)
            case "quota-available-bytes": quotaAvailableBytes = Int64(value)
            case "privatelink": privateLink = URL(string: value)
            case "getcontenttype": contentType = value
            case "creationdate": createdAt = WebDAVDate.parse(value)
            case "getlastmodified": modifiedAt = HTTPDate.parse(value)
            default: break
            }
        }

        func remotePath(requestedPath: String) -> String? {
            let hrefPath = href.hasPrefix("http") ? (URL(string: href)?.path ?? href) : href
            let components = hrefPath.split(separator: "/", omittingEmptySubsequences: true)
            let baseComponents = basePath?.split(separator: "/", omittingEmptySubsequences: true) ?? []
            let relativeComponents: ArraySlice<Substring>
            if !baseComponents.isEmpty, components.starts(with: baseComponents) {
                relativeComponents = components.dropFirst(baseComponents.count)
            } else if let markerIndex = components.firstIndex(where: { $0 == "files" || $0 == "spaces" }),
                      components.index(after: markerIndex) < components.endIndex {
                // Fallback without a known base: `/files/<user>/…` or `/spaces/<space-id>/…`.
                relativeComponents = components.dropFirst(components.distance(from: components.startIndex, to: markerIndex) + 2)
            } else {
                relativeComponents = components[...]
            }
            let path = "/" + relativeComponents.joined(separator: "/")
            guard !path.isEmpty else { return nil }
            return path == requestedPath ? requestedPath : path
        }

        func item(requestedPath: String) -> RemoteItem? {
            guard let path = remotePath(requestedPath: requestedPath) else { return nil }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
            let parent = String(trimmed.split(separator: "/").dropLast().joined(separator: "/"))
            let stableID = fileID?.isEmpty == false ? fileID! : path
            return RemoteItem(
                id: stableID,
                parentID: parent.isEmpty ? nil : "/" + parent,
                name: name.isEmpty ? "Root" : name,
                path: path == requestedPath ? requestedPath : path,
                kind: isCollection ? .folder : .file,
                size: size,
                etag: etag,
                fileID: fileID,
                checksum: checksum,
                permissions: permissions,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                contentType: contentType,
                quotaUsedBytes: quotaUsedBytes,
                quotaAvailableBytes: quotaAvailableBytes,
                privateLink: privateLink
            )
        }
    }
}

private extension String {
    /// Etags are stored unquoted; HTTP conditional headers need the quoted entity-tag form.
    var quotedETag: String {
        hasPrefix("\"") || hasPrefix("W/") ? self : "\"\(self)\""
    }

    var normalizedETag: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    var localXMLName: String {
        split(separator: ":").last.map(String.init) ?? self
    }

    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private extension Data {
    func chunked(into size: Int) -> [Data] {
        guard !isEmpty else { return [Data()] }
        var result: [Data] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + size, count)
            result.append(subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}

private enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

private enum WebDAVDate {
    static func parse(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
