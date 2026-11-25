# Wokintosh 2.0.1

Keep temporary Codex background jobs out of the main Agents list, and see when your machines need a collector update.

- **Temporary Codex runs.** Hooks that explicitly report no persistent transcript are classified as helpers. They are hidden when Show Helpers is off, including in published iPhone/iPad widgets. Older hooks that omit this information remain supported; regular sessions are never hidden just because a title or transcript is missing.
- **Collector update notices.** Settings → Machines shows each connected machine’s collector status and an Update button when needed. A dashboard reminder opens Machines. Code fingerprints detect changes without depending on the protocol version; a newer collector is identified without recommending a downgrade. Older collectors show “version unknown” until updated.
- **Observer copies stay current.** An explicit remote Update also refreshes an existing private Wokintosh-managed status-observer copy, with a backup. It does not enable new hooks or change provider hook settings or trust. A failure to update an observer is reported separately from a successful collector installation.

## Update

Install the Mac update through Sparkle’s **Check for Updates**, then open **Settings → Machines** and update each remote collector. On any Mac running local Wokintosh observers, use **Enable / Update Codex Hooks** there as well. Reload or restart affected Codex clients if needed and review any changed commands normally in `/hooks`.

Already-saved temporary Done notices from older observers may need to be reviewed once: their saved metadata did not retain the evidence required to reclassify them. New observations with explicit nonpersistent metadata are classified automatically. Show Helpers remains available if you want to inspect these runs.

The Mac app and DMG are signed, notarized and stapled, and use the existing Sparkle signing key. Your dashboards, source settings, pairing and unread notices are preserved. Existing iPhone/iPad builds continue working; this patch does not require reinstalling them. The companion remains [self-built with Xcode](https://github.com/anandman/wokintosh/blob/v2.0.1/docs/IPHONE.md), with no prebuilt IPA or TestFlight distribution.
