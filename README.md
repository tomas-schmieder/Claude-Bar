# ClaudeBar

Thin Claude-only macOS menu-bar app extracted from CodexBar.

## Layout

- `Sources/ClaudeBarCore` — Claude usage fetch (OAuth / Web / CLI) + shared helpers
- `Sources/ClaudeBar` — menu-bar app (`NSStatusItem`)
- `Sources/ClaudeBarDebug` — one-shot CLI that prints a usage snapshot
- `ClaudeBar.app` — packaged macOS application (created by `Scripts/package_app.sh`)
- `REFERENCE.md` — freeze tip of the CodexBar strip branch this was cut from

## Build / run (real macOS app)

Requires Xcode’s Swift toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/windy/claude-bar/ClaudeBar

# Build ClaudeBar.app and open it (no terminal attachment)
./Scripts/compile_and_run.sh

# Or package then launch separately
./Scripts/package_app.sh          # → ClaudeBar.app
./Scripts/launch.sh

# Optional: double-click ClaudeBar.app in Finder, or:
open -n ./ClaudeBar.app
```

`LSUIElement` is set, so it runs as a menu-bar agent (no Dock icon), same idea as CodexBar.

### Debug CLI (still terminal)

```bash
swift run ClaudeBarDebug
```

## Install to Applications (optional)

```bash
./Scripts/package_app.sh release
cp -R ClaudeBar.app /Applications/
open -a ClaudeBar
```

## Scope (MVP)

In:
- Packaged `.app` bundle (Finder / `open` / Applications)
- CodexBar-style dual-bar template icon (session + weekly)
- SwiftUI usage card: paced Session/Weekly bars, Daily Routines extras, cost grid, 30d chart
- Cache-first launch + OAuth-preferring refresh
- Local Claude JSONL cost scan in the background
- Auto refresh every 5 minutes + Refresh action

Deferred: Preferences window, widgets, Sparkle auto-update, Developer ID notarization, custom app icon.
