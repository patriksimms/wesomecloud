import Foundation
import WesomeCloudShared
import WesomeFileProviderCore

public protocol FileProviderSelectionRestoring: Sendable {
    func restoreSelections(_ selections: [CloudDomain]) async throws
}

/// CloudDomain records still identify individual sync stores. Only this aggregate
/// domain is registered with macOS, so all selections share one Finder location.
public actor UnifiedFileProviderDomainManager: FileProviderDomainManaging, FileProviderSelectionRestoring {
    public static let domain = CloudDomain(
        id: ProviderSpaceIdentifier.domainID,
        accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        displayName: "WesomeCloud"
    )

    private let manager: any FileProviderDomainManaging
    private let signaler: (any FileProviderChangeSignaling)?

    public init(manager: any FileProviderDomainManaging, signaler: (any FileProviderChangeSignaling)? = nil) {
        self.manager = manager
        self.signaler = signaler
    }

    public func register(_ domain: CloudDomain) async throws {
        try await manager.register(Self.domain)
    }

    public func remove(domainID: String) async throws {
        // Removing a selection must leave other spaces' Finder location intact.
        if try await manager.domains().contains(where: { $0.id == domainID }) {
            try await manager.removePreservingUserData(domainID: domainID)
        }
    }

    public func domains() async throws -> [CloudDomain] {
        try await manager.domains()
    }

    public func restoreSelections(_ selections: [CloudDomain]) async throws {
        let registered = try await manager.domains()
        if selections.isEmpty {
            if registered.contains(where: { $0.id == Self.domain.id }) {
                try await manager.removePreservingUserData(domainID: Self.domain.id)
            }
        } else {
            if !registered.contains(where: { $0.id == Self.domain.id }) {
                try await manager.register(Self.domain)
            }
            try await signaler?.signalEnumerator(domainID: Self.domain.id, containerItemIdentifier: "NSFileProviderRootContainerItemIdentifier")
            try await signaler?.signalEnumerator(domainID: Self.domain.id, containerItemIdentifier: "NSFileProviderWorkingSetContainerItemIdentifier")
        }
        // Retain downloaded and unsynced Finder data when retiring old locations.
        // Internal metadata IDs and upload queues are not changed by this migration.
        for domain in registered where domain.id != Self.domain.id {
            try await manager.removePreservingUserData(domainID: domain.id)
        }
    }
}

/// Background sync continues to use remote IDs. Translate its refresh requests
/// to the identifiers in the aggregate Finder domain.
public struct UnifiedFileProviderChangeSignaler: FileProviderChangeSignaling {
    private let signaler: any FileProviderChangeSignaling

    public init(signaler: any FileProviderChangeSignaling) {
        self.signaler = signaler
    }

    public func signalAuthenticationResolved(domainID: String) async throws {
        try await signaler.signalAuthenticationResolved(domainID: ProviderSpaceIdentifier.domainID)
    }

    public func signalEnumerator(domainID: String, containerItemIdentifier: String) async throws {
        let identifier: String
        switch containerItemIdentifier {
        case "NSFileProviderWorkingSetContainerItemIdentifier":
            identifier = containerItemIdentifier
        case "NSFileProviderRootContainerItemIdentifier":
            identifier = domainID == ProviderSpaceIdentifier.domainID ? containerItemIdentifier : ProviderSpaceIdentifier.folder(domainID)
        default:
            identifier = ProviderSpaceIdentifier.item(containerItemIdentifier, spaceID: domainID)
        }
        try await signaler.signalEnumerator(domainID: ProviderSpaceIdentifier.domainID, containerItemIdentifier: identifier)
    }
}
