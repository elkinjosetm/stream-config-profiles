# stream-config-profiles

## What It Is

**stream-config-profiles** automatically manages game graphics settings for different streaming clients. Games store their display configuration (resolution, quality) in config files on your PC but have no awareness of different client devices. This tool solves that: when you stream to different devices with different resolutions, each client automatically gets its own saved graphics profile, with no manual tweaking in-game.

## The Problem It Solves

Streaming the same PC to multiple clients (e.g., a tablet at 1080p vs. a 4K TV) usually requires manually adjusting in-game graphics settings every time you switch clients. Games persist their own config files and ignore the streaming client's display. This tool maintains a separate graphics profile for each client, automatically restoring it at session start.

## How It Works

### Per-Client Profiles + The Implicit Local Profile

The tool maintains a folder structure under `profiles/`:
- **`profiles/_local/`** — Your PC's own graphics settings, created automatically and refreshed every time you start a clean streaming session (it's overwritten with whatever your local config was immediately before that session began — not a one-time snapshot taken at install time)
- **`profiles/<ClientName>/`** — One profile per streaming client (the folder name comes from whatever name your client reports via `APOLLO_CLIENT_NAME` or `SUNSHINE_CLIENT_NAME`)

Each profile contains copies of the config files/folders you list in `paths.txt`.

### Save-at-Start + State.json Design

The tool uses a two-phase strategy designed to survive crashes and unexpected disconnects:

1. **At session start (`do`)**: Before restoring the incoming client's profile, the tool saves the current disk state somewhere first — where depends on what happened last time:
   - **If a previous session never got a proper `undo`** (crash, network disconnect): the current disk state is that orphaned client's own settings, so it's saved back into *that client's* profile folder. `_local` is left untouched, since it still holds the true local config from before that orphaned session started.
   - **Otherwise (the normal case)**: the current disk state is your own local settings, so it's saved into `profiles/_local/` (overwriting the previous `_local` snapshot) before the incoming client's profile is restored.

2. **At session end (`undo`)**: Save the client's latest config, then restore `_local/` to the disk so your PC returns to its own settings.

3. **Why this design**: If `undo` never fires (client disconnects without properly closing the app), the tool can recover at the next session start by saving the orphaned state first. You never lose a client's config, and your PC's config stays protected in `_local`.

## The Easy Way: Install with the App

1. **Download** `StreamConfigProfiles-Setup.bat` from the latest Release
2. **Double-click `StreamConfigProfiles-Setup.bat`** — a five-step wizard guides you through:
   - **Welcome**: confirms the fixed program/data folder locations (neither is changeable)
   - **Install files**: writes the engine, template, and a fresh `paths.txt` into the data folder
   - **Connect to Vibepollo/Apollo**: edits its `.conf` file directly, no web UI needed; the wizard warns explicitly if you skip this step
   - **Watchdog protection**: logon/unlock protection is on by default; Windows may ask for administrator approval to *register* it, but the watchdog itself always *runs* as your normal user account (see "About the Watchdog" below for when that approval prompt appears)
   - **Done**: Start Menu shortcut created by default (optional Desktop shortcut available)
3. **Done** — your next stream will use the profiles automatically. Afterwards, add/remove game config paths from the Main Window (Add File/Add Folder). Reopen it any time using the Start Menu shortcut, or optionally the Desktop shortcut if you created one during setup.

**Updating:** download a newer `StreamConfigProfiles-Setup.bat` and run it again — it updates your existing installation in place (paths, profiles, and connection are all preserved) instead of reinstalling from scratch; see install.md's "Updating" section for details.

## File Locations

- **Program file**: `%LOCALAPPDATA%\Programs\stream-config-profiles\manager.ps1` (the GUI app)
- **Data & engine**: `%LOCALAPPDATA%\stream-config-profiles\` contains:
  - `sync-configs.ps1` (the core engine, called by Vibepollo)
  - `paths.txt` (your game paths)
  - `state.json`, `sync.log` (created automatically)
  - `profiles\` (your client profiles and local backup)

## About the Watchdog

The "settle" watchdog fixes sessions that crashed or disconnected without properly closing, so your PC's local settings never get polluted by an orphaned streaming profile. It has two parts, registered independently:

- **Logon / unlock** — on by default. Registering it can prompt Windows for administrator approval (see below); it always runs as you.
- **Poll** — off by default; an optional periodic re-check every N minutes (min. 5). A poll-only selection does not itself require administrator approval to register.

Both parts always *run* entirely under your own account -- the watchdog itself is never elevated. *Registering* the logon/unlock part is a different story: Windows requires administrator approval to create a scheduled task with a logon-type trigger, even though the task's owner is your own account, so clicking Register/Update with logon/unlock protection checked can show a UAC prompt -- each time it (re-)registers that task, not only the first time (e.g. changing the poll interval and clicking Register/Update again re-registers logon/unlock too). If you approve it, only that one registration step runs elevated -- the task it creates still runs as you, same as always. Decline it and logon/unlock protection is simply not registered; everything else keeps working. The periodic poll task uses a different kind of trigger that Windows does not require approval for, so a poll-only selection does not itself trigger that prompt -- though the same Register/Update click also removes any logon/unlock task you just unchecked, and removing one that a previous approval left behind can still need approval of its own if that removal is denied. There is deliberately no boot-time (startup) task: local play after a reboot always requires logging in first, and the logon/unlock protection above already fires at exactly that moment. An earlier build did register a SYSTEM-level boot task, but it added an elevation surface (a privileged scheduled task pointing at a script in your ordinary, writable data folder) for no protection beyond what logon/unlock already provides, so it was removed. If you installed that earlier build, the app will try to clean up its leftover task the next time you unregister the watchdog or uninstall.

Once configured, whichever parts you enabled run silently in the background.

## Quick Start

### File Layout

```
%LOCALAPPDATA%\stream-config-profiles\
├── sync-configs.ps1       # Core engine (called by Vibepollo)
├── paths.example.txt      # Template: copy this to paths.txt to get started
├── paths.txt              # YOUR CONFIG: one path per line (gitignored — safe across updates)
├── state.json             # Written by the script (session state)
├── sync.log               # Append-only debug log
└── profiles\              # Created automatically
    ├── _local\            # Your PC's config (implicit profile)
    ├── LivingRoomTV\      # Example: profile for a specific client
    └── <ClientName>\      # Replace with your actual client name(s)
