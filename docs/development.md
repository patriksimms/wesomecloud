# Development notes

Native macOS ownCloud client prototype built around Apple's File Provider model.

This repository currently contains the testable core for the client described in
[architecture plan](../macos-owncloud-client-plan.md):

- `OwnCloudKit`: WebDAV operations used by ownCloud (`PROPFIND`, `REPORT`
  sync-collection, `GET`, `PUT`, `MKCOL`, `MOVE`, `DELETE`), ownCloud metadata,
  sync-token, and deletion parsing, and server capability fetching with
  basic/app-password and bearer-token authentication, including open-ended and
  closed ranged `GET` support for resumable and partial downloads plus chunked
  upload assembly for large files.
- `SyncStore`: metadata-store protocol, stored item model, pending operation
  model, sync cursor, sync error, transfer, and conflict-resolution records,
  in-memory implementation, and SQLite-backed sync journal.
- `WesomeFileProviderCore`: File Provider-facing item mapping, enumeration,
  materialization, upload/edit coordination, remote polling diffs, and mutation
  coordination, with adapter abstractions, offline queue retry processing, early
  conflict handling, filename policy, and Finder package/content-type policy.
- `WesomeCloudAppCore`: account session setup, app-password and OAuth-token
  capability validation, credential persistence orchestration, account/domain
  persistence, app status snapshots, sync issue projection, diagnostics
  buffering/export, user preferences, background sync scheduling, and File
  Provider domain registration plus update checking.
- `WesomeCloudMacApp`: SwiftUI shell and observable view model for the macOS
  account/status/diagnostics experience, with production app-model composition,
  native `ASWebAuthenticationSession` OAuth presentation, and
  `NSBackgroundActivityScheduler` refresh integration.
- `WesomeCloudApp`: command-line host that verifies the core and SwiftUI shell
  compile outside the eventual signed `.app` bundle.
- `WesomeFileProviderExtension`: SDK-backed File Provider item/enumerator bridge
  and replicated extension scaffold wired into the tested adapter, with a
  production runtime factory for account credentials, WebDAV, SQLite, paths, and
  materialization plus domain-id runtime resolution.

## Build and test

```sh
swift test
swift run wesomecloud
swift run wesomecloud validate-appcast ./appcast.xml --version 0.1.0 --build 1 --download-length 123456
scripts/validate-packaging.sh

# Optional, once xcodegen is installed:
scripts/generate-xcode-project.sh
scripts/validate-packaging.sh --require-generated
scripts/validate-packaging.sh --require-generated --release
```

Signed beta DMG and ZIP, after creating a Developer ID Application certificate
and storing notarization credentials in Keychain:

```sh
export WESOME_CLOUD_DEVELOPMENT_TEAM=YOURTEAMID
export WESOME_CLOUD_SIGNING_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
export WESOME_CLOUD_NOTARY_PROFILE=wesomecloud-notary
export WESOME_CLOUD_APPCAST_URL=https://your-domain.test/appcast.xml
export WESOME_CLOUD_SPARKLE_ACCOUNT=cloud.wesome.wesomecloud

swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "$WESOME_CLOUD_SPARKLE_ACCOUNT"
export WESOME_CLOUD_SPARKLE_PUBLIC_ED_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "$WESOME_CLOUD_SPARKLE_ACCOUNT" -p)"

scripts/generate-xcode-project.sh
scripts/validate-release-signing.sh --archive
```

Use your own team and certificate if distributing under another membership.
The Sparkle private key stays in Keychain under the configured account. Do not
export it or add it to the repository. The public key and future HTTPS feed URL
are build settings; the feed does not need to be online to prepare a release.
For local configuration, an ignored `.envrc` can export these settings directly.
Run `source .envrc` before building, or allow it through direnv.

`--manual-updates` leaves Sparkle unconfigured; testers install later versions
manually. It also skips appcast generation and Sparkle signing.

