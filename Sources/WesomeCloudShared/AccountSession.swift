import Foundation

public struct AccountSession: Equatable, Sendable {
    public var account: Account
    public var credentialKind: CredentialKind
    public var serverVersion: String?
    public var serverEdition: String?
    public var serverPollInterval: TimeInterval?

    public init(
        account: Account,
        credentialKind: CredentialKind,
        serverVersion: String?,
        serverEdition: String?,
        serverPollInterval: TimeInterval? = nil
    ) {
        self.account = account
        self.credentialKind = credentialKind
        self.serverVersion = serverVersion
        self.serverEdition = serverEdition
        self.serverPollInterval = serverPollInterval
    }
}
