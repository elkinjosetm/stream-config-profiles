# stream-config-profiles — Per-client game config profiles for Vibepollo/Apollo

Spec for implementation with Claude Code. Planning discussion happened in chat; this
document is the source of truth for v1.

## Problem

Games persist their own graphics settings (resolution, quality) in config files and
ignore the streaming client's display. Streaming the same PC to different clients
(iPad @ 1080p/120, Apple TV @ 1440p/60, 4K monitor) requires manually changing
in-game settings every time the client changes.

ApolloProfileManager (upstream tool) was evaluated and discarded: on Vibepollo it
registers duplicated hooks (2× restore, 2× save) and its save-at-session-start
writes the *current* disk config into the *incoming* client's profile, destroying
that profile. Its restore path, however, proved the concept works: with a manually
edited profile, each client loads its own resolution correctly.

## Goals (v1)

- Game-agnostic: a flat list of paths (files or folders). No game names, no
  per-app setup. "Configuring a game" = pasting its config path into a text file.
- Per-client profiles restored automatically at session start.
- Correct save semantics under Vibepollo, including sessions that end by
  disconnect (where `undo` never fires) — solved via save-at-start + state file.
- Local PC config treated as an implicit profile: installing this tool never
  clobbers the user's local settings.
- Exactly ONE global `do` + ONE global `undo` command registered in Vibepollo.
- Zero dependencies: pure PowerShell 5.1+ (Windows built-in). No modules, no
  binaries, no installers.

## Non-goals (v1)

- Per-path flags (e.g. mirror mode for folders) — deferred to v2.
- Save/mod-set management (configs only) — deferred to v2.
- Detecting whether a game is currently running — deferred to v2.

**Note:** GUI (WinForms, path browsing/add/remove) and settle mode (crash recovery at logon/unlock) are now v2 features; see v2 Implementation section.

## Files

```
stream-config-profiles\
├── sync-configs.ps1     # the only executable piece; called by Vibepollo
├── paths.example.txt    # shipped template; committed to the repo
├── paths.txt            # user-edited: one path per line; created by the
│                         # user from paths.example.txt during install;
│                         # gitignored (keeps local config paths out of
│                         # version control)
├── state.json           # written by the script; session state
├── sync.log             # append-only log
└── profiles\            # created automatically
    ├── _local\          # implicit profile: the PC's own config
    ├── <ClientName>\    # one folder per streaming client
    │   └── <hash8>_<leaf>   # per-path profile copy
    └── ...
```

If `paths.txt` is missing entirely (e.g. the user skipped the copy step),
`sync-configs.ps1` logs a `paths-file-missing` line and continues with zero
configured paths (still exits 0). This does NOT skip folder/state creation:
`profiles\_local\` and `profiles\<ClientName>\` are still created (empty),
and state.json is still written with an `activeClient` — the tool looks
exactly as "working" as it does with paths configured, just with nothing
inside the profile folders.

- `<hash8>` = first 8 hex chars of MD5 of the lowercased full path, with any
  trailing path separator (`\` or `/`) removed before hashing — avoids
  collisions between games whose config files share a name (settings.ini),
  and makes `C:\Foo` and `C:\Foo\` resolve to the same profile entry.
  Trailing separators are in fact stripped once, when a path is read out of
  paths.txt (see below), so every consumer (hashing, copying, logging)
  works from the same normalized string.
- Client name comes from env: `APOLLO_CLIENT_NAME`, fallback
  `SUNSHINE_CLIENT_NAME`. Sanitize for filesystem use. If neither is set,
  exit 0 doing nothing (not a streaming session).

## paths.txt format

```
# One path per line. File or folder — detected automatically.
# Blank lines and lines starting with # are ignored.
# Comments let the user remember which game each path belongs to.

