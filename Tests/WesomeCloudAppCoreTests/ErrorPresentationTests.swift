import Foundation
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

@Test
func userFacingFormatterDescribesHTTPFailures() {
    let failure = HTTPFailure(statusCode: 507, kind: .quotaExceeded)

    #expect(UserFacingErrorFormatter.message(for: failure) == "The server quota is full.")
    #expect(UserFacingErrorFormatter.message(for: WesomeCloudError.httpFailure(failure)) == "The server quota is full.")
}

@Test
func userFacingFormatterDescribesInvalidFilenames() {
    let empty = WesomeCloudError.invalidFilename("", .empty)
    let colon = WesomeCloudError.invalidFilename("Bad:", .containsColon)

    #expect(UserFacingErrorFormatter.message(for: empty) == "Choose a valid filename. The name cannot be empty.")
    #expect(UserFacingErrorFormatter.message(for: colon) == "Choose a valid filename for \"Bad:\". The name cannot contain a colon.")
}

@Test
func userFacingFormatterDescribesDecodingFailures() {
    struct MissingName: Decodable {
        var name: String
    }

    do {
        _ = try JSONDecoder().decode(MissingName.self, from: Data("{}".utf8))
        Issue.record("Expected decoding to fail")
    } catch {
        #expect(UserFacingErrorFormatter.message(for: error) == "The server returned data in an unexpected format.")
    }
}

@Test
func userFacingFormatterNormalizesStoredQueueErrors() {
    #expect(UserFacingErrorFormatter.message(forStoredErrorDescription: "quotaExceeded") == "The server quota is full.")
    #expect(UserFacingErrorFormatter.message(forStoredErrorDescription: "HTTP 503") == "The server is temporarily unavailable. Try again later.")
    #expect(UserFacingErrorFormatter.message(forStoredErrorDescription: "custom failure") == "custom failure")
}
