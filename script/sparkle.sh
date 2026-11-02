# Source after setting BUILD_DIR. SwiftPM verifies the pinned artifact checksum.
SPARKLE_ROOT="$BUILD_DIR/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_BIN="$SPARKLE_ROOT/bin"
[[ -d "$SPARKLE_FRAMEWORK" && -x "$SPARKLE_BIN/generate_appcast" ]] || {
    printf 'Pinned Sparkle artifact is missing. Run swift package resolve with the same scratch path.\n' >&2
    exit 1
}
