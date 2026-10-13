import Foundation
import OwnCloudKit
import Testing
import WesomeCloudAppCore
import WesomeCloudShared

@Test
func domainServiceRegistersAndRemovesAccountDomain() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let session = AccountSession(account: account, credentialKind: .appPassword, serverVersion: "10", serverEdition: "Community")
    let manager = MemoryFileProviderDomainManager()
    let diagnostics = MemoryDiagnosticSink()
    let service = FileProviderDomainService(manager: manager, diagnostics: diagnostics)

    let domain = try await service.registerDomain(for: session)

    #expect(domain.id == account.id.uuidString)
    #expect(try await manager.domains() == [domain])

    try await service.removeDomain(for: account.id)

    #expect(try await manager.domains().isEmpty)
    #expect(await diagnostics.events.map(\.category) == ["FileProviderDomain", "FileProviderDomain"])
}

@Test
func domainServiceRegistersOwnCloudSpaceDomainWithWebDAVRoot() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let manager = MemoryFileProviderDomainManager()
    let service = FileProviderDomainService(manager: manager)
    let space = OwnCloudSpace(
        id: "storage-users-1$space",
        name: "Marketing",
        webDAVURL: URL(string: "https://cloud.example/dav/spaces/storage-users-1$space")!
    )

    let domain = try await service.registerDomain(for: account, space: space)

    #expect(domain.id == "\(account.id.uuidString)-storage-users-1-space")
    #expect(domain.displayName == "Marketing")
    #expect(domain.rootPath == "/")
    #expect(domain.webDAVRootURL == URL(string: "https://cloud.example/dav/spaces/storage-users-1$space")!)
    #expect(try await manager.domains() == [domain])
}

@Test
func domainServicePersistsRegisteredDomainsWhenRepositoryIsConfigured() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice", displayName: "Alice Cloud")
    let session = AccountSession(account: account, credentialKind: .appPassword, serverVersion: nil, serverEdition: nil)
    let manager = MemoryFileProviderDomainManager()
    let repository = MemoryAccountRepository()
    let service = FileProviderDomainService(manager: manager, repository: repository)

    let domain = try await service.registerDomain(for: session)

    #expect(try await repository.domains(accountID: account.id) == [domain])

    try await service.removeDomain(id: domain.id)

    #expect(try await repository.domains(accountID: account.id).isEmpty)
}

@Test
func cloudDomainParsesAccountIDFromAccountAndSpaceDomainIdentifiers() throws {
    let accountID = try #require(UUID(uuidString: "A1B2C3D4-E5F6-4701-8901-ABCDEF123456"))

    #expect(CloudDomain.accountID(fromDomainIdentifier: accountID.uuidString) == accountID)
    #expect(CloudDomain.accountID(fromDomainIdentifier: "\(accountID.uuidString)-storage-users-1-space") == accountID)
    #expect(CloudDomain.accountID(fromDomainIdentifier: "\(accountID.uuidString)storage-users-1-space") == nil)
    #expect(CloudDomain.accountID(fromDomainIdentifier: "storage-users-1-space") == nil)
}

@Test
func domainServiceRemovesAllRegisteredDomainsForAccount() async throws {
    let accountID = try #require(UUID(uuidString: "A1B2C3D4-E5F6-4701-8901-ABCDEF123456"))
    let otherAccountID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"))
    let accountDomain = CloudDomain(id: accountID.uuidString, accountID: accountID, displayName: "Alice")
    let spaceDomain = CloudDomain(id: "\(accountID.uuidString)-space-1", accountID: accountID, displayName: "Alice - Space")
    let otherDomain = CloudDomain(id: otherAccountID.uuidString, accountID: otherAccountID, displayName: "Bob")
    let manager = MemoryFileProviderDomainManager()
    try await manager.register(accountDomain)
    try await manager.register(spaceDomain)
    try await manager.register(otherDomain)
    let service = FileProviderDomainService(manager: manager)

    try await service.removeDomains(for: accountID)

    #expect(try await manager.domains() == [otherDomain])
}

@Test
func domainServiceRemovesPersistedDomainsEvenWhenSystemManagerDoesNotListThem() async throws {
    let accountID = try #require(UUID(uuidString: "A1B2C3D4-E5F6-4701-8901-ABCDEF123456"))
    let persistedSpaceDomain = CloudDomain(id: "\(accountID.uuidString)-space-1", accountID: accountID, displayName: "Alice - Space")
    let manager = MemoryFileProviderDomainManager()
    let repository = MemoryAccountRepository()
    try await repository.saveDomain(persistedSpaceDomain)
    let service = FileProviderDomainService(manager: manager, repository: repository)

    try await service.removeDomains(for: accountID)

    #expect(try await repository.domains(accountID: accountID).isEmpty)
}

private actor PreservingDomainManager: FileProviderDomainManaging {
    let manager = MemoryFileProviderDomainManager()
    var preserved: [String] = []

    func register(_ domain: CloudDomain) async throws { try await manager.register(domain) }
    func remove(domainID: String) async throws { try await manager.remove(domainID: domainID) }
    func removePreservingUserData(domainID: String) async throws {
        preserved.append(domainID)
        try await manager.remove(domainID: domainID)
    }
    func domains() async throws -> [CloudDomain] { try await manager.domains() }
}

@Test
func unifiedDomainRestoreRetiresLegacyLocationsWithoutDiscardingUserDataOrSelections() async throws {
    let account = Account(serverURL: URL(string: "https://cloud.example/")!, username: "alice")
    let personal = CloudDomain(id: account.id.uuidString, accountID: account.id, displayName: "Personal")
    let project = CloudDomain(id: "project", accountID: account.id, displayName: "Marketing", storageID: UUID())
    let manager = PreservingDomainManager()
    try await manager.register(personal)
    try await manager.register(project)
    let repository = MemoryAccountRepository()
    try await repository.saveDomain(personal)
    try await repository.saveDomain(project)
    let signaler = MemoryFileProviderChangeSignaler()
    let unified = UnifiedFileProviderDomainManager(manager: manager, signaler: signaler)
    let service = FileProviderDomainService(manager: unified, repository: repository)

    try await service.restore([personal, project])
    #expect(try await manager.domains().map(\.displayName) == ["WesomeCloud"])
    #expect(Set(await manager.preserved) == [personal.id, project.id])
    #expect(Set(try await repository.domains(accountID: account.id).map(\.metadataID)) == [personal.metadataID, project.metadataID])

    try await service.removeDomain(project)
    try await service.refreshSelections([personal])
    #expect(try await manager.domains().map(\.displayName) == ["WesomeCloud"])
    #expect(try await repository.domains(accountID: account.id) == [personal])
    try await service.restore([personal])
    #expect(await manager.preserved.count == 2)

    try await service.removeDomain(personal)
    try await service.refreshSelections([])
    #expect(try await manager.domains().isEmpty)
    #expect(await manager.preserved.count == 3)
    #expect(await signaler.signaledEnumerators.map(\.containerItemIdentifier).contains("NSFileProviderRootContainerItemIdentifier"))
}
