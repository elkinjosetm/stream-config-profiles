# Save-at-start with a state file, not `undo`

Vibepollo/Apollo only guarantees `do` fires (session start) — `undo` (session end) can be skipped entirely by a disconnect, host crash, or a resumed Desktop-app session — so persisting a session's config in `undo` would lose it whenever that happens. Instead `sync-configs.ps1` saves at `do`, coordinating through `state.json`.

## The algorithm

- **At `do`**: read `state.json` for a pending session left by a previous client A.
  - If one exists, the current disk state (A's orphaned settings) is saved into A's profile and `_local` is left untouched.
  - Otherwise (the clean case), disk is saved into `_local` before restoring/seeding the incoming client B's profile.
  - Either way, `{ activeClient: B, since }` is written. A reconnect (A == B) falls out of the same steps as a harmless round trip.
- **At `undo`**: first check for a pending session and no-op otherwise, since a stray or duplicate `undo` would overwrite a client's profile with the already-restored `_local` state.
- **Profile entries**: every path gets a stable `<hash8>_<leaf>` name (hash of the lowercased, separator-stripped path) so same-named config files across games don't collide.
- **Exit code**: the script always exits 0, so a broken path never blocks a stream launch.

## Consequences

Known accepted limitation: playing locally while a session is still pending attributes those local changes to the orphaned client's profile at the next `do`, since disk contents alone can't distinguish "orphaned client state" from "user played locally on top of it."
