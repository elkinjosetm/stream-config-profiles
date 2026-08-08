# Register with Vibepollo/Apollo by editing its `.conf` file directly

Vibepollo/Apollo's web UI has no documented automation contract (no CLI, no REST endpoint) and can change layout between versions, so the install wizard edits the host's `.conf` file directly — its actual persisted `global_prep_cmd` state, not a rendering of it.

## Consequences

- Program Files roots are probed `ProgramW6432` → `$env:ProgramFiles` → `ProgramFiles(x86)`, since WOW64 redirects `$env:ProgramFiles` on 32-bit PowerShell 5.1 and `ProgramW6432` doesn't — probing it last would silently prefer a stale x86 install.
- The conf path and its parent directories are checked for reparse points before any elevated write, closing a symlink-planting privilege-escalation angle.
