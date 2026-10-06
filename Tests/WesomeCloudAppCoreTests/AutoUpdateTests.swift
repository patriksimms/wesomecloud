import Foundation
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

private let validEdSignature = Data(repeating: 0, count: 64).base64EncodedString()

@Test
func appVersionComparesNumericAndSuffixComponents() {
    #expect(AppVersion("1.10.0") > AppVersion("1.2.9"))
    #expect(AppVersion("2.0") > AppVersion("2.0-beta"))
    #expect(AppVersion("1.0.0") == AppVersion("1.0"))
}

@Test
func appcastParserExtractsSparkleUpdateCandidates() throws {
    let data = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>WesomeCloud 0.2.0</title>
          <sparkle:releaseNotesLink>https://example.com/releases/0.2.0</sparkle:releaseNotesLink>
          <pubDate>Wed, 27 May 2026 10:00:00 +0000</pubDate>
          <enclosure url="https://example.com/WesomeCloud.zip" sparkle:shortVersionString="0.2.0" sparkle:version="20" length="12345" sparkle:edSignature="signed-update" />
        </item>
      </channel>
    </rss>
    """.utf8)

    let candidates = try AppcastParser().parse(data)

    #expect(candidates.count == 1)
    #expect(candidates.first?.version == "0.2.0")
    #expect(candidates.first?.build == "20")
    #expect(candidates.first?.title == "WesomeCloud 0.2.0")
    #expect(candidates.first?.downloadURL?.absoluteString == "https://example.com/WesomeCloud.zip")
    #expect(candidates.first?.downloadLength == 12345)
    #expect(candidates.first?.edSignature == "signed-update")
    #expect(candidates.first?.releaseNotesURL?.absoluteString == "https://example.com/releases/0.2.0")
}

@Test
func appcastParserExtractsSparkleTopLevelVersions() throws {
    let data = Data("""
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <sparkle:shortVersionString>0.4.0</sparkle:shortVersionString>
          <sparkle:version>40</sparkle:version>
          <enclosure url="https://example.com/WesomeCloud.zip" length="99" sparkle:edSignature="signature" />
        </item>
      </channel>
    </rss>
    """.utf8)

    let candidate = try #require(AppcastParser().parse(data).first)

    #expect(candidate.version == "0.4.0")
    #expect(candidate.build == "40")
    #expect(candidate.downloadLength == 99)
    #expect(candidate.edSignature == "signature")
}

@Test
func updateCheckerReportsNewestAvailableVersion() async throws {
    let appcastURL = URL(string: "https://updates.example/appcast.xml")!
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/old.zip" sparkle:shortVersionString="0.1.0" /></item>
        <item><enclosure url="https://example.com/new.zip" sparkle:shortVersionString="0.3.0" /></item>
        <item><enclosure url="https://example.com/mid.zip" sparkle:shortVersionString="0.2.0" /></item>
      </channel>
    </rss>
    """.utf8)
    let service = UpdateCheckingService(
        currentVersion: "0.1.5",
        clock: { Date(timeIntervalSince1970: 42) },
        fetchAppcast: { url in
            #expect(url == appcastURL)
            return data
        }
    )

    let status = try await service.check(appcastURL: appcastURL)

    #expect(status.availableUpdate?.version == "0.3.0")
    #expect(status.lastCheckedAt == Date(timeIntervalSince1970: 42))
    #expect(status.message == "Version 0.3.0 is available")
}

@Test
func signedUpdateCheckerIgnoresUnsignedNewerCandidates() async throws {
    let appcastURL = URL(string: "https://updates.example/appcast.xml")!
    let signature = validEdSignature
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/unsigned.zip" sparkle:shortVersionString="0.4.0" /></item>
        <item><enclosure url="https://example.com/signed.zip" sparkle:shortVersionString="0.3.0" length="123" sparkle:edSignature="\(signature)" /></item>
      </channel>
    </rss>
    """.utf8)
    let service = UpdateCheckingService(
        currentVersion: "0.2.0",
        securityPolicy: .signedDownloads,
        clock: { Date(timeIntervalSince1970: 42) },
        fetchAppcast: { _ in data }
    )

    let status = try await service.check(appcastURL: appcastURL)

    #expect(status.availableUpdate?.version == "0.3.0")
    #expect(status.availableUpdate?.edSignature == signature)
    #expect(status.message == "Version 0.3.0 is available")
}

@Test
func signedUpdateCheckerReportsWhenOnlyUnsignedUpdatesExist() async throws {
    let malformedSignature = "not-a-64-byte-signature"
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/unsigned.zip" sparkle:shortVersionString="0.4.0" /></item>
        <item><enclosure url="http://example.com/insecure.zip" sparkle:shortVersionString="0.5.0" length="123" sparkle:edSignature="\(validEdSignature)" /></item>
        <item><enclosure url="https://example.com/malformed.zip" sparkle:shortVersionString="0.6.0" length="123" sparkle:edSignature="\(malformedSignature)" /></item>
      </channel>
    </rss>
    """.utf8)
    let service = UpdateCheckingService(
        currentVersion: "0.2.0",
        securityPolicy: .signedDownloads,
        clock: { Date(timeIntervalSince1970: 42) },
        fetchAppcast: { _ in data }
    )

    let status = try await service.check(appcastURL: URL(string: "https://updates.example/appcast.xml")!)

    #expect(status.availableUpdate == nil)
    #expect(status.lastCheckedAt == Date(timeIntervalSince1970: 42))
    #expect(status.message == "No trusted signed updates available")
}

