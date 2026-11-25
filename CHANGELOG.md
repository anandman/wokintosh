# Changelog

## 2.1.1 — 2026-11-25

- Stop historical Claude helper errors and unfinished observations from overriding a newer complete task inventory. Preserve confirmed helper completions and newer requests for input.
- Exclude explicitly identified internal Codex Guardian reviews from project background work, preventing metadata-only reviews from leaving completed sessions Unknown.
- Support Claude's session-specific task-output directories when verifying that quiet background work is still running. Continue supporting the older directory layout and require positive writer evidence.
- The iPhone/iPad companion is unchanged from 2.1.0; corrected states arrive through the publishing Mac after its collectors update.

## 2.1.0 — 2026-11-24

- Add Antigravity App/CLI and OpenCode App/CLI as explicitly Untested integrations, with fixture-tested metadata collection, observational installation and conservative state handling. Antigravity IDE is excluded.
- Add official Antigravity/OpenCode logos across Mac, iPhone, iPad and widgets, including the dark OpenCode mark for dark widgets.
- Extend provider filters, per-provider app choices, names, accessibility and shared Done/Blocked controls. New-provider mobile links are optional and require explicit verified HTTPS configuration.
- Include the additional-provider setup and limitations guide in release packages. Neither integration has live-provider end-to-end verification.


## 2.0.5 — 2026-11-24

- Add Update All in Machines for pending collector and existing local status-observer updates, processed one machine at a time.
- Show live update stages beside each machine and above the list, with waiting states and persistent success, warning and failure results. Batch updates continue after a machine fails.
- Collector code and the iPhone/iPad companion are unchanged from 2.0.4.

## 2.0.4 — 2026-11-24

- Use compatible Linux process-probe arguments so positive writer evidence can keep quiet background jobs Working.
- Track Claude and Codex background-task lifecycles separately from foreground responses, keeping finite background work from becoming false Done notices. Missing or stale evidence is reported as unverified.
- Add per-runner Automatic, Work and Monitor controls through the Mac right-click and mobile app long-press menus. Choices are shared by the publishing Mac and excluded from setup exports.
- Show Monitoring below Working on the Mac, iPhone/iPad app and widgets, including when inactive sessions are hidden. Monitor lifecycle updates do not create repeated Done notices.

## 2.0.2 — 2026-11-24

- Add a native collector-update popup with Review Updates and Later. Reminders cover remote collectors and local managed observers, and acknowledged updates stay quiet across refreshes and app relaunches.
- Make System readings visually distinct with larger icons, bold colored labels and values, matching tinted backgrounds, and prominent USED/FREE qualifiers. RAM stays in GB.
- Collector code is unchanged from 2.0.1; existing current collectors and iPhone/iPad builds do not need reinstalling.

## 2.0.1 — 2026-11-24

- Classify Codex’s explicitly nonpersistent hook sessions as helpers, so temporary suggestion and safety jobs respect the existing Show Helpers setting. Missing transcript metadata remains compatible with older hooks.
- Show collector and observer update notices in Machines, with a dashboard shortcut. Compare code fingerprints while preserving protocol-v1 compatibility and avoid recommending downgrades of newer collectors.
- Refresh an existing private Wokintosh-managed observer copy during an explicit remote collector update, with backup and atomic replacement. Provider hook configuration, trust and session state stay intact.

## 2.0.0 — 2026-11-22

- Add a universal iPhone and iPad companion app with Agent widgets, including full-width iPad layouts and the tall family where the system offers it.
- Publish selected Agent widgets privately through Tailscale HTTPS, with pairing, matching desktop filters and ordering, and original source timestamps and stale/offline states.
- Open Claude Code and Codex sessions using collector-supplied links, with clear handling when a session has no direct link.
- Sync reviewed Done notices and manual Blocked annotations with the publishing Mac. Agent controls are optional; provider sessions remain observational.
- Bring the desktop’s classic Mac styling and provider artwork to the companion app and widgets, while preserving automatic dark appearance in widgets.
- Keep pairing codes stable across refreshes, coordinate app/widget cache and action changes, and size provider images for reliable WidgetKit rendering. Publishing settings and credentials stay out of setup exports and templates.

## 1.3.1

Released: consistent, readable System widget layouts across machines. See the [1.3.1 release notes](https://github.com/anandman/wokintosh/releases/tag/v1.3.1).
