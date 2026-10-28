# Personal builds and releases

Routine personal builds use the [CI workflow](../.github/workflows/ci.yml). Push to `main`, open a pull request, or manually dispatch the workflow for a pushed branch. It runs regression tests, builds a universal Release app, verifies signatures and architectures, and uploads an artifact named for the workflow commit. No release tag or Homebrew tap is required.

Open [personal CI](https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml), select a successful run for the intended source, and download its artifact. Follow [cloud-build](../.agents/skills/cloud-build/SKILL.md) for run matching, checksum verification, and update limitations. For pull requests, the workflow commit can be GitHub's merge commit; verify the recorded source rather than assuming it is the branch head.

## Optional durable releases

The existing [Release workflow](../.github/workflows/release.yml) remains available when a permanent download is wanted. From validated source, update `MARKETING_VERSION` and monotonically increasing `CURRENT_PROJECT_VERSION`, add `docs/releases/vX.Y.Z.md` and a changelog entry, then push a new `vX.Y.Z` tag to the personal fork. The workflow builds and publishes `Usagebar.zip` with the curated notes to this repository's Releases.

For an unpublished tag whose workflow failed, dispatch `release.yml` on `main` with its `release_tag` input. It checks out the original tag. Never move an existing published tag or replace its artifact. No upstream Homebrew tap update is part of the personal release process; `Casks/usagebar.rb` remains an upstream reference.

Both distribution paths use ad hoc signing and are not notarized. Cloud checks establish build and packaging status. User interaction and launch behavior require separate runtime verification when implementing product changes.