# Forza Horizon 6 (graphics config only, not saves)
%LOCALAPPDATA%\ForzaHorizon6\LocalStorage_Shared\ForzaUserConfigSelections
```

- No quotes, even with spaces (the whole line is the path).
- Expand environment variables (`%LOCALAPPDATA%` etc.) when reading.
- Strip any trailing `\` or `/` after expansion (unless doing so would leave
  a bare drive letter like `C:`). This avoids a Windows PowerShell 5.1
  native-argv quoting hazard where a path that both contains a space and
  ends in `\` gets mis-parsed by robocopy.exe, and keeps the hash8/leaf
  computation, the copy call, and the log line all working from one
  consistent string.

## Core semantics — save-at-start with state.json

`undo` firing is NOT guaranteed (client disconnects, host crash, Desktop-app
sessions that are resumed instead of relaunched). The design must be correct
even if only `do` ever runs.

`state.json` shape: `{ "activeClient": "iPad", "since": "<ISO8601>", "localBackedUp": true }`
Absent/empty file = no pending session.

### do (session start, incoming client = B)

1. Read state.json.
2. **Pending session exists (client A, undo never ran):**
   - Save current disk state of every path → `profiles\A\` (recovers the state
     A's session left behind).
   - Do NOT touch `_local` (the existing `_local` backup from before A's
     session is still the true local config).
3. **No pending session (clean):**
   - Backup current disk state of every path → `profiles\_local\` (overwrite).
4. For every path: if `profiles\B\<entry>` exists → copy it onto the real path.
   Else → seed `profiles\B\<entry>` from the real path (first session of this
   client; nothing else is touched).
5. Write state.json → `{ activeClient: B, since: now }`.
6. `A == B` (reconnect/relaunch of same client) is handled naturally by the
   same steps: save disk→A, restore A→disk. Harmless.

### undo (session end, active client = B)

1. Save current disk state of every path → `profiles\B\`.
2. Restore `profiles\_local\` → real paths (PC returns to its own config).
3. Delete/clear state.json.

### Consequences (document in README)

- Crash/disconnect recovery is automatic: the next `do` settles the previous
  session's save before restoring anything.
- Known limitation: if the user plays LOCALLY while a session is pending
  (undo never ran), those local changes get attributed to the previous
  client's profile at the next `do`. Acceptable for v1; a timestamp heuristic
  is v2 material.
- Configs apply when the game LAUNCHES. Swapping while a game is open does
  nothing (games cache config in memory and rewrite it on exit). Documented
  rule: don't start a stream with the game already open; close the game to
  switch profiles.

## Copy semantics

- Single file: `Copy-Item -Force` (create destination dir as needed).
- Folder: `robocopy <src> <dst> /E /R:1 /W:1 /NFL /NDL /NJH /NJS` — recurse
  into subfolders (`/E`; without it, real robocopy copies only the
  top-level files of a folder and silently skips nested content — the
  opposite of what "folders that mix configs with other data" requires),
  overwrite, never delete extra files (safe default). `/MIR` explicitly NOT
  used in v1.
- robocopy exit codes ≥ 8 are errors; < 8 is success.

## Error handling

- A path listed in paths.txt that doesn't exist: log and skip.
- Any copy failure: log and continue with remaining paths. NEVER abort the
  session — the script always exits 0 so Vibepollo never blocks a launch.
- Log lines: timestamp, mode (do/undo), client, action, path.

## Vibepollo registration (install.md)

Single global pair (Vibepollo web UI → global prep commands):

```
do:   powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
undo: powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode undo
```

install.md must be beginner-friendly (screenshot-level detail): where the
global prep commands live in the Vibepollo UI, and a warning to verify no
duplicated command pairs exist.

## Manual test plan

1. Baseline: PC local config = 4K. Add FH6 path to paths.txt.
2. Stream from client 1 (iPad) via the Desktop app → verify `_local` and a
   seeded `iPad` profile appear; game still shows 4K (seeded).
3. In-game, change resolution to 1080p, quit the game, Quit app from the
   client → verify iPad profile now contains 1080p and disk is back to 4K
   (`_local` restored).
4. Stream again from iPad → game launches at 1080p (restore works).
5. Disconnect WITHOUT Quit app, then start a session from client 2 → verify
   the pending iPad session was saved to the iPad profile at `do`, and
   client 2 got its own profile — nothing leaked into `_local`.
6. Play locally (no stream) → verify local config intact after step 4's undo.

## Environment notes

- Host: Windows gaming PC running Vibepollo 1.17.0 (Apollo fork).
- Known real path for FH6 (Steam):
  `%LOCALAPPDATA%\ForzaHorizon6\LocalStorage_Shared\ForzaUserConfigSelections\`
  (main file: `UserConfigSelections`, plain text).
- Watch out during testing: Steam Cloud may resync configs; disable per-game
  if results look inconsistent. FH6 has `UseDynamicOptimization` / `isDynamic`
  attributes that can override manual values.

## v2 Implementation

Completed v1 backlog features and architectural contracts.

### Settle Mode (Crash/Disconnect Recovery)

A guarded recovery mode that fixes orphaned sessions at logon, unlock, and
(optionally) on a poll interval. Guarantees the local PC's settings are never
polluted by pending streaming profiles.

**Trigger:** scheduled tasks with AtLogOn and OnUnlock (session-unlock) triggers, plus an
optional periodic Poll trigger (default OFF). There is deliberately no AtStartup/Boot
task -- see "Scheduled Tasks" below for why.

**Behavior (settle guard v2):** Vibepollo/Apollo runs as an always-on service, so a
matching process merely existing is NOT evidence that it is actively serving the
pending session recorded in state.json — the same instance could easily have
crashed and restarted, or state.json could predate the service's current run
entirely. settle instead compares process *instance identity* (StartTime) against
when the pending session began (state.json's `since`):
- No state.json/pending → log 'settle-no-pending', exit 0, touch nothing
- Pending, no process matches any host name pattern (vibepollo, apollo, sunshine;
  override via `SCP_HOST_PROCESS_NAMES` env var for tests) → recover (nothing could
  possibly be serving the session)
- Pending, matching process(es) found → read the EARLIEST StartTime among them: if
  it is LATER than `since`, every matching instance started after the pending
  session began (a previous instance's crash/restart, not this session's host) →
  recover anyway; otherwise an instance that was already running at/before `since`
  could still be serving it → log 'settle-host-running', exit 0, touch nothing
- StartTime unreadable (access denied) or `since` missing/unparseable → can't
  safely tell instances apart → conservative no-op, log 'settle-host-unknown',
  exit 0, touch nothing
- "recover" = execute existing pending-recovery semantics (save disk → pending
  client's profile) PLUS restore `_local` → disk and clear state.json; log all
  actions with mode=settle; always exit 0

**Scheduled Tasks:**
- `StreamConfigProfiles-Settle-Logon` (AtLogOn + OnUnlock, user-level, default enabled)
- `StreamConfigProfiles-Settle-Poll` (repetition every N minutes, N configurable min 5, default OFF)

**No Boot task (architecture decision):** an earlier build also registered
`StreamConfigProfiles-Settle-Boot` (AtStartup, SYSTEM/ServiceAccount principal at
RunLevel Highest -- the only principal that fires an AtStartup trigger before anyone
logs on). This product removes it entirely: local play after a reboot always requires
a logon first, and the Logon task's AtLogOn trigger already fires at exactly that
moment, covering the same window. Keeping an admin-level task whose action targets
`<DATA>\sync-configs.ps1` -- a file living in the ordinary user's own writable
profile, rewritten in place by every unelevated `install`/reinstall -- bought zero
additional protection over Logon alone while adding a real elevation-and-escalation
surface (anything that can write to DATA while the Boot task exists gets SYSTEM
execution at the next restart). Every remaining watchdog task RUNS as a purely
user-level principal (Interactive, the resolved caller's own account, Limited
RunLevel) -- that runtime guarantee is unconditional. Registering that principal is
a separate matter: on real Windows, `Register-ScheduledTask` requires administrator
APPROVAL to register a logon-type trigger (`AtLogOn` / session-unlock) even when the
principal being registered is the calling user themself, so `register-watchdog` can
prompt for elevation whenever it (re-)registers the Logon task -- `Register-ScheduledTask
-Force` is called unconditionally for every requested task, so this is not a
one-time first-registration prompt; changing the poll interval and re-applying
re-registers Logon too if it is still checked.
The Poll task's time/repetition trigger does not have this requirement, so a
poll-only registration (`-IncludeLogon:$false`) does not itself trigger that
prompt for the ADD direction. `register-watchdog` is a full desired-state
reconciler, though (see below): the same call also REMOVES whichever
well-known task was not requested, so a poll-only call that also needs to
remove an already-registered, possibly admin-owned Logon task can still
prompt on that removal. Elevation in this
tool is therefore reserved for: conf editing/service restart, the uninstall paths
that touch Program Files/protected locations, and registering/unregistering the
Logon-triggered watchdog task when Windows denies the unelevated attempt -- never
for the GUI process as a whole, and the task's own principal is never elevated.
`Unregister-Watchdog` still best-effort-removes a legacy `StreamConfigProfiles-Settle-Boot`
task if one is found (cleanup for anyone who installed that interim build); since
deleting an admin-level task from an unelevated process is expected to fail, that
outcome is swallowed rather than surfaced as an overall failure.

All actions execute: `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<DATA>\sync-configs.ps1" -Mode settle`

