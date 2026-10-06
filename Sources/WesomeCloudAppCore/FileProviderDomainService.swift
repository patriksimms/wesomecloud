import Foundation
import OwnCloudKit
import WesomeCloudShared

public struct CloudDomain: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var accountID: UUID
    public var displayName: String
    public var rootPath: String
    public var webDAVRootURL: URL?
    public var storageID: UUID?
    public var metadataID: UUID { storageID ?? accountID }

    public init(id: String, accountID: UUID, displayName: String, rootPath: String = "/", webDAVRootURL: URL? = nil, storageID: UUID? = nil) {
        self.id = id
        self.accountID = accountID
        self.displayName = displayName
        self.rootPath = rootPath
        self.webDAVRootURL = webDAVRootURL
        self.storageID = storageID
    }

    public func represents(_ space: OwnCloudSpace) -> Bool {
        if let webDAVRootURL {
            let slashes = CharacterSet(charactersIn: "/")
            return webDAVRootURL.absoluteString.trimmingCharacters(in: slashes)
                == space.webDAVURL.absoluteString.trimmingCharacters(in: slashes)
        }
        // The legacy account endpoint already exposes the personal Space.
        return space.driveType == "personal" && id == accountID.uuidString && rootPath == "/"
    }

    public static func accountID(fromDomainIdentifier identifier: String) -> UUID? {
        if let accountID = UUID(uuidString: identifier) {
            return accountID
        }
        guard identifier.count > 36 else {
            return nil
        }
        let prefix = String(identifier.prefix(36))
        guard identifier[identifier.index(identifier.startIndex, offsetBy: 36)] == "-" else {
            return nil
        }
        return UUID(uuidString: prefix)
    }
}

public protocol FileProviderDomainManaging: Sendable {
    func register(_ domain: CloudDomain) async throws
    func remove(domainID: String) async throws
    func domains() async throws -> [CloudDomain]
}

public protocol FileProviderChangeSignaling: Sendable {
    func signalEnumerator(domainID: String, containerItemIdentifier: String) async throws
}

