# CI matrix includes a real Windows PowerShell 5.1 leg

This project is deliberately dual-`PSEdition` PowerShell (ADR-0002), and Windows PowerShell 5.1 (`PSEdition = Desktop`) is only actually available via `shell: powershell` on a Windows CI runner — a Linux runner, or Windows running pwsh, cannot substitute for it. `ci.yml`'s test matrix runs all three suites across three `fail-fast: false` legs: real 5.1, Windows/pwsh, and Ubuntu/pwsh (the fast default dev loop).

## Consequences

- The Windows legs caught four real bugs before release, two visible only on real 5.1: an explicit `-Name:$true`/`-Name:$false` switch token failing to bind across the `-File` boundary (ADR-0007); a `-IncludeLogon` restoration failure across that same boundary, 5.1-only; a CRLF-only test failure from a literal-LF source check against a Windows/`autocrlf` checkout; and a `ConvertFrom-Json` output-shape divergence (`PSCustomObject` vs. a filtered `Object[]`) breaking a `[bool]` assertion, 5.1-only.
