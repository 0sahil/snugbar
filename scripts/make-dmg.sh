#!/usr/bin/env bash
# Builds a drag-to-Applications DMG from an existing SnugBar.app.
#   scripts/make-dmg.sh [path/to/SnugBar.app] [out.dmg]
# Defaults: build/SnugBar.app -> build/SnugBar-<version>.dmg
# Signs the DMG when SIGN_IDENTITY is set (package-release.sh notarizes it).
# Needs create-dmg (brew install create-dmg). Arranging the window drives Finder with AppleScript, so the first local
# run may ask to let your terminal control Finder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="${1:-$ROOT/build/SnugBar.app}"
DMG="${2:-$ROOT/build/SnugBar-$VERSION.dmg}"
WORK="$ROOT/build/dmg"

command -v create-dmg >/dev/null || { echo "create-dmg not found: brew install create-dmg" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "No app at $APP (run scripts/build-app.sh first)" >&2; exit 1; }

echo "==> drawing the DMG background"
rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/bg" "$ROOT/build/tools"
swiftc -O -o "$ROOT/build/tools/make-dmg-background" "$ROOT/scripts/make-dmg-background.swift"
"$ROOT/build/tools/make-dmg-background" "$WORK/bg" >/dev/null
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$WORK/bg/background.tiff" >/dev/null

echo "==> building $DMG"
ditto "$APP" "$WORK/src/SnugBar.app"
rm -f "$DMG"
create-dmg \
    --volname "SnugBar" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$WORK/bg/background.tiff" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --text-size 13 \
    --icon-size 128 \
    --icon "SnugBar.app" 165 185 \
    --hide-extension "SnugBar.app" \
    --app-drop-link 495 185 \
    --no-internet-enable \
    "$DMG" "$WORK/src" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> signing the DMG"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi
rm -rf "$WORK"
echo "==> built $DMG"
