# Wokintosh quick start

Requires an Apple silicon Mac with macOS 14 or later. Agent machines may run macOS or Linux with Python 3.10 or later and SSH.

1. Drag **Wokintosh.app** to **Applications**. Quit any older running copy, then open the installed app. Upgrading preserves your dashboard and connected machines.
2. Click the Mac at the top right, or press **Command-comma**, to open **Dashboard & Settings**.
3. In **Dashboard**, add widgets, choose their **Content / Layout / Actions**, and drag their title bars or resize corners in the preview. Changes save automatically.
4. In **Connections**, connect Apple Music and Calendar if desired. macOS asks permission only when you connect. Choose weather locations and calendars per widget in Content.
5. In **Machines**, add an SSH alias or user@host and select **Install / Update over SSH**. SSH keys and host trust must already work in Terminal. Installation finds a compatible Python without changing the system default. Existing hooks and collector state are preserved.
6. In **Display**, select the Wokyis screen and **Present on Display**. Adjust text size as needed. Escape leaves presentation; Command-comma opens settings. You can hide the Dock icon; the six-color square menu still offers **Quit Wokintosh**.

Done agents stay highlighted until you use their separate Review control. Right-click an unfinished session to mark it Blocked. Widget click actions are optional; they open apps on this Mac, including for remote-machine widgets.

For manual agent installation, use the supplied **wokintosh-agent** and Python 3.10+. Optional status hooks are enabled separately on each machine:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex
~/.local/bin/wokintosh-agent install-hooks --provider claude
```

Restart/resume the corresponding client after installing or updating hooks and review changed Codex observers in `/hooks`. No new conversation is required. See README.md for manual installation, migration, blocked goals, troubleshooting, privacy details and all configuration options.

The display app is Developer ID signed and notarized. No account or telemetry service is included. Weather requests use your chosen city; missing-cover catalog lookup sends the current title, artist and album to Apple and can be disabled in Connections. Calendar events and agent summaries remain local or travel over your SSH connection.
