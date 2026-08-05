# Installation Guide

## Prerequisites

- Windows PC running **Vibepollo 1.17.0 or later** (Apollo fork for game streaming)
- Basic familiarity with copy/paste and text editing

## Method A: Using the App (Recommended)

The easiest way: download `manager.ps1` and `Install.bat` from the latest Release and run the wizard. You do not create or choose any folder yourself -- both the program and data locations are fixed (see File Locations in README.md) and the wizard just shows them to you.

### Installation Steps

1. **Download** the latest `manager.ps1` and `Install.bat` from Releases, into any folder (e.g. your Downloads folder -- they don't need to live anywhere permanent; `Install.bat` copies `manager.ps1` into the real program folder for you)
2. **Double-click `Install.bat`** — a five-step wizard appears:
   - **Welcome**: shows the fixed program folder (`%LOCALAPPDATA%\Programs\stream-config-profiles\`) and fixed data folder (`%LOCALAPPDATA%\stream-config-profiles\`) — neither is editable here
   - **Install files**: writes `sync-configs.ps1`, `paths.example.txt`, and a fresh `paths.txt` (copied from the template automatically -- no manual copy step) into the data folder, and copies `manager.ps1` into the program folder
   - **Connect to Vibepollo/Apollo**: click **Connect** to edit its `.conf` file directly (automatic backup, no web UI needed) — Vibepollo/Apollo is usually auto-detected; browse to the file manually if not
   - **Watchdog protection**: logon/unlock protection is checked by default, and an optional periodic poll checkbox is available too — both run entirely as you, so this step never needs administrator rights (see README.md's "About the Watchdog" for why there's no boot-time option)
   - **Done**
3. **Add your game config paths.** The wizard does not ask you to hand-edit `paths.txt` — after Setup finishes, the **Main Window** opens automatically (or reopen it any time by running `%LOCALAPPDATA%\Programs\stream-config-profiles\manager.ps1`). Use its **Add File...** / **Add Folder...** buttons to add each game's config path; **Remove Selected** to remove one.
4. **Done** — your next stream will use profiles automatically

### Verify Installation

1. **Start a stream** from any client
2. **Check that folders appeared:**
   - A `profiles\_local\` folder (your PC's original config)
   - A folder named after your client (e.g., `profiles\LivingRoomTV\`)
3. **Check the log:**
   - Open `sync.log` and verify it shows real activity (not `action=paths-file-missing`)
   - If missing, you skipped the paths.txt step — go back and add your game paths
4. **Test:** Play the game, change settings, and end the stream
   - If you quit the client app properly, your local settings restore immediately
   - If you disconnect without quitting, your settings restore on the next stream (crash recovery)

---

## Method B: Manual Setup (Appendix)

For auditors, minimalists, or when the app isn't available.

### Step 1: Place the Files

Download or clone the repo and place it at any location (e.g., `C:\stream-config-profiles`). Commands below assume this path — substitute your actual location if different.

### Step 2: Configure Your Game Paths

**First action:** Copy `paths.example.txt` to `paths.txt` in the same folder (`stream-config-profiles\`). The template is shipped with the tool; by copying it, you create your own `paths.txt` which is gitignored — this keeps your personal game paths out of version control and safe across updates.

Then open the `paths.txt` file in any text editor (Notepad is fine) and add the full paths to your game configuration files or folders — one path per line. Examples:

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

### Step 3: Register Commands in Vibepollo

This is where the tool integrates with Vibepollo's streaming system. Follow these steps:

#### 3a. Open Vibepollo Configuration

1. Open Vibepollo in your browser (navigate to `https://localhost:47990`)
2. Click the **"Configuration"** tab in the top navigation bar (page `/settings`)
3. Under the **"General"** section, you will see three similar lists displayed in this order:
   - **Command Preparations** (the one you want — description reads *"Configure a list of commands to be executed before or after running any application..."*)
   - State Commands
   - Server Commands

**⚠️ Important:** Do not confuse these lists. Make sure you are editing **Command Preparations**, not State Commands or Server Commands.

#### 3b. Add Commands to Command Preparations

Under **Command Preparations**, click the **"+ Add"** button. A new row titled **"Step 1"** appears with:
- An **"Elevated"** checkbox (LEAVE THIS UNCHECKED — no admin privileges needed)
- A trash icon (to delete the row)
- Two text fields: **"Do Command"** and **"Undo Command"**

**Important:** Both the start and end commands go in a SINGLE row using the two fields. The most common mistake is creating two separate rows. Instead:

- Paste the "start stream" command into the **"Do Command"** field:
  ```
  powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do
  ```

- Paste the "end stream" command into the **"Undo Command"** field:
  ```
  powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode undo
  ```

#### 3c. Save Changes

After entering both commands:
- An orange toast notification appears at the bottom-right: **"Manual save required for recent changes; these settings will not auto-save"** with a **"Save"** button
- Click the **"Save"** button to persist your changes

#### 3d. Restart Vibepollo

After saving, **restart Vibepollo completely** for the changes to take effect. The page header itself notes that a restart is required for runtime changes to apply.

#### 3e. Verify

After restarting, check that:
- The **"Do Command"** and **"Undo Command"** fields in your Command Preparations row both contain the correct commands
- No duplicate pairs exist (you should have exactly one row with both commands)

### ⚠️ Important Warning: Check for Duplicates

**Duplicated command pairs corrupt your game profiles.** Ideally do this check before saving in Step 3c above — but if you've already saved and restarted (Steps 3c-3e), it's not too late: go back and check now, before your first stream:

1. **Check for existing hooks:** If you previously used **ApolloProfileManager** or any other tool, search your **Command Preparations** list for any leftover entries related to those tools and **remove them completely** before adding this tool's commands.

2. **Verify the final list:** You should have **EXACTLY ONE ROW** in Command Preparations with both commands:
   - **"Do Command"** field containing `powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode do`
   - **"Undo Command"** field containing `powershell.exe -ExecutionPolicy Bypass -File "C:\stream-config-profiles\sync-configs.ps1" -Mode undo`

   If you see more rows, or if this pair is duplicated, remove the extras and keep only one row.

3. **Save** and verify (as described in Steps 3c, 3d and 3e) to apply changes.

### Step 4: Verify Installation Works

Test the installation before relying on it for gameplay:

1. **Open your game** and verify you can see your current graphics settings (resolution, quality, etc.) — take note of what you see
2. **Start a stream** from any client (tablet, phone, another PC, etc.)
3. **Check that the tool created the folders:**
   - Navigate to `C:\stream-config-profiles\profiles\`
   - You should now see:
     - A `_local` folder (your PC's original config backup)
     - A folder named after your streaming client (e.g., `LivingRoomTV`, or whatever name your client reports)
4. **Check for the log file — and that it shows real activity, not just "missing paths":**
   - In `C:\stream-config-profiles\`, you should see a `sync.log` file (created by the tool)
   - Open it and confirm it does **NOT** contain `action=paths-file-missing`. If it does, you skipped Step 2 — go back and copy `paths.example.txt` to `paths.txt`, then start a stream again.
   - Confirm the client profile folder from step 3 above (`profiles\<YourClient>\`) is **NOT empty** — it should contain one `<hash8>_<leaf>` entry per line in your `paths.txt`. An empty folder with no error in the log is the signature of a missing `paths.txt`, not a working install.

5. **Play the game** during the stream and change your graphics settings (e.g., resolution)
6. **End the stream** — test BOTH of these separately, since they behave differently:
   - **(a) Quit the app properly on the client.** This runs `undo`, which immediately restores your local config to disk. Restart the game locally right away — your graphics settings should already be back to what they were before the stream.
   - **(b) Disconnect without quitting the client app** (e.g., close the client window, lose network). `undo` does NOT run in this case — this is expected, not a bug. Your disk stays in the streamed client's config until the *next* time you start a stream (any client); that next `do` reconciles the orphaned session automatically (see README's "Automatic Crash/Disconnect Recovery"). If you restart the game locally right after a disconnect, don't be surprised to still see the client's settings — start one more stream and quit it properly (case a) to get your local config back immediately.

If case (a) works as expected, installation is complete! Case (b) is just there so you know what "not reverted yet" looks like and don't mistake it for a broken install.

---

## Uninstalling

### If You Used Method A (the App)

1. **Run** `%LOCALAPPDATA%\Programs\stream-config-profiles\manager.ps1` to open the Main Window, then click **Disconnect all / Uninstall...** at the bottom
2. Confirm, and choose whether to also delete your data folder (configured paths, saved profiles, log) -- declining leaves it in place
3. The app removes the Vibepollo/Apollo registration, the watchdog scheduled tasks, and the program folder (and, if you chose to, the data folder)

### If You Used Method B (Manual Setup)

1. **Open Vibepollo** → **Configuration** → **Command Preparations** (see Step 3a)
2. **Delete the single row** whose **Do Command** and **Undo Command** fields both point to `sync-configs.ps1` (trash icon), then **Save** and restart Vibepollo
3. **(Optional) Remove scheduled tasks** if you set up the watchdog:
   - Open **Task Scheduler** and delete any tasks named `StreamConfigProfiles-Settle-*`
4. **Delete the data folder** `C:\stream-config-profiles` from your disk

### General Notes

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
- Remove all duplicates, keeping exactly one "do" and one "undo" command (see Step 3e and the warning above)
