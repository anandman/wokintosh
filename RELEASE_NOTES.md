# Wokintosh 2.1.2

Restore Claude session links when Remote Control is connected but observational hooks have not captured its bridge ID.

- **Live-session fallback.** The collector can read the exact Claude session's Remote Control ID from its local registry. Hook-provided IDs remain preferred. Mac, iPhone and iPad keep the tested `claude://code/{bridge-id}` target and HTTPS backup.
- **Validated association.** The registered process must be live and match its owner, process-start token and host/PID namespace. Bounded reads reject malformed IDs, conflicting records, symlinks and nonregular files. Ended sessions remain unavailable until a new lifecycle event.
- **Observational behavior.** Fallback metadata does not create agent rows, change status, enable Remote Control or grant permissions. It is rechecked each poll and is not persisted in collector caches. Claude's registry is undocumented, so unsupported metadata leaves links unavailable.

Install the signed, notarized Mac update through **Check for Updates**, then use **Settings → Machines → Update All** for remote collectors and existing managed observers.

The iPhone/iPad companion remains **2.1.0 (build 23)**. No mobile reinstall or re-pairing is needed; corrected links arrive through the publishing Mac's feed.
