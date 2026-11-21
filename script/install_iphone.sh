#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: script/install_iphone.sh --device IPHONE_UDID [--team TEAM_ID] [--dry-run]
       script/install_iphone.sh --build-only [--team TEAM_ID] [--dry-run]

Requires Xcode iPhone development signing and a trusted device. Uses only the
explicitly chosen iPhone; builds stay under /private/tmp by default.
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
    printf '%s\n' 'Use the iPhone UDID from Xcode Devices and Simulators.' >&2; exit 2
fi
if [ -n "$wokintosh_phone_team" ] && ! [[ "$wokintosh_phone_team" =~ ^[A-Z0-9]{10}$ ]]; then
    printf '%s\n' 'Use the ten-character Apple developer team ID.' >&2; exit 2
fi
wokintosh_phone_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
wokintosh_phone_build=${WOKINTOSH_PHONE_BUILD_DIR:-/private/tmp/wokintosh-phone-device}
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
python3 - "$wokintosh_phone_app" <<'PYENTITLEMENTS'
import pathlib,plistlib,subprocess,sys
app=pathlib.Path(sys.argv[1])
expected_group='group.dev.wokintosh.phone.shared'
teams=set()
prefixes=set()
for bundle,identifier in [(app,'dev.wokintosh.phone'),(app/'PlugIns/WokintoshAgentWidget.appex','dev.wokintosh.phone.agents')]:
    try:
        ent=plistlib.loads(subprocess.check_output(['/usr/bin/codesign','-d','--entitlements','-',str(bundle)],stderr=subprocess.DEVNULL))
    except (subprocess.CalledProcessError,plistlib.InvalidFileException):
        raise SystemExit('The app and widget need valid signed iPhone entitlements. Repair Signing & Capabilities in Xcode.')
    team=ent.get('com.apple.developer.team-identifier')
    application=ent.get('application-identifier','')
    if not team or not application.endswith('.'+identifier):
        raise SystemExit('The signed app and widget need their explicit iPhone provisioning profiles.')
    prefix=application[:-len(identifier)]
    shared=prefix+'dev.wokintosh.phone.shared'
    info=plistlib.loads((bundle/'Info.plist').read_bytes())
    if (expected_group not in ent.get('com.apple.security.application-groups',[]) or
        shared not in ent.get('keychain-access-groups',[]) or
        info.get('WokintoshKeychainAccessGroup') != shared):
        raise SystemExit('The signed app and widget are missing matching App Group/Keychain sharing. Repair Signing & Capabilities in Xcode.')
    teams.add(team);prefixes.add(prefix)
if len(teams)!=1 or len(prefixes)!=1:
    raise SystemExit('The app and widget must use the same developer team.')
PYENTITLEMENTS
if $wokintosh_phone_build_only; then
    printf 'Prepared %s\n' "$wokintosh_phone_app"
else
    xcrun devicectl device install app --device "$wokintosh_phone_device" "$wokintosh_phone_app"
    printf '%s\n' 'Installed. Open Wokintosh on your iPhone to pair it with your Mac.'
fi