The script archives Apple Silicon code with Hardened Runtime,
then exports with Developer ID signing and automatic distribution provisioning.
It creates a signed `build/WesomeCloud-<version>.dmg` containing WesomeCloud and an
Applications shortcut, submits it to Apple, staples the notarization ticket,
and verifies Gatekeeper acceptance. It also staples the exported app and creates
`build/updates/WesomeCloud-<version>.zip`. The filenames follow the app's release
version. Increase `CFBundleVersion` in both host plists for every new build and
keep their displayed versions in sync.

After stapling, Sparkle generates `build/updates/appcast.xml` and signs both the
feed and final ZIP using Keychain. The script verifies their signatures and
checks the appcast version, build, and ZIP length locally. Download URLs default
to this repository's GitHub release for `v<version>`; override
`WESOME_CLOUD_DOWNLOAD_URL_PREFIX` when using another download location.
This script prepares artifacts only. It never creates a GitHub release, uploads
files, or publishes the feed. A first install and a version-to-version Sparkle
update still need validation on a separate Mac with a test account.

Distribute these artifacts only after the script succeeds. Keep the app inside
its ZIP or DMG when transferring it. Users need macOS 15 or later and drag
WesomeCloud into Applications before launching it. They should not need quarantine
removal commands. A successful notarization and Gatekeeper check do not replace
an installation and Finder extension test on a separate Mac.

## Current status

Implemented:

- Root and nested-folder enumeration core through WebDAV `PROPFIND`.
- Offline enumeration fallback for transient WebDAV/network failures when
  cached folder children exist, while authentication and authorization failures
  still surface instead of showing stale Finder contents.
- ownCloud `fileid`, `permissions`, `checksum`, `etag`, size, content type,
  creation-time, modification-time, private-link, and root quota used/available metadata
  parsing for account storage display.
- ownCloud capabilities parsing includes the server-advertised desktop
  `core.pollinterval`, and persisted account records feed that interval into
  background remote polling when the server provides it.
- OCS Notifications API support for detecting notification capability,
  listing user notifications, treating `204 No Content` as an unsupported/empty
  notification source, deleting notifications, and surfacing server
  notifications in app snapshots and the SwiftUI dashboard with dismiss
  actions.
- Infinite Scale Spaces discovery through the Graph drives API, including
  per-space WebDAV root URLs, drive metadata, quota summaries, app snapshot
  exposure, and an Add to Finder action for each Space. Multiple selected Spaces
  remain available as separate Finder locations and are restored on startup.
  Selected Spaces can be removed from Finder without deleting server files;
  pending changes or conflicts must be resolved first. Removing the final Space
  leaves the account connected with no active Finder locations. Locations use
  the Space name, with any provider prefix added by macOS.
  Each new Space has its own metadata, operation queue, sync cursors, and
  downloaded-file directory. Existing account locations retain their cache.
  Background sync and file actions use the selected domain's WebDAV root;
  public-link requests for Space files include their server resource ID.
- File Provider content-type mapping for remote MIME types and Finder package
  directories, including iWork document bundles.
- File Provider item metadata maps ownCloud creation and modification times
  into Finder dates.
- File Provider item metadata versions now include server identity, checksum,
  permissions, quota, and private-link metadata so Finder refreshes item state
  after metadata-only server changes, with fixed-size version components that
  stay within File Provider limits even for long ownCloud metadata.
- File Provider item metadata reports downloaded vs dataless state from the
  metadata journal so Finder receives native virtual-file availability signals.
- File Provider items project running and failed upload/download transfer state
  from the metadata journal into Finder badges, while stable completed items
  remain eligible for replicated-extension eviction.
- File Provider global upload/download progress is derived from active transfer
  records so system progress UI can summarize queued, running, and paused work.
- File Provider items expose the native content policy for `Keep Downloaded`,
  inherited, and lazy online-only availability intents, so Finder and the system
  receive the same availability semantics as the app.
- File Provider capability mapping from ownCloud remote permissions so read-only
  or non-deletable server items do not expose unavailable Finder actions.
