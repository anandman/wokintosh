# Wokintosh 2.0.0

Your Agents widget, on your iPhone and iPad. Publish selected widgets privately from your Mac and keep Claude Code and Codex sessions close at hand.

- **Private mobile publishing.** Select Agent widgets in **Settings → iPhone & iPad**. Tailscale Serve supplies private HTTPS; a pairing code grants access. Publishing starts off, and your widget filters and attention-first ordering carry over.
- **iPhone and iPad companion.** See session titles, machines, projects and states in the app and Home Screen widgets. Medium and large widgets are joined by a full-width, two-column iPad option and a tall family where the system offers it.
- **Direct session links.** Tap a row to open its Claude Code or Codex session when the collector supplies a link. Missing or rejected links show useful details instead of opening a different conversation.
- **Shared Agent controls.** Optionally allow paired devices to review Done notices or set/clear Wokintosh's manual Blocked annotations. Changes are saved on the publishing Mac and appear on other devices when they refresh. Home Screen widgets include a Done checkmark; the app also offers long-press status controls.
- **Classic Mac styling.** The companion app and compact widget headers use Wokintosh's desktop palette and provider artwork. Widgets follow system light/dark appearance.
- **Reliable snapshots.** Stable pairing codes, coordinated app/widget storage and bounded provider artwork keep the experience consistent. As of timestamps and stale/offline indicators describe source freshness; iOS controls background refresh timing.

## Install and upgrade

The Mac app requires Apple silicon and macOS 14 or later. Download the signed, notarized and stapled DMG, or use **Check for Updates** / **Settings → Updates**. Existing dashboards, source settings and unread notices are preserved. The update uses the existing Sparkle signing key.

The iPhone/iPad app is **source-built with your own Apple Account**, using Xcode 27 or later for iOS/iPadOS 17 or later. There is no prebuilt IPA, App Store or TestFlight distribution in this release. Follow the [build and pairing guide](https://github.com/anandman/wokintosh/blob/v2.0.0/docs/IPHONE.md), then add the Agents Home Screen widget. Keep Tailscale connected on your device and Wokintosh running on the publishing Mac.

Update collectors separately through **Settings → Machines → Install / Update over SSH** to obtain session links. Claude Code needs connected Remote Control and a version exposing its bridge session ID (v2.1.199+). Codex's tested iOS thread route remains undocumented; compatibility details are in the guide.

Publishing and Agent controls are opt-in. Pairing credentials and publishing choices stay out of setup exports and templates. These controls update Wokintosh bookkeeping; they do not send prompts or approve provider actions.
