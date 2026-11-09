# Agent setup and troubleshooting

The normal remote setup is **Settings → Machines → Install / Update over SSH**. It copies the bundled collector, finds a compatible Python, verifies a snapshot and saves the connection. Use the reference below for optional lifecycle hooks, blocked-goal integration or troubleshooting.

## SSH and Python

SSH keys and host trust must already work from Terminal. Wokintosh uses batch mode and will report an error instead of asking for a password or trusting a new host. Use the same SSH alias or `user@host` you use in Terminal.

The collector requires Python 3.10 or later on macOS or Linux. Installation checks the actual version in the noninteractive SSH environment. A compatible `python3` keeps priority; otherwise it searches versioned executables in PATH, standard installation directories, Homebrew version-specific prefixes and Python.org frameworks. The installed collector is pinned to the selected absolute interpreter, without changing PATH or Python symlinks. Local collection uses the same discovery, off the UI thread. If Python was missing and you have just installed it, allow 30 seconds before retrying.

An existing collector is backed up during an update. Hooks and collector state are retained. **Connect Existing Collector** verifies an installation you already maintain. The collector-file export is an advanced fallback; it is not required for the SSH installer.

## Optional lifecycle hooks


Read-only transcript discovery works without changing agent settings. For reliable permission/input lifecycle signals, enable the optional observational hooks. The Mac app offers explicit buttons for its local harnesses; on a remote machine run:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex
~/.local/bin/wokintosh-agent install-hooks --provider claude
```

**Enable / Update Hooks** in Settings → Machines installs or refreshes clearly named Wokintosh observers. Both providers receive event-specific Wokintosh status messages, such as Working, Needs permission, and Done; commands identify Wokintosh explicitly. Existing settings are preserved and backed up. Hooks return neutral JSON and never approve, deny, block, or continue agent work. For Codex, review and trust new or changed observers in `/hooks` before they can run. Restart the client and resume existing conversations after installation to ensure observers load; no new conversation is required. Existing sessions are discovered without restarting, but earlier hook events are not replayed. See [Codex hook trust](https://learn.chatgpt.com/docs/hooks). Codex uses an existing inline `~/.codex/config.toml` hook configuration when present, otherwise `~/.codex/hooks.json`; Claude Code uses `~/.claude/settings.json`. The installer migrates its own marked JSON handlers into an existing TOML hook source. Unrelated hooks and metadata are preserved. If unrelated JSON content remains, the installer reports which handler groups/metadata remain. To consolidate them explicitly into the existing supported TOML configuration, run:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex --consolidate-sources
```

Consolidation validates the migration first and backs up the original files. Unrelated observers, matchers and settings are preserved. Unsupported or ambiguous data is refused before settings are changed. Existing Wokintosh hooks from earlier script versions are updated without adding duplicate observers; collector state is retained. Lifecycle events remain separate entries for Codex trust review. The collector stores bounded summaries in the platform's Wokintosh state directory, not full transcripts. Provider formats can change; unfamiliar or stale lifecycle state remains unknown rather than inventing progress.

The initial collector bounds discovery to recent files and caches unchanged parses. It is intended for an ambient view of active work, not a complete searchable transcript archive.

## Blocked goals

On Codex versions with a supported local goal store, the collector checks goal identities and statuses read-only on each refresh. Changes made in Codex’s UI—including deletion, completion and replacement with a new goal—are reflected without waiting for a hook. Goal objectives are not queried or stored. Update the collector on every remote machine through **Machines → Install / Update over SSH** to enable this behavior there; existing hook settings are preserved.

A missing, busy, unreadable or unfamiliar goal store is treated as unknown, so it cannot erase an unfinished goal. Explicit statuses published with `goal-status` and manual dashboard annotations remain independent. Pre-1.0.1 markers have no origin label: a matching current Codex goal can establish that association, but an old marker whose goal was already deleted is retained conservatively. If needed, clear that one obsolete collector marker with `wokintosh-agent goal-status --provider codex --session-id <session-id> --status active`; this changes Wokintosh’s cached status, not the Codex goal.


**Blocked** is an unfinished-goal state, separate from a completed turn. It stays visible beyond recent transcript history, across restarts, and while a previously connected machine is offline. Real permission/input requests take priority. The row stays compact; details are available in help/settings.

