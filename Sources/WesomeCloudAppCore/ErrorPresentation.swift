import Foundation
import WesomeCloudShared

public enum UserFacingErrorFormatter {
    public static func message(for error: Error) -> String {
        if let cloudError = error as? WesomeCloudError {
            switch cloudError {
            case .invalidFilename(let filename, let violation):
                return filename.isEmpty
                    ? "Choose a valid filename. \(message(for: violation))"
                    : "Choose a valid filename for \"\(filename)\". \(message(for: violation))"
            case .conflict(let conflict):
                return conflict.message
            case .httpFailure(let failure):
                return message(for: failure)
            case .missingItem:
                return "The item is no longer available."
            case .transferIntegrityMismatch(let message):
                return "The transfer could not be verified. \(message)"
            case .unsupported(let message):
                return message
            case .invalidResponse:
                return "The server returned an invalid response."
            case .httpStatus(let statusCode):
                return "The server returned HTTP \(statusCode)."
            }
        }
        if error is DecodingError {
            return "The server returned data in an unexpected format."
        }
        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }

    public static func message(for failure: HTTPFailure) -> String {
        switch failure.kind {
        case .authentication:
            return "Authentication failed. Check the account credentials and try again."
        case .authorization:
            return "The account does not have permission to perform this action."
        case .notFound:
            return "The item is no longer available on the server."
        case .conflict:
            return "The server reported a name or version conflict."
        case .quotaExceeded:
            return "The server quota is full."
        case .rateLimited:
            return "The server is rate limiting requests. Try again later."
        case .server, .unavailable:
            return "The server is temporarily unavailable. Try again later."
        case .client:
            return "The server rejected the request with HTTP \(failure.statusCode)."
        case .unexpected:
            return "The server returned HTTP \(failure.statusCode)."
        }
    }

    public static func message(for violation: FilenameViolation) -> String {
        switch violation {
        case .empty:
            return "The name cannot be empty."
        case .containsSlash:
            return "The name cannot contain a slash."
        case .containsColon:
            return "The name cannot contain a colon."
        case .reservedName:
            return "That name is reserved on macOS."
        case .trailingWhitespaceOrPeriod:
            return "The name cannot end with whitespace or a period."
        case .ignoredPattern:
            return "That name is ignored by the current sync preferences."
        }
    }

    public static func message(forStoredErrorDescription description: String) -> String {
        if description.contains("quotaExceeded") || description.contains("HTTP 507") {
            return "The server quota is full."
        }
        if description.contains("authentication") || description.contains("HTTP 401") {
            return "Authentication failed. Check the account credentials and try again."
        }
        if description.contains("authorization") || description.contains("HTTP 403") {
            return "The account does not have permission to perform this action."
        }
        if description.contains("notFound") || description.contains("HTTP 404") {
            return "The item is no longer available on the server."
        }
        if description.contains("rateLimited") || description.contains("HTTP 429") {
            return "The server is rate limiting requests. Try again later."
        }
        if description.contains("unavailable") || description.contains("server") || description.contains("HTTP 500") || description.contains("HTTP 503") {
            return "The server is temporarily unavailable. Try again later."
        }
        if description.contains("conflict") || description.contains("HTTP 409") {
            return "The server reported a name or version conflict."
        }
        return description
    }
}
