#!/usr/bin/env bash
# Produce distributable artifacts. Does not publish, install, or stop a running app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.sh"
: "${WOKINTOSH_SIGNING_IDENTITY:?Set a Developer ID Application certificate fingerprint}"
: "${WOKINTOSH_NOTARY_PROFILE:?Set a saved notarytool keychain profile}"
[[ "$(uname -m)" == arm64 ]] || { printf 'Build this release on Apple silicon.\n' >&2; exit 1; }
RELEASE_STAGE="$(mktemp -d /private/tmp/wokintosh-distribution.XXXXXX)"
trap 'printf "Release staging and notarization logs: %s\n" "$RELEASE_STAGE"' EXIT
APP="$RELEASE_STAGE/Wokintosh.app"
NAME="Wokintosh-${WOKINTOSH_VERSION}-macOS-arm64"
DMG="$RELEASE_STAGE/$NAME.dmg"
COLLECTOR_NAME="wokintosh-agent-${WOKINTOSH_VERSION}"
COLLECTOR_ZIP="$RELEASE_STAGE/$COLLECTOR_NAME.zip"
# Validate the saved profile before starting the build. No credentials are printed.
xcrun notarytool history --keychain-profile "$WOKINTOSH_NOTARY_PROFILE" --output-format json > /dev/null
WOKINTOSH_STAGE_DIR="$RELEASE_STAGE" WOKINTOSH_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --build-only
[[ "$(lipo -archs "$APP/Contents/MacOS/Wokintosh")" == arm64 ]]
# The resource bundle contains data only; the app has no nested executable code.
codesign --force --sign "$WOKINTOSH_SIGNING_IDENTITY" --options runtime --timestamp \
    --entitlements "$ROOT_DIR/script/Wokintosh.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" > "$RELEASE_STAGE/signed-entitlements.plist" 2>/dev/null
python3 - "$RELEASE_STAGE/signed-entitlements.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: entitlements=plistlib.load(f)
assert entitlements == {'com.apple.security.automation.apple-events': True,
                        'com.apple.security.personal-information.calendars': True}, entitlements
PY
notarize() {
    local artifact="$1" log="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$WOKINTOSH_NOTARY_PROFILE" \
        --wait --output-format json > "$log"
    python3 - "$log" <<'PY'
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
print('Notarization:',result.get('id'),result.get('status'))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; inspect the saved submission log.')
PY
}
ditto -c -k --norsrc --keepParent "$APP" "$RELEASE_STAGE/Wokintosh-notarization.zip"
notarize "$RELEASE_STAGE/Wokintosh-notarization.zip" "$RELEASE_STAGE/app-notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
PAYLOAD="$RELEASE_STAGE/dmg"
mkdir -p "$PAYLOAD" "$RELEASE_STAGE/$COLLECTOR_NAME"
ditto "$APP" "$PAYLOAD/Wokintosh.app"
ln -s /Applications "$PAYLOAD/Applications"
for target in "$PAYLOAD" "$RELEASE_STAGE/$COLLECTOR_NAME"; do
    cp "$ROOT_DIR/collector/wokintosh_agent.py" "$target/wokintosh-agent"
    chmod 755 "$target/wokintosh-agent"
    cp "$ROOT_DIR/README.md" "$ROOT_DIR/QUICKSTART.md" "$ROOT_DIR/RELEASE_NOTES.md" \
       "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/CONTRIBUTING.md" "$target/"
    mkdir -p "$target/docs/images"
    cp "$ROOT_DIR/docs/images/dashboard.png" "$target/docs/images/"
done
ditto -c -k --norsrc --keepParent "$RELEASE_STAGE/$COLLECTOR_NAME" "$COLLECTOR_ZIP"
hdiutil create -volname "Wokintosh $WOKINTOSH_VERSION" -srcfolder "$PAYLOAD" -format UDZO -ov "$DMG"
codesign --sign "$WOKINTOSH_SIGNING_IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG" "$RELEASE_STAGE/dmg-notarization.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
mkdir -p "$ROOT_DIR/dist"
cp "$DMG" "$COLLECTOR_ZIP" "$ROOT_DIR/dist/"
cp "$ROOT_DIR/RELEASE_NOTES.md" "$ROOT_DIR/dist/Wokintosh-${WOKINTOSH_VERSION}-release-notes.md"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$NAME.dmg" "$COLLECTOR_NAME.zip" \
    "Wokintosh-${WOKINTOSH_VERSION}-release-notes.md" > "Wokintosh-${WOKINTOSH_VERSION}-SHA256SUMS.txt")
printf 'Validated release artifacts: %s/dist/\n' "$ROOT_DIR"
