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

## Run and retrieve

1. Push the intended source branch to the personal fork. Main pushes trigger CI; dispatch `ci.yml` with `gh workflow run ci.yml --repo allgemeiner-intellekt/Usagebar --ref BRANCH` for other branches. The dispatch-enabled workflow must first exist on the default branch.
2. Find the run with `gh run list --repo allgemeiner-intellekt/Usagebar --workflow ci.yml --commit COMMIT_SHA`. Inspect the selected run's `headSha`, event, status, and conclusion with `gh run view`. Watch that run, and inspect failing job logs if needed. Do not choose by “latest” alone.
3. Download that run's artifact with `gh run download RUN_ID --repo allgemeiner-intellekt/Usagebar --dir DESTINATION`. Check `build-info.txt` against the intended full commit SHA and run URL, and verify `shasum -a 256 -c SHA256SUMS` inside the download directory before using `Usagebar.zip`.
4. The inner archive contains `Usagebar.app` for macOS 14+, Apple Silicon and Intel. It is ad hoc signed, not notarized; macOS may require explicit user approval to open it. Do not remove quarantine as part of artifact retrieval.

Updates are manual, optionally assisted by an agent when requested. Quit the installed app before replacement, keep one installed copy, and verify its version/source afterward. App update actions open the personal Actions page and never install an upstream Homebrew build. An existing Homebrew-managed installation can still be overwritten by an external `brew upgrade`; resolve that ownership when installation is requested, without deleting preferences or credentials. Setup itself does not install or restart the app.

## Verification status

Setup configuration is on `codex/personal-fork-setup`. Workflow YAML parsing, shell syntax, documentation links, and diff whitespace checks passed. The personal repository has Actions enabled. Full GitHub build, artifact download, and runtime validation have not yet run for this setup. The owner deferred cloud execution until product changes are ready. Default-branch workflow availability must be checked before dispatch. A successful build alone does not prove menu interactions work.
