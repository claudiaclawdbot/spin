# Core System Roadmap — known weaknesses + what's next, in priority order

Honest list for the plain-file SPIN runtime: `spin`, `org`, the Navigator loop,
project floors, jobs, approvals, receipts, and supervisors. The macOS wrapper
work is tracked separately in [APP_ROADMAP](APP_ROADMAP.md) so app packaging and
core orchestration do not blur together.

## 1. Harden the singleton lock (atomicity)

Found while wiring up the launchd supervisor: the "only one driver" guard writes
its PID with `echo $$ > lock` under `noclobber`. The *create* is atomic, but
there's a sliver between create and write where a second near-simultaneous start
can read an empty lock, decide it's stale, clobber it, and **both run** — the
exact duplicate-driver failure that once burned a weekly quota. In practice the
supervisor (launchd/systemd) only starts one, so it doesn't bite — but it should
be mechanically impossible. Fix: write the PID to a temp file and `ln` (hardlink)
it into place — `ln` is atomic and fails if the target exists, so the lock always
has its PID. Apply to the driver, the watchers, and the dispatcher.

## 2. INBOX / receipts rotation

`org/ceo/INBOX.md` and `RECEIPTS.md` grow forever; the brain reads tails so it
works, but a year of operation shouldn't mean a 5 MB inbox. Rotate to dated
archive files past ~400 lines (only when mtime is quiet to dodge append races).

## 3. Coordinator-driven onboarding (conversational)

`spin init` is a solid bash wizard, but the real vision is the **Coordinator
agent** onboarding you: first run drops you into the Coordinator floor with an
onboarding directive, and it asks what you want to build, creates the project
(`spin new-project`), and briefs it — all in conversation. Keep the bash wizard
as the headless fallback.

## 4. PID-reuse hardening

Locks and job liveness use `kill -0 <pid>`. After a reboot (or very long uptime)
a recycled PID could make a stale lock look alive. Record
`<pid>:<boot-epoch>:<start-time>` and compare all three. (Pairs with #1.)

## 5. Live OMP/cmux product proof and a `--dry-run` org mode

SPIN's central claim is not just that one job can dispatch. It is that multiple
scoped project agents can stay context-isolated while the Navigator maintains the
organization-level view. The smoke test now proves this org protocol offline
with deterministic project-agent stubs for `example-app` and `workspace`.

For demos and tests: dispatcher prints what it *would* spawn; brain runs against
a sandbox copy of `org/`. CI covers plumbing, symlink/launcher paths, and the
multi-project org protocol, but not live OMP provider execution or the cmux
floor-spawn (no GUI in CI — currently manual-verified only).

## 6. Job-level provider/model overrides in the queue schema

`max_runtime_seconds` is honored per job; `provider`/`model` overrides still come
from job *type* tiering only. Let the Navigator request `"provider": "omp"` (e.g.
the OpenRouter lane) per job, with benching still able to veto.

## 7. Cross-platform reach

The supervisor is launchd (macOS) / systemd-user (Linux); Windows/WSL users fall
back to `spin start`. A scheduled-task path (or a documented WSL recipe) would
close the gap. Also: a screenshot/GIF of the cmux interface on the landing site.

## Done (recently)

- ~~**Optional web control panel**~~ — `spin web` starts a local-only browser
  panel that renders projects, queued jobs, approvals, floor boards, and recent
  receipts from the plain files; approve/decline/ask buttons write back to the
  normal `APPROVALS.md` flow.
- ~~**Approval-latency surfacing**~~ — `spin` and the live dashboard now show the
  active human-wait count plus oldest age; the status watcher paints a cmux chip
  and can send a one-shot notification when the oldest item crosses
  `SPIN_APPROVAL_NOTIFY_MINUTES`.
- ~~**Richer project floors (2-pane layout)**~~ — `spin new-project` and `spin up`
  now seed `FLOOR.md` boards and open them in a live cmux markdown pane beside
  each project agent; existing projects missing a board get one backfilled.
- ~~**Stale-STOP alarm**~~ — a STOP file is an intentional pause, but one left for
  hours is forgotten (it once silently paused the driver ~20h). The watchdog now
  escalates a STOP older than 2h (`SPIN_STALE_STOP_HOURS`) with an orange chip +
  notification, instead of a quiet "paused" forever.
- ~~**Durability: the driver stays up**~~ — `spin service` installs a supervisor
  (launchd on macOS, systemd-user on Linux) that respawns the driver on
  crash/pane-close/wake and pauses cleanly on the STOP file. (Largely closes the
  old "machine-sleep awareness" item — it resumes on wake.)
- ~~**cmux is the GUI**~~ — `spin up` opens the Coordinator floor + driver + boards;
  `spin new-project <id> "<goal>"` registers a project AND spawns its cmux floor
  (a sidebar tab) with its own omp orchestrator; the Coordinator creates projects
  conversationally.
- ~~**OpenRouter (and Groq/xAI/Mistral/…)**~~ — OMP is now the primary harness;
  SPIN writes `modelRoles` + `retry.fallbackChains` at runtime, and
  `CEO_OMP_MODEL` is just an optional OpenRouter entry in that chain.
- ~~**Onboarding wizard**~~ — `spin init`: providers, OpenRouter, first project, supervisor.
- ~~**Single-file install, fixed**~~ — split into a tiny `curl|bash` launcher
  (`spin-bootstrap.sh`) + an offline self-extractor (`spin-offline.sh`) after the
  fat piped script desynced over real networks.
- ~~**Symlink-safe commands**~~ — `spin`/`org` resolve their real repo when run via
  the `~/.local/bin` symlink (was "no such file" on `spin init`).
- ~~**Stop letting the LLM hand-edit JSON**~~ — the `org` verb CLI (validated, locked,
  atomic, append-only). See [ARCHITECTURE](ARCHITECTURE.md#the-org-state-cli--why-agents-dont-touch-json).
- ~~Job timeouts~~ · ~~dispatcher lock~~ · ~~harness-driven floors~~ · ~~driver watchdog~~ ·
  ~~"no inline project work" rule~~.
