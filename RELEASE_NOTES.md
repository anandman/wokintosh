# Wokintosh 2.1.1

Correct agent states when old internal helpers or quiet background work are involved.

- **Current Claude task inventories take precedence.** Historical helper errors and incomplete helper transcripts no longer resurrect tasks that a newer complete inventory says have ended. Newer requests for input still show Needs you, and explicit completion history is retained.
- **Internal Codex reviews do not become project work.** Guardian approval reviews are identified from provider metadata, so metadata-only internal reviews no longer keep completed sessions Unknown. Ordinary delegated agents remain part of the parent's state.
- **Quiet Claude runners remain verifiable.** The collector checks both current session-specific and older task-output directories for positive writer evidence. Stale or genuinely unresolved work continues to show Unknown.

Install the signed, notarized Mac update through **Check for Updates**, then choose **Settings → Machines → Update All** to update collectors and existing managed observers. Hooks remain observational and never submit prompts or approve provider actions.

The iPhone/iPad companion remains **2.1.0 (build 23)**. No mobile reinstall is required for this fix: updated agent states arrive through the publishing Mac's feed. Automatic still treats a generic shell command as Work; use **Background Tasks → Monitor** for a runner whose purpose is watching for events.
