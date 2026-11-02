#!/usr/bin/env bash
# Generate the feed only after the DMG has its final signed/stapled bytes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.sh"
source "$ROOT_DIR/script/update_config.sh"
BUILD_DIR="${WOKINTOSH_BUILD_DIR:-/private/tmp/wokintosh-build}"
source "$ROOT_DIR/script/sparkle.sh"
APP="${1:?Pass the final app bundle}"
DMG="${2:?Pass the final signed and stapled DMG}"
FEED_DIR="${3:?Pass a new empty feed staging directory}"
[[ ! -e "$FEED_DIR" ]] || { printf 'Feed staging directory must be new.\n' >&2; exit 1; }
mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
cp "$ROOT_DIR/RELEASE_NOTES.md" "$FEED_DIR/$(basename "${DMG%.dmg}").md"
"$SPARKLE_BIN/generate_appcast" --account "$WOKINTOSH_UPDATE_KEY_ACCOUNT" \
    --download-url-prefix "https://github.com/anandman/wokintosh/releases/download/v${WOKINTOSH_VERSION}/" \
    --link https://github.com/anandman/wokintosh --embed-release-notes --maximum-deltas 0 "$FEED_DIR"
python3 "$ROOT_DIR/script/validate_update.py" --app "$APP" --archive "$DMG" \
    --feed "$FEED_DIR/appcast.xml" --version "$WOKINTOSH_VERSION" --build "$WOKINTOSH_BUILD_NUMBER" \
    --public-key "$WOKINTOSH_UPDATE_PUBLIC_KEY" --tools "$SPARKLE_BIN" --account "$WOKINTOSH_UPDATE_KEY_ACCOUNT"
