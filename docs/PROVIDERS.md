# Additional providers in Wokintosh 2.1

Antigravity App/CLI and OpenCode App/CLI are **Untested** integrations. Their adapters and installer behavior have fixture coverage, including executing the generated OpenCode bridge against the collector. Neither provider has been verified with a live session. Antigravity standalone IDE is excluded. Claude and Codex keep their existing collection behavior.

## Setup

On this Mac, use **Settings → Machines → Observers on This Mac → Enable / Update [provider] (Untested) Observer…**. These buttons affect only the local source. For a remote source, run the equivalent commands on that observed host:

```sh
wokintosh-agent install-hooks --provider antigravity --dry-run
wokintosh-agent install-hooks --provider antigravity
wokintosh-agent install-hooks --provider opencode --dry-run
wokintosh-agent install-hooks --provider opencode
```

Use the installed `wokintosh-agent` or `python3 /absolute/path/wokintosh_agent.py`. Global `--home` and `--state-dir` arguments go before the subcommand. Run installation on each observed host. Do not point an observer on one host at a different host's provider data.

Installation is explicit. Snapshot collection never installs hooks/plugins, starts a provider, starts a server, changes approval rules, or enables remote access. Absent installations produce no provider rows or errors. Existing changed files receive a `.wokintosh-backup-<timestamp>` sibling before replacement; unchanged repeated installations create no additional backups. Dry runs perform no writes. Unsafe paths, symlinks, malformed/oversized configuration, and occupied observer names are rejected.

## Antigravity

The installer adds a named `wokintosh-observer` entry to `~/.gemini/config/hooks.json`, retaining other named hooks and an explicitly disabled observer. Restart App/CLI sessions, then inspect the loaded hooks with the provider's normal controls. The shared global configuration can also be loaded by the standalone IDE, but Wokintosh rejects its payloads.

