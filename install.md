# Installation Guide

## Prerequisites

- Windows PC running **Vibepollo 1.17.0 or later** (Apollo fork for game streaming)
- Administrator access to run PowerShell commands
- Basic familiarity with copy/paste and text editing

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
# Forza Horizon 6
%LOCALAPPDATA%\ForzaHorizon6\LocalStorage_Shared\ForzaUserConfigSelections

# Another game
C:\Users\YourUsername\Documents\MyGame\settings.ini
```

**Format rules:**
- One path per line
- No quotes needed, even if paths contain spaces
- Lines starting with `#` are comments
- Blank lines are ignored
- Paths can use environment variables like `%LOCALAPPDATA%`, `%USERPROFILE%`, etc.

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
2. **Start a stream** from any client (iPad, phone, another PC, etc.)
3. **Check that the tool created the folders:**
   - Navigate to `C:\stream-config-profiles\profiles\`
   - You should now see:
     - A `_local` folder (your PC's original config backup)
     - A folder named after your streaming client (e.g., `iPad`, `AppleTV`, `Phone`)
4. **Check for the log file:**
   - In `C:\stream-config-profiles\`, you should see a `sync.log` file (created by the tool)
   - Open it to verify there are no error messages

5. **Play the game** during the stream and change your graphics settings (e.g., resolution)
6. **End the stream** (quit the app on your client or disconnect)
7. **Check that the game reverted:** Restart the game locally (not streaming) — your graphics settings should be back to what they were before the stream

If all of this works as expected, installation is complete!

---

## Uninstalling

If you need to remove this tool:

1. **Open Vibepollo settings** and navigate to global prep commands
2. **Delete both commands** (the "do" and "undo" entries pointing to `sync-configs.ps1`)
3. **Delete the folder** `C:\stream-config-profiles` from your disk

Your game settings will not be affected — the tool backs up your original config and always restores it after a stream ends.

---

## Troubleshooting

**The folders `profiles\` and `sync.log` don't appear after starting a stream:**
- Check that Vibepollo can access the path (permissions, typos in the command)
- Open `Command Prompt` or `PowerShell` and manually run the command to see any error messages:
  ```
  powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
  ```

**Game settings didn't switch when I started a stream:**
- Make sure you closed the game completely before starting the stream (games cache settings in memory)
- Check the `sync.log` file for errors related to your game's config path

**I see duplicate commands in Vibepollo:**
- Remove all duplicates, keeping exactly one "do" and one "undo" command (see Step 3d and the warning above)
