#!/usr/bin/env bash
# Sign all nested Sparkle code inside-out, then the host app. No --deep signing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Pass the staged app bundle}"
: "${WOKINTOSH_SIGNING_IDENTITY:?Set a Developer ID Application certificate fingerprint}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -f "$FRAMEWORK/Versions/B/Autoupdate" ]] || { printf 'Missing Sparkle framework.\n' >&2; exit 1; }
for code in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"; do
    codesign --force --sign "$WOKINTOSH_SIGNING_IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$code"
done
codesign --force --sign "$WOKINTOSH_SIGNING_IDENTITY" --options runtime --timestamp "$FRAMEWORK"
codesign --force --sign "$WOKINTOSH_SIGNING_IDENTITY" --options runtime --timestamp \
    --entitlements "$ROOT_DIR/script/Wokintosh.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