- File Provider delete-capable items expose Finder trashing as well as direct
  deletion, and trash reparent callbacks are translated into the same remote
  WebDAV delete flow with cache invalidation.
- File Provider rename and reparent capabilities now map separate ownCloud
  permissions, so Finder move/rename actions match the server's advertised
  mutation rights.
- Preflight ownCloud permission enforcement for create, upload, rename,
  reparent/move, and delete mutations before issuing WebDAV write requests.
- Typed HTTP failure classification for authentication, authorization, not
  found, conflict/precondition, quota, rate-limit, retryable server, and
  unavailable responses, including `Retry-After` propagation.
- ownCloud OCS capability validation honors both HTTP status and OCS meta
  failure payloads before account credentials are persisted.
- On-demand materialization core through WebDAV `GET`.
- Resumable on-demand materialization using HTTP `Range` requests,
  `Content-Range` validation, partial files, and transfer progress records.
- File Provider partial-content fetching uses closed HTTP byte ranges and
  sparse temporary files so macOS can materialize requested extents without
  downloading the whole item.
- File Provider incremental-content fetch callbacks validate the requested
  version, reuse Finder's existing local contents when the existing version is
  already current, and otherwise fall back to a full replacement download,
  preserving correctness while leaving room for future byte-delta updates.
- Download integrity verification for expected file size and common ownCloud
  checksum formats before materialized files replace their partial downloads.
- Transfer cancellation gates, including between chunked upload parts, and
  user-configurable concurrent transfer throttling.
- Chunked upload progress is persisted after each successful chunk so large
  uploads surface in-flight byte counts before completion.
- App-level transfer activity surfaces recent upload/download phase, progress,
  byte counts, and failure details from the metadata journal.
- Local mutation routing for file creation, folder creation, delete, move, and
  modified file upload through WebDAV `PUT`.
- Offline-created files queue distinct create-file replay operations so local
  creations are retried through create semantics rather than edit semantics.
- Authoritative metadata refresh after successful file and folder creation so
  new items keep server `fileid`, `etag`, permissions, and stable parent IDs,
  with local fallback metadata when the post-create refresh is temporarily
  unavailable so Finder does not retry already-accepted creates.
- Immediate local metadata updates for successful rename/reparent operations,
  including moved folder descendants, so Finder sees the new paths before the
  next polling pass.
- Subtree-aware folder deletes that remove cached descendants and materialized
  files/partials after the server delete succeeds, and item removal also clears
  item-scoped pending operations, sync issues, transfer activity, and conflict
  records so app/Finder status does not drift after successful deletes.
- Large modified-file uploads through ownCloud 10 chunking NG (MKCOL transfer
  folder, chunk PUTs with `OC-Total-Length`, MOVE commit guarded by an `If`
  header). oCIS spaces have no NG endpoint and fall back to a single PUT until
  TUS is implemented.
- Remote polling diff support that reports added, updated, and subtree-deleted
  provider items after `PROPFIND`, ignores the requested container when
  comparing child changes, follows changed folders recursively during
  production background sync with a bounded poll budget, and cleans up local
  materialized content for remotely deleted folders.
- WebDAV sync-collection report support parses and persists server-side change
  tokens, changed items, and deleted paths for cursor-based remote detection,
  with `PROPFIND` fallback when a stored token is rejected.
- WebDAV polling and sync-token reconciliation translate path-derived parent
  references from server responses back to stable stored item IDs, so nested
  Finder enumeration remains attached to the correct File Provider folders.
- WebDAV response parsing normalizes both classic `/remote.php/dav/files/...`
  and Infinite Scale `/dav/spaces/...` hrefs into File Provider-relative paths.
- OCS Share API client and app actions for creating, listing, copying, and
  revoking public links for synced files and folders.
- WebDAV private-link retrieval with app actions for copying Finder-style
  private links to the clipboard.
- Stable File Provider sync anchors for change enumeration that advance only
  after a successful remote-change poll.
- Paged File Provider enumeration with snapshot-backed page tokens so large
  folders can be delivered to Finder incrementally without skipping or
  duplicating items when the remote listing changes mid-enumeration.
