# Pure PowerShell, zero dependencies

The tool runs as a `global_prep_cmd` hook on a general population of Windows gaming PCs the project doesn't control, so it ships as plain PowerShell 5.1+ with no external modules, binaries, or installers — engine, manager, and build tooling are pure `.ps1`, and the GUI uses only in-box WinForms/P-Invoke.

## Considered Options

A compiled .NET/C# helper for the GUI or elevation pieces was rejected: it's opaque to a user or antivirus without decompiling, requires a build/signing toolchain, and multiplies unsigned-binary AV/SmartScreen friction — a plain-text `.ps1` release artifact is its own inspectable source.
