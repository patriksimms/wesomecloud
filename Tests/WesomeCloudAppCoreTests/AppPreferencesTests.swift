import Foundation
import Testing
import WesomeCloudAppCore

@Test
func jsonPreferencesRepositoryPersistsPreferences() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    let preferences = AppPreferences(
        sync: SyncPreferences(isSyncPaused: true, pollInterval: 120, queueInterval: 20, retryMaximumAttempts: 5, maximumConcurrentTransfers: 2),
        files: FilePreferences(defaultAvailability: .alwaysLocal, showHiddenFiles: true, ignoredFilenamePatterns: ["*.tmp", "~$*"], excludedRemotePaths: ["Projects/Private", "/Archive/"]),
        diagnostics: DiagnosticPreferences(retainEventLimit: 500, includeDebugEvents: true),
        updates: UpdatePreferences(
            automaticallyCheckForUpdates: false,
            appcastURL: URL(string: "https://updates.example/appcast.xml"),
            checkInterval: 172_800
        )
    )

    do {
        let repository = JSONPreferencesRepository(fileURL: fileURL)
        try await repository.save(preferences)
    }

    let reopened = JSONPreferencesRepository(fileURL: fileURL)
    #expect(try await reopened.load() == preferences)
}

@Test
func jsonPreferencesRepositoryMigratesMissingUpdatePreferences() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    try """
    {
      "sync" : { "pollInterval" : 120, "queueInterval" : 20, "retryBaseDelay" : 2, "retryMaximumDelay" : 300, "retryMaximumAttempts" : 5 },
      "files" : { "defaultAvailability" : "onlineOnly", "showHiddenFiles" : false },
      "diagnostics" : { "retainEventLimit" : 500, "includeDebugEvents" : true }
    }
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    let preferences = try await JSONPreferencesRepository(fileURL: fileURL).load()

    #expect(preferences.updates == UpdatePreferences())
    #expect(preferences.sync.isSyncPaused == false)
    #expect(preferences.sync.maximumConcurrentTransfers == 3)
    #expect(preferences.files.ignoredFilenamePatterns == FilePreferences.defaultIgnoredFilenamePatterns)
    #expect(preferences.files.excludedRemotePaths.isEmpty)
}

@Test
func syncPreferencesClampUnsafePersistedValues() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
        .appendingPathExtension("json")
    try """
    {
      "sync" : {
        "pollInterval" : 1,
        "queueInterval" : 1,
        "retryBaseDelay" : -2,
        "retryMaximumDelay" : 0,
        "retryMaximumAttempts" : 0,
        "maximumConcurrentTransfers" : 0
      }
    }
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    let preferences = try await JSONPreferencesRepository(fileURL: fileURL).load()

    #expect(preferences.sync.pollInterval == 15)
    #expect(preferences.sync.queueInterval == 5)
    #expect(preferences.sync.retryBaseDelay == 1)
    #expect(preferences.sync.retryMaximumDelay == 1)
    #expect(preferences.sync.retryMaximumAttempts == 1)
    #expect(preferences.sync.maximumConcurrentTransfers == 1)
    #expect(preferences.sync.backgroundSyncConfiguration == BackgroundSyncConfiguration(pollInterval: 15, minimumQueueInterval: 5))
}

@Test
func memoryPreferencesRepositoryDefaultsAndSaves() async throws {
    let repository = MemoryPreferencesRepository()
    #expect(try await repository.load() == AppPreferences())

    var preferences = AppPreferences()
    preferences.files.defaultAvailability = .alwaysLocal
    try await repository.save(preferences)

    #expect(try await repository.load().files.defaultAvailability == .alwaysLocal)
}
