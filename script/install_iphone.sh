#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: script/install_iphone.sh --device DEVICE_UDID [--team TEAM_ID] [--dry-run]
       script/install_iphone.sh --build-only [--team TEAM_ID] [--dry-run]

Requires Xcode iOS/iPadOS development signing and a trusted device. Uses only the
explicitly chosen iPhone or iPad; builds stay under /private/tmp by default.
HELP
}
wokintosh_phone_device=""
wokintosh_phone_team=""
wokintosh_phone_build_only=false
wokintosh_phone_dry_run=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --device|--team)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            if [ "$1" = --device ]; then wokintosh_phone_device=$2; else wokintosh_phone_team=$2; fi
            shift 2 ;;
        --build-only) wokintosh_phone_build_only=true; shift ;;
        --dry-run) wokintosh_phone_dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if ! $wokintosh_phone_build_only && [ -z "$wokintosh_phone_device" ]; then usage >&2; exit 2; fi
if [ -n "$wokintosh_phone_device" ] && ! [[ "$wokintosh_phone_device" =~ ^[A-Fa-f0-9-]{8,64}$ ]]; then
    printf '%s\n' 'Use the iPhone or iPad UDID from Xcode Devices and Simulators.' >&2; exit 2
fi
if [ -n "$wokintosh_phone_team" ] && ! [[ "$wokintosh_phone_team" =~ ^[A-Z0-9]{10}$ ]]; then
    printf '%s\n' 'Use the ten-character Apple developer team ID.' >&2; exit 2
fi
wokintosh_phone_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
# Asset thinning changes the signed resources for each device. Keep incremental
# products separate so switching between iPhone and iPad cannot reuse a stale seal.
wokintosh_phone_default_build=/private/tmp/wokintosh-phone-device
if [ -n "$wokintosh_phone_device" ]; then wokintosh_phone_default_build+="-$wokintosh_phone_device"; fi
wokintosh_phone_build=${WOKINTOSH_PHONE_BUILD_DIR:-$wokintosh_phone_default_build}
python3 - "$wokintosh_phone_root" "$wokintosh_phone_build" <<'PY'
import os,sys
source,build=map(os.path.realpath,sys.argv[1:])
if not os.path.isabs(sys.argv[2]) or os.path.commonpath([source,build])==source or 'Dropbox' in build.split(os.sep):
    raise SystemExit('Choose an absolute build directory outside Dropbox.')
PY
wokintosh_phone_destination='generic/platform=iOS'
if [ -n "$wokintosh_phone_device" ]; then wokintosh_phone_destination="platform=iOS,id=$wokintosh_phone_device"; fi
wokintosh_phone_command=(xcodebuild -project "$wokintosh_phone_root/iOS/WokintoshPhone.xcodeproj" -scheme WokintoshPhone -configuration Debug -destination "$wokintosh_phone_destination" -derivedDataPath "$wokintosh_phone_build" -allowProvisioningUpdates)
if [ -n "$wokintosh_phone_device" ]; then wokintosh_phone_command+=(-allowProvisioningDeviceRegistration); fi
if [ -n "$wokintosh_phone_team" ]; then wokintosh_phone_command+=("DEVELOPMENT_TEAM=$wokintosh_phone_team"); fi
wokintosh_phone_command+=(build)
wokintosh_phone_app="$wokintosh_phone_build/Build/Products/Debug-iphoneos/WokintoshPhone.app"
if $wokintosh_phone_dry_run; then
    printf '%q ' "${wokintosh_phone_command[@]}"; printf '\n'
    if ! $wokintosh_phone_build_only; then printf '%q ' xcrun devicectl device install app --device "$wokintosh_phone_device" "$wokintosh_phone_app"; printf '\n'; fi
    exit 0
fi
"${wokintosh_phone_command[@]}"
[ -d "$wokintosh_phone_app/PlugIns/WokintoshAgentWidget.appex" ] || { printf '%s\n' 'The app is missing its Agent widget.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$wokintosh_phone_app"
# An archive can be signed successfully while missing the capabilities shared by
# the app and extension. Refuse installation until both signed bundles have them.
python3 "$wokintosh_phone_root/script/validate_iphone.py" "$wokintosh_phone_app"
if $wokintosh_phone_build_only; then
    printf 'Prepared %s\n' "$wokintosh_phone_app"
else
    xcrun devicectl device install app --device "$wokintosh_phone_device" "$wokintosh_phone_app"
    printf '%s\n' 'Installed. Open Wokintosh on your iPhone or iPad to pair it with your Mac.'
fi