@Test
func appcastReleaseValidatorAcceptsExpectedSignedVersionAndBuild() throws {
    let signature = validEdSignature
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/WesomeCloud.zip" sparkle:shortVersionString="0.1.0" sparkle:version="1" length="100" sparkle:edSignature="\(signature)" /></item>
      </channel>
    </rss>
    """.utf8)

    let report = try AppcastReleaseValidator().validate(data: data, expectedVersion: "0.1.0", expectedBuild: "1")

    #expect(report.isValid)
    #expect(report.candidate?.version == "0.1.0")
    #expect(report.candidate?.build == "1")
    #expect(report.issues.isEmpty)
}

@Test
func appcastReleaseValidatorReportsMissingBuildAndSignatureIssues() throws {
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/WesomeCloud.zip" sparkle:shortVersionString="0.1.0" sparkle:version="2" length="100" /></item>
      </channel>
    </rss>
    """.utf8)

    let buildReport = try AppcastReleaseValidator().validate(data: data, expectedVersion: "0.1.0", expectedBuild: "1")
    let signatureReport = try AppcastReleaseValidator().validate(data: data, expectedVersion: "0.1.0", expectedBuild: "2")

    #expect(buildReport.issues == [.missingExpectedBuild])
    #expect(signatureReport.issues == [.missingEdSignature])
}

@Test
func appcastReleaseValidatorReportsInsecureDownloadsAndMalformedSignatures() throws {
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="http://example.com/WesomeCloud.zip" sparkle:shortVersionString="0.1.0" sparkle:version="1" length="100" sparkle:edSignature="not-a-64-byte-signature" /></item>
      </channel>
    </rss>
    """.utf8)

    let report = try AppcastReleaseValidator().validate(data: data, expectedVersion: "0.1.0", expectedBuild: "1")

    #expect(report.issues == [.insecureDownloadURL, .malformedEdSignature])
}

@Test
func appcastReleaseValidatorReportsMismatchedDownloadLength() throws {
    let data = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item><enclosure url="https://example.com/WesomeCloud.zip" sparkle:shortVersionString="0.1.0" sparkle:version="1" length="100" sparkle:edSignature="\(validEdSignature)" /></item>
      </channel>
    </rss>
    """.utf8)

    let report = try AppcastReleaseValidator().validate(
        data: data,
        expectedVersion: "0.1.0",
        expectedBuild: "1",
        expectedDownloadLength: 101
    )

    #expect(report.issues == [.mismatchedDownloadLength])
}

@Test
func appcastValidationOptionParserRequiresExactOptionValues() throws {
    let options = try AppcastValidationOptionParser().parse([
        "https://updates.example/appcast.xml",
        "--version",
        "0.1.0",
        "--build",
        "1",
        "--download-length",
        "123"
    ])

    #expect(options == AppcastValidationOptions(
        location: "https://updates.example/appcast.xml",
        expectedVersion: "0.1.0",
        expectedBuild: "1",
        expectedDownloadLength: 123
    ))
    #expect(throws: AppcastValidationOptionError.missingValue("--build")) {
        try AppcastValidationOptionParser().parse(["appcast.xml", "--version", "0.1.0", "--build"])
    }
    #expect(throws: AppcastValidationOptionError.missingValue("--version")) {
        try AppcastValidationOptionParser().parse(["appcast.xml", "--version", "--build", "1"])
    }
    #expect(throws: AppcastValidationOptionError.invalidDownloadLength("0")) {
        try AppcastValidationOptionParser().parse(["appcast.xml", "--version", "0.1.0", "--download-length", "0"])
    }
}

@Test
func appModelChecksForUpdatesAndRecordsDiagnostics() async throws {
    let appcastURL = URL(string: "https://updates.example/appcast.xml")!
    let preferences = AppPreferences(updates: UpdatePreferences(appcastURL: appcastURL))
    let appcast = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item><enclosure url="https://example.com/new.zip" sparkle:shortVersionString="9.0.0" /></item></channel>
    </rss>
    """.utf8)
    let model = WesomeCloudAppModel(
        accountSessions: AccountSessionService(credentialStore: MemoryCredentialStore()),
        domains: FileProviderDomainService(manager: MemoryFileProviderDomainManager()),
        repository: MemoryAccountRepository(),
        preferencesRepository: MemoryPreferencesRepository(preferences: preferences),
        updateChecker: UpdateCheckingService(currentVersion: "1.0.0", fetchAppcast: { _ in appcast })
    )

    let status = try await model.checkForUpdates()
    let snapshot = try await model.loadSnapshot()

    #expect(status.availableUpdate?.version == "9.0.0")
    #expect(snapshot.updateStatus == status)
    #expect(snapshot.diagnostics.contains { $0.category == "Updates" && $0.level == .warning })
}
