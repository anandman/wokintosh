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


**Blocked** is an unfinished-goal state, separate from a completed turn. It stays visible beyond recent transcript history, across restarts, and while a previously connected machine is offline. Real permission/input requests take priority. The row stays compact; details are available in help/settings.

Right-click a session to **Mark Blocked**; **Clear Manual Blocked** removes only that local dashboard annotation. Agents on either Mac or Linux can publish the same durable signal for Codex or Claude Code:

```sh
wokintosh-agent goal-status --provider codex --session-id <session-id> --status blocked --title "Release testing" --project sample-project
```

Use `--provider claude` for Claude Code. Publish `--status active` or `--status complete` when the goal is unblocked. Recognized successful direct Codex goal-tool output can supply this automatically when exposed by the client. Existing historical goals and clients without structured goal output need explicit registration or manual marking; Wokintosh does not guess from final-response wording. Claude idle reminders do not count as blocked or as requests for input.

## Manual collector installation

Use this only when you are managing the collector yourself instead of using Install / Update over SSH. The collector is included in the app’s DMG and the separate agent ZIP.

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 ./wokintosh-agent "$HOME/.local/bin/wokintosh-agent"
"$HOME/.local/bin/wokintosh-agent" snapshot --json
```

The default `python3` must be compatible for that last command. If it is older, invoke the script with your compatible versioned Python, or use Wokintosh’s SSH installer to pin it automatically. Then use Connect Existing Collector in Machines.

## Data, permissions and recovery

Layouts save automatically in `~/Library/Application Support/Wokintosh/layout.json`. A file that cannot be decoded is preserved as a backup before defaults are saved. Quit an older running app before opening an updated copy; this prevents two copies from saving conflicting layouts.

Music and Calendar access are requested only when you connect them. Music must be open; polling does not launch it. Local Music artwork is tried first. Optional missing-cover lookup sends the current title, artist and album to Apple’s catalog; disable it in Connections to use local artwork only. Weather uses the city chosen per widget; no device location is inferred.

Agent discovery reads local transcripts or remote collector snapshots over SSH. The collector caches bounded summaries, not full transcript bodies. Unknown evidence remains Unknown; a failed connection remains Offline. Old completed history is not imported as new Done notices on the first connection. New unreviewed completions and registered blocked goals persist across app restarts.

Widget actions open applications on the display Mac, including when a widget shows a remote machine. Agent actions open the selected provider app and do not navigate to an exact session or mark it reviewed. There is no lock-screen display or automatic app updater in 1.0.

See the [quick start](../QUICKSTART.md), [README](../README.md), [release notes](../RELEASE_NOTES.md) and [credits](../THIRD_PARTY_NOTICES.md).
