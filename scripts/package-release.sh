#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled SnugBar release: a DMG and a zip.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-release.sh
#
# Notarization credentials (pick one):
#   - App Store Connect API key:  NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   - Stored keychain profile:     NOTARY_PROFILE (created with `xcrun notarytool store-credentials`)
#   - SKIP_NOTARIZE=1              sign only (local testing; Gatekeeper still warns)
# Dry run: SKIP_NOTARIZE=1 without SIGN_IDENTITY signs ad-hoc, to check the packaging. Such a build is not
# for distribution.
#
# Output: build/SnugBar-<version>.dmg (drag to Applications) and build/SnugBar-<version>.zip (the update archive
# Sparkle downloads), each with a .sha256 file. The DMG needs create-dmg (brew install create-dmg).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
        echo "Set SIGN_IDENTITY to your 'Developer ID Application: …' identity (or SKIP_NOTARIZE=1 for an ad-hoc dry run)" >&2
        exit 1
    fi
    echo "==> no SIGN_IDENTITY: ad-hoc dry run, not for distribution"
else
    case "$SIGN_IDENTITY" in
        "Developer ID Application"*) ;;
        *) echo "SIGN_IDENTITY must be a 'Developer ID Application' certificate (got: $SIGN_IDENTITY)" >&2; exit 1 ;;
    esac
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/SnugBar.app"
ZIP="$ROOT/build/SnugBar-$VERSION.zip"
DMG="$ROOT/build/SnugBar-$VERSION.dmg"
command -v create-dmg >/dev/null || { echo "create-dmg not found: brew install create-dmg" >&2; exit 1; }

notary_args=()
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1: not notarizing"
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_PATH}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_PATH}"
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
    echo "No notarization credentials: set NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID or NOTARY_PROFILE (or SKIP_NOTARIZE=1)" >&2
    exit 1
fi

# build-app.sh signs inside-out: Sparkle's helpers, Sparkle, the command-line tool (Contents/Helpers/snugbar), the app.
SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/scripts/build-app.sh"

notarize() { # <file> <log name>
    local file="$1" log="$ROOT/build/$2"
    xcrun notarytool submit "$file" "${notary_args[@]}" --wait --timeout 30m | tee "$log"
    if ! grep -q "status: Accepted" "$log"; then
        local id
        id="$(awk '/^  id:/{print $2; exit}' "$log")"
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary_args[@]}" || true
        echo "Notarization of $(basename "$file") failed" >&2
        exit 1
    fi
}

rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
if [[ ${#notary_args[@]} -gt 0 ]]; then
    echo "==> submitting the app for notarization (this usually takes a few minutes)"
    SUBMIT_ZIP="$ROOT/build/SnugBar-notarize.zip"
    rm -f "$SUBMIT_ZIP"
    ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
    notarize "$SUBMIT_ZIP" notarize.log
    rm -f "$SUBMIT_ZIP"
    echo "==> stapling"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "==> Gatekeeper check"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The DMG holds the (notarized, stapled) app; then the DMG itself is signed, notarized and stapled.
SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG"
if [[ ${#notary_args[@]} -gt 0 ]]; then
    echo "==> notarizing the DMG"
    notarize "$DMG" notarize-dmg.log
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$ROOT/build" && for f in "$(basename "$ZIP")" "$(basename "$DMG")"; do shasum -a 256 "$f" > "$f.sha256"; done)
cat "$ZIP.sha256" "$DMG.sha256"
echo "==> done: $DMG and $ZIP"
