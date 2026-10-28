import Foundation
import CryptoKit

public enum DiagnosticRedactor {
    /// Stable references let support correlate paths and items without exporting their names.
    public static func reference(_ value: String) -> String {
        "ref:" + SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func redact(_ value: String) -> String {
        var result = value
        for pattern in [
            #"(?i)\b(password|token|secret|authorization|cookie|access_token|refresh_token)\s*[:=]\s*[^\r\n]+"#,
            #"(?i)\b(basic|bearer)\s+[A-Za-z0-9._~+/=-]+"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        // Redact complete quote groups first, then any truncated localized quote to end of line.
        // NSError descriptions may contain file names or paths with spaces.
        for pattern in [#""(?:\\.|[^"\\\r\n])*""#, #"[“„][^\r\n]*[”“]"#, #"[“„][^\r\n]*"#, #"https?://[^\s<>\"\)]+"#, #"(?<!\w)/[^\r\n]*"#,
                        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: reference(String(result[range])))
            }
        }
        return result
    }
}
