# Wokintosh

A Color Classic-style dashboard for a small Mac display. Arrange independently resizable widgets for individual Codex and Claude Code sessions, Apple Music, system status, clock, weather, and calendar.

## Install on the display Mac

1. Move **Wokintosh.app** to Applications and open it. Requires an Apple silicon Mac running macOS 14 or later.
2. Click **Wokintosh** in the dashboard menu bar, or press **Command-comma**, to open the Layout Editor.
3. Choose the dock's display and click **Present on Display**. Presentation mode and display selection are remembered. **Escape** returns to a normal window.
4. Add widgets from the library. Move each by its title bar; resize with its purple corner or enter dimensions in the inspector. Widgets adapt the detail and row count to their dimensions. Text size and a calibrated actual-size preview help judge a five-inch panel.

Layouts are saved automatically in `~/Library/Application Support/Wokintosh/layout.json`. If a saved file cannot be read, the app shows defaults and preserves the original as a backup before saving changes. Removing a widget does not delete any source data.

**Sample data** is an explicit editor option and is labeled **PREVIEW** on the dashboard. Turn it off to see live sources. It does not represent your actual sessions, calendar, weather, music or machine readings.

## Agent machines: macOS and Linux

The companion collector is a Python 3.10+ command-line program using only the standard library. It does not need a GUI, web server, API key, or an open network port. The dashboard polls remote collectors over your existing SSH connection.

Install the supplied collector on each agent machine:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 ./wokintosh-agent "$HOME/.local/bin/wokintosh-agent"
"$HOME/.local/bin/wokintosh-agent" snapshot --json
```

In **Machines & Live Sources**, add a friendly name, an SSH alias or `user@host`, and the collector path (default `~/.local/bin/wokintosh-agent`). SSH keys and host trust must already work from Terminal; the dashboard uses batch mode and will show a connection error rather than ask for a password. Local collection also needs Python 3.10+; Homebrew and standard Python installation paths are detected.

Each row is a distinct session/task, including multiple sessions of the same harness on one machine. The widget can filter by machine and harness, include recent finished sessions and helper agents, and sort sessions needing attention first. Overflow is always visible. Unknown or disconnected state is shown explicitly; bars are used only for measured system readings.

### Precise attention signals

Read-only transcript discovery works without changing agent settings. For reliable permission/input lifecycle signals, enable the optional observational hooks. The Mac app offers explicit buttons for its local harnesses; on a remote machine run:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex
~/.local/bin/wokintosh-agent install-hooks --provider claude
```

Existing settings are preserved and backed up. Hooks return neutral JSON and never approve, deny, block, or continue agent work. Restart agent sessions after installation so they load the observers. Codex uses `~/.codex/hooks.json`; Claude Code uses `~/.claude/settings.json`. The collector stores bounded summaries in the platform's Wokintosh state directory, not full transcripts. Provider formats can change; unfamiliar or stale lifecycle state remains unknown rather than inventing progress.

The initial collector bounds discovery to recent files and caches unchanged parses. It is intended for an ambient view of active work, not a complete searchable transcript archive.

## Personal widgets

- **Apple Music:** click **Connect Apple Music** while Music is running and grant macOS automation access. Wokintosh reads the actual track and color artwork. Polling does not launch Music. Playback buttons control Music only when clicked.
- **Calendar:** click **Enable Calendar** and grant EventKit access. Upcoming events are read locally. Permission is never requested just by launching Wokintosh.
- **Weather:** search for an explicit city in source settings and choose Celsius or Fahrenheit. No device location is inferred. Weather is provided by [Open-Meteo](https://open-meteo.com/); place search uses [GeoNames](https://www.geonames.org/). See [Open-Meteo terms and attribution](https://open-meteo.com/en/terms). Cached weather is marked offline when refresh fails.
- **System:** select this Mac or a connected agent machine. CPU, memory and storage are measured by the collector. Unavailable readings remain blank rather than simulated.
- **Clock:** follows the Mac's locale and time settings. A menu-bar clock remains visible independently of the optional clock widget.

This is a locally signed development build, not an App Store/notarized release. No account or telemetry service is included. Physical legibility should be checked on the actual Wokyis panel at your usual viewing distance; its native resolution is 1280×720.