### Install Layout (v2 Contract)

Two-folder design:
- **Program folder:** `%LOCALAPPDATA%\Programs\stream-config-profiles\` holds `manager.ps1` only
- **Data folder:** `%LOCALAPPDATA%\stream-config-profiles\` holds `sync-configs.ps1` (engine), `paths.example.txt`, `paths.txt`, `state.json`, `sync.log`, `profiles\`

Engine stays co-located with its data — `$PSScriptRoot` logic untouched. Vibepollo/Apollo
registration points at `<DATA>\sync-configs.ps1`.

Optionally, a "Stream Config Profiles.lnk" shortcut for `PROGRAM\manager.ps1` (launched via
the real Windows PowerShell 5.1 executable, `-NoProfile -ExecutionPolicy Bypass -File`) may
also exist at the Start Menu Programs folder and/or the Desktop -- created by
`New-ManagerShortcut` (wizard Done step default: Start Menu checked, Desktop unchecked; or
headlessly via `-AddStartMenuShortcut`/`-AddDesktopShortcut`) and removed, best-effort, by
`uninstall`.

### Manager.ps1 Architecture

Single self-contained file, structured into regions:

- **#region Core:** Headless functions (no GUI wiring). All manager core functions take explicit path parameters (no hardcoded env lookups inside logic) so tests can drive them against sandbox dirs cross-platform.
- **#region Gui:** WinForms wiring. GUI never runs elevated wholesale; elevation only for specific admin operations (conf edit, service restart, uninstall paths that touch Program Files/protected locations, and register-watchdog/unregister-watchdog when the unelevated attempt is denied) via `Start-Process -Verb RunAs` re-entry. `Invoke-GuiElevatable` detects a denial two ways: a thrown access-denied-shaped exception (preferring the HRESULT/exception type over message text, since the field failure this exists to catch arrives as a localized message like "Acceso denegado"), or -- since Register-Watchdog/Unregister-Watchdog/Uninstall-App signal a per-task failure by RETURNING Success=$false rather than throwing -- treating ANY such Result-shaped failure from those three specific actions (`register-watchdog`, `unregister-watchdog`, `uninstall`) as elevation-eligible; `uninstall`'s top-level `Success` reflects only a failed nested watchdog unregister, so this never fires for an unrelated business-logic failure (e.g. malformed conf JSON) that elevating would not fix. Either path always confirms with the user before elevating, and `Invoke-GuiElevationRetry` skips straight to reporting the original failure -- no confirm dialog, no second elevation -- when this process is already running elevated, since `Start-Process -Verb RunAs` would otherwise trigger a pointless second UAC prompt for a failure elevation cannot fix. The re-entered `-UserId` is resolved once in the *original* unelevated process and passed through explicitly, never re-derived inside the elevated child, so an over-the-shoulder elevation approval by a *different* account than the one that started the action can't register the task under the wrong identity (this does not cover the GUI itself having been launched already elevated, in which case its own identity already is that admin account).
- **#region EmbeddedPayload:** Two marked here-string slots, EMPTY in the repo (marked `<#PAYLOAD:ENGINE#>` and `<#PAYLOAD:TEMPLATE#>`).

