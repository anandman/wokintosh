# Wokintosh 2.0.4

Background work now has a lifecycle of its own, with shared controls for persistent monitors on Mac, iPhone and iPad.

- **Background jobs stay Working.** Claude and Codex task evidence is tracked separately from the foreground response. A response ending no longer means that its finite background jobs have finished. Helpers contribute to their parent session even when helper rows are hidden; permission and input requests still take precedence.
- **Monitoring stays visible below Working.** Explicit provider monitors, or runners you designate as monitors, use the neutral Monitoring state between active turns. They remain visible with inactive sessions hidden and do not inflate the Working count.
- **Choose a role for each runner.** Right-click a session on Mac, or long-press it in the iPhone/iPad app, then choose Background Tasks… and Automatic, Work or Monitor. The display Mac saves these choices and shares the resulting state with paired devices. Normal session taps still open Claude or Codex immediately. Home Screen widgets display the shared status and retain their Done review action.
- **Linux process verification.** Use portable `fuser` arguments to verify live output writers on Linux. Missing or inaccessible process evidence remains unverified.
- **Reliable completion notices.** Duplicate task notifications do not recreate a reviewed Done notice. Task-ID reuse, incomplete inventories, stale mobile actions and legacy observer timestamps are handled conservatively. Missing activity evidence shows Unknown instead of inventing a completion. A task that leaves a complete provider registry has an unspecified Ended outcome unless the provider reports more detail.

Install the signed, notarized Mac update through Sparkle’s **Check for Updates**, then use **Settings → Machines → Update** for affected collectors and managed observers. Version 2.0.4 includes changed collector code. Older collectors remain compatible but cannot supply the new task details.

Update the source-built iPhone/iPad companion to 2.0.4 (build 21) for the new controls and Monitoring labels. These require the publishing Mac’s existing **Allow Agent controls** setting. Runner choices apply to the current task run and stay out of setup exports. They do not start, stop or approve provider work.

Codex currently uses recorded command and task events; Wokintosh does not attach a second server to infer the state of existing terminals. Known tasks whose activity cannot be verified are shown as Unknown. Widget refreshes remain scheduled by iOS/iPadOS, with the source time shown.
