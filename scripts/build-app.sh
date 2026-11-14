#!/usr/bin/env bash
# Builds build/SnugBar.app from a release build.
#
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy the app to /Applications
#
# Signing: uses the identity in SNUGBAR_SIGN_IDENTITY when set (hardened runtime, timestamp), otherwise ad-hoc.
# Note: with ad-hoc signing every build gets a new signature, so macOS may ask for permissions again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

BUNDLE_ID="app.snugbar.SnugBar"
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/build/SnugBar.app"

echo "==> swift build -c release"
swift build -c release --product SnugBar
swift build -c release --product snugbar-cli
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/SnugBar" "$APP/Contents/MacOS/SnugBar"
# The command-line tool. Not in Contents/MacOS: on a case-insensitive volume "snugbar" there is the app's own binary
# (which, when run under that name, also acts as the command-line tool).
cp "$BIN_DIR/snugbar-cli" "$APP/Contents/Helpers/snugbar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SnugBar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SnugBar</string>
    <key>CFBundleDisplayName</key>
    <string>SnugBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 0sahil. MIT License.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>snugbar</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

IDENTITY="${SNUGBAR_SIGN_IDENTITY:-}"
# Nested code first, then the bundle.
HELPER="$APP/Contents/Helpers/snugbar"
if [[ -n "$IDENTITY" ]]; then
    echo "==> signing with '$IDENTITY'"
    codesign --force --options runtime --timestamp --identifier "${BUNDLE_ID}.cli" --sign "$IDENTITY" "$HELPER"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "==> signing ad-hoc"
    codesign --force --identifier "${BUNDLE_ID}.cli" --sign - "$HELPER"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "==> built $APP"

if [[ "$INSTALL" == 1 ]]; then
    DEST="/Applications/SnugBar.app"
    echo "==> installing to $DEST"
    if pgrep -x SnugBar >/dev/null; then
        echo "SnugBar is running; quit it first." >&2
        exit 1
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "==> installed"
fi