- File Provider page snapshots are bounded so abandoned Finder pagination or
  search sessions cannot grow extension memory without limit.
- Cached File Provider search for macOS search requests, matching visible
  working-set metadata by filename or path with snapshot-backed paging.
- Conflict detection for remote-changed local uploads, name collisions,
  remote-deleted local uploads, case-only renames, Unicode
  normalization differences, type changes, and invalid macOS filenames.
- Availability intent model for `Keep Downloaded` and `Free Up Space`.
- App-level file list and availability controls for marking synced items
  `Keep Downloaded`, `Free Up Space`, or system managed, plus revealing
  downloaded materialized files in Finder.
- Free Up Space and disk-pressure eviction behavior that removes materialized
  files and partial downloads while preserving explicit `Keep Downloaded` files.
- Offline operation queue with due-operation filtering, exponential backoff,
  server `Retry-After` handling, retry state persistence, replayable uploads,
  creates, deletes, moves, and folder creation, completion removal, and
  permanent failure cutoff.
- SQLite pending-operation rows now persist retry scheduling, attempt counts,
  source/destination paths, and last error details as indexed columns in
  addition to their replay payloads, with migration coverage for older journals
  so background sync can query only due work at production scale.
- Successful modified-file uploads refresh server metadata/ETag after commit so
  later edits use current WebDAV preconditions, with poll reconciliation as a
  fallback if the refresh is temporarily unavailable.
- SQLite-backed metadata journal with indexes for file ID, parent/name, path,
  ETag, pending operation state, sync errors, transfer state, and conflict
  records.
- SQLite item persistence includes ownCloud quota and private-link metadata,
  with schema migration coverage so account storage and Finder/private-link
  state survive production journal reopen.
- App group path resolution, diagnostics events, and Keychain credential store.
- Local crash report persistence, app snapshot surfacing, and redacted
  diagnostics export inclusion.
- Account setup service that validates ownCloud capabilities before saving an
  app-password credential, including OCS-level capability failures.
- Account removal unregisters File Provider domains, deletes the account
  record, and removes the account credential from the Keychain-backed credential
  store.
- OAuth account setup path that validates capabilities with a bearer access
  token and stores the refresh token in the credential store.
- OAuth authorization URL and callback parsing helpers for browser-based login,
  production `ASWebAuthenticationSession` presentation, plus
  app-model/view-model plumbing for adding OAuth accounts.
- OAuth refresh-token exchange for production WebDAV, sharing, private-link,
  Spaces, and File Provider runtime requests, including persistence of rotated
  refresh tokens before sync work uses the returned bearer access token.
- File Provider adapter abstraction for enumeration, materialization, mutation,
  and remote-change callbacks.
- File Provider `NSFileProviderItem` mapping, enumerator bridge, and
  `NSFileProviderReplicatedExtension` callback scaffold for item lookup,
  content fetch, create, modify, and delete.
- File Provider root item lookup preserves Apple's root container identifier in
  the returned item so Finder sees a consistent root identity.
- File Provider callback errors map missing backend items to
  `NSFileProviderError.noSuchItem` for stale Finder fetch/delete requests and
  WebDAV 404s, authentication failures to `notAuthenticated`, and retryable
  server failures to `serverUnreachable`; quota and sync/name-conflict failures
  plus invalid local filenames, unsupported sync denials, and selective-sync
  exclusions use native File Provider errors so Finder can present the right
  remediation.
- File Provider materialized-set and pending-set lifecycle callbacks complete
  promptly and emit diagnostics, providing hooks for future system-set
  reconciliation without blocking the extension.
- File Provider item lookup, content fetch, create, modify, and delete progress
  handles are cancellable and propagate Finder cancellation into the underlying
  async work, reporting user-cancelled errors for interrupted operations.
- File Provider extension callbacks emit structured diagnostics/OSLog events
  for item lookup, content fetch, create, modify, delete, enumerator creation,
  and invalidation so Finder lifecycle issues can be debugged from app logs.
