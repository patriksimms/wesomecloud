import Foundation
import WesomeCloudShared

public struct FilenamePolicy: Sendable {
    public init() {}

    public func validate(_ name: String) throws {
        if name.isEmpty { throw WesomeCloudError.invalidFilename(name, .empty) }
        if name.contains("/") { throw WesomeCloudError.invalidFilename(name, .containsSlash) }
        if name.contains(":") { throw WesomeCloudError.invalidFilename(name, .containsColon) }
        if name.last?.isWhitespace == true || name.hasSuffix(".") {
            throw WesomeCloudError.invalidFilename(name, .trailingWhitespaceOrPeriod)
        }
        let reserved = [".", "..", ".DS_Store"]
        if reserved.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw WesomeCloudError.invalidFilename(name, .reservedName)
        }
    }
}

public struct SyncPolicy: Sendable {
    private let filenamePolicy: FilenamePolicy

    public init(filenamePolicy: FilenamePolicy = FilenamePolicy()) {
        self.filenamePolicy = filenamePolicy
    }

    public func validateNewName(_ name: String, siblings: [RemoteItem], excluding itemID: String? = nil) throws {
        try filenamePolicy.validate(name)
        if let sibling = siblings.first(where: { sibling in
            sibling.id != itemID && sibling.name.canonicalFilenameKey == name.canonicalFilenameKey && !sibling.name.hasSameUnicodeScalars(as: name)
        }) {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .unicodeNormalization,
                    itemID: itemID ?? name,
                    localPath: name,
                    remotePath: sibling.path,
                    message: "An item named \(name) is canonically equivalent to \(sibling.name) on macOS."
                )
            )
        }
        // APFS is case-insensitive but not accent-insensitive: "resume.pdf" and "résumé.pdf" can coexist.
        if siblings.contains(where: { sibling in
            sibling.id != itemID && sibling.name.canonicalFilenameKey.caseInsensitiveCompare(name.canonicalFilenameKey) == .orderedSame
        }) {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .nameCollision,
                    itemID: itemID ?? name,
                    message: "An item named \(name) already exists in this folder."
                )
            )
        }
    }

    public func validateMove(item: RemoteItem, destinationPath: String, destinationSiblings: [RemoteItem]) throws {
        let destinationName = destinationPath.lastPathComponent
        try validateNewName(destinationName, siblings: destinationSiblings, excluding: item.id)
        if item.name.caseInsensitiveCompare(destinationName) == .orderedSame && item.name != destinationName {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .caseOnlyRename,
                    itemID: item.id,
                    localPath: destinationPath,
                    remotePath: item.path,
                    message: "Case-only renames require explicit conflict handling on case-insensitive filesystems."
                )
            )
        }
        if item.name.canonicalFilenameKey == destinationName.canonicalFilenameKey && !item.name.hasSameUnicodeScalars(as: destinationName) {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .unicodeNormalization,
                    itemID: item.id,
                    localPath: destinationPath,
                    remotePath: item.path,
                    message: "Unicode-normalization-only renames require explicit conflict handling on macOS."
                )
            )
        }
    }

    public func validateUpload(stored: RemoteItem, latestRemote: RemoteItem?) throws {
        guard let latestRemote else {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .remoteDeletedDuringLocalEdit,
                    itemID: stored.id,
                    localPath: stored.path,
                    remotePath: stored.path,
                    message: "The remote file was deleted before the local edit could upload."
                )
            )
        }
        if latestRemote.kind != stored.kind {
            throw WesomeCloudError.conflict(
                SyncConflict(
                    kind: .typeChanged,
                    itemID: stored.id,
                    localPath: stored.path,
                    remotePath: latestRemote.path,
                    message: "The remote item changed type before the local edit could upload."
                )
            )
        }
        if latestRemote.etag != nil, stored.etag != nil, latestRemote.etag != stored.etag {
            throw remoteChangedDuringLocalEdit(stored, remotePath: latestRemote.path)
        }
    }

    public func remoteChangedDuringLocalEdit(_ stored: RemoteItem, remotePath: String) -> WesomeCloudError {
        WesomeCloudError.conflict(
            SyncConflict(
                kind: .remoteChangedDuringLocalEdit,
                itemID: stored.id,
                localPath: stored.path,
                remotePath: remotePath,
                message: "The remote file changed before the local edit could upload."
            )
        )
    }
}

private extension String {
    var lastPathComponent: String {
        split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? self
    }

    var canonicalFilenameKey: String {
        precomposedStringWithCanonicalMapping
    }

    func hasSameUnicodeScalars(as other: String) -> Bool {
        unicodeScalars.elementsEqual(other.unicodeScalars)
    }
}
