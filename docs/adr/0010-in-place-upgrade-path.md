# In-place upgrade path with repointed elevation target

Re-running a newer `Setup.bat`/`manager.ps1` over an existing install silently changed nothing, because `Setup.bat` runs its extracted `%TEMP%` copy directly without touching the installed PROGRAM copy — leaving every later elevation pointed at a world-writable temp path instead of the installed one. `Show-ManagerGui` now calls `Invoke-ManagerAutoUpgrade` before opening the Main Window: if the running script differs from `PROGRAM\manager.ps1`, it re-runs `Install-App` (idempotent, leaving paths/profiles/connection state untouched), writes PROGRAM before DATA, and repoints all later elevation in that session to the freshly-written PROGRAM path.

## Consequences

- `Test-ManagerUpgradeNeeded` compares file contents, not version numbers, so running an older installer against a newer install silently downgrades it — documented as a known caveat in install.md rather than guarded in code.
- Writing PROGRAM before DATA only makes a retry possible, not reliable: if PROGRAM succeeds and DATA then fails, both the upgrade check and a re-run see `Running == Installed` and skip, leaving DATA stale with no retry path the check can detect.
