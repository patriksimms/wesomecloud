import Foundation
import WesomeCloudAppCore
import WesomeCloudMacApp

@main
struct WesomeCloudCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "validate-appcast" {
                try await validateAppcast(arguments: Array(arguments.dropFirst()))
                return
            }
            print("WesomeCloud macOS client core and SwiftUI shell compile successfully.")
            print("Use the WesomeCloudMacApp library from an Xcode app target for the signed app bundle and File Provider extension.")
        } catch let error as CLIError {
            FileHandle.standardError.writeLine(error.description)
            Foundation.exit(error.exitCode)
        } catch {
            FileHandle.standardError.writeLine("Unexpected error: \(error)")
            Foundation.exit(1)
        }
    }

    private static func validateAppcast(arguments: [String]) async throws {
        let options: AppcastValidationOptions
        do {
            options = try AppcastValidationOptionParser().parse(arguments)
        } catch let error as AppcastValidationOptionError {
            throw CLIError.usage(error.description)
        }

        let data = try await loadAppcast(options.location)
        let report = try AppcastReleaseValidator().validate(
            data: data,
            expectedVersion: options.expectedVersion,
            expectedBuild: options.expectedBuild,
            expectedDownloadLength: options.expectedDownloadLength
        )
        if report.isValid {
            print("Appcast contains signed release \(options.expectedVersion)\(options.expectedBuild.map { " (\($0))" } ?? "").")
            return
        }
        let issues = report.issues.map(\.rawValue).joined(separator: ", ")
        throw CLIError.validation("Appcast validation failed: \(issues)")
    }

    private static func loadAppcast(_ location: String) async throws -> Data {
        if let url = URL(string: location), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        return try Data(contentsOf: URL(fileURLWithPath: location))
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case validation(String)

    var description: String {
        switch self {
        case .usage(let message), .validation(let message):
            message
        }
    }

    var exitCode: Int32 {
        switch self {
        case .usage:
            64
        case .validation:
            1
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension FileHandle {
    func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        write(data)
    }
}