- File Provider enumerator invalidation cancels in-flight item and change
  enumeration work so disposed Finder enumerators do not keep stale backend
  requests alive.
- File Provider item lookup resolves directly by stable item identity before
  falling back to parent enumeration, avoiding stale cached parent paths during
  Finder callbacks.
- File Provider modify callbacks handle combined rename/reparent plus content
  edits by applying the move before uploading the new contents.
- File Provider modify callbacks honor fail-on-conflict base-version checks so
  stale Finder edits are rejected before upload or move mutations are attempted.
- File Provider fetch callbacks honor requested item versions so stale Finder
  materialization requests fail with `versionNoLongerAvailable` before
  downloading newer content.
- Metadata-only File Provider modify callbacks now return a no-such-item error
  when the target can no longer be resolved instead of falling back to the root
  placeholder item.
- File Provider create callbacks distinguish folder templates from file
  templates with no contents URL, creating zero-byte files through the normal
  upload path instead of misclassifying them as folders.
- File Provider extension item cache for parent/path resolution across
  enumeration, lookup, create, move, and fetch callbacks.
- File Provider enumerators resolve cached folder paths at enumeration time so
  stable ownCloud file IDs are not mistaken for remote paths.
- File Provider working-set enumeration now comes from the stored visible item
  set across folders instead of treating `.workingSet` as the root container,
  preserving nested recent/changed items for Finder.
- File Provider working-set change enumeration now diffs against the last
  working-set snapshot or a dedicated backend change source instead of polling
  the root folder, so Finder receives added, updated, and removed working-set
  items with working-set semantics.
- File Provider search support on macOS versions that expose the search API
  returns paged matches from cached working-set metadata by filename or path.
- Background sync signals the File Provider working-set enumerator whenever
  remote changes arrive, in addition to root and affected parent folders, so
  Finder refreshes nested recent/changed items promptly.
- File Provider delete callbacks invalidate cached item paths for the removed
  subtree so later create, move, and lookup callbacks do not use stale parents.
- File Provider delete callbacks treat missing backend items as already deleted,
  matching the system contract for deletes replayed after remote removal.
- File Provider delete callbacks reject stale base versions with
  `DeletionRejected` before mutating the backend so Finder can restore the item
  from current metadata.
- File Provider delete callbacks reject non-recursive deletes of cached
  non-empty folders with `DirectoryNotEmpty`, matching Finder's recursive
  delete contract.
- File Provider coordinator persists sync-policy conflicts from local creates,
  moves, and uploads so the app can show them in its conflict resolution UI,
  while avoiding duplicate pending conflict records for repeated retries.
- File Provider conflict resolutions can now execute sync actions: keep-remote
  refreshes metadata and evicts stale local content, keep-local/retry overwrites
  the remote file from materialized contents, and rename-local uploads a local
  copy under a validated alternate name before journaling the resolution, with
  local fallback metadata when the post-upload refresh is temporarily
  unavailable.
- The macOS app model delegates user-selected conflict resolutions to a
  production coordinator-backed resolver when available, so UI conflict actions
  drive WebDAV/File Provider sync work and leave conflicts pending if execution
  fails.
- Production File Provider extension runtime factory that composes account
  credentials, app-group paths, SQLite metadata, WebDAV, and materialization
  directories.
- Domain runtime resolver that maps a File Provider domain identifier back to
  the persisted account, loads its credential, selects the persisted domain
  WebDAV root when present, and produces an extension runtime.
- File Provider domain registration service with a system manager for macOS and
  an in-memory manager for tests.
- Account removal cleans up every selected and registered Finder location,
  including each Space's metadata and downloaded files.
- Account removal purges the account's metadata journal state, including cached
  items, queued operations, sync errors, transfers, conflicts, and sync cursors,
  while deleting its local materialized files/transfer partials and leaving
  other accounts' sync state and local content intact.
