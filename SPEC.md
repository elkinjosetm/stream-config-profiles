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

## Non-goals (v1) — backlog for v2

- GUI (planned: WinForms in PowerShell, browse/add/remove paths only).
- Per-path flags (e.g. mirror mode for folders).
- Save/mod-set management (configs only).
- Detecting whether a game is currently running.

## Files

```
stream-config-profiles\
├── sync-configs.ps1     # the only executable piece; called by Vibepollo
├── paths.txt            # user-edited: one path per line
├── state.json           # written by the script; session state
├── sync.log             # append-only log
└── profiles\            # created automatically
    ├── _local\          # implicit profile: the PC's own config
    ├── <ClientName>\    # one folder per streaming client
    │   └── <hash8>_<leaf>   # per-path profile copy
    └── ...
```

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

## Future (v2 backlog)

- WinForms GUI (`manager.ps1`): list, add file, add folder, remove; writes
  paths.txt only. Zero extra dependencies.
- Per-path flags (`| mirror`).
- Community release: README, MIT license, `.gitignore` for `profiles\`,
  `state.json`, `sync.log`. Publish only once polished.
