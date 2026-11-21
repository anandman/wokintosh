# Wokintosh on your iPhone or iPad

This is initially a personal development build installed directly on iPhone or iPad (iOS/iPadOS 17+), with medium and large Home Screen Agent widgets and a full-width extra-large option on iPad. The app and extension share the portable WokintoshCore models; remote collectors keep using SSH.

The iPad app supports portrait and landscape. All widget sizes use the same pairing and session links. Extra-large uses two columns and shows up to ten sessions. On iOS/iPadOS 27+, the app also supports Apple's tall extra-large portrait family where the system offers it; Apple documents that family for Today View on iPad. WidgetKit does not offer an arbitrary full-width, double-height Home Screen size.

## Build and install

Open `iOS/WokintoshPhone.xcodeproj` in Xcode. The checked-in project is ready to use; `iOS/project.yml` is its XcodeGen source if you change targets or capabilities.

Select your Apple developer team in Signing & Capabilities for **both** WokintoshPhone and WokintoshAgentWidget. They require the same App Group (`group.dev.wokintosh.phone.shared`) and shared Keychain group. App IDs are `dev.wokintosh.phone` and `dev.wokintosh.phone.agents`. A Mac Developer ID certificate does not sign an iPhone development build; Xcode may need to create an Apple Development certificate and provisioning profiles.

Connect your iPhone or iPad mini to the Mac, trust the Mac if prompted, and enable Developer Mode on your device if Xcode requests it. Select your device as the run destination, then build/run the **WokintoshPhone** scheme. After initial pairing, Xcode may offer wireless development.

Alternatively, once Xcode signing/device setup is ready:

```sh
script/install_iphone.sh --device YOUR_DEVICE_UDID
```

The helper builds outside Dropbox, verifies the signed app, embedded widget and their matching App Group/Keychain capabilities, and installs to the explicitly chosen device. `--build-only` prepares a signed build without installing; `--dry-run` prints the operations. Override the project team using `--team YOUR_TEAM_ID` when appropriate. It never requests a password in the terminal, revokes certificates, publishes to an app store, or changes another app.

## Connect the display Mac

1. Use the Mac build containing this feature. Open **Settings → iPhone & iPad** and enable publishing.
2. Select the Agent widgets to publish. Their machine/provider/helper/finished/Done-collapse choices stay on the Mac and also control your device’s contents.
3. Follow the private Tailscale setup shown there. The dedicated route is:

   ```sh
   tailscale serve --bg --https=9443 --set-path=/wokintosh http://127.0.0.1:8787
   ```

   This uses Tailscale Serve, not Funnel, and preserves other ports/routes. If Tailscale requests HTTPS consent, finish it through its own setup page. Keep access limited to your intended tailnet devices/users. Do not replace another existing service on port 9443.
4. Paste the HTTPS `.ts.net` address shown by Tailscale into Wokintosh and save it. Wokintosh fills the dedicated port/path.
5. Show the private pairing code. In the companion app choose **Scan pairing code**. The code grants read access to selected widgets; keep it private.
6. Add the **Agents** widget using the steps below.

The display Mac and Wokintosh must remain running. The dashboard window can be closed. Your iPhone or iPad needs its Tailscale connection. There is no public relay, iCloud sync, remote command endpoint, or keep-awake change.

## Add the Home Screen widget

1. Open Wokintosh on your paired iPad and tap **Refresh** so its saved list includes the latest collector links.
2. Long-press an empty part of the Home Screen, then choose **Edit → Add Widget**.
3. Search for **Wokintosh**, choose **Agents**, and swipe to the **extra-large** size for a full-width, two-column list on iPad. Medium and large remain available. Tap **Add Widget**, then **Done**.
4. Long-press the new widget and choose **Edit Widget**. Set **Published widget** to your Mac's **Agents** widget (or the name you gave it).
5. Tap a session row to open its official app directly. Details appear only if the link is missing or cannot be opened.

These Home Screen controls follow [Apple's iPad widget instructions](https://support.apple.com/en-ie/guide/ipad/ipadb0de8630/27/ipados/27). For the tall option on iPadOS 27+, swipe right to Today View and use its widget gallery. See Apple's [extra-large](https://developer.apple.com/documentation/widgetkit/widgetfamily/systemextralarge) and [extra-large portrait](https://developer.apple.com/documentation/widgetkit/widgetfamily/systemextralargeportrait) families for platform availability. Compact sizes and larger text may show fewer rows with an overflow count. USB is unnecessary after installation. Keep Tailscale connected and Wokintosh running on the publishing Mac. Refresh timing remains controlled by iPadOS; the widget's **As of** time shows the age of its source data.

## Session links and freshness

Update the collector on each source machine to supply session links. Codex uses its normal thread UUID. Claude needs a Remote Control bridge ID from `CLAUDE_CODE_BRIDGE_SESSION_ID` in observational hook invocations (Claude Code v2.1.199+). Enable/update the observer through the existing Machines setup and review/trust it normally. Wokintosh does not enable Remote Control automatically. After connecting Remote Control, the next hook event can establish the association; a missing bridge ID stays unavailable. PID metadata is not used as a fallback.

On the initial user's iPhone, both Claude forms opened an exact existing session. The preferred target is `claude://code/{bridge-id}`, with `https://claude.ai/code/{bridge-id}` as backup. `codex://threads/{thread-id}` also opened the distinct sample-project session with the unchanged UUID; this mobile route remains an undocumented compatibility contract. The explicitly labeled backup **Open ChatGPT (new chat)** uses `https://chatgpt.com/app`; it opens ChatGPT but does not select a Codex view or session. A failed exact-session link never opens that backup automatically. Do not substitute `/c/{thread-id}`.

Rows route through the Wokintosh app into the official app without an intermediate details sheet. If the link is missing or the OS rejects it, details show the title, machine, project and state, with an explicit backup button when available. The OS accepting a link does not prove the official app resolved the right host/chat.

Widgets request updates about every 15 minutes; iOS controls the schedule and can wait longer. **As of** is based on source observation, not a new HTTP response around old data. Snapshots become stale after 30 minutes and disconnected sources show Offline immediately, including an empty list. Mixed-source widgets also mark affected rows Offline or Stale. Compact widget sizes and larger text use fewer rows with accurate overflow counts; the layout keeps the source time visible. Companion views never review Done, send prompts, approve actions, or control the source session.

Publishing consent/credentials stay out of setup exports and templates. Imported/replaced widgets require publication selection again. Stopping publishing prevents new access; a paired device can retain its last snapshot until it refreshes. Change the access key to require pairing again, or **Unpair** in the companion app to clear its credential and saved data.
