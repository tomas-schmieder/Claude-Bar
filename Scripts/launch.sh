#!/usr/bin/env bash
# Kill any running ClaudeBar, then open the packaged .app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT/ClaudeBar.app"

echo "==> Stopping existing ClaudeBar"
pkill -x ClaudeBar 2>/dev/null || true
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
sleep 0.4

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: ClaudeBar.app not found at $APP_PATH"
  echo "Run ./Scripts/package_app.sh first"
  exit 1
fi

echo "==> Opening $APP_PATH"
open -n "$APP_PATH"
sleep 1

if pgrep -x ClaudeBar >/dev/null 2>&1 || pgrep -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" >/dev/null 2>&1; then
  echo "OK: ClaudeBar is running as a macOS app (no terminal needed)."
else
  echo "ERROR: App exited immediately. Check Console.app for crash reports."
  exit 1
fi
