import WesomeFileProviderExtension

/// Principal class named in WesomeFileProviderExtension-Info.plist. The inherited
/// `init(domain:)` wires the production runtime resolver for the domain.
final class FileProviderExtension: WesomeFileProviderReplicatedExtension, @unchecked Sendable {}
