# Architecture Decision Records

Numbered sequentially: `000N-slug.md`. Scan for the highest existing number and increment by one.

Add one when all three are true: the decision is **hard to reverse**, **surprising without context** (a future reader would look at the code and wonder why), and the result of a **real trade-off** between genuine alternatives. Skip decisions that are easy to reverse, unsurprising, or had no real alternative — there's nothing to record beyond "we did the obvious thing."

| # | Title |
|---|-------|
| [0001](0001-save-at-start-with-state-file.md) | Save-at-start with a state file, not `undo` |
| [0002](0002-pure-powershell-zero-dependencies.md) | Pure PowerShell, zero dependencies |
| [0003](0003-per-user-install-program-data-split.md) | Per-user install with a Program/Data folder split |
| [0004](0004-vibepollo-integration-via-conf-editing.md) | Register with Vibepollo/Apollo by editing its `.conf` file directly |
| [0005](0005-settle-guard-by-host-instance-identity.md) | Settle-mode recovery gated on host instance identity, not process existence |
| [0006](0006-watchdog-user-level-no-boot-task.md) | Watchdog runs entirely at user level; no boot-time task |
| [0007](0007-file-elevation-boundary-contract.md) | File-elevation boundary contract: bare-token switches, pre-resolved identity, single quoted command line |
| [0008](0008-windowless-launch-via-wscript.md) | Windowless launch via wscript.exe + generated launch.vbs |
| [0009](0009-dpi-and-adaptive-layout.md) | DPI awareness and adaptive GUI layout |
| [0010](0010-in-place-upgrade-path.md) | In-place upgrade path with repointed elevation target |
| [0011](0011-ci-real-windows-powershell-51-leg.md) | CI matrix includes a real Windows PowerShell 5.1 leg |
| [0012](0012-release-pipeline-single-file.md) | Release pipeline: tag-frozen workflow with dispatch escape hatch, single-file Setup.bat installer |
