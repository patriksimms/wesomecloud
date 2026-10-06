# WesomeCloud

A modern, native macOS client for ownCloud, built with Swift 6, SwiftUI, and
Apple's File Provider framework.

We want to make large ownCloud Spaces practical on a Mac, even when they exceed
its local storage. Virtual files let you browse remote folders in Finder and
only download content when you need it. Files can stay downloaded for offline
use or return to online-only storage to free up disk space.

## Status

WesomeCloud is a prototype under active development. It includes Finder
integration, on-demand downloads, offline operations, and ownCloud Infinite Scale
Spaces support. Signed and notarized releases support Sparkle updates. Finder
and synchronization behavior still need wider release validation. Use a test
account and disposable files while evaluating it.

## ownCloud credit

The [ownCloud Desktop Client](https://github.com/owncloud/client) was a behavior
and architecture reference for this native Swift implementation. Its source
code was not copied or translated into WesomeCloud.

Credit goes to its authors and contributors for their work on synchronization,
WebDAV, metadata journals, virtual files, and conflict handling. WesomeCloud
adapts these concepts to a native macOS client using modern Apple technologies.
It is an independent project and is not an official ownCloud client.

See [NOTICE](NOTICE) for attribution and third-party notices.

## Build and run

Requirements:

- macOS 15 or later.
- Xcode 26 or later with Swift 6.2 or later. Select the full Xcode installation
  as the active developer directory.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the app project.

Build and test the Swift package:

```sh
swift test
swift run wesomecloud
```

The command-line host checks that the client core and UI compile. To build the
macOS app and its embedded File Provider extension:

```sh
brew install xcodegen
scripts/generate-xcode-project.sh
open WesomeCloud.xcodeproj
```

Choose the `WesomeCloud` scheme. Configure your own development team for both
app and extension targets before running a signed build. The generated project
is ignored; shared build settings belong in `project.yml`.

To validate an unsigned app build:

```sh
scripts/validate-packaging.sh --require-generated
```

An unsigned build verifies packaging; Finder integration needs a signed app
and extension. See [development and release notes](docs/development.md) for
signing, notarization, and update configuration.

## How it is built

SwiftUI provides the app interface. A replicated File Provider extension handles
Finder integration and virtual files. WebDAV and ownCloud APIs provide remote
file operations and Spaces discovery, SQLite stores synchronization metadata,
and Keychain stores credentials. Sparkle supports signed automatic updates.

The [architecture plan](macos-owncloud-client-plan.md) explains the design.
[Development notes](docs/development.md) describe the implemented behavior and
remaining release work.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, validation, repository file
policy, and attribution requirements. Report security issues as described in
[SECURITY.md](SECURITY.md).

## License

WesomeCloud is free software licensed under the GNU General Public License,
version 2 or, at your option, any later version (`GPL-2.0-or-later`), matching the
[ownCloud Desktop Client's license](https://github.com/owncloud/client#license).
You may redistribute and modify it under those terms. It comes without warranty,
including any implied warranty of merchantability or fitness for a particular
purpose. See [LICENSE](LICENSE) for the full text.

Upstream copyright and license notices remain applicable to copied or adapted
material. Sparkle and its bundled components retain their own licenses, reproduced
in [docs/Sparkle-LICENSE.txt](docs/Sparkle-LICENSE.txt).
