# Releases

When creating a release:

1. Inspect commits and merged PRs since the previous release to write the
   changelog. Keep app and extension versions and build numbers aligned.
2. Merge the release preparation PR, including version changes, into `main`
   after its checks pass. Confirm those changes are present on `origin/main`.
3. Build and validate the release from that merged commit on `main`. Point the
   release tag at the exact commit used to build the artifacts.
4. Publish the GitHub release and update the public download page and Sparkle
   feed only after the preceding steps succeed. This also applies to previews.

`scripts/release` currently combines version bumping, building, committing,
tagging, and publication from the current branch. Before using it for a new
release, separate preparation from publication so the sequence above is
enforced. A release request does not authorize publishing an unmerged branch.
