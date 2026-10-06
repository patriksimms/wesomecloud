import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct AppVersion: Equatable, Sendable, Comparable, CustomStringConvertible {
    public var rawValue: String
    private var components: [VersionComponent]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.components = rawValue
            .split { $0 == "." || $0 == "-" || $0 == "_" || $0 == "+" }
            .map { VersionComponent(String($0)) }
    }

    public var description: String { rawValue }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = lhs.components[safe: index] ?? .numeric(0)
            let right = rhs.components[safe: index] ?? .numeric(0)
            if left == right { continue }
            return left < right
        }
        return false
    }
}

private enum VersionComponent: Equatable, Comparable {
    case numeric(Int)
    case text(String)

    init(_ value: String) {
        if let number = Int(value) {
            self = .numeric(number)
        } else {
            self = .text(value.lowercased())
        }
    }

    static func < (lhs: VersionComponent, rhs: VersionComponent) -> Bool {
        switch (lhs, rhs) {
        case let (.numeric(left), .numeric(right)):
            left < right
        case let (.text(left), .text(right)):
            left < right
        case (.numeric, .text):
            false
        case (.text, .numeric):
            true
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct UpdateCandidate: Equatable, Sendable {
    public var version: String
    public var build: String?
    public var title: String?
    public var releaseNotesURL: URL?
    public var downloadURL: URL?
    public var downloadLength: Int64?
    public var edSignature: String?
    public var publishedAt: Date?

    public init(
        version: String,
        build: String? = nil,
        title: String? = nil,
        releaseNotesURL: URL? = nil,
        downloadURL: URL? = nil,
        downloadLength: Int64? = nil,
        edSignature: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.build = build
        self.title = title
        self.releaseNotesURL = releaseNotesURL
        self.downloadURL = downloadURL
        self.downloadLength = downloadLength
        self.edSignature = edSignature
        self.publishedAt = publishedAt
    }
}

public struct UpdateSecurityPolicy: Equatable, Sendable {
    public var requiresDownloadURL: Bool
    public var requiresHTTPSDownloadURL: Bool
    public var requiresDownloadLength: Bool
    public var requiresEdSignature: Bool

    public init(
        requiresDownloadURL: Bool = false,
        requiresHTTPSDownloadURL: Bool = false,
        requiresDownloadLength: Bool = false,
        requiresEdSignature: Bool = false
    ) {
        self.requiresDownloadURL = requiresDownloadURL
        self.requiresHTTPSDownloadURL = requiresHTTPSDownloadURL
        self.requiresDownloadLength = requiresDownloadLength
        self.requiresEdSignature = requiresEdSignature
    }

    public static let permissive = UpdateSecurityPolicy()
    public static let signedDownloads = UpdateSecurityPolicy(
        requiresDownloadURL: true,
        requiresHTTPSDownloadURL: true,
        requiresDownloadLength: true,
        requiresEdSignature: true
    )

    public func accepts(_ candidate: UpdateCandidate) -> Bool {
        if requiresDownloadURL, candidate.downloadURL == nil { return false }
        if requiresHTTPSDownloadURL, candidate.downloadURL?.scheme?.lowercased() != "https" { return false }
        if requiresDownloadLength, (candidate.downloadLength ?? 0) <= 0 { return false }
        if requiresEdSignature, !Self.isValidEdSignature(candidate.edSignature) { return false }
        return true
    }

    public static func isValidEdSignature(_ signature: String?) -> Bool {
        guard
            let signature,
            let data = Data(base64Encoded: signature)
        else {
            return false
        }
        return data.count == 64
    }
}

public struct UpdateStatus: Equatable, Sendable {
    public var currentVersion: String
    public var availableUpdate: UpdateCandidate?
    public var lastCheckedAt: Date?
    public var message: String

    public init(
        currentVersion: String,
        availableUpdate: UpdateCandidate? = nil,
        lastCheckedAt: Date? = nil,
        message: String = "Updates have not been checked"
    ) {
        self.currentVersion = currentVersion
        self.availableUpdate = availableUpdate
        self.lastCheckedAt = lastCheckedAt
        self.message = message
    }
}

public enum AppcastValidationIssue: String, Codable, Equatable, Sendable {
    case missingExpectedVersion
    case missingExpectedBuild
    case missingDownloadURL
    case insecureDownloadURL
    case missingDownloadLength
    case mismatchedDownloadLength
    case missingEdSignature
    case malformedEdSignature
}

public struct AppcastValidationReport: Equatable, Sendable {
    public var expectedVersion: String
    public var expectedBuild: String?
    public var candidate: UpdateCandidate?
    public var issues: [AppcastValidationIssue]

    public init(
        expectedVersion: String,
        expectedBuild: String? = nil,
        candidate: UpdateCandidate? = nil,
        issues: [AppcastValidationIssue]
    ) {
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
        self.candidate = candidate
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

public struct AppcastValidationOptions: Equatable, Sendable {
    public var location: String
    public var expectedVersion: String
    public var expectedBuild: String?
    public var expectedDownloadLength: Int64?

    public init(location: String, expectedVersion: String, expectedBuild: String? = nil, expectedDownloadLength: Int64? = nil) {
        self.location = location
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
        self.expectedDownloadLength = expectedDownloadLength
    }
}

public enum AppcastValidationOptionError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingLocation
    case missingVersion
    case missingValue(String)
    case invalidDownloadLength(String)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .missingLocation:
            "Usage: wesomecloud validate-appcast <url-or-path> --version <version> [--build <build>] [--download-length <bytes>]"
        case .missingVersion:
            "Missing required --version"
        case .missingValue(let option):
            "Missing value for \(option)"
        case .invalidDownloadLength(let value):
            "Invalid --download-length value: \(value)"
        case .unknownArgument(let argument):
            "Unknown argument: \(argument)"
        }
    }
}

public struct AppcastValidationOptionParser: Sendable {
    public init() {}

    public func parse(_ arguments: [String]) throws -> AppcastValidationOptions {
        guard let location = arguments.first else {
            throw AppcastValidationOptionError.missingLocation
        }
        var expectedVersion: String?
        var expectedBuild: String?
        var expectedDownloadLength: Int64?
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--version":
                index += 1
                expectedVersion = try value(after: option, at: index, in: arguments)
            case "--build":
                index += 1
                expectedBuild = try value(after: option, at: index, in: arguments)
            case "--download-length":
                index += 1
                let rawValue = try value(after: option, at: index, in: arguments)
                guard let length = Int64(rawValue), length > 0 else {
                    throw AppcastValidationOptionError.invalidDownloadLength(rawValue)
                }
                expectedDownloadLength = length
            default:
                throw AppcastValidationOptionError.unknownArgument(option)
            }
            index += 1
        }
        guard let expectedVersion else {
            throw AppcastValidationOptionError.missingVersion
        }
        return AppcastValidationOptions(
            location: location,
            expectedVersion: expectedVersion,
            expectedBuild: expectedBuild,
            expectedDownloadLength: expectedDownloadLength
        )
    }