public actor MemoryFileProviderDomainManager: FileProviderDomainManaging {
    private var registered: [String: CloudDomain] = [:]

    public init() {}

    public func register(_ domain: CloudDomain) async throws {
        registered[domain.id] = domain
    }

    public func remove(domainID: String) async throws {
        registered[domainID] = nil
    }

    public func domains() async throws -> [CloudDomain] {
        registered.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

public actor MemoryFileProviderChangeSignaler: FileProviderChangeSignaling {
    public private(set) var signaledEnumerators: [(domainID: String, containerItemIdentifier: String)] = []
    public var error: Error?

    public init() {}

    public func set(error: Error?) {
        self.error = error
    }

    public func signalEnumerator(domainID: String, containerItemIdentifier: String) async throws {
        if let error {
            throw error
        }
        signaledEnumerators.append((domainID: domainID, containerItemIdentifier: containerItemIdentifier))
    }
}

public actor FileProviderDomainService {
    private let manager: FileProviderDomainManaging
    private let repository: CloudDomainRepository?
    private let changeSignaler: FileProviderChangeSignaling?
    private let diagnostics: DiagnosticSink?

    public init(
        manager: FileProviderDomainManaging,
        repository: CloudDomainRepository? = nil,
        changeSignaler: FileProviderChangeSignaling? = nil,
        diagnostics: DiagnosticSink? = nil
    ) {
        self.manager = manager
        self.repository = repository
        self.changeSignaler = changeSignaler
        self.diagnostics = diagnostics
    }

    public init(manager: FileProviderDomainManaging, diagnostics: DiagnosticSink?) {
        self.manager = manager
        self.repository = nil
        self.changeSignaler = nil
        self.diagnostics = diagnostics
    }

    public func registerDomain(for session: AccountSession) async throws -> CloudDomain {
        let domain = CloudDomain(
            id: session.account.id.uuidString,
            accountID: session.account.id,
            displayName: session.account.displayName
        )
        try await manager.register(domain)
        try await repository?.saveDomain(domain)
        await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Registered domain \(domain.displayName)"))
        return domain
    }

    public func registerDomain(for account: Account, space: OwnCloudSpace) async throws -> CloudDomain {
        let domain = CloudDomain(
            id: "\(account.id.uuidString)-\(space.id.stableDomainComponent)",
            accountID: account.id,
            displayName: space.name,
            rootPath: "/",
            webDAVRootURL: space.webDAVURL,
            storageID: UUID()
        )
        try await manager.register(domain)
        try await repository?.saveDomain(domain)
        await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Registered space domain \(space.name)"))
        return domain
    }

    public func updateDomain(_ domain: CloudDomain) async throws {
        try await manager.register(domain)
        try await repository?.saveDomain(domain)
    }

    public func removeDomain(_ domain: CloudDomain) async throws {
        try await manager.remove(domainID: domain.id)
        try await repository?.deleteDomain(id: domain.id)
        await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Removed Finder location \(domain.displayName)"))
    }

    public func restore(_ selections: [CloudDomain]) async throws {
        let registered = Set(try await manager.domains().map(\.id))
        for domain in selections {
            if !registered.contains(domain.id) {
                try await manager.register(domain)
                await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Restored Finder location \(domain.displayName)"))
            }
            // Refresh cached metadata, including capabilities changed by an app update.
            try await changeSignaler?.signalEnumerator(domainID: domain.id, containerItemIdentifier: "NSFileProviderWorkingSetContainerItemIdentifier")
        }
    }

    public func removeDomain(for accountID: UUID) async throws {
        try await manager.remove(domainID: accountID.uuidString)
        await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Removed domain \(accountID.uuidString)"))
    }

    public func removeDomains(for accountID: UUID, including knownDomainID: String? = nil) async throws {
        var domainIDs = Set<String>()
        domainIDs.insert(accountID.uuidString)
        if let knownDomainID {
            domainIDs.insert(knownDomainID)
        }
        let registeredDomainIDs = Set(try await manager.domains().filter { $0.accountID == accountID }.map(\.id))
        domainIDs.formUnion(registeredDomainIDs)
        if let repository {
            for domain in try await repository.domains(accountID: accountID) {
                domainIDs.insert(domain.id)
            }
        }
        // Candidate IDs (bare account ID, persisted or known IDs) may already be gone from the
        // system, so their removal failures are ignored. Failures for domains the system still
        // lists are rethrown, but only after every other domain has been attempted.
        var firstRegisteredFailure: Error?
        for domainID in domainIDs.sorted() {
            do {
                try await manager.remove(domainID: domainID)
            } catch {
                let isRegistered = registeredDomainIDs.contains(domainID)
                await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: isRegistered ? .error : .debug, message: "Could not remove domain \(domainID): \(error.localizedDescription)"))
                if isRegistered {
                    firstRegisteredFailure = firstRegisteredFailure ?? error
                    continue
                }
            }
            try await repository?.deleteDomain(id: domainID)
            await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Removed domain \(domainID)"))
        }
        if let firstRegisteredFailure {
            throw firstRegisteredFailure
        }
    }

    public func removeDomain(id domainID: String) async throws {
        try await manager.remove(domainID: domainID)
        try await repository?.deleteDomain(id: domainID)
        await diagnostics?.record(DiagnosticEvent(category: "FileProviderDomain", level: .info, message: "Removed domain \(domainID)"))
    }
}

private extension String {
    var stableDomainComponent: String {
        map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        .reduce(into: "") { $0.append($1) }
    }
}

#if canImport(FileProvider)
import FileProvider

public final class SystemFileProviderDomainManager: FileProviderDomainManaging, @unchecked Sendable {
    public init() {}

    public func register(_ domain: CloudDomain) async throws {
        let fileProviderDomain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domain.id),
            displayName: domain.displayName
        )
        try await NSFileProviderManager.add(fileProviderDomain)
    }

    public func remove(domainID: String) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainID),
            displayName: domainID
        )
        try await NSFileProviderManager.remove(domain)
    }

    public func domains() async throws -> [CloudDomain] {
        try await NSFileProviderManager.domains().map {
            let identifier = $0.identifier.rawValue
            return CloudDomain(
                id: identifier,
                accountID: CloudDomain.accountID(fromDomainIdentifier: identifier) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                displayName: $0.displayName
            )
        }
    }
}

public final class SystemFileProviderChangeSignaler: FileProviderChangeSignaling, @unchecked Sendable {
    public init() {}

    public func signalEnumerator(domainID: String, containerItemIdentifier: String) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainID),
            displayName: domainID
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            throw WesomeCloudError.missingItem(domainID)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.signalEnumerator(for: NSFileProviderItemIdentifier(containerItemIdentifier)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif
