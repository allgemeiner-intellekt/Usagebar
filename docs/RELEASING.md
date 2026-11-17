# Personal builds and releases

For routine personal updates, run:

```sh
python3 script/update_personal.py
```

The updater reuses a verified successful CI artifact when its source tree matches personal main. Otherwise it waits for target CI or dispatches a missing build. Installation includes a backup and rollback on startup failure. See [cloud-build](../.agents/skills/cloud-build/SKILL.md) for requirements, options, provenance, and installation limits.

The [CI workflow](../.github/workflows/ci.yml) builds PRs and manually dispatched refs. Main pushes reuse an equivalent validated artifact when available, or run the full build and regression tests. The Actions summary links to the original artifact download. Reuse preserves the source commit and the original 30-day expiry.

## Optional durable releases

The existing [Release workflow](../.github/workflows/release.yml) remains available when a permanent download is wanted. From validated source, update `MARKETING_VERSION` and monotonically increasing `CURRENT_PROJECT_VERSION`, add `docs/releases/vX.Y.Z.md` and a changelog entry, then push a new `vX.Y.Z` tag to the personal fork. The workflow builds and publishes `Usagebar.zip` with the curated notes to this repository's Releases.

For an unpublished tag whose workflow failed, dispatch `release.yml` on `main` with its `release_tag` input. It checks out the original tag. Never move an existing published tag or replace its artifact. No upstream Homebrew tap update is part of the personal release process; `Casks/usagebar.rb` remains an upstream reference.

Both distribution paths use ad hoc signing and are not notarized. Cloud checks establish build and packaging status. User interaction and launch behavior require separate runtime verification when implementing product changes.
