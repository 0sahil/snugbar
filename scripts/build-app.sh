#!/usr/bin/env bash
# Builds build/SnugBar.app from a release build.
#
#   scripts/build-app.sh            build and sign
#   scripts/build-app.sh --install  also copy the app to /Applications
#
# Signing: uses the identity in SIGN_IDENTITY (or SNUGBAR_SIGN_IDENTITY) when set, with the hardened runtime and a
# secure timestamp, as notarization requires; otherwise ad-hoc. With ad-hoc signing every build gets a new signature,
# so macOS may ask for permissions again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

BUNDLE_ID="app.snugbar.SnugBar"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
# Sparkle compares CFBundleVersion, so it must grow with every release: the commit count does.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/build/SnugBar.app"
ICONSET="$ROOT/build/AppIcon.iconset"
IDENTITY="${SIGN_IDENTITY:-${SNUGBAR_SIGN_IDENTITY:-}}"

# Sparkle: the appcast is a release asset, so installed copies only see a release once it is published.
# SUEnableAutomaticChecks skips Sparkle's "check automatically?" prompt; Settings > General turns checks off.
FEED_URL="https://github.com/0sahil/snugbar/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="8M7xS+2o0Lthp6fXCqo7GU59c+I/Ql7qf82SL9RP30Y="

echo "==> swift build -c release ($VERSION, build $BUILD_NUMBER)"
swift build -c release --product SnugBar
swift build -c release --product snugbar-cli
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN_DIR/SnugBar" "$APP/Contents/MacOS/SnugBar"
# The command-line tool. Not in Contents/MacOS: on a case-insensitive volume "snugbar" there is the app's own binary
# (which, when run under that name, also acts as the command-line tool).
cp "$BIN_DIR/snugbar-cli" "$APP/Contents/Helpers/snugbar"

# Sparkle (in-app updates). SwiftPM links it as @rpath/Sparkle.framework but only adds build-tree rpaths.
echo "==> embedding Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are only needed by sandboxed apps; Sparkle's docs allow removing them otherwise.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SnugBar"

echo "==> drawing the app icon"
mkdir -p "$ROOT/build/tools"
swiftc -O -o "$ROOT/build/tools/make-icon" "$ROOT/scripts/make-icon.swift"
"$ROOT/build/tools/make-icon" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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
    <key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

# Inside-out, without --deep (per Sparkle's docs): Sparkle's helpers, the framework, the command-line tool, the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
HELPER="$APP/Contents/Helpers/snugbar"
SPARKLE_PARTS=("$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE")
if [[ -n "$IDENTITY" ]]; then
    echo "==> signing with '$IDENTITY' (hardened runtime)"
    for item in "${SPARKLE_PARTS[@]}"; do
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
    done
    codesign --force --options runtime --timestamp --identifier "${BUNDLE_ID}.cli" --sign "$IDENTITY" "$HELPER"
    codesign --force --options runtime --timestamp --entitlements "$ROOT/scripts/SnugBar.entitlements" \
        --sign "$IDENTITY" "$APP"
else
    echo "==> signing ad-hoc"
    for item in "${SPARKLE_PARTS[@]}"; do
        codesign --force --sign - --timestamp=none "$item"
    done
    codesign --force --identifier "${BUNDLE_ID}.cli" --sign - --timestamp=none "$HELPER"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"
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
