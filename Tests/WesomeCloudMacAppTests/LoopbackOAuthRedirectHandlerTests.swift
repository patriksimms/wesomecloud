#if canImport(AuthenticationServices) && canImport(AppKit)
import Foundation
import Testing
import WesomeCloudShared
@testable import WesomeCloudMacApp

@Test
func loopbackRedirectHandlerIgnoresUnrelatedRequestsUntilTheRedirectArrives() async throws {
    let handler = LoopbackOAuthRedirectHandler()
    let redirectURI = try await handler.start(preferredRedirectURI: URL(string: "http://127.0.0.1/callback")!)
    let base = try #require(URLComponents(url: redirectURI, resolvingAgainstBaseURL: false))
    #expect(base.host == "127.0.0.1")
    #expect(base.path == "/callback")

    let favicon = try await URLSession.shared.data(from: redirectURI.deletingLastPathComponent().appending(path: "favicon.ico"))
    let missingCode = try await URLSession.shared.data(from: URL(string: redirectURI.absoluteString + "?state=abc")!)
    #expect((favicon.1 as? HTTPURLResponse)?.statusCode == 404)
    #expect((missingCode.1 as? HTTPURLResponse)?.statusCode == 404)

    let redirect = URL(string: redirectURI.absoluteString + "?state=abc&code=xyz")!
    let response = try await URLSession.shared.data(from: redirect)
    #expect((response.1 as? HTTPURLResponse)?.statusCode == 200)

    let callback = try await handler.waitForCallback()
    #expect(callback.path == "/callback")
    #expect(callback.query == "state=abc&code=xyz")
}

@Test
func loopbackRedirectHandlerTimesOutWhenNoRedirectArrives() async throws {
    let handler = LoopbackOAuthRedirectHandler(timeout: 0.1)
    _ = try await handler.start(preferredRedirectURI: URL(string: "http://127.0.0.1/callback")!)

    await #expect(throws: WesomeCloudError.self) {
        _ = try await handler.waitForCallback()
    }
}
#endif