- Production SQLite-backed account-record repository for account setup,
  removal, server/domain metadata, sync status, sync issues, pending conflicts,
  conflict resolution, and diagnostics snapshots, with lazy migration from the
  legacy JSON account/domain repository, discovery of existing Qt ownCloud
  desktop-client account configuration, in-place reconnect for imported accounts
  after credentials are supplied, validation for rename-based conflict
  resolutions, persisted per-domain WebDAV roots, and versioned account-record
  schema guards.
- File Provider domains are now persisted as first-class SQLite records in
  addition to the selected account domain, including migration from older
  inline account-domain rows and cleanup of persisted domains even when the
  system File Provider manager does not list them.
- Redacted diagnostics export bundle containing account summaries,
  preferences, and recent diagnostic events, with Finder reveal from the app.
- User-facing availability controls are wired through the production File
  Provider coordinator when available, so "Free Up Space" performs subtree
  materialization eviction instead of only flipping stored metadata.
- Background sync scheduler for per-account remote polling and offline queue
  draining with persisted interval, retry, and pause preferences, manual sync-now
  forcing, status updates, File Provider root and changed/deleted-parent
  enumerator refresh signaling after remote changes, and persisted sync errors
  for account failures, failed refresh signaling, and permanently failed queued
  operations, including item, operation kind, path, and user-facing last-error
  details when available.
- Shared user-facing error formatter for common ownCloud/WebDAV, filename,
  conflict, transfer-integrity, and queued-operation failures across sync status,
  sync issue persistence, File Provider refresh diagnostics, Spaces/Notifications
  diagnostics, and SwiftUI actions.
- Queued folder creation records the stable parent identity and replays it
  through the offline WebDAV executor instead of deriving identity from the
  mutable destination path.
- Retryable File Provider mutation failures for uploads, deletes, moves, and
  folder creation now enqueue replayable pending operations while preserving
  local metadata until the server accepts the change; successful mutations leave
  no pending replay rows, preventing later background drains from duplicating
  already-applied WebDAV operations.
- macOS background activity bridge that registers app refresh work, schedules
  the next run from sync preferences, polls persisted accounts, and drains
  queued mutations through the production File Provider coordinator using the
  persisted sync retry and transfer preferences.
- JSON-backed preferences for sync pause, sync intervals, retry limits, default
  file availability, hidden files, transfer concurrency, diagnostics retention,
  and update checking, with persisted sync intervals, retry settings, and
  transfer limits clamped to safe production bounds on load.
- Production File Provider runtime now applies file preferences so Finder hides
  dotfiles unless enabled and assigns the configured default availability intent
  to newly discovered remote items.
- Configurable ignored filename patterns are persisted, exposed in preferences,
  filtered from Finder enumeration/polling, and rejected before local WebDAV
  mutations.
- Selective-sync excluded remote paths are persisted, exposed in preferences,
  filtered from File Provider enumeration/polling, and protected from local
  create, upload, move, delete, and materialization operations.
- Appcast update checking core with version comparison, update availability
  snapshots, Sparkle signed-enclosure metadata parsing, production signed-update
  policy requiring HTTPS downloads and valid 64-byte Ed25519 signatures, release
  appcast validation for expected app version/build, Sparkle framework wiring
  for the macOS update command, production URLSession fetching, and SwiftUI
  controls for update preferences and manual checks.
- Local crash reporting persists app-generated reports, imports matching
  WesomeCloud app and File Provider `.crash`/`.ips` files from macOS DiagnosticReports,
  and includes redacted crash details in diagnostics exports.
- SwiftUI macOS shell views for selectable account sidebar, sync status dashboard with
  account storage usage, server browser launch, reconnect and confirmed removal actions, transfer activity,
  per-file availability and public-link management actions, including clipboard
  copy for share URLs and Finder reveal for downloaded files, server
  notification dismiss actions, conflict resolution actions, sync issue list
  with clear actions, user-facing error messages for common ownCloud/sync
  failures, diagnostics list and export reveal, account setup
  sheet with app-password and browser OAuth modes, preferences pane, menu bar
  popover with empty-account state and app activation, refresh flow, forced
  sync-now action, update status/checking, quick sync pause/resume, and quit.
