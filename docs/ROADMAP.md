# Roadmap — known weaknesses, in priority order

Honest list. The system works; these are the places it still leans on luck or
discipline instead of mechanism.

## 1. Stop letting the LLM hand-edit JSON (biggest win)

Today the CEO brain *writes `org/state.json` and `org/AGENT_QUEUE.json` directly*.
It's prompt-disciplined ("append, don't replace") and it has worked — but an LLM
editing shared JSON is the least robust joint in the machine (we've seen one
wrong-direction doc edit and one node crash mid-run).

**Plan:** a tiny `org` verb CLI the brain calls instead of writing files:

```
org queue-job <project> <type> "<description>"
org set-handoff <project> <<'EOF' … EOF
org escalate "<human-queue item>"
org process-approval <line-id> --action approve --note "…"
org receipt <<'EOF' … EOF
```

Each verb validates, locks, appends, never deletes. The brain's write access
drops to receipts only. This also makes every state mutation unit-testable.

## 2. INBOX / receipts rotation

`org/ceo/INBOX.md` and `RECEIPTS.md` grow forever; the brain reads tails so it
works, but a year of operation shouldn't mean a 5 MB inbox. Rotate to dated
archive files past ~400 lines (only when mtime is quiet to dodge append races).

## 3. PID-reuse hardening

Locks and job liveness use `kill -0 <pid>`. After a reboot (or very long
uptime) a recycled PID could make a stale lock look alive. Record
`<pid>:<boot-epoch>:<start-time>` and compare all three. Low probability,
cheap fix.

## 4. Approval-latency surfacing

The org idles correctly when everything is gated on the human — but "5 items
waiting, oldest is 4 days old" should be loud (chip + `ceo` banner + optional
notification), not something you discover by asking.

## 5. Machine-sleep awareness

Ticks silently stop when the laptop sleeps (correct, but invisible). The
watchdog should distinguish "driver dead" from "machine slept" via wall-clock
gap detection, and `workstation.sh status` should report last-tick age.

## 6. A `--dry-run` org mode

For demos and tests: dispatcher prints what it *would* spawn; brain runs against
a sandbox copy of `org/`. Today the install-smoke CI covers plumbing but not a
full simulated tick with a fake agent.

## 7. Job-level provider/model overrides in the queue schema

`max_runtime_seconds` is honored per job (since v3.1); `provider`/`model`
overrides still come from job *type* tiering only. Let the CEO request
`"provider": "gemini"` per job, with benching still able to veto.

## Done (recently)

- ~~Job timeouts~~ — hung jobs killed (process group) and marked failed; per-job
  `max_runtime_seconds`, default 1 h.
- ~~Dispatcher singleton lock~~ — manual run + tick can no longer double-dispatch.
- ~~Hardcoded floor map~~ — `workstation.sh` derives floors from the harness.
- ~~Driver watchdog~~ — red chip + notification when the loop dies without a STOP.
- ~~"No inline project work" hard rule~~ — dispatch failures get fixed, not
  papered over by the coordinator doing the work itself.
