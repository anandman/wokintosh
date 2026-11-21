# Wokintosh on your iPhone

This is initially a personal development build installed directly, with medium and large home-screen Agent widgets. The app and extension share the portable WokintoshCore models; remote collectors keep using SSH.

## Build and install

Open `iOS/WokintoshPhone.xcodeproj` in Xcode. The checked-in project is ready to use; `iOS/project.yml` is its XcodeGen source if you change targets or capabilities.

Select your Apple developer team in Signing & Capabilities for **both** WokintoshPhone and WokintoshAgentWidget. They require the same App Group (`group.dev.wokintosh.phone.shared`) and shared Keychain group. App IDs are `dev.wokintosh.phone` and `dev.wokintosh.phone.agents`. A Mac Developer ID certificate does not sign an iPhone development build; Xcode may need to create an Apple Development certificate and provisioning profiles.

Connect your iPhone to the Mac, trust the Mac if prompted, and enable Developer Mode on the phone if Xcode requests it. Select the iPhone as the run destination, then build/run the **WokintoshPhone** scheme. After initial pairing, Xcode may offer wireless development.

Alternatively, once Xcode signing/device setup is ready:

```sh
script/install_iphone.sh --device YOUR_IPHONE_UDID
```

The helper builds outside Dropbox, verifies the signed app, embedded widget and their matching App Group/Keychain capabilities, and installs to the explicitly chosen device. `--build-only` prepares a signed build without installing; `--dry-run` prints the operations. Override the project team using `--team YOUR_TEAM_ID` when appropriate. It never requests a password in the terminal, revokes certificates, publishes to an app store, or changes another app.

## Connect the display Mac

1. Use the Mac build containing this feature. Open **Settings → iPhone** and enable publishing.
2. Select the Agent widgets to publish. Their machine/provider/helper/finished/Done-collapse choices stay on the Mac and also control the phone's contents.
3. Follow the private Tailscale setup shown there. The dedicated route is:

   ```sh
   tailscale serve --bg --https=9443 --set-path=/wokintosh http://127.0.0.1:8787
   ```

   This uses Tailscale Serve, not Funnel, and preserves other ports/routes. If Tailscale requests HTTPS consent, finish it through its own setup page. Keep access limited to your intended tailnet devices/users. Do not replace another existing service on port 9443.
4. Paste the HTTPS `.ts.net` address shown by Tailscale into Wokintosh and save it. Wokintosh fills the dedicated port/path.
5. Show the private pairing code. In the iPhone app choose **Scan pairing code**. The code grants read access to selected widgets; keep it private.
6. Add a Wokintosh **Agents** widget to your Home Screen. Long-press/edit the widget to choose a published Agent widget.

The display Mac and Wokintosh must remain running. The dashboard window can be closed. The phone needs its Tailscale connection. There is no public relay, iCloud sync, remote command endpoint, or keep-awake change.

## Session links and freshness

Update the collector on each source machine to supply session links. Codex uses its normal thread UUID. Claude needs a Remote Control bridge ID from `CLAUDE_CODE_BRIDGE_SESSION_ID` in observational hook invocations (Claude Code v2.1.199+). Enable/update the observer through the existing Machines setup and review/trust it normally. Wokintosh does not enable Remote Control automatically. After connecting Remote Control, the next hook event can establish the association; a missing bridge ID stays unavailable. PID metadata is not used as a fallback.

On the initial user's iPhone, both Claude forms opened an exact existing session. The preferred target is `claude://code/{bridge-id}`, with `https://claude.ai/code/{bridge-id}` as backup. `codex://threads/{thread-id}` also opened the distinct sample-project session with the unchanged UUID; this mobile route remains an undocumented compatibility contract. The explicitly labeled backup **Open ChatGPT (new chat)** uses `https://chatgpt.com/app`; it opens ChatGPT but does not select a Codex view or session. A failed exact-session link never opens that backup automatically. Do not substitute `/c/{thread-id}`.

Rows route through the Wokintosh app into the official app. The OS accepting a link does not prove the official app resolved the right host/chat; use the session detail's backup link when needed. A missing link still shows title, machine, project and state.

Widgets request updates about every 15 minutes; iOS controls the schedule and can wait longer. **As of** is based on source observation, not a new HTTP response around old data. Snapshots become stale after 30 minutes and disconnected sources show Offline immediately, including an empty list. Mixed-source widgets also mark affected rows Offline or Stale. Larger text uses fewer rows with accurate overflow counts. Phone views never review Done, send prompts, approve actions, or control the source session.

Publishing consent/credentials stay out of setup exports and templates. Imported/replaced widgets require publication selection again. Stopping publishing prevents new access; a phone can retain its last snapshot until it refreshes. Change the access key to require pairing again, or **Unpair** in the phone app to clear its credential and saved data.
