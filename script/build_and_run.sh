#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.sh"
BUILD_DIR="${WOKINTOSH_BUILD_DIR:-/private/tmp/wokintosh-build}"
STAGE_DIR="${WOKINTOSH_STAGE_DIR:-/private/tmp/wokintosh-stage-${UID}}"
APP_BUNDLE="$STAGE_DIR/Wokintosh.app"
CONFIGURATION="${WOKINTOSH_CONFIGURATION:-debug}"
MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
cd "$ROOT_DIR"
if [[ "$MODE" != --build-only ]]; then pkill -x Wokintosh >/dev/null 2>&1 || true; fi
swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR"
BUILD_BINARY="$(swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" --show-bin-path)/Wokintosh"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/Wokintosh"
chmod +x "$APP_BUNDLE/Contents/MacOS/Wokintosh"
cp "$ROOT_DIR/collector/wokintosh_agent.py" "$APP_BUNDLE/Contents/Resources/wokintosh_agent.py"
cp "$ROOT_DIR/Sources/Wokintosh/Resources/Wokintosh.icns" "$APP_BUNDLE/Contents/Resources/Wokintosh.icns"
RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/Wokintosh_Wokintosh.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE/Contents/Resources/Wokintosh_Wokintosh.bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wokintosh</string>
<key>CFBundleIdentifier</key><string>dev.wokintosh.dashboard</string>
<key>CFBundleName</key><string>Wokintosh</string>
<key>CFBundleDisplayName</key><string>Wokintosh</string>
<key>CFBundleVersion</key><string>${WOKINTOSH_BUILD_NUMBER}</string>
<key>CFBundleShortVersionString</key><string>${WOKINTOSH_VERSION}</string>
<key>CFBundleIconFile</key><string>Wokintosh.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Wokintosh reads Apple Music playback and album artwork when you connect it.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Wokintosh shows your upcoming calendar events when you enable the calendar widget.</string>
</dict></plist>
PLIST
# Cloud-synced source resources can carry Finder metadata. Clean only the staged app.
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"
case "$MODE" in
    --build-only) printf '%s\n' "$APP_BUNDLE" ;;
    --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/Wokintosh" "$@" ;;
    --verify|run|--logs|--telemetry)
        /usr/bin/open -n "$APP_BUNDLE" --args "$@"
        if [[ "$MODE" == --verify ]]; then
            for attempt in {1..30}; do if pgrep -x Wokintosh >/dev/null; then printf 'Wokintosh launched: %s\n' "$APP_BUNDLE"; exit 0; fi; sleep 0.1; done
            printf 'Wokintosh did not remain running\n' >&2; exit 1
        elif [[ "$MODE" == --logs || "$MODE" == --telemetry ]]; then
            /usr/bin/log stream --info --style compact --predicate 'process == "Wokintosh"'
        fi ;;
    *) printf 'Usage: %s [run|--build-only|--verify|--debug|--logs|--telemetry] [app arguments]\n' "$0" >&2; exit 2 ;;
esac
