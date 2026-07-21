#!/usr/bin/env bash
# Package ClaudeBar as a real macOS .app (Finder / Dock / open -a compatible).
# Usage:
#   ./Scripts/package_app.sh          # debug
#   ./Scripts/package_app.sh release  # release

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONF="${1:-debug}"
LOWER_CONF="$(printf '%s' "$CONF" | tr '[:upper:]' '[:lower:]')"
case "$LOWER_CONF" in
  debug) SWIFT_CONF=debug ;;
  release) SWIFT_CONF=release ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

echo "==> Building ClaudeBar ($SWIFT_CONF)"
swift build -c "$SWIFT_CONF" --product ClaudeBar

BIN_DIR="$(swift build -c "$SWIFT_CONF" --show-bin-path)"
BINARY="$BIN_DIR/ClaudeBar"
if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: missing binary at $BINARY" >&2
  exit 1
fi

APP_FINAL="$ROOT/ClaudeBar.app"
APP_STAGE="$ROOT/.build/package/ClaudeBar.app"
rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"

MARKETING_VERSION="${CLAUDEBAR_VERSION:-0.1.0}"
BUILD_NUMBER="${CLAUDEBAR_BUILD:-1}"
if [[ "$LOWER_CONF" == "debug" ]]; then
  BUNDLE_ID="com.claudebar.app.debug"
else
  BUNDLE_ID="com.claudebar.app"
fi

cat > "$APP_STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeBar</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeBar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © ClaudeBar contributors</string>
</dict>
</plist>
PLIST

# PkgInfo is traditional but optional for modern macOS.
printf 'APPL????' > "$APP_STAGE/Contents/PkgInfo"

echo "==> Installing binary"
cp "$BINARY" "$APP_STAGE/Contents/MacOS/ClaudeBar"
chmod +x "$APP_STAGE/Contents/MacOS/ClaudeBar"

# Ad-hoc sign so Gatekeeper will launch a locally built app.
echo "==> Codesigning (adhoc)"
codesign --force --deep --sign - "$APP_STAGE/Contents/MacOS/ClaudeBar"
codesign --force --deep --sign - "$APP_STAGE"

# Swap into place atomically-ish
rm -rf "$APP_FINAL"
mv "$APP_STAGE" "$APP_FINAL"

echo "==> Packaged: $APP_FINAL"
echo "    Launch with: open -n \"$APP_FINAL\""
echo "    Or:          ./Scripts/launch.sh"
