# stream-config-profiles

## What It Is

**stream-config-profiles** automatically manages game graphics settings for different streaming clients. Games store their display configuration (resolution, quality) in config files on your PC but have no awareness of different client devices. This tool solves that: when you stream to an iPad at 1080p, then switch to a 4K monitor, each client automatically gets its own saved graphics profile, with no manual tweaking in-game.

## The Problem It Solves

Streaming the same PC to multiple clients (iPad @ 1080p/120, Apple TV @ 1440p/60, 4K monitor) usually requires manually adjusting in-game graphics settings every time you switch clients. Games persist their own config files and ignore the streaming client's display. This tool maintains a separate graphics profile for each client, automatically restoring it at session start.

## How It Works

### Per-Client Profiles + The Implicit Local Profile

The tool maintains a folder structure under `profiles/`:
- **`profiles/_local/`** — Your PC's own graphics settings (created automatically, preserved from before installation)
- **`profiles/<ClientName>/`** — One profile per streaming client (iPad, AppleTV, Monitor, etc.)

Each profile contains copies of the config files/folders you list in `paths.txt`.

### Save-at-Start + State.json Design

The tool uses a two-phase strategy designed to survive crashes and unexpected disconnects:

1. **At session start (`do`)**: Before restoring a client's profile, save the current disk state to that client's profile folder. This handles the case where a previous session ended abnormally (crash, network disconnect) and `undo` never ran. The pending session's changes are preserved automatically.

2. **At session end (`undo`)**: Save the client's latest config, then restore `_local/` to the disk so your PC returns to its own settings.

3. **Why this design**: If `undo` never fires (client disconnects without properly closing the app), the tool can recover at the next session start by saving the orphaned state first. You never lose a client's config, and your PC's config stays protected in `_local`.

## Quick Start

### File Layout

```
stream-config-profiles\
├── sync-configs.ps1       # Main executable (called by Vibepollo)
├── paths.txt              # YOUR CONFIG: one path per line
├── state.json             # Written by the script (session state)
├── sync.log               # Append-only debug log
└── profiles\              # Created automatically
    ├── _local\            # Your PC's config (implicit profile)
    ├── iPad\              # Example: profile for iPad client
    └── AppleTV\           # Example: profile for AppleTV client
```

### Editing paths.txt

List the full paths to game config files or folders you want managed:

```
# One path per line. No quotes, even with spaces.
# Blank lines and lines starting with # are ignored.

# Forza Horizon 6 (graphics config only, not saves)
%LOCALAPPDATA%\ForzaHorizon6\LocalStorage_Shared\ForzaUserConfigSelections

# Your Game (another example)
%APPDATA%\YourGame\Config\GraphicsSettings
```

**Format rules:**
- One path per line
- **No quotes**, even if the path has spaces
- Environment variables (`%LOCALAPPDATA%`, `%APPDATA%`, etc.) are expanded automatically
- Lines starting with `#` and blank lines are ignored
- Comments help you remember which game each path belongs to

### Installation

See **install.md** for step-by-step instructions to register this tool with Vibepollo. You'll add two global prep commands (do/undo) in the Vibepollo web UI — the tool handles everything else automatically.

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
- **Forza Horizon 6**: FH6 has `UseDynamicOptimization` / `isDynamic` attributes in its config that can override your manual graphics settings. Manual resolution changes work, but be aware the game may adjust quality dynamically.

## Troubleshooting

Check **sync.log** for details. Each log line shows the timestamp, mode (do/undo), client name, action (save/restore), and the path involved. If a config isn't being applied as expected:

1. Verify the game is closed before starting a stream
2. Confirm the path in `paths.txt` exists on your system (expand environment variables manually if unsure)
3. Check sync.log for errors or warnings on that path
4. Verify each client name in Vibepollo matches what you expect (the tool uses `APOLLO_CLIENT_NAME` env var, fallback `SUNSHINE_CLIENT_NAME`)

If you don't see a log entry at all, the tool may not have run — verify the Vibepollo do/undo commands are registered correctly (see install.md).
