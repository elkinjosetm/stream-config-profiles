# File-elevation boundary contract: bare-token switches, pre-resolved identity, single quoted command line

`manager.ps1` re-launches itself elevated via `powershell.exe -File`, which parses arguments as literal strings — so an explicit `-Name:$true`/`-Name:$false` token fails to bind to `[SwitchParameter]` at all, a bug caught on both Windows CI legs plus a related 5.1-only default-restoration failure. `ConvertTo-ElevatedArgumentString` fixes this by rendering every switch as a bare `-Name` for true and omitting it for false — requiring every crossing switch to default `$false` (hence `-IncludeLogon` became `-SkipLogon`) — while identity/paths are resolved once pre-elevation rather than re-derived, and the command line is built as one fully-quoted string, guarding against injection from paths with spaces or quotes.

## Consequences

- The `-SkipLogon` (boundary)/`-IncludeLogon` (in-process) name split must stay synchronized at the one conversion site — getting it wrong silently reintroduces the original bug rather than failing loudly.
- Every new switch parameter that can cross this boundary must default `$false`; enforced by convention and tests, not the language.
