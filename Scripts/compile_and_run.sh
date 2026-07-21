#!/usr/bin/env bash
# Build ClaudeBar.app and launch it (Finder-style, no attached terminal).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONF="${1:-debug}"

"$ROOT/Scripts/package_app.sh" "$CONF"
"$ROOT/Scripts/launch.sh"