**Dev mode:** When payload slots are empty, manager loads `sync-configs.ps1` and `paths.example.txt` from its own script directory (the repo).

**Release mode:** Build inlines file contents into slots, producing self-contained `dist/manager.ps1`.

### Headless Actions & CLI Surface

`manager.ps1 -Action <value>` with no GUI:

- `install` — lays down the file layout only: creates PROGRAM/DATA, writes the engine + template into DATA, creates `paths.txt` from the template if absent, copies `manager.ps1` into PROGRAM. It does not touch Vibepollo registration or the watchdog -- those are separate actions (the wizard simply calls all of them in sequence across its steps).
- `register-vibepollo` — edit Vibepollo's `.conf`, add our entry with automatic backup
- `unregister-vibepollo` — remove our entry from `.conf` (leaves the `.bak` file on disk for manual recovery; does not automatically restore from it)
- `register-watchdog` — a full DESIRED-STATE reconciler for the two well-known tasks, not add-only: registers Logon by default (opt out with `-IncludeLogon:$false`) and/or Poll (opt-in, default interval or specified), AND unregisters whichever of Logon/Poll was not requested if it already exists. The Logon task's registration can prompt Windows for administrator approval even though its principal is always the calling user (see the Scheduled Tasks section above), and `Register-ScheduledTask -Force` runs unconditionally, so this can prompt on every call that (re-)registers Logon, not only the first. A poll-only registration (`-IncludeLogon:$false -IncludePoll`) does not itself attempt (and so does not itself prompt for) the Logon registration -- but the SAME call still removes an already-registered Logon task in that case, which can prompt if that removal is denied.
- `unregister-watchdog` — delete scheduled tasks (Logon, Poll), plus best-effort-remove a legacy Boot task if one is found. Deleting a task you own generally does not need elevation the way registering the Logon trigger does, but a real failure is still surfaced as Success=$false and the GUI routes this through the same elevation-retry path as register-watchdog, defensively; the legacy Boot cleanup is attempted regardless but its failure never fails the overall call.
- `uninstall` — cleanup: unregister-watchdog, unregister-vibepollo (if a conf path is known/found), restart the host service, remove the Start Menu/Desktop shortcuts if present (best-effort -- never fails the overall call), remove the program folder (and the data folder if `-RemoveData` is passed). The returned summary carries a top-level `Success` that is `$false` when the nested watchdog unregister failed (only that failure; a nested conf-edit failure stays a final business-logic outcome), so both the headless exit code and the GUI's elevation-retry offer can see it -- see #region Gui above.

