# Wokintosh 1.0.2

Fixes Calendar showing **Not connected** after launch or installation when macOS access is already granted.

- Checks Calendar authorization immediately, independently of remote-machine polling, Music and event loading.
- Refreshes source status when Settings opens, the Connections tab appears, or Wokintosh becomes active.
- Keeps delayed reads from overwriting a newer permission check and clears stale event data when access is revoked.
- Reuses existing grants. Permission requests remain confined to explicit Connect actions.

The app and DMG are Developer ID signed, notarized and stapled. Quit the running copy before installing; your dashboard and connected machines are preserved. This patch does not change the agent collector, so remote collectors already updated for 1.0.1 need no update.
