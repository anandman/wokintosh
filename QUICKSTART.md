# Wokintosh quick start

Tested on the [Wokyis M5 (10Gbps) retro docking station](https://wokyis.com/products/wokyis-m5-10gbps) with its 5-inch 1280 × 720 display.

Requires an Apple silicon Mac with macOS 14 or later. Agent machines may run macOS or Linux with Python 3.10 or later and SSH.

1. Drag **Wokintosh.app** to **Applications**. Quit any older running copy, then open the installed app. Upgrading preserves your dashboard and connected machines.
2. Click the Mac at the top right, or press **Command-comma**, to open **Dashboard & Settings**.
3. In **Dashboard**, add widgets, choose their **Content / Layout / Actions**, and drag their title bars or resize corners in the preview. Changes save automatically.
4. In **Connections**, connect Apple Music and Calendar if desired. macOS asks permission only when you connect. Choose weather locations and calendars per widget in Content.
5. In **Machines**, add an SSH alias or user@host and select **Install / Update over SSH**. SSH keys and host trust must already work in Terminal. Installation finds a compatible Python without changing the system default. Existing hooks and collector state are preserved.
6. In **Display**, select the Wokyis screen and **Present on Display**. Adjust text size as needed. Escape leaves presentation; Command-comma opens settings. You can hide the Dock icon; the six-color square menu still offers **Quit Wokintosh**.

To show another Mac’s music or calendar, install Wokintosh 1.3 there and enable **Connections → Share from this Mac**. Select the calendars to share; none are selected initially. Keep Wokintosh running there. On the display Mac, update that machine’s collector in **Machines**, then choose it in the widget’s **Content → Machine** setting. Remote sources are read-only; local Calendar access is unnecessary. Sharing choices are never imported or exported with a setup.

Done agents stay unread until you use their separate Review control. In an Agent widget’s Content settings, **Collapse Done after** optionally moves older notices into **Earlier Done**; open that list to review them later. Right-click an unfinished session to mark it Blocked. Widget click actions are optional; they open apps on this Mac, including for remote-machine widgets.

To move a setup between Macs, open **Dashboard → (…) → Export Setup…** and use **Import Setup…** on the destination. Import reviews machine selections and saves a backup. Use **Export Shareable Template…** for a reusable layout that omits personal settings.

For manual agent installation, use the supplied **wokintosh-agent** and Python 3.10+. Optional status hooks are enabled separately on each machine:

```sh
~/.local/bin/wokintosh-agent install-hooks --provider codex
~/.local/bin/wokintosh-agent install-hooks --provider claude
```

Restart/resume the corresponding client after installing or updating hooks and review changed Codex observers in `/hooks`. No new conversation is required. See README.md for manual installation, migration, blocked goals, troubleshooting, privacy details and all configuration options.

The display app is Developer ID signed and notarized. No account or telemetry service is included. Weather requests use your chosen city; missing-cover catalog lookup sends the current title, artist and album to Apple and can be disabled in Connections. Calendar events and agent summaries remain local or travel over your SSH connection.
