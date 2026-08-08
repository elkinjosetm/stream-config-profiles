# Watchdog runs entirely at user level; no boot-time task

The watchdog registers two scheduled tasks — Logon/unlock (default on) and periodic Poll (default off) — both under an Interactive, user-level principal, never SYSTEM. An earlier build also registered a SYSTEM-level Boot task, but it was removed: it pointed at a script in the user's own writable data folder, so anything able to write there while it existed would get SYSTEM execution at the next restart, for no protection beyond what the Logon trigger already provides.

## Consequences

- Registering a logon-type trigger unelevated always fails, even though the task's own principal is the user — the GUI treats a per-task failure as a cue to offer a confirm-and-elevate retry; headless mode just reports it.