```

### Editing paths.txt

**First, create `paths.txt` from the template:** Copy `paths.example.txt` to `paths.txt` in the same folder. The template is shipped with the tool; `paths.txt` is gitignored, so your personal game paths stay out of version control and remain safe across updates.

Then open `paths.txt` in a text editor and list the full paths to game config files or folders you want managed:

```
# One path per line. No quotes, even with spaces.
# Blank lines and lines starting with # are ignored.

# Replace these examples with your actual game config paths (see below for how to find them):
# %LOCALAPPDATA%\YourGame1\Settings\graphics.ini
# %APPDATA%\YourGame2\Config\GraphicsSettings
```

**Finding your game's config path:** Every game stores its configuration in a different location. A good resource is [PCGamingWiki](https://www.pcgamingwiki.com) — each game's page has a "Configuration file(s) location" section listing the exact path.

**Format rules:**
- One path per line
- **No quotes**, even if the path has spaces
- Environment variables (`%LOCALAPPDATA%`, `%APPDATA%`, etc.) are expanded automatically
- Lines starting with `#` and blank lines are ignored
- Comments help you remember which game each path belongs to

### Registration with Vibepollo

**Method A (recommended): Use the app.** The `manager.ps1` wizard edits Vibepollo's `.conf` file directly with automatic backup, so it never depends on the web UI layout.

**Method B: Manual setup.** See **install.md** for detailed step-by-step instructions if you prefer to register commands manually.

## Consequences & Behavior

### Automatic Crash/Disconnect Recovery

If a streaming session ends abnormally (crash, network disconnect, app force-close), `undo` never runs. The next time you start a stream (any client), the tool automatically saves that orphaned session's state before restoring the new client. You won't lose configuration changes.

### Known Limitation: Local Play While Session Pending

If you play locally on your PC *while a streaming session is pending* (meaning `undo` didn't run), those local changes get saved to the previous client's profile when the next session starts. This is acceptable for v1. Workaround: properly end the streaming session (close the app) before playing locally.

### Configs Apply at Game Launch

Graphics settings are loaded when the game starts. If you swap profiles while a game is running, nothing happens — games cache config in memory and only write it back on exit. **Rule:** Close the game before switching profiles. Don't start a stream with the game already open.

## Environment Notes

Some games have special behavior worth knowing:

- **Steam Cloud**: Steam may auto-sync your game's cloud saves, which can interfere with testing. If config changes seem to "reset" unexpectedly, disable Steam Cloud for that game in your Steam client.
- **Dynamic Optimization**: Some games have dynamic-optimization settings that can override manually chosen values. If restored settings don't seem to stick, check your game's configuration for such options.

## Architecture & Design Decisions

This project's significant design choices are documented in [Architecture Decision Records (ADRs)](docs/adr/README.md) — short records of decisions that were hard to reverse, surprising without context, and the result of a real trade-off. Domain terms (profile, `_local`, settle, elevation boundary, etc.) are defined in [CONTEXT.md](CONTEXT.md).

## Troubleshooting

Check **sync.log** for details. Each log line shows the timestamp, mode (do/undo), client name, action (save/restore), and the path involved. If a config isn't being applied as expected:

1. Verify the game is closed before starting a stream
2. Confirm the path in `paths.txt` exists on your system (expand environment variables manually if unsure)
3. Check sync.log for errors or warnings on that path
4. Verify each client name in Vibepollo matches what you expect (the tool uses `APOLLO_CLIENT_NAME` env var, fallback `SUNSHINE_CLIENT_NAME`)

**If `paths.txt` is missing:** The tool logs `paths-file-missing` in sync.log and syncs nothing until you create it (by copying `paths.example.txt` to `paths.txt`). The profile folders and state.json are still created/updated as usual — `profiles\_local\`, `profiles\<ClientName>\`, and an `activeClient` entry in state.json all still appear — they will simply be empty/pointing at zero synced paths, so their presence alone does not mean the tool is actually syncing anything.

If you don't see a log entry at all, the tool may not have run — verify the Vibepollo do/undo commands are registered correctly (see install.md).
