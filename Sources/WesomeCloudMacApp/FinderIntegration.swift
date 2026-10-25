import Foundation
import WesomeCloudAppCore
import WesomeCloudShared

public enum FinderIntegrationStatus: Equatable, Sendable {
    case checking
    case notRegistered
    case activationRequired(URL?)
    case disconnected(URL?)
    case enabled(URL)
    case unavailable(String)

    public var locationURL: URL? {
        switch self {
        case .activationRequired(let url), .disconnected(let url): url
        case .enabled(let url): url
        default: nil
        }
    }
}

public protocol FinderIntegrationChecking: Sendable {
    func status() async throws -> FinderIntegrationStatus
}

public struct SystemFinderIntegration: FinderIntegrationChecking {
    public init() {}

    public func status() async throws -> FinderIntegrationStatus {
        #if canImport(FileProvider)
        guard let domain = try await NSFileProviderManager.domains().first(where: {
            $0.identifier.rawValue == UnifiedFileProviderDomainManager.domain.id
        }) else { return .notRegistered }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw WesomeCloudError.unsupported("WesomeCloud's Finder location is unavailable. Try checking again.")
        }
        // A disabled domain may not yet have a URL. Keep the activation instruction
        // visible even when macOS cannot resolve its location until activation.
        if !domain.userEnabled {
            return .activationRequired(try? await manager.getUserVisibleURL(for: .rootContainer))
        }
        if domain.isDisconnected {
            return .disconnected(try? await manager.getUserVisibleURL(for: .rootContainer))
        }
        return .enabled(try await manager.getUserVisibleURL(for: .rootContainer))
        #else
        return .notRegistered
        #endif
    }
}

#if canImport(FileProvider)
import FileProvider
#endif
