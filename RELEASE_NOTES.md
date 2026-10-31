# Wokintosh 1.0.0

A Macintosh Color Classic-style dashboard for a small display, with independently placed and resized widgets. Designed for and tested on the [Wokyis M5 (10Gbps) retro docking station](https://wokyis.com/products/wokyis-m5-10gbps) and its 5-inch 1280 × 720 display.

- Individual Codex and Claude Code sessions across Macs and Linux machines, with attention first, durable Blocked states, and Done notices with explicit Review controls.
- Apple Music playback, color album artwork and optional Apple catalog fallback for missing covers.
- Calendar agenda with per-widget calendar selections, all-day and title filters, and duplicate availability-block filtering.
- Per-widget weather locations, clocks, and CPU, memory and multiple drive readings.
- One Dashboard & Settings workspace with a live layout preview, aligned snapping, and consistent Content / Layout / Actions configuration.
- Optional app or link actions for each widget and provider-app actions for agent rows. Review remains separate.
- Fullscreen presentation, readable compact layouts, an optional Dock icon, and an always-accessible dashboard menu with Quit.
- SSH installation and updates for the companion collector, version-aware Python discovery locally and remotely, and backward-compatible observer-hook migration.

Requires Apple silicon and macOS 14 or later for the display app. The companion collector requires Python 3.10 or later on macOS or Linux. The app and DMG are Developer ID signed, notarized and stapled.

Upgrading preserves saved layouts, connected machines and collector state. Quit an older running copy before replacing the app. Update remote collectors using Machines → Install / Update over SSH. Optional observer hooks are refreshed separately and may require client restart/resume and Codex trust review.

Known boundaries: widget actions open applications on the display Mac rather than navigating to an exact agent session; blocked goals without structured provider signals require explicit registration or manual marking. The dashboard is not displayed over the macOS lock screen. Updates are installed manually from GitHub releases.