[Antigravity's lifecycle hook contract](https://antigravity.google/docs/hooks) supplies camelCase `conversationId`, `workspacePaths` and `transcriptPath`. The adapter accepts only the documented transcript location under:

- App: `~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`
- CLI: `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`

Wokintosh validates that path without opening the transcript. It never scans `antigravity-ide`, prompt bodies, artifacts or screenshots. A UUID and an existing transcript filename can establish that a conversation exists; the file's contents and modification time cannot prove lifecycle state. Such discovery starts as Unknown and supplies a placeholder title. Hook workspace metadata supplies the project name.

The installed command supplies the event name separately because the common payload does not identify it:

```sh
wokintosh-agent hook --provider antigravity --event PreInvocation
```

The command reads the provider JSON from stdin. The installer registers SessionStart, PreInvocation, PostInvocation, PreToolUse, PostToolUse and Stop. Invocation/tool hooks indicate activity; PostInvocation and PostToolUse do not mean Done. Stop requires `terminationReason: "model_stop"` and `fullyIdle: true` before reporting Done. An error/step limit needs attention. Incomplete or still-running background work remains Unknown rather than fabricated completion. The public common hook contract does not establish parent relationships, so Wokintosh does not guess Antigravity helpers.

PreToolUse returns `{"decision":"allow"}`, which delegates to subsequent hooks or the provider's default policy. It never returns `auto_approve`, permission overrides, replacement tool arguments, or injected steps. Stop returns the same non-continuing decision. Observer write failures preserve these neutral outputs.

## OpenCode

This integration targets the **V2 plugin API** documented on November 24, 2026. V1 plugins and the older `/session` API are not used. A current OpenCode installation that supports `@opencode/plugin`, `Plugin.define`, `ctx.event.subscribe` and `ctx.session.list` is required. Exact minimum V2 package version and live-provider compatibility remain unverified.

The installer writes:

- `~/.local/share/wokintosh/opencode-observer/index.js`
- `~/.local/share/wokintosh/opencode-observer/package.json`
- One plugin-directory entry in `~/.config/opencode/opencode.json`, or the existing `opencode.jsonc`.

[OpenCode supports local plugin directories and a shared server part](https://opencode.ai/docs/build/plugins). Its App and CLI observe the same server sessions, so Wokintosh deduplicates by provider/session identity on the collector host. Restart the provider server through OpenCode's normal controls after installation. The collector never restarts it. OpenCode resolves the plugin SDK dependency as part of its plugin loader; Wokintosh does not run a package manager. Remove the plugin-directory entry and restart OpenCode to disable observation.

JSONC comments, formatting, unrelated plugins and permission rules are retained. If both global `.json` and `.jsonc` files exist, installation refuses to choose between them. Custom config roots and project/system configurations that override or disable this plugin require manual placement of the generated directory entry in the active configuration. Review [OpenCode configuration precedence](https://opencode.ai/docs/config) when the observer does not load.

The generated [V2 server plugin](https://opencode.ai/docs/build/plugins/server) subscribes to public lifecycle events and reads one initial page of at most 20 session metadata records in its location. It does not register an interception hook. It forwards selected identifiers, timestamps, titles, parent IDs and directories to a bounded Python subprocess using an argument array with `shell: false`. No tool inputs, outputs, prompt content, permission resources, error bodies or credentials enter the bridge or the feed. The event stream is aborted on plugin cleanup; a failed bridge/stream cannot report completion.

The collector accepts the V2 envelope (`id`, `type`, `created`, `location`, `data.sessionID`) and bounded durable ordering metadata (`aggregateID`, `seq`, `version`). Event identifiers and per-aggregate sequence watermarks survive polls and collector restarts; duplicate or older events cannot overwrite newer lifecycle evidence even when timestamps are equal or regress. Deletion leaves a private tombstone, preventing delayed events and in-flight discovery from recreating the session. Tombstones do not appear in the feed. The replay-ID history is bounded to 64 identifiers per session, with at most eight aggregate watermarks; durable sequence checks continue to reject old events after the replay history turns over. Relevant observations include `session.execution.started/succeeded/failed/interrupted`, `permission.asked/replied`, creation/rename/fork metadata, tool activity and shell lifecycle. Only an execution-succeeded event establishes Done. Initial discovery ignores historical `outcome`; idle, interruption, tool success, session disappearance and failed reads do not manufacture success. Approval requests remain pending until their matching request IDs receive a valid `once`, `always` or `reject` reply, or an explicit execution transition supersedes them. A reply clears only its matching wait and does not establish renewed activity: after all replies, the state is Unknown until positive lifecycle evidence arrives. Human forks remain visible independent sessions. A `session.forked` event or `Session.Info.fork` metadata distinguishes fork provenance from the explicit `parentID` used for helpers; an interrupted/idle helper never becomes a completed background task.

Detached command inventory is not verified. After a shell-start observation, the session retains an incomplete background marker; later execution success cannot prove all background work finished. This can leave the session Unknown even after a command has ended. The integration deliberately exposes that limitation until a complete background inventory contract is verified.

The current [OpenCode HTTP API](https://opencode.ai/docs/api) documents `/api/session` and `/api/session/active`, but this collector makes no HTTP requests. It never reads server passwords or pairing credentials. [The shared service ordinarily listens on localhost](https://opencode.ai/docs/cli/web); this integration neither changes its port nor makes it reachable remotely. Install the observer on the server host when App/CLI clients connect to a remote server.

## State, privacy and links

Additional-provider lifecycle observations become Unknown after 30 minutes without a new signal. Quiet long-running work can therefore become Unknown. Old activity never becomes synthetic Done. Sessions retain existing protocol-v1 fields; `provider` is `antigravity` or `opencode`. No new required field is introduced.

Provider configuration/evidence reads are limited to 256 KiB per file; hook input is limited to 1 MiB. Antigravity discovery examines at most 256 entries in each supported brain directory. Existing transcript-reader/cache bounds still apply to Claude/Codex. New summaries retain body-free state only. Display strings are truncated by Unicode scalar and lone surrogates are sanitized; invalid provider identities are rejected before publication. Observer locks must be owned regular files and use a 0.2-second acquisition deadline. Pinned directory descriptors and no-follow reads/writes prevent linked hook directories, lock symlinks and FIFO targets from escaping private state or blocking neutral hook output. The standalone collector remains one Python file using the standard library; the optional OpenCode plugin is generated by its installer.

Exact-session links are optional and independent per platform. Wokintosh never invents a custom scheme, extracts URLs from message text, starts remote control, or reconstructs an Antigravity instance ID from a conversation ID. To supply an already captured, trusted HTTPS session link, create `provider-links.json` inside the collector's state directory:

```json
{
  "version": 1,
  "sessions": [
    {
      "provider": "antigravity",
      "id": "ec33ebf9-0cba-4100-8142-c61503f6c587",
      "iOS": "https://antigravity.google.com/r/CAPTURED-INSTANCE?p=c%2Fec33ebf9-0cba-4100-8142-c61503f6c587"
    },
    {
      "provider": "opencode",
      "id": "ses_example",
      "macOS": "https://your-existing-server.example/session/EXPLICIT-SESSION-PATH"
    }
  ]
}
```

These are placeholders: paste an actual provider link. Omit unsupported platforms. Helpers receive no session links. The bounded file permits at most 256 entries. Its values must be HTTPS URLs of at most 2,048 characters without userinfo, controls, fragments, authentication routes or credential-like query keys. Antigravity targets must use the exact `antigravity.google.com` host, a nonempty `/r/<opaque-instance-id>` path and exactly one `p=c/<matching-conversation-UUID>` navigation parameter. Each platform target is validated independently; no missing instance ID is inferred. OpenCode permits ordinary navigation queries, but authentication-route checks first decode escaped path segments and resolve dot segments so encoded login/pairing routes cannot bypass validation. Queries have at most 16 fields, with bounded key/value lengths. Pairing/login links are rejected because they can contain access credentials. OpenCode routes requiring URL fragments are currently unsupported.

[Antigravity Remote Control](https://antigravity.google/docs/remote-control) can print the complete instance/conversation link when enabled by the user. Wokintosh accepts that explicitly supplied link but does not enable the tunnel. Missing/invalid links remain absent from `openURLs`; the apps can explain that exact-session navigation is unavailable.

## Verification and remaining limits

Run the collector suite with:

```sh
python3 -m unittest discover -s collector/tests -v
```

The new fixtures cover App/CLI deduplication, IDE exclusion, lifecycle and approval matching, stale/malformed/unsafe evidence, no false completion, helper classification, metadata privacy, exact-session URLs, bounded reads, configuration preservation (including primitive values in JSONC), backups, Unicode safety, durable replay/deletion ordering, fork provenance, bounded locking and generated-plugin execution. The plugin harness supplies the documented SDK boundary and executes the real generated bridge and Python collector; it does not replace a live-provider test.

Still unverified: real Antigravity hook loading/output handling, real OpenCode SDK loading and server lifecycle, exact minimum V2 version, full detached-task inventory, remote-session navigation on each device, and provider-specific helper behavior beyond explicit metadata. Keep both integrations labeled **Untested** until those checks are performed.
