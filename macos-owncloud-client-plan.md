# Native macOS ownCloud Desktop Client Plan

## Goal

Build a native macOS ownCloud desktop client that uses Swift where possible and supports virtual files so users can browse remote files in Finder without downloading every file locally.

The existing ownCloud desktop client in [ownCloud Desktop Client](https://github.com/owncloud/client/tree/master) should be treated as a behavioral and architectural reference, not as a direct porting base. It is a mature Qt/C++ application with a custom sync engine, WebDAV layer, SQLite sync journal, GUI orchestration, shell integration, and a plugin-style VFS abstraction. For a modern macOS-only client, the biggest architectural shift is to use Apple's File Provider framework for virtual files.

## Core Recommendation

Use `NSFileProviderReplicatedExtension` for virtual files.

This is the modern Apple-supported approach for cloud storage integrations on macOS. It gives the app native Finder integration, dataless files, on-demand materialization, eviction/dehydration, system-managed storage behavior, and a cleaner user experience than a custom FUSE layer or suffix-file placeholder system.

Do not build a custom VFS for macOS unless File Provider proves impossible for a specific requirement.

Useful Apple references:

- [File Provider](https://developer.apple.com/documentation/fileprovider)
- [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/FileProvider/synchronizing-the-file-provider-extension)
- [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)

## What The Existing Client Teaches

The current ownCloud client is not just a UI around WebDAV. Its main responsibilities are:

- Account and credential management.
- Remote discovery via WebDAV `PROPFIND`.
- Local discovery via filesystem scanning.
- Reconciliation between local state, remote state, and the local sync journal.
- Propagation of uploads, downloads, deletes, moves, metadata updates, and conflicts.
- A SQLite sync journal for durable metadata.
- VFS abstraction for placeholder files.
- Finder/shell integration.
- Error retry, blacklisting, resumable transfers, and conflict handling.

Important reference files:

- [src/libsync/syncengine.h](https://github.com/owncloud/client/tree/master/src/libsync/syncengine.h)
- [src/libsync/syncengine.cpp](https://github.com/owncloud/client/tree/master/src/libsync/syncengine.cpp)
- [src/libsync/discoveryphase.h](https://github.com/owncloud/client/tree/master/src/libsync/discoveryphase.h)
- [src/libsync/discoveryphase.cpp](https://github.com/owncloud/client/tree/master/src/libsync/discoveryphase.cpp)
- [src/libsync/discovery.cpp](https://github.com/owncloud/client/tree/master/src/libsync/discovery.cpp)
- [src/libsync/owncloudpropagator.h](https://github.com/owncloud/client/tree/master/src/libsync/owncloudpropagator.h)
- [src/libsync/owncloudpropagator.cpp](https://github.com/owncloud/client/tree/master/src/libsync/owncloudpropagator.cpp)
- [src/libsync/propagatedownload.cpp](https://github.com/owncloud/client/tree/master/src/libsync/propagatedownload.cpp)
- [src/libsync/propagateuploadfile.cpp](https://github.com/owncloud/client/tree/master/src/libsync/propagateuploadfile.cpp)
- [src/libsync/networkjobs.h](https://github.com/owncloud/client/tree/master/src/libsync/networkjobs.h)
- [src/common/syncjournaldb.h](https://github.com/owncloud/client/tree/master/src/common/syncjournaldb.h)
- [src/common/syncjournalfilerecord.h](https://github.com/owncloud/client/tree/master/src/common/syncjournalfilerecord.h)
- [src/common/vfs.h](https://github.com/owncloud/client/tree/master/src/common/vfs.h)
- [src/common/pinstate.h](https://github.com/owncloud/client/tree/master/src/common/pinstate.h)
- [src/plugins/vfs/win/vfs_win.h](https://github.com/owncloud/client/tree/master/src/plugins/vfs/win/vfs_win.h)
- [src/plugins/vfs/win/vfs_win.cpp](https://github.com/owncloud/client/tree/master/src/plugins/vfs/win/vfs_win.cpp)
- [shell_integration/MacOSX](https://github.com/owncloud/client/tree/master/shell_integration/MacOSX)

## Architectural Shape

### `WesomeCloudApp`

Native SwiftUI macOS app.

Responsibilities:

- Account setup and removal.
- Login flow.
- File Provider domain registration.
- Menu bar status.
- Sync status and errors.
- Settings.
- Diagnostics and logs.
- User-facing controls for "Keep Downloaded" and "Free Up Space".

### `WesomeFileProviderExtension`

File Provider extension using `NSFileProviderReplicatedExtension`.

Responsibilities:

- Expose ownCloud files and folders in Finder.
- Enumerate folders.
- Return metadata for items.
- Fetch file contents on demand.
- Handle local edits.
- Handle deletes, renames, moves, and folder creation.
- Signal remote changes to the system.
- Keep Finder state aligned with local metadata.

### `OwnCloudKit`

Swift package for ownCloud/WebDAV API access.

Responsibilities:

- WebDAV `PROPFIND`.
- `GET` downloads.
- `PUT` uploads.
- `MKCOL` folder creation.
- `MOVE` renames and moves.
- `DELETE`.
- ETag parsing and normalization.
- File IDs.
- Checksums.
- Server capabilities.
- OAuth or basic auth.
- Retry and request classification.

### `SyncStore`

SQLite-backed local metadata store.

Responsibilities:

- Accounts.
- File Provider domains.
- Remote item records.
- Parent/child relationships.
- Path and filename indexes.
- ETags.
- File IDs.
- Item versions.
- File size and modification time.
- Permissions.
- Materialization state.
- Pin/availability intent.
- Pending operations.
- Error state.
- Change cursors or sync anchors.

Use GRDB or SQLite.swift rather than writing raw SQLite glue everywhere.

### `WesomeCloudShared`

Shared code used by app and extension.

Responsibilities:

- Shared models.
- App group paths.
- Logging.
- Keychain helpers.
- Configuration.
- Error types.

## File Provider Model

Map ownCloud remote files into File Provider items.

Suggested item identity:

- Prefer ownCloud file ID when available.
- Keep a stable internal UUID for cases where the server file ID is missing or unreliable.
- Store path as mutable metadata, not as the primary identity.

Suggested item version:

- Content version: remote ETag or checksum-derived version.
- Metadata version: hash of filename, parent, permissions, size, mtime, and ETag.

Suggested metadata fields:

- `itemIdentifier`
- `parentItemIdentifier`
- `filename`
- `contentType`
- `documentSize`
- `creationDate`
- `contentModificationDate`
- `capabilities`
- `versionIdentifier`
- `etag`
- `fileId`
- `checksum`
- `remotePermissions`

## Virtual Files And Availability

Keep the product concepts from the existing client, but implement them through File Provider:

- `AlwaysLocal`: user intends the file or subtree to stay materialized.
- `OnlineOnly`: user intends the file or subtree to be dataless when possible.
- `Unspecified`: system/app may choose based on usage and storage pressure.
- `Inherited`: item follows parent intent.

The existing concepts live in [src/common/pinstate.h](https://github.com/owncloud/client/tree/master/src/common/pinstate.h).

In the new app, expose these as native Finder-style actions:

- "Keep Downloaded"
- "Free Up Space"

Avoid inventing a custom placeholder file format.

## Initial Milestone: Tracer Bullet

Build the smallest end-to-end version that proves the architecture.

Scope:

- One account.
- One File Provider domain.
- Root folder enumeration.
- Nested folder enumeration.
- Dataless files visible in Finder.
- Opening a file triggers download.
- Editing a downloaded file uploads it.
- Creating a folder sends `MKCOL`.
- Deleting a file sends `DELETE`.
- Basic error display in the app.

Out of scope for the first milestone:

- Multiple accounts.
- Spaces.
- Sharing UI.
- Selective sync UI.
- Chunked upload.
- Full conflict resolution.
- Sparkle updater.
- Crash reporter.
- Migration from the Qt client.

## Implementation Phases

### Phase 1: Project Skeleton

- Create an Xcode workspace.
- Add macOS SwiftUI app target.
- Add File Provider extension target.
- Add shared app group.
- Add Keychain access group.
- Add `OwnCloudKit` Swift package.
- Add `SyncStore` Swift package.
- Add structured logging.
- Add basic diagnostics screen.

### Phase 2: Account And Auth

- Implement account model.
- Implement login with `ASWebAuthenticationSession` for OAuth-capable servers.
- Add basic auth or app-password support if needed.
- Store credentials in Keychain.
- Fetch server capabilities after login.
- Persist account and server metadata in SQLite.

### Phase 3: WebDAV Client

Implement and test:

- `PROPFIND Depth: 0`
- `PROPFIND Depth: 1`
- `GET`
- `PUT`
- `MKCOL`
- `MOVE`
- `DELETE`
- ETag handling.
- File ID handling.
- Permission parsing.
- Checksum parsing.
- HTTP error classification.

Use the current client's `DiscoverySingleDirectoryJob`, `GETFileJob`, `PUTFileJob`, and `PropfindJob` as reference behavior.

### Phase 4: Metadata Store

Create tables for:

- Accounts.
- Domains.
- Items.
- Pending operations.
- Sync errors.
- Pin/availability intent.
- Transfer state.

Add indexes for:

- Account plus file ID.
- Parent ID plus filename.
- Path.
- ETag.
- Pending operation state.

### Phase 5: File Provider Enumeration

- Register a File Provider domain for the account.
- Implement root container.
- Implement folder enumeration from server and/or store.
- Persist enumerated items.
- Return stable File Provider items.
- Handle pagination if needed.
- Handle offline enumeration from local store.

### Phase 6: On-Demand Materialization

- Implement `fetchContents`.
- Download file content with `GET`.
- Verify size and ETag.
- Update metadata store.
- Return local file URL to File Provider.
- Surface errors cleanly.

This replaces the existing client's VFS hydration path.

### Phase 7: Local Mutations

Implement File Provider mutation handlers:

- Create file.
- Modify file.
- Delete item.
- Rename item.
- Move item.
- Create folder.

Translate these into WebDAV operations.

### Phase 8: Remote Change Detection

Start simple:

- Poll root and changed folders using `PROPFIND`.
- Compare ETags and item versions.
- Signal changes to File Provider.

Later:

- Add push notifications if the server supports them.
- Add smarter subtree invalidation.
- Add server-side change tokens if available.

### Phase 9: Conflict Handling

Add rules for:

- Local edit while remote ETag changed.
- Remote delete while local edit exists.
- Rename conflicts.
- Type changes: file to folder, folder to file.
- Case-only renames.
- Unicode normalization differences.
- Invalid macOS filenames.

Use tests from [test](https://github.com/owncloud/client/tree/master/test) as scenario inspiration.

### Phase 10: Production Hardening

- Chunked uploads.
- Resumable downloads.
- Transfer throttling.
- Retry and backoff.
- Offline queue.
- Disk pressure behavior.
- Checksums.
- Diagnostics export.
- Crash reporting.
- Auto-update.
- Migration from earlier app versions.
- Multi-account support.

## Important Differences From The Existing Client

### Replace Qt With Swift

Use SwiftUI, Foundation, URLSession, FileProvider, Keychain, OSLog, and SQLite bindings.

### Replace FinderSync With File Provider

The existing `shell_integration/MacOSX` FinderSync extension is not the right foundation for a virtual-files client. File Provider should provide the Finder integration.

### Replace The VFS Plugin Layer

The existing VFS abstraction in `src/common/vfs.h` is useful conceptually, but the implementation strategy should be different on macOS. Do not port the Windows CfAPI code. It is useful only as a comparison for hydration, pinning, and placeholder lifecycle.

### Reinterpret Discovery And Propagation

The current client has explicit discovery, reconciliation, and propagation phases. File Provider changes the shape:

- Enumeration replaces much of remote discovery.
- `fetchContents` replaces placeholder hydration.
- File Provider mutation callbacks replace many propagation jobs.
- Local metadata still remains essential for correctness.

## Risk Areas

Highest-risk areas:

- File Provider extension lifecycle and debugging.
- Correct item identity across renames and moves.
- Offline edits.
- Conflict handling.
- macOS package/bundle directories.
- iWork documents.
- Unicode normalization.
- Case-insensitive filesystem behavior.
- Large folders.
- Large files.
- App group and extension data access.
- Multiple accounts and domains.

## Suggested First Prototype

Build a throwaway prototype before the real client:

- Hard-code one test account.
- Register one File Provider domain.
- Enumerate only root and one nested folder.
- Download files on open.
- Upload edits.
- Store metadata in SQLite.
- Log every File Provider callback.

The prototype should answer:

- Does ownCloud metadata map cleanly to File Provider items?
- Does Finder behave well with dataless ownCloud files?
- Are file IDs stable enough?
- How painful are local edits and conflict cases?
- Which File Provider APIs are awkward or underdocumented?

## Decision Log

- Use native Swift where possible.
- Use File Provider, not FUSE, for virtual files.
- Use the existing ownCloud client as a reference implementation for behavior.
- Do not port the Qt GUI.
- Do not port the Windows VFS implementation.
- Keep a SQLite metadata journal.
- Start with a tracer bullet before implementing advanced sync behavior.
