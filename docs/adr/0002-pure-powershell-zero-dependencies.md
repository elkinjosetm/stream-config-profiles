# Pure PowerShell, zero dependencies

The tool runs as a `global_prep_cmd` hook on a general population of Windows gaming PCs the project doesn't control, so it ships as plain PowerShell 5.1+ with no modules, binaries, or installers — engine (`sync-configs.ps1`), manager (`manager.ps1`), and build tooling (`build/make-dist.ps1`) are pure `.ps1`, and the GUI uses only in-box WinForms/P/Invoke. Once the project grew a GUI with a companion engine and template file, PowerShell had no native way to ship them as one download; `build/make-dist.ps1` solves this by inlining `sync-configs.ps1` and `paths.example.txt` into two here-string markers in `manager.ps1` to produce `dist/manager.ps1`, then wraps that byte-for-byte into a polyglot `StreamConfigProfiles-Setup.bat` (batch header + marker + verbatim `.ps1` payload, extracted to a temp file and run with `-File`, never `iex`) — self-tested at build time by independently re-implementing the extraction and asserting a byte-identical round trip.

## Considered Options

A compiled .NET/C# helper (for the GUI or the elevation/task-registration pieces) was rejected: it's opaque to a user or antivirus without decompiling, adds a build/signing toolchain the project would have to maintain, and multiplies unsigned-binary AV/SmartScreen friction — a plain-text `.ps1` release artifact is its own inspectable source.
