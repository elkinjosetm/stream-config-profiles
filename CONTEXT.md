# Domain Language

Ubiquitous-language glossary for stream-config-profiles. Decisions and their whys live in [docs/adr/](docs/adr/); this file gives names to the seams those decisions cut along.

**profile** — A saved copy of every configured path's config, kept under `profiles\<name>\`. One profile per streaming client, plus the implicit `_local` profile. A profile is "seeded" the first time a client streams (copied from whatever is on disk) and "restored" (copied onto disk) every session after.

**`_local`** — The implicit profile for the PC's own, non-streaming config. Not a client name; created and refreshed automatically whenever a *clean* session starts, and restored to disk at `undo` or at settle recovery. Never treated as "just another client's leftovers" — see [ADR-0001](docs/adr/0001-save-at-start-with-state-file.md).

**pending session** — The state between a `do` that hasn't yet been matched by its `undo`, recorded in `state.json` as `{ activeClient, since }`. A pending session is "orphaned" if `undo` never fires (crash, disconnect, resumed Desktop-app session) and is settled either by the next `do` (any client) or by settle mode.

**do / undo** — The two hook points Vibepollo/Apollo/Sunshine fires per streaming session: `do` at session start, `undo` at session end. `undo` firing is **not guaranteed**; the whole save/restore design exists to be correct even when it never runs.

**settle** — A third mode (`-Mode settle`), run outside any streaming session by the watchdog's scheduled tasks, that closes out an orphaned pending session left behind after a crash, reboot, or disconnect. Gated on host *instance identity* (process `StartTime` vs. the pending session's `since`), not mere process existence — see [ADR-0005](docs/adr/0005-settle-guard-by-host-instance-identity.md).

**client name** — The identity a profile folder is named after, read from the `APOLLO_CLIENT_NAME` env var (fallback `SUNSHINE_CLIENT_NAME`) and sanitized for filesystem use. No client name set means "not a streaming session" — the engine exits 0 doing nothing.

**configured path** — One line of `paths.txt`: the absolute path of a game's config file *or* folder (detected automatically), with environment variables expanded. Blank lines and `#` comments are ignored. Each configured path gets exactly one profile entry per profile.

**profile entry** — The on-disk name for one configured path's saved copy inside a profile folder: `<hash8>_<leaf>`, where `<hash8>` is the first 8 hex chars of the MD5 of the lowercased, trailing-separator-stripped full path, and `<leaf>` is the path's own file/folder name. Prevents collisions between games whose config files share a leaf name (e.g. two `settings.ini`).

**watchdog** — The pair of scheduled tasks that run settle mode outside of streaming sessions: `StreamConfigProfiles-Settle-Logon` (`AtLogOn` + session-unlock, on by default) and `StreamConfigProfiles-Settle-Poll` (repetition interval, off by default). Both always *run* as the ordinary user; *registering* the Logon task can require an admin-approval elevation even though its principal never changes — see [ADR-0006](docs/adr/0006-watchdog-user-level-no-boot-task.md). There is deliberately no boot-time (`AtStartup`) task.

**host** — The always-on streaming service this tool integrates with: Vibepollo (the fork this project targets), upstream Apollo, or its ancestor Sunshine. All three are treated interchangeably by name-pattern matching (service names, process names, conf filenames) since any of the three lineages may be installed.

**conf / `global_prep_cmd` / prep commands** — The host's persisted configuration file (`vibepollo.conf`/`apollo.conf`/`sunshine.conf`, `key=value` lines). `global_prep_cmd` is the key whose value is a JSON array of `{do, undo, elevated}` objects — the "prep commands" the host runs per session. This tool registers itself by editing that file directly, never the host's web UI — see [ADR-0004](docs/adr/0004-vibepollo-integration-via-conf-editing.md).

**PROGRAM dir / DATA dir** — The two per-user install folders. PROGRAM (`%LOCALAPPDATA%\Programs\stream-config-profiles\`) holds `manager.ps1` and `launch.vbs` — what a shortcut points at. DATA (`%LOCALAPPDATA%\stream-config-profiles\`) holds the engine copy, `paths.txt`, `state.json`, `sync.log`, and `profiles\` — what the host's `global_prep_cmd` points at. See [ADR-0003](docs/adr/0003-per-user-install-program-data-split.md).

**engine vs. manager** — `sync-configs.ps1` (the engine) is the only piece the host ever calls; it does the actual do/undo/settle save-and-restore work and knows nothing about installation or GUI. `manager.ps1` (the manager) is the GUI/CLI installer and admin tool — it lays down the engine, registers it with the host, manages the watchdog, and never itself performs a do/undo/settle sync.

**payload / dev mode / embedded mode** — `manager.ps1` has two here-string slots, `<#PAYLOAD:ENGINE#>` and `<#PAYLOAD:TEMPLATE#>`. Empty in the repo, the manager falls back to loading `sync-configs.ps1`/`paths.example.txt` from its own neighboring files (**dev mode**). `build/make-dist.ps1` fills the slots with the real file contents to produce a self-contained `dist/manager.ps1` (**embedded**/release mode) — see [ADR-0002](docs/adr/0002-pure-powershell-zero-dependencies.md).

**Setup.bat** — `StreamConfigProfiles-Setup.bat`, the single-file distributed installer: an ASCII batch header followed by a marker line and the verbatim bytes of `dist/manager.ps1`. Extracts its own payload to `%TEMP%` and runs it with `powershell.exe -File` — never `iex`. See [ADR-0012](docs/adr/0012-release-pipeline-single-file.md).

**launch.vbs** — A small generated Windows Script Host file written into PROGRAM alongside `manager.ps1`. Start Menu/Desktop shortcuts target `wscript.exe "PROGRAM\launch.vbs"` instead of `powershell.exe` directly, so launching the manager never flashes a console window — see [ADR-0008](docs/adr/0008-windowless-launch-via-wscript.md).

**elevation boundary** — The point where `manager.ps1` re-launches itself as `powershell.exe -File <manager.ps1> -Action <name> ...` under `Start-Process -Verb RunAs`, for the three operations that need admin rights (conf edit/service restart, protected-location uninstall, Logon watchdog registration). Everything that crosses this boundary — switch serialization, identity resolution, command-line quoting — follows the structural contract in [ADR-0007](docs/adr/0007-file-elevation-boundary-contract.md).
