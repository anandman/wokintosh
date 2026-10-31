#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_STAGE="$(mktemp -d /private/tmp/wokintosh-release.XXXXXX)"
trap 'rm -rf "$RELEASE_STAGE"' EXIT
WOKINTOSH_STAGE_DIR="$RELEASE_STAGE" WOKINTOSH_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --build-only
PACKAGE_ROOT="$RELEASE_STAGE/package/Wokintosh"
mkdir -p "$PACKAGE_ROOT" "$ROOT_DIR/dist"
cp -R "$RELEASE_STAGE/Wokintosh.app" "$PACKAGE_ROOT/"
cp "$ROOT_DIR/collector/wokintosh_agent.py" "$PACKAGE_ROOT/wokintosh-agent"
chmod +x "$PACKAGE_ROOT/wokintosh-agent"
cp "$ROOT_DIR/README.md" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$PACKAGE_ROOT/"
xattr -cr "$PACKAGE_ROOT"
codesign --verify --deep --strict "$PACKAGE_ROOT/Wokintosh.app"
ARCHIVE="$ROOT_DIR/dist/Wokintosh-0.6.0-macOS-arm64.zip"
ditto -c -k --norsrc --keepParent "$PACKAGE_ROOT" "$ARCHIVE"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf 'Packaged %s\n' "$ARCHIVE"