Supporting params (actual, as implemented): `-ProgramDir`, `-DataDir`, `-ConfPath`, `-IncludeLogon`, `-IncludePoll`, `-PollMinutes`, `-RemoveData`, `-DesktopDir`, `-ProgramsDir`, `-AddStartMenuShortcut`, `-AddDesktopShortcut`, `-ManagerScriptPath`, `-UserId`, `-NoRun`. `-DesktopDir`/`-ProgramsDir` (uninstall only) override the folders whose shortcut file gets removed, defaulting to `[Environment]::GetFolderPath('Desktop'/'Programs')`; the GUI resolves and passes these explicitly before an elevated uninstall retry, for the same over-the-shoulder-admin reason `-UserId` is. `-AddStartMenuShortcut`/`-AddDesktopShortcut` (install only) create the corresponding `.lnk` shortcut for `manager.ps1`; both default off headlessly (the wizard's own Done-step checkboxes default Start Menu checked / Desktop unchecked instead -- see Show-WizardDoneStep). `-IncludeLogon` defaults ON (every existing headless caller that doesn't say otherwise still gets Logon protection); it exists so a poll-only registration can skip the Logon task's registration attempt entirely rather than attempt-then-immediately-unregister it (which would otherwise prompt for elevation for a task the caller never wanted) -- it does NOT skip removing an already-registered Logon task, which `register-watchdog`'s desired-state reconcile still does in the same call when `-IncludeLogon:$false` is passed. There is no `-IncludeBoot` -- the product has no boot-time task (see the Settle Mode section above). `-DataDir` is not user-changeable in the wizard (there is nowhere contract-compliant to persist a custom choice, since PROGRAM is fixed to hold `manager.ps1` only -- see the Install Layout contract above); it always resolves to the fixed default unless the param is passed explicitly (tests, elevation re-entry). `-ConfPath` falls back to a fresh `Find-HostConf` auto-detection when omitted. `-UserId` defaults to a SID resolved from the current process when omitted (falling back to `DOMAIN\User`/`$env:USERNAME` where a SID isn't available -- see `Get-ResolvedUserId`), but the GUI always resolves and passes it explicitly before any elevation re-entry (see #region Gui above) so an elevated child launched under a *different* account never re-derives it from that account's own identity (a GUI that was itself launched already elevated is a separate case -- its own resolved identity already is the approving admin's).

The elevation-argument boundary itself (`ConvertTo-ElevatedArgumentString`) renders every switch/bool parameter as an explicit `-Name:$true`/`-Name:$false` token, never a bare `-Name` for true and never silent omission for false: omission is only safe when the receiving parameter's own declared default already matches "absent", which does NOT hold for `-IncludeLogon` (declared default `$true`) -- an omitted `-IncludeLogon:$false` would otherwise bind to `$true` in the elevated child and silently re-register the Logon task the user had just declined.

Running with no `-Action` opens the GUI (wizard on first run, main window if installed).

### Vibepollo/Apollo Registration (Conf-Edit Contract)

Manager edits the `.conf` file directly, never the web UI:
- `.conf` uses key=value lines; global prep commands live in a `global_prep_cmd` key whose value is a JSON array of `{do, undo, elevated}` objects
- Our entry identified by its do-command containing the engine path
- Always back up the conf (timestamped `.bak` alongside) before writing
- Merge with existing entries (never clobber others)
- Removal deletes only our entry

Service restart via Get-Service name patterns (`*vibepollo*`, `*apollo*`, `*sunshine*`) — if none found, surface 'restart manually'.

### Watchdog Task Set

Two scheduled tasks, both execute:
```
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<DATA>\sync-configs.ps1" -Mode settle
```

- `StreamConfigProfiles-Settle-Logon`: AtLogOn + a real session-unlock trigger (`MSFT_TaskSessionStateChangeTrigger`, StateChange=SessionUnlock), Interactive principal under the resolved user, default enabled
- `StreamConfigProfiles-Settle-Poll`: Repetition trigger (every N minutes), Interactive principal under the resolved user, configurable (min 5 minutes), default OFF

There is no `StreamConfigProfiles-Settle-Boot` task -- see the Settle Mode section
above ("No Boot task") for the architecture decision. Both remaining tasks always
RUN as an Interactive/user-level principal (never elevated). Registering that
principal is a separate matter, though: real Windows requires administrator
approval to `Register-ScheduledTask` a logon-type trigger (Logon's `AtLogOn` +
session-unlock) even though the principal being registered is the calling user
themself, so `register-watchdog` can prompt for elevation whenever it (re-)registers
the Logon task -- not only the first time, since registration is unconditional
(`-Force`) on every call -- the GUI's `Invoke-GuiElevatable` handles the
confirm-and-retry for that case (see #region Gui above). The Poll task's repetition
trigger carries no such requirement, so a poll-only registration does not itself
attempt (and so does not itself prompt for) the Logon registration; the same call
can still prompt if it also needs to remove an already-registered, possibly
admin-owned Logon task (see `register-watchdog`'s desired-state reconcile above).
`unregister-watchdog`
still best-effort-attempts to delete a legacy `StreamConfigProfiles-Settle-Boot`
task (present only if the user installed an interim build that registered one);
that attempt's own success/failure never affects the overall result.

### Release Pipeline

1. Build: Inline `sync-configs.ps1` and `paths.example.txt` into `manager.ps1` payload slots → `dist/manager.ps1`
2. Generate `StreamConfigProfiles-Setup.bat`: polyglot batch/PowerShell single-file installer (batch header + marker + PS1 payload)
3. Package for release: `StreamConfigProfiles-Setup.bat` (primary), `manager.ps1` (for auditors), `SHA256SUMS.txt` (hashes of both, generated by the release job)
4. CI/CD: matrix across Windows PowerShell 5.1 + pwsh 7, verify both payload modes (dev + release)