- App host templates for the SwiftUI `@main` app entrypoint and File Provider
  extension principal class metadata.
- Reproducible XcodeGen project spec for the signed app target, File Provider
  extension target, package products, entitlements, and extension embedding.
- Packaging validator that checks the Swift package products, XcodeGen app and
  extension contract, entitlements, host metadata, and generated project builds
  when `WesomeCloud.xcodeproj` is present, including Release-mode validation.
- Release signing validator that checks the required Apple development team,
  Developer ID signing identity, notarytool profile, appcast URL, entitlements,
  signed appcast entry for the app host version/build/final ZIP length, rejects
  placeholder release settings, and can optionally build, export, notarize,
  staple, and verify a Developer ID distribution artifact.
- Generated `WesomeCloud.xcodeproj` output from the XcodeGen spec, with the
  unsigned Release app bundle building and embedding the File Provider
  extension through `scripts/validate-packaging.sh --require-generated
  --release`.
- Production app metadata uses the `cloud.wesome.wesomecloud` bundle namespace,
  matching app group, keychain, background refresh, File Provider extension,
  and release-validation checks instead of placeholder `com.example` IDs.
- Production entitlements for the app and File Provider extension with sandbox
  and shared app group enabled, and File Provider testing-mode entitlement
  excluded from the signing path.
- Unit tests for WebDAV, sync-collection reports, metadata storage and sync
  cursor persistence, provider mapping, ETag-verified materialization,
  HTTP/OCS failure classification, resumable downloads, simple and chunked
  upload coordination with in-flight progress, paged enumeration, remote polling, conflict policy, domain
  registration, File Provider item/extension bridging, domain runtime
  resolution, and runtime bootstrap, app model orchestration, account
  persistence, OAuth authorization and refresh-token helpers, and SwiftUI view-model, account
  form, preferences, diagnostics export, native OAuth presentation, offline queue,
  sync error/transfer journal, sync issue UI plumbing,
  conflict-resolution journal and UI plumbing, Unicode-normalization conflict
  policy, remote-delete local-edit conflict policy, Finder package/iWork content
  type mapping, ownCloud permission-to-capability and mutation-denial mapping,
  OCS notification listing/deletion and SwiftUI view-model surfacing,
  persisted coordinator conflicts, duplicate conflict suppression, and invalid
  rename-resolution rejection, executable conflict-resolution actions, production
  conflict-resolution resolver wiring, offline enumeration fallback behavior,
  background scheduler behavior including sync pause, forced manual sync,
  server-advertised poll intervals,
  bounded recursive changed-folder polling, fallback path-identity preservation
  when later polling discovers server file IDs, File Provider root and
  changed/deleted-parent refresh signaling, macOS background activity integration,
  retry-after queue scheduling, non-retryable queue failure blacklisting,
  detailed permanent queue failure reporting, stable create-file/create-folder
  offline replay, transfer cancellation/throttling, selective-sync excluded paths,
  production availability resolver wiring, availability eviction/disk-pressure handling,
  space-domain private-link WebDAV root selection,
  metadata schema versioning, account-record migration, local crash reporting,
  appcast update checking with signed-candidate filtering and release appcast
  validation, persisted extension path cache warmup, cached enumerator path
  resolution, direct item lookup, combined rename/content modification, delete
  invalidation, working-set item/change enumeration, stable File Provider
  change anchors, legacy Qt ownCloud
  desktop-client account discovery and reconnect, Graph spaces discovery and
  space-domain runtime selection, lazy system-launched File Provider extension
  runtime resolution, packaging metadata, production entitlements,
  plus app host metadata.

Still needed for a full shipping macOS app:

- Signed app packaging validation in an environment with a real Apple
  development team, provisioning, notarization, and distribution identity
  configured, using `scripts/validate-release-signing.sh --archive`.
- Live Sparkle update validation against a signed/notarized appcast and release
  distribution channel using the production EdDSA key.
