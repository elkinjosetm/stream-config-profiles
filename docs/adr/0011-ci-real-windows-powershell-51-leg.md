# CI matrix includes a real Windows PowerShell 5.1 leg

This project is deliberately dual-`PSEdition` PowerShell (ADR-0002), and Windows PowerShell 5.1 (`powershell.exe`, `PSEdition = Desktop`) is only actually available on a Windows CI runner using `shell: powershell` — a Linux runner, or even a Windows runner running pwsh, cannot substitute for it. `ci.yml`'s test matrix runs all three suites across three `fail-fast: false` legs: `windows-latest`/`powershell` (real 5.1), `windows-latest`/`pwsh`, and `ubuntu-latest`/`pwsh` (the fast default dev loop).

## Bugs this caught

In practice the Windows legs caught four real bugs before release, two of them visible only on real 5.1:

- An explicit `-Name:$true`/`-Name:$false` switch token failing to bind across the `-File` boundary (ADR-0007, also visible on pwsh-on-Windows).
- A `-IncludeLogon` restoration failure across that same boundary that was 5.1-only.
- A CRLF-only test failure from a literal-LF source check against a Windows/`autocrlf` checkout (swept to a `\r?\n`-tolerant convention across ~25 similar checks).
- A `ConvertFrom-Json` output-shape divergence (`PSCustomObject` vs. a filtered `Object[]`) that broke a `[bool]` assertion, also 5.1-only.

## Other CI shape decisions

- Because `shell:` cannot take a matrix expression, each test suite runs as two separate steps gated by `if: matrix.shell == '...'` rather than one interpolated step.
- A workflow-level `concurrency` group cancels a stale in-flight run on a new push to the same ref (the Windows legs bill 2x runner-minutes) — `release.yml` is deliberately excluded from this group so a release run is never silently cancelled by an unrelated push.
- A `build-dist` job additionally runs `build/make-dist.ps1` and asserts byte-identical output (ADR-0012).
- A `lint` job runs PSScriptAnalyzer pinned to `1.24.0`, treating `Error`/`ParseError` severity and any `PSUseCompatibleSyntax` diagnostic as fatal.