    private func value(after option: String, at index: Int, in arguments: [String]) throws -> String {
        guard index < arguments.count else {
            throw AppcastValidationOptionError.missingValue(option)
        }
        let value = arguments[index]
        guard !value.hasPrefix("--") else {
            throw AppcastValidationOptionError.missingValue(option)
        }
        return value
    }
}

public struct AppcastReleaseValidator: Sendable {
    private let parser: AppcastParser
    private let securityPolicy: UpdateSecurityPolicy

    public init(parser: AppcastParser = AppcastParser(), securityPolicy: UpdateSecurityPolicy = .signedDownloads) {
        self.parser = parser
        self.securityPolicy = securityPolicy
    }

    public func validate(
        data: Data,
        expectedVersion: String,
        expectedBuild: String? = nil,
        expectedDownloadLength: Int64? = nil
    ) throws -> AppcastValidationReport {
        let candidates = try parser.parse(data)
        let versionCandidates = candidates.filter { $0.version == expectedVersion }
        guard !versionCandidates.isEmpty else {
            return AppcastValidationReport(
                expectedVersion: expectedVersion,
                expectedBuild: expectedBuild,
                issues: [.missingExpectedVersion]
            )
        }

        let candidate: UpdateCandidate?
        if let expectedBuild {
            candidate = versionCandidates.first { $0.build == expectedBuild }
            guard candidate != nil else {
                return AppcastValidationReport(
                    expectedVersion: expectedVersion,
                    expectedBuild: expectedBuild,
                    candidate: versionCandidates.first,
                    issues: [.missingExpectedBuild]
                )
            }
        } else {
            candidate = versionCandidates.max { AppVersion($0.version) < AppVersion($1.version) }
        }

        guard let candidate else {
            return AppcastValidationReport(expectedVersion: expectedVersion, expectedBuild: expectedBuild, issues: [.missingExpectedVersion])
        }

        var issues: [AppcastValidationIssue] = []
        if securityPolicy.requiresDownloadURL, candidate.downloadURL == nil {
            issues.append(.missingDownloadURL)
        }
        if securityPolicy.requiresHTTPSDownloadURL, let downloadURL = candidate.downloadURL, downloadURL.scheme?.lowercased() != "https" {
            issues.append(.insecureDownloadURL)
        }
        if securityPolicy.requiresDownloadLength, (candidate.downloadLength ?? 0) <= 0 {
            issues.append(.missingDownloadLength)
        }
        if let expectedDownloadLength, candidate.downloadLength != expectedDownloadLength {
            issues.append(.mismatchedDownloadLength)
        }
        if securityPolicy.requiresEdSignature {
            if (candidate.edSignature ?? "").isEmpty {
                issues.append(.missingEdSignature)
            } else if !UpdateSecurityPolicy.isValidEdSignature(candidate.edSignature) {
                issues.append(.malformedEdSignature)
            }
        }

        return AppcastValidationReport(
            expectedVersion: expectedVersion,
            expectedBuild: expectedBuild,
            candidate: candidate,
            issues: issues
        )
    }
}

