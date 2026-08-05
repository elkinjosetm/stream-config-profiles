# Installation Guide

## Prerequisites

- Windows PC running **Vibepollo 1.17.0 or later** (Apollo fork for game streaming)
- Basic familiarity with copy/paste and text editing
- The script itself never needs to run as Administrator — Vibepollo runs it unattended at every stream start/end, and an elevation (UAC) prompt would silently block that. You only need elevated access at all if you choose to place the `stream-config-profiles` folder somewhere that requires it (e.g. directly under `C:\` or inside `Program Files`); picking a location under your own user profile avoids this entirely.

## Installation Steps

### Step 1: Place the Folder

Download or clone the `stream-config-profiles` folder and place it at:

```
C:\stream-config-profiles
```

**Note:** You can use any location on your PC, but all commands in the following steps assume `C:\stream-config-profiles`. If you place it elsewhere (e.g., `D:\MyTools\stream-config-profiles`), replace `C:\stream-config-profiles` with your actual path in all commands below.

---

### Step 2: Configure Your Game Paths

Open the `paths.txt` file (located inside the `stream-config-profiles` folder) in any text editor (Notepad is fine).

Add the full paths to your game configuration files or folders — one path per line. Examples:

```
# Replace these examples with your actual game config paths (see README for details):
# %LOCALAPPDATA%\YourGame1\Settings\graphics.ini
# %APPDATA%\YourGame2\Config\GraphicsSettings
```

**Format rules:**
- One path per line
- No quotes needed, even if paths contain spaces
- Lines starting with `#` are comments
- Blank lines are ignored
- Paths can use environment variables like `%LOCALAPPDATA%`, `%USERPROFILE%`, etc.

**Finding your game's config path:** Every game stores its configuration in a different location. A good resource is [PCGamingWiki](https://www.pcgamingwiki.com) — each game's page has a "Configuration file(s) location" section listing the exact path.

See `README.md` for more details on the format.

---

### Step 3: Register Commands in Vibepollo

This is where the tool integrates with Vibepollo's streaming system. Follow these steps:

#### 3a. Open Vibepollo Settings

1. Open Vibepollo in your browser or desktop interface
2. Navigate to the **global settings** or **global configuration** area
3. Find the section for **global prep commands** or **global stream setup commands** — this is where Vibepollo runs commands automatically when you start or stop a stream

#### 3b. Add the "Start Stream" Command

Create a new **global prep command** (sometimes called "pre-launch command" or "before session" command):

- **Mode/Type:** Start / Do / Launch (the command that runs when a stream BEGINS)
- **Command line:**
```
powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
```

#### 3c. Add the "End Stream" Command

Create a second **global prep command**:

- **Mode/Type:** End / Undo / Cleanup (the command that runs when a stream ENDS)
- **Command line:**
```
powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode undo
```

#### 3d. Save and Verify

After entering both commands, check that:
- Both commands appear exactly once in your global prep commands list
- No duplicate pairs exist (e.g., two copies of the "do" command, or two copies of the "undo" command)

---

### ⚠️ Important Warning: Check for Duplicates

**Duplicated command pairs corrupt your game profiles.** Before saving:

1. **Check for existing hooks:** If you previously used **ApolloProfileManager** or any other tool, search your global prep commands for any leftover entries related to those tools and **remove them completely** before adding this tool's commands.

2. **Verify the final list:** You should have **EXACTLY TWO** commands:
   - One "do" command pointing to `sync-configs.ps1 -Mode do`
   - One "undo" command pointing to `sync-configs.ps1 -Mode undo`

   If you see more, or if commands are duplicated, remove the extras and keep only one of each.

3. **Save after cleanup** to avoid conflicts.

---

### Step 4: Verify Installation Works

Test the installation before relying on it for gameplay:

1. **Open your game** and verify you can see your current graphics settings (resolution, quality, etc.) — take note of what you see
2. **Start a stream** from any client (tablet, phone, another PC, etc.)
3. **Check that the tool created the folders:**
   - Navigate to `C:\stream-config-profiles\profiles\`
   - You should now see:
     - A `_local` folder (your PC's original config backup)
     - A folder named after your streaming client (e.g., `LivingRoomTV`, or whatever name your client reports)
4. **Check for the log file:**
   - In `C:\stream-config-profiles\`, you should see a `sync.log` file (created by the tool)
   - Open it to verify there are no error messages

5. **Play the game** during the stream and change your graphics settings (e.g., resolution)
6. **End the stream** — test BOTH of these separately, since they behave differently:
   - **(a) Quit the app properly on the client.** This runs `undo`, which immediately restores your local config to disk. Restart the game locally right away — your graphics settings should already be back to what they were before the stream.
   - **(b) Disconnect without quitting the client app** (e.g., close the client window, lose network). `undo` does NOT run in this case — this is expected, not a bug. Your disk stays in the streamed client's config until the *next* time you start a stream (any client); that next `do` reconciles the orphaned session automatically (see README's "Automatic Crash/Disconnect Recovery"). If you restart the game locally right after a disconnect, don't be surprised to still see the client's settings — start one more stream and quit it properly (case a) to get your local config back immediately.

If case (a) works as expected, installation is complete! Case (b) is just there so you know what "not reverted yet" looks like and don't mistake it for a broken install.

---

## Uninstalling

If you need to remove this tool:

1. **Open Vibepollo settings** and navigate to global prep commands
2. **Delete both commands** (the "do" and "undo" entries pointing to `sync-configs.ps1`)
3. **Delete the folder** `C:\stream-config-profiles` from your disk

Your game settings are safe as long as your last session ended cleanly (the client app was properly quit, so `undo` ran and restored your local config to disk). If your last stream instead ended by disconnect rather than quitting the client, `undo` never ran and your disk may still hold that client's settings — start one more stream and properly quit it before uninstalling, so your local config is restored first. You can also check `state.json` in the install folder: if it exists and lists an `activeClient`, a session is still pending.

---

## Troubleshooting

**The folders `profiles\` and `sync.log` don't appear after starting a stream:**
- Check that Vibepollo can access the path (permissions, typos in the command)
- Open `Command Prompt` or `PowerShell` and manually run the command to see any error messages:
  ```
  powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
  ```
  **Important:** the script intentionally does nothing at all — no log, no output, no error, just a silent successful exit — unless it sees `APOLLO_CLIENT_NAME` (or `SUNSHINE_CLIENT_NAME`) set in its environment, since that's how it knows a stream is actually starting. Outside of an actual stream, that variable isn't set. To test manually in the same PowerShell window, set it first:
  ```
  $env:APOLLO_CLIENT_NAME = "TestClient"
  powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
  ```

**Game settings didn't switch when I started a stream:**
- Make sure you closed the game completely before starting the stream (games cache settings in memory)
- Check the `sync.log` file for errors related to your game's config path

**I see duplicate commands in Vibepollo:**
- Remove all duplicates, keeping exactly one "do" and one "undo" command (see Step 3d and the warning above)
