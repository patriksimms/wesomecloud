# Contributing

Open an issue to discuss bugs or larger changes. For bugs, include the macOS and
Xcode versions, server type and version, steps to reproduce, and expected behavior.
Remove credentials, account details, private URLs, and file contents from logs.

For local setup, see [README.md](README.md). Keep changes focused and run
`swift test`. For app-host, entitlement, or packaging changes, also generate the
Xcode project and run `scripts/validate-packaging.sh --require-generated`.
Use a test account and disposable files for Finder and server integration checks.

Add tests for behavior you change when they provide useful coverage. Include
the checks you ran and any remaining limitations in the pull request.

## Repository files

Commit Swift source and tests, `Package.swift`, `Package.resolved`, `project.yml`,
app-host plists and entitlements, scripts, and documentation. The dependency
lockfile keeps package versions reproducible. Plists and entitlements describe
the app and extension and are required to build them.

The Xcode project is generated with XcodeGen and ignored. Change `project.yml`
and regenerate instead of editing the generated project. Build products, SwiftPM
caches, personal Xcode state, and local editor settings are ignored. If a shared
scheme is needed, define it in `project.yml`.

Keep signing certificates, private keys, provisioning profiles, account data,
and credentials out of the repository. Configure signing locally with your own
Apple developer team. Public Sparkle verification keys may be committed;
private signing keys may not.

## License and attribution

Contributions are provided under GPL-2.0-or-later, the project's license.
Preserve copyright and license notices when copying or adapting upstream work.
For material from ownCloud or another project, record the upstream file URL and
commit, its authors and license, and what you changed. Modified upstream files
must retain their notices and record the modification date. General credit in
[NOTICE](NOTICE) does not replace file-specific attribution.

## Publishing

ownCloud was used as a behavior and architecture reference; its source was not
copied or translated. Any future copied or adapted source needs file-specific
attribution, including the upstream revision, before publication.

Enable private vulnerability reporting in the GitHub repository settings.
For binary releases, include `LICENSE`, `NOTICE`, and the Sparkle notices with
the distribution. Publish the complete corresponding source, including build
scripts, alongside each binary release and identify the exact source revision.
Run the signed release validation and test Finder integration on a separate Mac
before calling a build ready for general use.
