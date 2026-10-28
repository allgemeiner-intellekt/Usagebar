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
- Keep the menu-bar icon static across usage, errors, setup, and updates. A simple monochrome vector symbol is sufficient; this version uses the built-in `chart.bar` symbol in a standard square slot. Right click has the same panel-toggle behavior as left click. Escape also closes the panel.
- The fixed icon is the only mode. Remove cycling-only preferences, timers, focus following, terminal scans, and provider status-image caches. Preserve shared authentication and provider functionality.
- Preserve panel information, card order, and layout. Remove the selected-provider dots, card selection actions, and obsolete menu-bar hints. Keep provider visibility switches.
- Refresh all enabled providers less often while the panel and settings menu are closed. Opening checks freshness immediately and refreshes stale data; fresh data need not refetch. Preserve Low Power Mode, retry backoff, and server cooldowns.
- The microphone overlap observation was resolved as normal menu-bar management behavior and requires no fix or alternate opening route.
- Future personal renaming and app-icon changes are separate work. Preserve MIT copyright and license notices.
- The owner uses services on multiple devices. Existing usage-limit displays remain useful; token counting is a separate, deferred feature.

The fixed-icon implementation replaces the original cycling design. Check the current code and validation evidence before claiming any requirement is delivered.

## Deferred token statistics

Investigate only when requested. A useful total must cover the owner's relevant usage across devices. Local-device logs alone do not meet this requirement; omit the feature if completeness cannot be achieved. First establish account-level provider data availability and the usage channels to include. Do not estimate token counts from quota percentages. Periods, presentation, and multi-account requirements remain undecided.

## Upstream decisions

Assess changes against actual use and preserve the fixed-icon interaction once implemented. Review security, dependencies, authentication compatibility, and shared infrastructure even when a change names a non-priority provider. Recommend relevant fixes; do not blindly import every upstream feature or discard fixes by provider name. Record new decisions here only when confirmed.
