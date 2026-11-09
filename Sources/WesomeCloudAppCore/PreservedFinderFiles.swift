import Foundation

/// Local recovery notes stay outside diagnostic exports because they contain readable paths.
enum PreservedFinderFiles {
    static func record(_ preservedURL: URL, in directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let note = directory.appending(path: "\(UUID().uuidString).txt")
        let text = "WesomeCloud preserved Finder files at:\n\(preservedURL.path)\n\nIn Finder, choose Go > Go to Folder and paste the path above. Check these files for local edits before removing them.\n"
        try Data(text.utf8).write(to: note, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
    }
}
