#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.sh"
RELEASE_STAGE="$(mktemp -d /private/tmp/wokintosh-release.XXXXXX)"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
WOKINTOSH_STAGE_DIR="$RELEASE_STAGE" WOKINTOSH_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --build-only
PACKAGE_ROOT="$RELEASE_STAGE/package/Wokintosh"
mkdir -p "$PACKAGE_ROOT" "$ROOT_DIR/dist"
cp -R "$RELEASE_STAGE/Wokintosh.app" "$PACKAGE_ROOT/"
cp "$ROOT_DIR/collector/wokintosh_agent.py" "$PACKAGE_ROOT/wokintosh-agent"
chmod +x "$PACKAGE_ROOT/wokintosh-agent"
cp "$ROOT_DIR/README.md" "$ROOT_DIR/QUICKSTART.md" "$ROOT_DIR/RELEASE_NOTES.md" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/CONTRIBUTING.md" "$PACKAGE_ROOT/"
mkdir -p "$PACKAGE_ROOT/docs/images"
cp "$ROOT_DIR/docs/images/dashboard.png" "$PACKAGE_ROOT/docs/images/"
cp "$ROOT_DIR/docs/ADVANCED.md" "$PACKAGE_ROOT/docs/"
xattr -cr "$PACKAGE_ROOT"
codesign --verify --deep --strict "$PACKAGE_ROOT/Wokintosh.app"
ARCHIVE="$ROOT_DIR/dist/Wokintosh-${WOKINTOSH_VERSION}-macOS-arm64-development.zip"
ditto -c -k --norsrc --keepParent "$PACKAGE_ROOT" "$ARCHIVE"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf 'Packaged %s\n' "$ARCHIVE"
