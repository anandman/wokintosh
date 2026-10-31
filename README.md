# Wokintosh

A Color Classic-style dashboard for a small Mac display. Arrange independently resizable widgets for individual Codex and Claude Code sessions, Apple Music, system status, clock, weather, and calendar.

## Install on the display Mac

1. Move **Wokintosh.app** to Applications and open it. Requires an Apple silicon Mac running macOS 14 or later.
2. Press **Command-comma** to open Settings. Use its **Widgets**, **Connections**, **Machines**, **Appearance**, and **Display** tabs. Click **Wokintosh** in the dashboard menu bar, or press **Command-Shift-L**, to open the Layout Editor.
3. In **Settings → Display**, choose the dock's display and click **Present on Display**. Native fullscreen hides the macOS menu bar and Dock; disable **Use native fullscreen** for a borderless window instead. Presentation mode and display selection are remembered. **Escape** returns to a normal window.
4. Add widgets from the library. Move each by its title bar; resize with its purple corner or enter dimensions in **Settings → Widgets → Layout**. Optional 16-pixel snapping keeps edges aligned. The close box removes a widget; the right title control and the same Configure context menu on preview/sidebar open that widget in Settings. Content choices are on **Content**; position and size are on **Layout**. Widgets adapt the detail and row count to their dimensions. Text size and a calibrated actual-size preview help judge a five-inch panel.

Layouts are saved automatically in `~/Library/Application Support/Wokintosh/layout.json`. If a saved file cannot be read, the app shows defaults and preserves the original as a backup before saving changes. Removing a widget does not delete any source data.

**Sample data** is an explicit **Settings → Appearance** option and is labeled **PREVIEW** on the dashboard. Turn it off to see live sources. It does not represent your actual sessions, calendar, weather, music or machine readings.

## Agent machines: macOS and Linux

The companion collector is a Python 3.10+ command-line program using only the standard library. It does not need a GUI, web server, API key, or an open network port. The dashboard polls remote collectors over your existing SSH connection.

Install the supplied collector on each agent machine:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 ./wokintosh-agent "$HOME/.local/bin/wokintosh-agent"
"$HOME/.local/bin/wokintosh-agent" snapshot --json
```

In **Settings → Machines**, add a friendly name, an SSH alias or `user@host`, and the collector path (default `~/.local/bin/wokintosh-agent`). SSH keys and host trust must already work from Terminal; the dashboard uses batch mode and will show a connection error rather than ask for a password. Local collection also needs Python 3.10+; Homebrew and standard Python installation paths are detected.

Each row is a distinct session/task, including multiple sessions of the same harness on one machine. The widget can filter by machine and harness and optionally include reviewed/recent inactive sessions and helper agents. Sessions needing attention come first; completed work stays highlighted **Done** until you mark it reviewed using its **Review** button, or the widget header’s check control to mark all Done as reviewed. These controls are available on the dashboard itself. Done notices survive restarting Wokintosh; new activity supersedes the previous completion. First connection establishes a baseline and does not import old completed history. New completions after that baseline are shown, including work finishing while Wokintosh is closed. Already-unreviewed notices from an earlier version remain until reviewed. Helper agents, including internal review assistants, are hidden by default and labeled Helper when included. Overflow is always visible. Unknown or disconnected state is shown explicitly; bars are used only for measured system readings.

### Precise attention signals

Read-only transcript discovery works without changing agent settings. For reliable permission/input lifecycle signals, enable the optional observational hooks. The Mac app offers explicit buttons for its local harnesses; on a remote machine run:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex
~/.local/bin/wokintosh-agent install-hooks --provider claude
```

**Enable / Update Hooks** in Settings → Machines installs or refreshes clearly named Wokintosh observers. Both providers receive event-specific Wokintosh status messages, such as Working, Needs permission, and Done; commands identify Wokintosh explicitly. Existing settings are preserved and backed up. Hooks return neutral JSON and never approve, deny, block, or continue agent work. For Codex, review and trust new or changed observers in `/hooks` before they can run. Restart the client and resume existing conversations after installation to ensure observers load; no new conversation is required. Existing sessions are discovered without restarting, but earlier hook events are not replayed. See [Codex hook trust](https://learn.chatgpt.com/docs/hooks). Codex uses an existing inline `~/.codex/config.toml` hook configuration when present, otherwise `~/.codex/hooks.json`; Claude Code uses `~/.claude/settings.json`. The installer migrates its own marked JSON handlers into an existing TOML hook source. Unrelated hooks and metadata are preserved. If unrelated JSON content remains, the installer reports the remaining dual-source conflict; unsupported TOML forms are refused before settings are changed. Lifecycle events remain separate entries for Codex trust review. The collector stores bounded summaries in the platform's Wokintosh state directory, not full transcripts. Provider formats can change; unfamiliar or stale lifecycle state remains unknown rather than inventing progress.

The initial collector bounds discovery to recent files and caches unchanged parses. It is intended for an ambient view of active work, not a complete searchable transcript archive.

## Personal widgets

- **Apple Music:** in **Settings → Connections**, click **Connect Apple Music** while Music is running and grant macOS automation access. Wokintosh reads the actual track and color artwork. Polling does not launch Music. Playback buttons control Music only when clicked. Connected access is shown separately from playback. A closed Music app has unverified access rather than a false denial; disabling reads clears the displayed track.
- **Calendar:** in **Settings → Connections**, click **Connect Calendar** and grant EventKit access. Upcoming events are read locally. In **Settings → Widgets → Content**, choose individual calendars (with account/source labels), include or exclude all-day events, and select **Only next event**. For a personal + work timed-event view, select those two calendars and turn all-day events off. Filtering happens before the event limit. Generic same-time mirrors such as “Blocked Time” yield to a selected event with a real title; standalone blocks remain. Add title phrases (one per line, case insensitive) to hide other unwanted events for that widget. Permission is never requested just by launching Wokintosh.
- **Weather:** select the Weather widget in **Settings → Widgets → Content** to search for an explicit city and choose Celsius or Fahrenheit. Each Weather widget has its own location and units. Existing widgets retain the previous shared choice on upgrade; new widgets start unconfigured. No device location is inferred. Weather is provided by [Open-Meteo](https://open-meteo.com/); place search uses [GeoNames](https://www.geonames.org/). See [Open-Meteo terms and attribution](https://open-meteo.com/en/terms). The widget’s Configure button opens its own Content settings. Cached weather is marked offline when refresh fails.
- **System:** select this Mac or a connected agent machine. Choose CPU, memory and individual mounted drives in **Settings → Widgets → Content**. Multiple drives can be shown together; enlarge the widget to reveal additional readings. CPU, memory and storage are measured by the collector. Update remote collectors for drive inventory; older collectors still supply their original disk reading. Drive selections identify mount points; a missing selected mount shows unavailable data. Usage gauges stay visible in compact layouts; unavailable readings show a dash. CPU uses host counter deltas, with the first sample unavailable until a second poll supplies an interval.
- **Clock:** follows the Mac's locale and time settings. A menu-bar clock remains visible independently of the optional clock widget.

This is a locally signed development build, not an App Store/notarized release. No account or telemetry service is included. Physical legibility should be checked on the actual Wokyis panel at your usual viewing distance; its native resolution is 1280×720.