Right-click a session to **Mark Blocked**; **Clear Manual Blocked** removes only that local dashboard annotation. Agents on either Mac or Linux can publish the same durable signal for Codex or Claude Code:

```sh
wokintosh-agent goal-status --provider codex --session-id <session-id> --status blocked --title "Release testing" --project sample-project
```

Use `--provider claude` for Claude Code. Publish `--status active` or `--status complete` when the goal is unblocked. Supported Codex goal metadata and recognized successful goal-tool output supply automatic status. Clients without either source need explicit registration or manual marking; Wokintosh does not guess from final-response wording. Explicit CLI statuses are cleared by publishing `active` or `complete`. Claude idle reminders do not count as blocked or as requests for input.

## Manual collector installation

Use this only when you are managing the collector yourself instead of using Install / Update over SSH. The collector is included in the app’s DMG and the separate agent ZIP.

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 ./wokintosh-agent "$HOME/.local/bin/wokintosh-agent"
"$HOME/.local/bin/wokintosh-agent" snapshot --json
```

The default `python3` must be compatible for that last command. If it is older, invoke the script with your compatible versioned Python, or use Wokintosh’s SSH installer to pin it automatically. Then use Connect Existing Collector in Machines.

## Shared native sources

Wokintosh 1.3 can display another Mac’s Apple Music and selected Calendar events using the existing SSH connection. On the source Mac, open **Connections → Share from this Mac**. Sharing is off by default. Connect the local sources explicitly, enable the desired sharing toggles, and select the calendars allowed to leave that Mac. Keep Wokintosh running; it continues publishing with its dashboard closed. On the display Mac, update the source machine’s collector through **Machines → Install / Update**, then choose it in a Music or Calendar widget’s Content settings. Calendar authorization is needed only on the source Mac.

Now Playing includes track metadata, playback state/position and a small artwork thumbnail. Remote playback controls are read-only. Calendar sharing includes the selected calendar names and up to 256 upcoming event titles/times in the next seven days; notes, attendees, locations and event links are omitted. The receiving widget applies its own Calendar filters. Changing a Calendar widget’s machine resets its calendar selection for that source, while retaining its other display/title filters.

The source app writes a private, atomic `shared-sources.json` beside `layout.json`. Its machine-local `sharing-settings.json` is separate from the portable layout. Disabling a source removes its publication immediately. Sharing settings and cached source data are excluded from setup and template export/import. The collector reads this fixed cache path with a 1 MiB limit, requires a private user-owned regular file, and forwards only supported fields; it does not request native access or run Apple Music/EventKit itself. Anyone who can sign in with the source Mac’s SSH account can read enabled shared sources.

Protocol 1 adds optional `sharedSources` with `version: 1`, an ISO-8601 `generatedAt`, and optional `music`/`calendar` objects. Each carries `available`, `updatedAt`, and `status`. Artwork is bounded base64 image data, never a filesystem path. Existing collectors and clients continue working without these optional fields. Missing sharing or an older collector produces setup guidance. Data older than 90 seconds, or more than 30 seconds into the future, is marked stale; failed SSH connections show Offline, and retained music stops advancing. No remote source falls back to the display Mac’s native data.

Weather remains location-based and can be configured directly on the display Mac without remote publishing.

## Data, permissions and recovery

Layouts save automatically in `~/Library/Application Support/Wokintosh/layout.json`. A file that cannot be decoded is preserved as a backup before defaults are saved. Quit an older running app before opening an updated copy; this prevents two copies from saving conflicting layouts.

Music and Calendar access are requested only when you connect them. Music must be open; polling does not launch it. Local Music artwork is tried first. Optional missing-cover lookup sends the current title, artist and album to Apple’s catalog; disable it in Connections to use local artwork only. Weather uses the city chosen per widget; no device location is inferred.

Agent discovery reads local transcripts or remote collector snapshots over SSH. The collector caches bounded summaries, not full transcript bodies. Unknown evidence remains Unknown; a failed connection remains Offline. Old completed history is not imported as new Done notices on the first connection. New unreviewed completions and registered blocked goals persist across app restarts.

Widget actions open applications on the display Mac, including when a widget shows a remote machine. Agent actions open the selected provider app and do not navigate to an exact session or mark it reviewed. There is no lock-screen display. App updates are available through Sparkle in versions 1.1 and later; remote collectors are updated separately in Machines.

See the [quick start](../QUICKSTART.md), [README](../README.md), [release notes](../RELEASE_NOTES.md) and [credits](../THIRD_PARTY_NOTICES.md).


## Moving and sharing setups

In **Settings → Dashboard**, open the **(…)** menu below the widget list.
**Export Setup…** saves a JSON file for your own Macs, including widget arrangement,
content, actions, weather locations, and remote connection definitions. The export
panel identifies this personal information. SSH keys, collector state files,
transcripts, and Done/Blocked records are never bundled. Machine identity references
are included to map widget selections; the collector’s own host-id file stays on
its original machine.

On the destination Mac choose **Import Setup…**. Review the replacement widgets,
added connections, and machine mappings before importing. An explicit selection of
the exporting Mac defaults to this Mac when the local collector is available;
missing machines remain explicitly unavailable until reconnected or remapped.
Implicit All machines and This Mac selections keep their meaning. Remote definitions
merge with existing connections by SSH destination and collector path. Confirming
import allows normal read-only polling of enabled added connections; install or
update collectors and hooks separately in Machines.

Import replaces the widget layout, text size, and grid preference. The destination's
display/presentation preferences, native source permissions, machine-local sharing choices, and unread notices are
kept. Check calendar and drive selections in each widget afterward, and connect Music
and Calendar in Connections as needed. Importing does not launch configured actions.

**Export Shareable Template…** keeps the arrangement and generic display choices,
including Done-collapse preferences, while removing machine references, selected
drives, calendar IDs and title filters, weather locations, and click actions.
Recipients choose those settings after import. Calendar templates initially select
no calendars. Template files are sanitized again on import.

Before an import commits, the current layout (including unsaved changes) is backed
up as a uniquely named `layout-backup-<date>-<id>.json` in the Wokintosh data folder.
The success screen offers **Show Backup in Finder**. To restore one, quit Wokintosh,
keep a copy of the current `layout.json`, copy the backup to `layout.json`, and reopen
the app. A backup or write failure leaves the current dashboard in place.

For a manual transfer, quit both copies and copy only `layout.json` between the
Wokintosh data folders, after backing up the destination file. This also copies
notification state and machine-specific display selections. Keep the collector
folder on its own machine: its host identity must stay unique.

## Earlier Done notices

Agent widget Content settings offer **Collapse Done after**: Until reviewed
(the default), 15 minutes, 1 hour, 4 hours, or 1 day. The timer starts when this
Mac first observes a completed turn, so a late-arriving remote completion gets its
full visibility interval. Existing pending notices begin their interval on the
first refresh after upgrading. The local observation time survives restarts.

Collapsed notices remain unread in **Earlier Done · N unread** and still count
in the widget's Done total. Open the list from the dashboard footer or
**Show Earlier Done…** in Content settings. Use a notice's Review button, or
**Review All Earlier Done**, to acknowledge it. Opening its configured app or link
keeps it unread. The dashboard's **Review Done** control reviews all matching Done
notices, including earlier ones. All controls respect the widget's machine,
provider, and helper-agent filters.

Collapse affects only pending Done rows; Needs You, Working, and Blocked stay in
the main list. Turning on recent inactive sessions does not bring collapsed unread
rows back into the main list. Change the timeout to Until reviewed to show them
there again. The dashboard tracks reminders and opens configured applications;
it does not display the original agent output or navigate to an exact session.

## System reading labels

CPU, RAM, and drive readings have distinct icons and gauge accents. The root
filesystem is labeled **Startup disk**; other drives keep their volume names.
Values identify RAM used and drive space free. All gauges show utilization;
hover for the used percentage and drive details. Missing readings remain unavailable.

System readings adapt their row/column arrangement to each widget’s dimensions and measured labels. Wide widgets can wrap complete headings; long drive names use a compact grid, and portrait widgets spread stacked readings across the available height. Larger text and unavailable sources retain separate, visible status and overflow space.
