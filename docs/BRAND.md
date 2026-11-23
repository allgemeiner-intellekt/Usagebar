# Usagebar brand assets

The approved Usagebar identity is stored in `assets/brand`.

| Asset | Intended use |
| --- | --- |
| `usagebar-logo.png` | Repository hero, documentation, release notes, and light-background horizontal placements. |
| `usagebar-icon.png` | Transparent 1024px master for app and repository icon usage. |
| `JustaUsageBar/Assets.xcassets/AppIcon.appiconset` | Generated macOS sizes from 16px through 1024px. |

## Usage guidance

- Keep the logo on white or very light neutral backgrounds.
- Preserve the original proportions and clear space.
- Do not stretch, rotate, recolor, outline, or add provider branding.
- Use the standalone icon only when the wordmark would be unreadable.
- Regenerate every AppIcon size from the master after changing the icon.
- Inspect the 16px and 32px files after any change.

The symbol represents a compact usage window with a local loading indicator. It is provider-neutral and should not be combined with Anthropic or OpenAI trademarks.

## Personal menu-bar symbol

The personal fork uses the built-in `chart.bar` system symbol as a monochrome template in a standard square status item. It is independent of the app icon and the original brand masters, which remain unchanged. Future personal renaming and app-icon work is separate from this menu-bar change.

## Provider marks in the panel

Each panel card shows its provider's mark as a template image, tinted with the provider's accent color, followed by the name. The same accent fills the card's usage meters. Marks live in `JustaUsageBar/Assets.xcassets` as `<Provider>Mark` or `ClaudeSpark`; titles and accents are defined in `DisplayProvider` in `UsagePanelView.swift`.

Claude Code, Antigravity and Kimi Code use their brand colors. Codex, Cursor, Z.ai and xAI have monochrome brands, so their accents are chosen to tell cards apart. Each accent has a light and a dark variant. The Antigravity and Kimi marks come from [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT). The Codex mark is the symbol from the Codex lockup. The others are traced from the official marks.
