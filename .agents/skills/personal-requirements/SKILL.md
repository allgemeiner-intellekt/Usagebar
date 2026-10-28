---
name: personal-requirements
description: Use when reviewing upstream changes, discussing features, developing, or fixing behavior that affects this personal Usagebar fork.
---

# Personal requirements

This fork is for the owner's personal use. Upstream contributions and public distribution are not goals. Build and distribution operations belong in `../cloud-build/SKILL.md`.

## Confirmed requirements

- Prioritize OpenAI/Codex, Grok and Cursor's existing subscription integrations, and Kimi. The owner's description of a unified subscription is usage context, not evidence that their provider APIs or account models are interchangeable. Preserve existing integrations unless a specific change is requested.
- Keep other providers for now. Unmentioned features are unknown, not unwanted.
- Replace the cycling provider display with a fixed Usagebar menu-bar icon. A left click or single-finger trackpad click opens the panel; another click or a click outside closes it. Opening must not require a right click or double click.
- Initially preserve the panel's contents and arrangement. Exact icon artwork is not yet selected.
- The owner uses services on multiple devices. Existing usage-limit displays remain useful; token counting is a separate, deferred feature.

The menu-bar requirements are planned product work, not implemented by the fork setup. Check the current code before claiming they are delivered.

## Deferred token statistics

Investigate only when requested. A useful total must cover the owner's relevant usage across devices. Local-device logs alone do not meet this requirement; omit the feature if completeness cannot be achieved. First establish account-level provider data availability and the usage channels to include. Do not estimate token counts from quota percentages. Periods, presentation, and multi-account requirements remain undecided.

## Upstream decisions

Assess changes against actual use and preserve the fixed-icon interaction once implemented. Review security, dependencies, authentication compatibility, and shared infrastructure even when a change names a non-priority provider. Recommend relevant fixes; do not blindly import every upstream feature or discard fixes by provider name. Record new decisions here only when confirmed.
