# Wokintosh 1.0.1

Fixes stale Blocked status after deleting or changing a Codex goal.

- Polls supported local Codex goal metadata read-only, so goal deletion and status changes are detected without a new hook event.
- Keeps genuinely blocked goals visible through completed turns and idle sessions, while preserving explicit manual statuses and uncertain legacy records.
- Handles renamed sessions and replacement goals by identity. Goal objectives are not read or copied into Wokintosh state.

Requires Apple silicon and macOS 14 or later for the display app. The companion collector requires Python 3.10 or later on macOS or Linux. Designed for and tested on the [Wokyis M5 (10Gbps) retro docking station](https://wokyis.com/products/wokyis-m5-10gbps), with its 5-inch 1280 × 720 display. The app and DMG are Developer ID signed, notarized and stapled.

Quit an older running copy before replacing the app. Your layout and connected machines are preserved. Update remote collectors with **Settings → Machines → Install / Update over SSH** so the fix runs on each agent machine. Existing hook configurations are retained. See [advanced agent setup](https://github.com/anandman/wokintosh/blob/main/docs/ADVANCED.md) for supported goal metadata and legacy-state behavior.
