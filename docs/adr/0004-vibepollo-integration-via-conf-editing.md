# Register with Vibepollo/Apollo by editing its `.conf` file directly

Vibepollo/Apollo's web UI has no documented automation contract (no CLI, no REST endpoint) and can change layout between versions, so the install wizard's "Connect to Vibepollo" step instead edits the host's `.conf` file directly — its actual persisted `key=value`/JSON `global_prep_cmd` state, not a rendering of it.

## Finding the conf file

`Find-HostConf` locates it via a layered strategy, each layer only running if the previous found nothing:

1. Known install paths.
2. A matching Windows service's binary/config dir.
3. A wildcard `*.conf` scan.

Program Files roots are probed in the order `ProgramW6432` → `$env:ProgramFiles` → `ProgramFiles(x86)`: WOW64 redirects `$env:ProgramFiles` on 32-bit Windows PowerShell 5.1, and `ProgramW6432` is the one variable it doesn't redirect, so probing it last would silently prefer a stale x86 install over a real 64-bit one.

## Writing

`Write-ConfGlobalPrepCmd`:

- Identifies our entry by its `do` command containing the engine's own path.
- Always merges with (never clobbers) other tools' entries.
- Is preceded by a timestamped backup.
- Applies the write atomically via a temp file + `[System.IO.File]::Replace`.
- Checks both the leaf conf path and every parent directory for being a reparse point before any elevated write, closing a symlink-planting privilege-escalation angle.

Unregistering removes only our entry and leaves the `.bak` on disk for manual recovery rather than auto-restoring it.
