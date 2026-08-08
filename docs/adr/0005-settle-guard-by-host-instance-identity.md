# Settle-mode recovery gated on host instance identity, not process existence

Settle mode recovers an orphaned session (`undo` never fired) at logon/unlock. Checking whether the host process still exists is unsound, since Vibepollo/Apollo runs as an always-on service that could have crashed and restarted — so settle instead compares the host process's `StartTime` against the pending session's `since` timestamp, recovering only when no matching instance was already running at or before that time.

## Consequences

- A genuinely stuck session (same instance still running, client gone for good) is never recovered by settle — it waits for the next `do` or a host restart, a deliberately conservative failure mode.
