# Roadmap — known weaknesses, in priority order

Honest list. The system works; these are the places it still leans on luck or
discipline instead of mechanism.

## 1. INBOX / receipts rotation

`org/ceo/INBOX.md` and `RECEIPTS.md` grow forever; the brain reads tails so it
works, but a year of operation shouldn't mean a 5 MB inbox. Rotate to dated
archive files past ~400 lines (only when mtime is quiet to dodge append races).

## 2. PID-reuse hardening

Locks and job liveness use `kill -0 <pid>`. After a reboot (or very long
uptime) a recycled PID could make a stale lock look alive. Record
`<pid>:<boot-epoch>:<start-time>` and compare all three. Low probability,
cheap fix.

## 3. Approval-latency surfacing

The org idles correctly when everything is gated on the human — but "5 items
waiting, oldest is 4 days old" should be loud (chip + `spin` banner + optional
notification), not something you discover by asking.

## 4. Machine-sleep awareness

Ticks silently stop when the laptop sleeps (correct, but invisible). The
watchdog should distinguish "driver dead" from "machine slept" via wall-clock
gap detection, and `workstation.sh status` should report last-tick age.

## 5. A `--dry-run` org mode

For demos and tests: dispatcher prints what it *would* spawn; brain runs against
a sandbox copy of `org/`. Today the install-smoke CI covers plumbing but not a
full simulated tick with a fake agent.

## 6. Job-level provider/model overrides in the queue schema

`max_runtime_seconds` is honored per job (since v3.1); `provider`/`model`
overrides still come from job *type* tiering only. Let the Navigator request
`"provider": "gemini"` per job, with benching still able to veto.

## Done (recently)

- ~~**Stop letting the LLM hand-edit JSON**~~ (was #1, the biggest win) — shipped
  the `org` verb CLI: every state mutation is validated, locked, atomic, and
  append-only; the brain's prompt now forbids direct JSON edits. See
  [ARCHITECTURE](ARCHITECTURE.md#the-org-state-cli--why-agents-dont-touch-json).
- ~~Job timeouts~~ — hung jobs killed (process group) and marked failed; per-job
  `max_runtime_seconds`, default 1 h.
- ~~Dispatcher lock file~~ — a manual supervisor run and the tick can no longer double-dispatch the same job.
- ~~Hardcoded floor map~~ — `workstation.sh` derives floors from the harness.
- ~~Driver watchdog~~ — red chip + notification when the loop dies without a STOP.
- ~~"No inline project work" hard rule~~ — dispatch failures get fixed, not
  papered over by the coordinator doing the work itself.
