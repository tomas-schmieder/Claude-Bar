# ClaudeBar

A minimal macOS menu-bar app that tracks your **Claude**, **Codex** and **Cursor** usage in one place,
inspired by [CodexBar](https://github.com/steipete/CodexBar),
[claude-usage-bar](https://github.com/mnapoli/claude-usage-bar) and
[CodexUsageBar](https://github.com/Artzainnn/CodexUsageBar).

For each provider:

- **Plan limits**: session / weekly / monthly bars with reset countdowns and an even-pace marker
- **Token usage over time**: a labelled daily bar chart (7 / 14 / 30 days), hover a bar for that day's
  input / output / cache breakdown, toggle between tokens and estimated cost
- **Estimated spend**: today, 7-day and 30-day cost at public API list prices. You pay a flat subscription;
  this shows what the same usage would have cost on the pay-as-you-go API.

Left-click the menu-bar icon for the popover, right-click for quick settings. The icon shows two bars
(top: first limit, bottom: second limit) for the provider you choose under **Menu Bar Shows**.

## Where the data comes from

Everything is read from sign-ins that already exist on your Mac. No API keys, no cookie copying.

| Provider | Limits | Token history + cost |
|---|---|---|
| Claude | Claude Code OAuth cache, falling back to the `claude` CLI (never shows Keychain prompts) | Local Claude Code logs in `~/.claude/projects`, priced at Anthropic API rates |
| Codex | `chatgpt.com/backend-api/wham/usage` using the tokens from `codex login` (`~/.codex/auth.json`); falls back to the last limits written in your session logs | Local Codex CLI logs in `~/.codex/sessions`, priced at OpenAI API rates |
| Cursor | `cursor.com/api/usage-summary` using the Cursor desktop app's session (`state.vscdb`) | `cursor.com` usage events; cost is Cursor's own per-request API list price (`totalCents`) |

Setup: be signed in to Claude Code (`claude`), the Codex CLI (`codex login`) and the Cursor app.
Providers you don't use can be switched off from the gear menu.

Notes:

- `$CODEX_HOME` is respected when set in the environment the app launches with.
- Codex logs are parsed incrementally (only newly appended lines are read on each refresh). Forked or
  resumed Codex sessions can occasionally be counted twice, so treat Codex totals as estimates.
- Refreshes run every 5 minutes; token history refreshes every 15 minutes or when you click refresh.

## Layout

- `Sources/ClaudeBarCore`: provider fetchers and shared helpers
  - `MultiProvider/`: provider-neutral limits (`ProviderLimitSnapshot`) and daily token history (`TokenUsageHistory`)
  - `Providers/Claude`, `Providers/Codex`, `Providers/Cursor`
- `Sources/ClaudeBar`: the menu-bar app (`NSStatusItem` + SwiftUI popover with Swift Charts)
- `Sources/ClaudeBarDebug`: one-shot CLI that prints every provider's limits and token totals
- `Tests/ClaudeBarCoreTests`: parser tests (Codex logs, Cursor responses, history math)

## Build / run

Requires Xcode 26 (Swift 6.2) on macOS 14+.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build ClaudeBar.app and open it
./Scripts/compile_and_run.sh

# Or package then launch separately
./Scripts/package_app.sh          # → ClaudeBar.app
./Scripts/launch.sh

# Tests
swift test

# Print what each provider reports, from the terminal
swift run ClaudeBarDebug
```

`LSUIElement` is set, so it runs as a menu-bar agent (no Dock icon).

## Install to Applications (optional)

```bash
./Scripts/package_app.sh release
cp -R ClaudeBar.app /Applications/
open -a ClaudeBar
```
