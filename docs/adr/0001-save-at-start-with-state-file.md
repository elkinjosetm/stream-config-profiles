# Save-at-start with a state file, not `undo`

Vibepollo/Apollo only guarantees `do` (session start) fires — `undo` can be skipped by a disconnect, crash, or resumed session — so persisting a session's config in `undo` would lose it. Instead `sync-configs.ps1` saves at `do`, using `state.json` to detect an orphaned previous session and save its state first.

## Consequences

- Playing locally while a session is pending attributes those changes to the orphaned client's profile at the next `do` — accepted as a known limitation.