public struct AppcastParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> [UpdateCandidate] {
        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.candidates
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var candidates: [UpdateCandidate] = []
    private var currentItem: PartialUpdateCandidate?
    private var currentElement: String?
    private var text = ""
    private let dateFormatter: DateFormatter

    override init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        super.init()
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        if elementName == "item" {
            currentItem = PartialUpdateCandidate()
        } else if elementName == "enclosure", var item = currentItem {
            if let version = attributeDict["sparkle:shortVersionString"] ?? attributeDict["shortVersionString"] {
                item.version = version
            }
            if let build = attributeDict["sparkle:version"] ?? attributeDict["version"] {
                item.build = build
            }
            if let url = attributeDict["url"].flatMap(URL.init(string:)) {
                item.downloadURL = url
            }
            if let length = attributeDict["sparkle:length"] ?? attributeDict["length"], let value = Int64(length) {
                item.downloadLength = value
            }
            if let signature = attributeDict["sparkle:edSignature"] ?? attributeDict["edSignature"] {
                item.edSignature = signature
            }
            currentItem = item
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        defer {
            text = ""
            currentElement = nil
        }
        guard var item = currentItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            item.title = value
        case "sparkle:shortVersionString", "shortVersionString":
            item.version = value
        case "sparkle:version", "version":
            item.build = value
        case "sparkle:releaseNotesLink", "releaseNotesLink":
            item.releaseNotesURL = URL(string: value)
        case "pubDate":
            item.publishedAt = dateFormatter.date(from: value)
        case "item":
            if let candidate = item.candidate {
                candidates.append(candidate)
            }
            currentItem = nil
            return
        default:
            break
        }
        currentItem = item
    }

    private struct PartialUpdateCandidate {
        var version: String?
        var build: String?
        var title: String?
        var releaseNotesURL: URL?
        var downloadURL: URL?
        var downloadLength: Int64?
        var edSignature: String?
        var publishedAt: Date?

        var candidate: UpdateCandidate? {
            guard let version else { return nil }
            return UpdateCandidate(
                version: version,
                build: build,
                title: title,
                releaseNotesURL: releaseNotesURL,
                downloadURL: downloadURL,
                downloadLength: downloadLength,
                edSignature: edSignature,
                publishedAt: publishedAt
            )
        }
    }
}

public struct UpdateCheckingService: Sendable {
    public var currentVersion: String
    public var fetchAppcast: @Sendable (URL) async throws -> Data
    public var clock: @Sendable () -> Date
    public var securityPolicy: UpdateSecurityPolicy
    private let parser: AppcastParser

    public init(
        currentVersion: String,
        parser: AppcastParser = AppcastParser(),
        securityPolicy: UpdateSecurityPolicy = .permissive,
        clock: @escaping @Sendable () -> Date = Date.init,
        fetchAppcast: @escaping @Sendable (URL) async throws -> Data
    ) {
        self.currentVersion = currentVersion
        self.fetchAppcast = fetchAppcast
        self.clock = clock
        self.securityPolicy = securityPolicy
        self.parser = parser
    }

    public func check(appcastURL: URL?) async throws -> UpdateStatus {
        guard let appcastURL else {
            return UpdateStatus(currentVersion: currentVersion, lastCheckedAt: clock(), message: "No update feed configured")
        }
        let data = try await fetchAppcast(appcastURL)
        let candidates = try parser.parse(data)
        let current = AppVersion(currentVersion)
        let newerCandidates = candidates.filter { AppVersion($0.version) > current }
        let newest = newerCandidates
            .filter { securityPolicy.accepts($0) }
            .max { AppVersion($0.version) < AppVersion($1.version) }
        if let newest {
            return UpdateStatus(
                currentVersion: currentVersion,
                availableUpdate: newest,
                lastCheckedAt: clock(),
                message: "Version \(newest.version) is available"
            )
        }
        if !newerCandidates.isEmpty {
            return UpdateStatus(
                currentVersion: currentVersion,
                lastCheckedAt: clock(),
                message: "No trusted signed updates available"
            )
        }
        return UpdateStatus(currentVersion: currentVersion, lastCheckedAt: clock(), message: "WesomeCloud is up to date")
    }
}
