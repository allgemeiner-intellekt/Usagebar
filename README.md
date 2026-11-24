> Personal fork of [betoxf/Usagebar](https://github.com/betoxf/Usagebar). Download personal builds from [GitHub Actions](https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml).

<div align="center">
  <img src="assets/brand/usagebar-logo.png" alt="Usagebar" width="760">

  <p><strong>CLIProxyAPI account limits in your macOS menu bar.</strong></p>
  <p>A free, private, native Mac app that shows your 5-hour window, weekly cap, and when each one resets, without opening a browser.</p>

  <p>
    <a href="https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml"><img src="https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml/badge.svg?branch=main" alt="Build"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-111827" alt="macOS 14 or newer">
    <img src="https://img.shields.io/badge/Swift-5-F05138" alt="Swift 5">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2563EB" alt="MIT license"></a>
  </p>

  <p>
    <a href="https://bullfighterstudio.com/usagebar">Website</a> ·
    <a href="#installation">Install</a> ·
    <a href="#how-it-works">How it works</a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="docs/ARCHITECTURE.md">Architecture</a> ·
    <a href="CONTRIBUTING.md">Contributing</a> ·
    <a href="SECURITY.md">Security</a>
  </p>
</div>

## What Usagebar shows

- Usage limits and reset times for Claude Code, Codex, Kimi Code, Grok Build and Antigravity accounts connected to CLIProxyAPI (CPA).
- Banked reset counts and expiry details for Claude and Codex.
- A compact card for a single account, with individual readings grouped by provider when CPA has multiple accounts.
- Provider visibility and Antigravity pool filters in Settings → Providers.

## Installation

### Personal builds and updates

Open a successful run in [personal CI](https://github.com/allgemeiner-intellekt/Usagebar/actions/workflows/ci.yml) and download its artifact. Extract the artifact, verify `SHA256SUMS`, and unpack `Usagebar.zip`. Quit Usagebar, replace `/Applications/Usagebar.app`, and launch the replacement. Keep only one installed copy. An agent can assist when asked.

Builds support Apple Silicon and Intel, use ad hoc signatures, and are not notarized. macOS may require explicit approval to open them. Actions downloads require GitHub sign-in and expire after 30 days. See [cloud-build](.agents/skills/cloud-build/SKILL.md) for source verification and [Releasing](docs/RELEASING.md) for optional durable releases.

The app's download action opens this fork's builds. It does not install Homebrew updates. `Casks/usagebar.rb` is retained as an upstream distribution reference, not a personal installer. If an older copy is managed by Homebrew, external `brew upgrade` can still overwrite a manual installation; resolve that before installing the personal build.

### Requirements

- macOS 14 Sonoma or newer.
- A reachable CLIProxyAPI instance, its management key, and a supported account configured in CPA.

## Quick start

1. Install and launch Usagebar. Click the chart icon in the menu bar.
2. Choose **Open Connection Settings…** and enter your CLIProxyAPI base address and management key.
3. Click **Test & Save**. Reopen the panel to see account limits.

Existing CPA configurations load automatically after upgrading. To change or clear the saved connection, open **Settings → Connection**. Manage provider sign-ins and expired accounts in CPA, then click **Refresh** in Usagebar.

| Control | Behavior |
| --- | --- |
| Left or right click the menu-bar icon | Open or close the usage panel. |
| Refresh (`⌘R`) | Refresh the CPA account list and visible providers, subject to server cooldowns. |
| Settings (`⌘,`) | Configure the CPA connection, provider visibility, refresh interval, launch at login and an optional global shortcut. |

## How it works

Usagebar reads the CPA account list, requests quota data through CPA, and displays each account's limits and reset times. It refreshes every two minutes by default while the panel or Settings is open. With both closed, it refreshes five times less often. Low Power Mode slows polling, and sleep pauses it. Failed requests keep the last successful reading and retry with backoff.

See [CLIProxyAPI setup](docs/CPA.md) for connection details and supported readings, or [Architecture](docs/ARCHITECTURE.md) for refresh and persistence behavior.

## Privacy and security

- Usagebar only queries account and usage data through the CPA instance you configure. Account management, token refresh and reset redemption happen outside Usagebar.
- The management key is stored in the existing device-encrypted `credentials.enc` file. Use HTTPS for remote CPA connections.
- Usagebar has no project-operated backend or telemetry.

Report suspected vulnerabilities privately according to the [security policy](SECURITY.md). Keep management keys and unredacted responses out of issues.

## Build from source

You need Xcode 26 or newer with its bundled macOS SDK.

```bash
git clone https://github.com/allgemeiner-intellekt/Usagebar.git
cd Usagebar
./script/build_and_run.sh --verify
```

Create a distributable archive with `make release`. The clean archive is written to `build/Usagebar.zip`.

## Repository map

```text
JustaUsageBar/       macOS application source and asset catalog
  Models/            provider-neutral usage models
  Services/          CPA client and encrypted connection storage
  ViewModels/        refresh orchestration and persisted preferences
  Views/             status item, menus, setup, and settings UI
assets/brand/        approved logo and standalone icon masters
Casks/               Homebrew cask definitions
docs/                architecture, brand, and release documentation
script/              local build and run entrypoint
.github/              CI, issue forms, and pull request guidance
```

## Project documentation

| Document | Purpose |
| --- | --- |
| [Architecture](docs/ARCHITECTURE.md) | Runtime components, data flow, credentials, and network boundaries. |
| [Brand assets](docs/BRAND.md) | Approved identity files and usage guidance. |
| [Contributing](CONTRIBUTING.md) | Local setup, change standards, and validation expectations. |
| [Releasing](docs/RELEASING.md) | Personal build artifacts and optional tagged releases. |
| [Security](SECURITY.md) | Supported versions and private reporting process. |
| [Code of Conduct](CODE_OF_CONDUCT.md) | Community participation expectations. |

## Contributing

Issues and focused pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), use the repository issue forms, and keep provider credentials out of logs and screenshots.

## Acknowledgements

- [CodexBar](https://github.com/steipete/CodexBar) for authentication-flow inspiration
- Anthropic for Claude and Claude Code
- OpenAI for Codex
- Moonshot AI for Kimi and Kimi Code

Usagebar is an independent open-source project and is not affiliated with, endorsed by, or sponsored by these providers.

## License

Usagebar is available under the [MIT License](LICENSE).
