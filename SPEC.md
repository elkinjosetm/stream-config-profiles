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
execution at the next restart). Because every remaining watchdog task is purely
user-level (Interactive principal, the resolved caller's own account),
registering/unregistering the watchdog never needs elevation -- elevation in this
tool is now reserved solely for conf editing/service restart and the uninstall paths
that touch Program Files/protected locations.
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

### Manager.ps1 Architecture

Single self-contained file, structured into regions:

- **#region Core:** Headless functions (no GUI wiring). All manager core functions take explicit path parameters (no hardcoded env lookups inside logic) so tests can drive them against sandbox dirs cross-platform.
- **#region Gui:** WinForms wiring. GUI never runs elevated wholesale; elevation only for specific admin operations (conf edit, service restart, uninstall paths that touch Program Files/protected locations) via `Start-Process -Verb RunAs` re-entry. Registering/unregistering the watchdog never routes through this -- every watchdog task is user-level, so there is nothing to elevate.
- **#region EmbeddedPayload:** Two marked here-string slots, EMPTY in the repo (marked `<#PAYLOAD:ENGINE#>` and `<#PAYLOAD:TEMPLATE#>`).

**Dev mode:** When payload slots are empty, manager loads `sync-configs.ps1` and `paths.example.txt` from its own script directory (the repo).

**Release mode:** Build inlines file contents into slots, producing self-contained `dist/manager.ps1`.

### Headless Actions & CLI Surface

`manager.ps1 -Action <value>` with no GUI:

- `install` — lays down the file layout only: creates PROGRAM/DATA, writes the engine + template into DATA, creates `paths.txt` from the template if absent, copies `manager.ps1` into PROGRAM. It does not touch Vibepollo registration or the watchdog -- those are separate actions (the wizard simply calls all of them in sequence across its steps).
- `register-vibepollo` — edit Vibepollo's `.conf`, add our entry with automatic backup
- `unregister-vibepollo` — remove our entry from `.conf` (leaves the `.bak` file on disk for manual recovery; does not automatically restore from it)
- `register-watchdog` — create scheduled tasks (Logon always; Poll with default interval or specified, opt-in). Never needs elevation -- every task registered is user-level.
- `unregister-watchdog` — delete scheduled tasks (Logon, Poll), plus best-effort-remove a legacy Boot task if one is found. Never needs elevation for the current task set; the legacy Boot cleanup is attempted regardless but its failure never fails the overall call.
- `uninstall` — cleanup: unregister-watchdog, unregister-vibepollo (if a conf path is known/found), restart the host service, remove the program folder (and the data folder if `-RemoveData` is passed)

Supporting params (actual, as implemented): `-ProgramDir`, `-DataDir`, `-ConfPath`, `-IncludePoll`, `-PollMinutes`, `-RemoveData`, `-ManagerScriptPath`, `-UserId`, `-NoRun`. There is no `-IncludeBoot` -- the product has no boot-time task (see the Settle Mode section above). `-DataDir` is not user-changeable in the wizard (there is nowhere contract-compliant to persist a custom choice, since PROGRAM is fixed to hold `manager.ps1` only -- see the Install Layout contract above); it always resolves to the fixed default unless the param is passed explicitly (tests, elevation re-entry). `-ConfPath` falls back to a fresh `Find-HostConf` auto-detection when omitted.

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
above ("No Boot task") for the architecture decision. Both remaining tasks are
Interactive/user-level, so `register-watchdog`/`unregister-watchdog` never need
elevation. `unregister-watchdog` still best-effort-attempts to delete a legacy
`StreamConfigProfiles-Settle-Boot` task (present only if the user installed an
interim build that registered one); that attempt's own success/failure never
affects the overall result.

### Release Pipeline

1. Build: Inline `sync-configs.ps1` and `paths.example.txt` into `manager.ps1` payload slots → `dist/manager.ps1`
2. Generate `Install.bat`: wrapper that sets execution policy and runs the wizard
3. Package for release: `manager.ps1`, `Install.bat`, README snippet (quick-start)
4. CI/CD: matrix across Windows PowerShell 5.1 + pwsh 7, verify both payload modes (dev + release)
