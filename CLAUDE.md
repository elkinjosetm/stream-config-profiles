Domain vocabulary lives in [CONTEXT.md](CONTEXT.md); decisions and their whys live in [docs/adr/](docs/adr/) — read the ADRs touching your area first and do not re-litigate them.

## The two executables

- **`sync-configs.ps1`** (the engine) — the only piece the streaming host calls, via `-Mode do|undo|settle`. Lives at `<DATA>\sync-configs.ps1` once installed. No GUI, no installation logic.
- **`manager.ps1`** (the manager) — GUI wizard + headless `-Action` CLI for install, host registration, and watchdog management. `#region Core` (headless, path-parameterized, testable on Linux) / `#region Gui` (WinForms, Windows-only) / `#region EmbeddedPayload` (see below).
- Build: `build/make-dist.ps1` inlines the engine + `paths.example.txt` into `manager.ps1`'s payload markers to produce `dist/manager.ps1`, then wraps that into `dist/StreamConfigProfiles-Setup.bat`.
- Install layout: PROGRAM (`%LOCALAPPDATA%\Programs\stream-config-profiles\`) = `manager.ps1` + `launch.vbs`; DATA (`%LOCALAPPDATA%\stream-config-profiles\`) = engine + `paths.txt`/`state.json`/`sync.log`/`profiles\`.

## Invariants — do not break these

- **The engine always exits 0.** A broken config path, a copy failure, a missing `paths.txt` — log it, never throw past the top level. Vibepollo must never see a nonzero exit and block a stream launch.
- **Strict dual PowerShell syntax: 5.1 (Desktop) and 7 (Core), everywhere.** No ternary, no `??`, no `&&`/`||` — none of these parse on Windows PowerShell 5.1. `PSUseCompatibleSyntax` (targets `5.1`/`7.0`) is fatal in CI regardless of severity.
- **Explicit `-Encoding` on every text read/write.** Default encoding differs between 5.1 and 7; an implicit encoding is a latent cross-version bug.
- **Source-level test regexes must be `\r?\n`-tolerant, never a literal `\n`/LF assumption.** Windows checkouts are CRLF (`autocrlf`); a literal-LF `IndexOf`/regex check passes on Linux dev and fails only on the Windows PowerShell 5.1 CI leg. This has already regressed once (~25 checks swept in one pass) — see [ADR-0011](docs/adr/0011-ci-real-windows-powershell-51-leg.md).
- **Every switch parameter that can cross the `-File` elevation boundary defaults `$false`.** `-File` parses arguments as literal strings, so `-Name:$true`/`-Name:$false` fails to bind to `[SwitchParameter]` — only a bare `-Name` (true) or its omission (false) survives. Why `-SkipLogon` exists instead of `-IncludeLogon`: [ADR-0007](docs/adr/0007-file-elevation-boundary-contract.md).
- **Never elevate a `%TEMP%` script path.** Elevation must always target the installed PROGRAM copy, never a throwaway extraction — a world-writable temp path is a strictly weaker elevation target. Why the auto-upgrade path repoints elevation at the freshly-written PROGRAM copy: [ADR-0010](docs/adr/0010-in-place-upgrade-path.md); the mechanism itself is in `Invoke-ManagerAutoUpgrade`.

## Validating a change

Run all of these before calling a change done — CI enforces the same set:

1. `./tests/run-tests.ps1` — engine suite (do/undo/settle scenarios, `sync-configs.ps1`).
2. `./tests/manager-tests.ps1` — manager suite (install, elevation boundary, watchdog, upgrade).
3. `./tests/make-dist-tests.ps1` — build suite (payload inlining, Setup.bat polyglot extraction).
4. `./build/make-dist.ps1` — the build's own self-test: independently re-implements the Setup.bat extraction and asserts a byte-identical round-trip against `dist/manager.ps1`. A parse-check alone is not sufficient here — see [ADR-0012](docs/adr/0012-release-pipeline-single-file.md).
5. `actionlint` against `.github/workflows/*.yml` for any workflow edit.

All three suites are self-contained (no Pester); the engine suite (`run-tests.ps1`) runs against a `robocopy` PATH shim off-Windows. Run all three on real Windows PowerShell 5.1 before trusting a change near the elevation boundary or JSON parsing — [ADR-0011](docs/adr/0011-ci-real-windows-powershell-51-leg.md).

## Release process

Tag `vX.Y.Z` and push it (`git tag && git push --tags`) to fire `release.yml`'s test → build → release pipeline. If a pipeline bug is found after tagging, re-run the **current** workflow against that tag via `workflow_dispatch` (required `tag` input) instead of deleting/recreating the tag. Asset publish is an upsert (`gh release view` then `--clobber`), not create-only, since the common path is a maintainer publishing release notes — and thus the tag — from the GitHub UI first.
