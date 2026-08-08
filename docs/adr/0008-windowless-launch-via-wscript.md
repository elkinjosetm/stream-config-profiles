# Windowless launch via wscript.exe + generated launch.vbs

Launching the manager from its shortcut showed a console window alongside the GUI, because Windows Terminal (the default console host on Windows 11) doesn't reliably honor `-WindowStyle Hidden` on `powershell.exe`. The shortcut now targets `wscript.exe` running a generated `launch.vbs` via `WshShell.Run(..., 0, False)` — a genuinely windowless host regardless of the user's default terminal.

## Consequences

- Scoped to the end-user launch path only — the STA self-relaunch, elevated `-Action` re-entry, and `Setup.bat`'s own extraction step stay on plain `powershell.exe -WindowStyle Hidden`, since each is a child of a session the user already started.
