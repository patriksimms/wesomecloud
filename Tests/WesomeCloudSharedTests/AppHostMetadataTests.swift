import Foundation
import Testing

private struct ScriptResult {
    let exitCode: Int32
    let output: String
}

private func runReleaseSigningValidator(environment overrides: [String: String]) throws -> ScriptResult {
    let script = root.appending(path: "scripts/validate-release-signing.sh")
    let process = Process()
    let pipe = Pipe()
    process.currentDirectoryURL = root
    process.executableURL = script
    process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ScriptResult(exitCode: process.terminationStatus, output: output)
}

private let validReleaseEnvironment = [
    "WESOME_CLOUD_DEVELOPMENT_TEAM": "ABCDE12345",
    "WESOME_CLOUD_SIGNING_IDENTITY": "Developer ID Application: Your Company, Inc. (ABCDE12345)",
    "WESOME_CLOUD_NOTARY_PROFILE": "wesomecloud-notary",
    "WESOME_CLOUD_APPCAST_URL": "https://updates.your-domain.test/appcast.xml",
    "WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
]

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private func plist(_ relativePath: String) throws -> NSDictionary {
    try #require(NSDictionary(contentsOf: root.appending(path: relativePath)), "\(relativePath) is not a readable plist")
}

// These checks guard values the compiler cannot: a wrong key in a plist or entitlements file
// still builds but ships an app whose extension never loads or cannot share the app group.
@Test
func extensionInfoPlistPointsAtShippedPrincipalClassAndMatchesAppVersion() throws {
    let appInfo = try plist("AppHost/Info.plist")
    let extensionInfo = try plist("AppHost/WesomeFileProviderExtension-Info.plist")
    let extensionDictionary = try #require(extensionInfo["NSExtension"] as? NSDictionary)

    #expect(appInfo["CFBundleExecutable"] as? String == "$(EXECUTABLE_NAME)")
    #expect(appInfo["CFBundlePackageType"] as? String == "APPL")
    #expect(extensionInfo["CFBundleExecutable"] as? String == "$(EXECUTABLE_NAME)")
    #expect(extensionInfo["CFBundlePackageType"] as? String == "XPC!")
    #expect(extensionDictionary["NSExtensionPointIdentifier"] as? String == "com.apple.fileprovider-nonui")
    #expect(extensionDictionary["NSExtensionPrincipalClass"] as? String == "$(PRODUCT_MODULE_NAME).FileProviderExtension")
    #expect(extensionDictionary["NSExtensionFileProviderDocumentGroup"] as? String == "$(TeamIdentifierPrefix)cloud.wesome.wesomecloud")
    #expect(extensionInfo["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    #expect(extensionInfo["CFBundleVersion"] as? String == appInfo["CFBundleVersion"] as? String)
    #expect(extensionInfo["CFBundleShortVersionString"] as? String == appInfo["CFBundleShortVersionString"] as? String)

    let principalClass = try String(contentsOf: root.appending(path: "AppHost/WesomeFileProviderExtension/FileProviderExtension.swift"), encoding: .utf8)
    #expect(principalClass.contains("class FileProviderExtension:"))
}

@Test
func appInfoPlistWiresSparkleToReleaseSettings() throws {
    let appInfo = try plist("AppHost/Info.plist")

    #expect(appInfo["SUFeedURL"] as? String == "$(WESOME_CLOUD_APPCAST_URL)")
    #expect(appInfo["SUPublicEDKey"] as? String == "$(WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY)")
    #expect(appInfo["SUEnableAutomaticChecks"] as? Bool == true)
    #expect(appInfo["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
}

@Test(arguments: [
    ("AppHost/WesomeCloud.entitlements", true),
    ("AppHost/WesomeCloud-Debug.entitlements", true),
    ("AppHost/WesomeFileProviderExtension.entitlements", false),
    ("AppHost/WesomeFileProviderExtension-Debug.entitlements", false),
])
func entitlementsShareAppGroupAndKeychainInsideSandbox(path: String, isApp: Bool) throws {
    let entitlements = try plist(path)

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
    #expect(entitlements["com.apple.security.application-groups"] as? [String] == ["$(TeamIdentifierPrefix)cloud.wesome.wesomecloud"])
    #expect(entitlements["com.apple.developer.fileprovider.testing-mode"] == nil)
    // App and extension read the same credentials from the data protection keychain.
    #expect(entitlements["keychain-access-groups"] as? [String] == ["$(AppIdentifierPrefix)cloud.wesome.wesomecloud"])
    // Only the app hosts the OAuth loopback redirect listener.
    #expect((entitlements["com.apple.security.network.server"] as? Bool == true) == isApp)
}

@Test
func exportOptionsProduceDeveloperIDBuildForReleaseTeam() throws {
    let exportOptions = try plist("AppHost/ExportOptions.plist")

    #expect(exportOptions["method"] as? String == "developer-id")
    #expect(exportOptions["teamID"] as? String == "$(WESOME_CLOUD_DEVELOPMENT_TEAM)")
}

@Test(arguments: [
    (
        "WESOME_CLOUD_DEVELOPMENT_TEAM",
        "BAD",
        "WESOME_CLOUD_DEVELOPMENT_TEAM must be a 10-character Apple team ID."
    ),
    (
        "WESOME_CLOUD_SIGNING_IDENTITY",
        "Mac Developer: Your Company, Inc. (ABCDE12345)",
        "WESOME_CLOUD_SIGNING_IDENTITY must be a Developer ID Application identity."
    ),
    (
        "WESOME_CLOUD_APPCAST_URL",
        "http://updates.your-domain.test/appcast.xml",
        "WESOME_CLOUD_APPCAST_URL must use an https:// URL."
    ),
    (
        "WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY",
        "AAAA",
        "WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte Ed25519 public key."
    ),
    (
        "WESOME_CLOUD_APPCAST_URL",
        "https://updates.example.com/appcast.xml",
        "Release setting WESOME_CLOUD_APPCAST_URL still contains placeholder value"
    ),
])
func releaseSigningValidatorRejectsMalformedProductionSettings(
    key: String,
    value: String,
    expectedMessage: String
) throws {
    var environment = validReleaseEnvironment
    environment[key] = value
    let result = try runReleaseSigningValidator(environment: environment)

    #expect(result.exitCode == 2)
    #expect(result.output.contains(expectedMessage))
}
