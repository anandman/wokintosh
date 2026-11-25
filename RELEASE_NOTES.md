# Wokintosh 2.1

Antigravity App/CLI and OpenCode App/CLI join the Agent dashboard as **Untested integrations**. Their adapters have automated fixture coverage, but neither has been verified end to end with a live provider session. Antigravity standalone IDE is excluded.

- **Additional provider collection.** Antigravity uses documented lifecycle hooks and bounded App/CLI discovery. OpenCode uses a V2 server plugin shared by App and CLI, forwarding selected session metadata. Missing, stale or incomplete evidence stays Unknown rather than inventing a successful completion.
- **Official logos everywhere.** Mac, iPhone, iPad and Home Screen widgets use the official Antigravity and OpenCode marks. OpenCode has a matching dark-mode variant; widget artwork retains the small raster budget used by the existing provider icons.
- **Familiar controls.** Provider filters and local app choices include the new providers. Done review and manual Blocked controls continue to sync through the publishing Mac. Settings, mobile rows, widgets and session details identify the new integrations as Untested.
- **Explicit mobile navigation.** Configure a captured, verified HTTPS session link on the source machine. Wokintosh leaves unavailable links empty and explains the setup in session details. It does not invent app schemes, infer an Antigravity Remote Control instance ID, start provider services or expose a new network endpoint.

Install the signed, notarized Mac update through Sparkle’s **Check for Updates**, then use **Settings → Machines → Update All** for changed collectors and existing managed observers. Enable a new provider’s observer on each source machine only when you want to use it. Machines’ observer buttons affect This Mac; remote hosts use the collector’s installation command.

The iPhone/iPad companion is version **2.1.0 (build 23)**. Update it for the new provider branding and guidance. Existing Claude/Codex sessions remain compatible. Publishing, pairing and shared controls keep their existing opt-in settings.

See [additional-provider setup and limitations](https://github.com/anandman/wokintosh/blob/v2.1.0/docs/PROVIDERS.md), including the current OpenCode V2 requirements and explicitly unverified behavior. Provider observation does not submit prompts or grant approvals.
