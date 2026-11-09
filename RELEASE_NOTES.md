# Wokintosh 1.3.0

Bring another Mac’s music and selected calendars to your dashboard, with System widgets that adapt to their shape.

- **Remote Now Playing:** choose a Mac in a Now Playing widget to display its Apple Music track, artist, artwork and playback state over the existing SSH connection. Remote sources are read-only; playback controls remain available for This Mac.
- **Remote Calendar:** show selected calendars from another Mac without enabling Calendar access on the display Mac. The source Mac shares only calendars you select, including upcoming titles and times; notes, attendees, locations and links stay there.
- **Explicit sharing:** enable sources in **Connections → Share from this Mac** on the source Mac. Sharing defaults off, Calendar starts with no selections, and these choices stay on that Mac rather than traveling with exported setups or templates. Keep Wokintosh running there; its dashboard can be closed.
- **Clear source status:** widget title bars name the remote machine. Stale and offline readings are labeled, retained music stops advancing, and an unavailable selected source never falls back to local data.
- **Responsive System widgets:** tall widgets distribute readings vertically; wide widgets wrap complete headings; longer drive names reflow into compact grids. Gauges, overflow and disconnected-source status keep their own space at larger text sizes.

To use remote Music or Calendar, install Wokintosh 1.3 on the source Mac, enable sharing there, then **Install / Update** that machine’s collector in the display Mac’s Machines settings. Choose the machine in each widget’s **Content → Machine** setting. Existing agents and System collection remain compatible; collectors need updating for the new shared sources. Weather continues using each widget’s chosen location.

Wokintosh 1.1 and later can update through Sparkle. Earlier versions require a manual installation. Existing layouts, permissions, connected machines and unread notices are preserved. Sharing remains off until explicitly enabled. Anyone using your SSH account on the source Mac can read enabled shared sources.

The app and DMG are Developer ID signed, notarized and stapled. The Sparkle feed and download use Wokintosh’s existing update key.
