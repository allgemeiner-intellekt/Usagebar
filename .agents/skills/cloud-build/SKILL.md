---
name: cloud-build
description: Use for Usagebar compilation, tests, checks, packaging, GitHub workflow execution, artifact retrieval, or preparing a personal update.
---

# Cloud build

Use GitHub for compilation, regression tests, checks, and packaging where possible to avoid local resource use. Local editing and lightweight configuration checks are appropriate. Follow normal development workflows for commits and pushes.

## Entry points

- Personal fork: `allgemeiner-intellekt/Usagebar`, Git remote `origin`.
- Upstream: `betoxf/Usagebar`, Git remote `upstream`.
- `.github/workflows/ci.yml` runs checks and packages a universal app on main pushes, pull requests, and manual dispatch. Its workflow and `script/package_artifact.sh` own build parameters and artifact naming.
- User download entry: https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml . Open a successful run and its Artifacts section. GitHub sign-in is required for Actions artifact downloads; artifacts expire according to workflow retention.
- `docs/RELEASING.md` describes optional durable tagged releases. Routine personal builds need no version tag or Homebrew tap.

## Update the installed app

Run `python3 script/update_personal.py` from the repository. Requires Python 3, authenticated `gh`, and macOS. The command resolves personal main once, searches recent successful CI artifacts by source tree, verifies checksums and provenance, then installs and launches `/Applications/Usagebar.app`. It reuses a PR build when its actual packaged source tree equals the target, even when its run head SHA differs. The source commit and run are retained rather than relabelled as a new build.

If no matching artifact exists, the command waits for target CI. If no target run exists or a successful build's artifact has expired, it dispatches CI for the selected ref. A failed run requires inspection rather than an automatic rebuild loop. `--no-wait` exits 2 when no matching artifact is available. `--commit REF` selects another source; automatic dispatch requires a branch or tag.

For inspection without installation:

```sh
python3 script/update_personal.py --download-only --no-wait --output build/personal-download
```

Installation verifies the universal app signature and version, quits the old process, replaces the bundle, and observes startup. A failed replacement or launch restores the previous app. Receipts and the previous app ZIP live outside the signed bundle, in `~/Library/Application Support/Usagebar/PersonalUpdates/`. Preferences and credentials are preserved. Homebrew ownership or a second installed copy must be resolved before installation; the command stops with an explanation.

The app is ad hoc signed, not notarized. Preserve quarantine; if macOS blocks launch, handle the system approval explicitly. Startup survival does not prove panel interactions work.

## CI and artifact matching

`ci.yml` always checks update tooling. Infrastructure and documentation changes skip app compilation; app source, Xcode project, application regression tests, and unknown paths require a full build. Manual dispatch always requests a full build. For build-relevant main pushes, CI first tries to reuse a successful same-repository artifact with the exact source tree; without a match it builds and tests normally. Workflow build-command or toolchain changes can be validated with manual dispatch. A reused build links to the original run in the Actions summary and keeps its original retention deadline. Artifacts remain available for 30 days. Expired or older artifacts outside the bounded recent-run search require a fresh build.

`script/package_artifact.sh` records the actual checkout commit, tree, run, architectures, version and build in `build-info.txt`. GitHub PR runs may report the branch head while checkout builds a temporary merge commit. Match the packaged commit's tree, not just the run head SHA. Older artifacts without a tree field remain usable after resolving their recorded commit through GitHub. Never select an artifact solely because it is the latest run.

Main protection requires a PR and the GitHub Actions `Build macOS app` check, including administrators, with zero required approving reviews. Force pushes and deletion are disabled. Merged branches are deleted automatically. Keep the check name stable when editing CI.

App update actions open the personal Actions page; they do not install upstream Homebrew builds. Routine personal updates need no version tag or Homebrew tap. Use `docs/RELEASING.md` only for durable tagged releases.
