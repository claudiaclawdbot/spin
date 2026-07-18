# Core System Roadmap — known weaknesses + what's next, in priority order

Honest list for the plain-file SPIN runtime: `spin`, `org`, the Navigator loop,
project floors, jobs, approvals, receipts, and supervisors. The macOS wrapper
work is tracked separately in [APP_ROADMAP](APP_ROADMAP.md) so app packaging and
core orchestration do not blur together.

## 1. INBOX / receipts rotation

`org/ceo/INBOX.md` and `RECEIPTS.md` grow forever; the brain reads tails so it
works, but a year of operation shouldn't mean a 5 MB inbox. Rotate to dated
archive files past ~400 lines (only when mtime is quiet to dodge append races).

## 2. Coordinator-driven onboarding (conversational)

`spin init` is a solid bash wizard, but the real vision is the **Coordinator
agent** onboarding you: first run drops you into the Coordinator floor with an
onboarding directive, and it asks what you want to build, creates the project
(`spin new-project`), and briefs it — all in conversation. Keep the bash wizard
as the headless fallback.

## 3. Live OMP/cmux product proof and a `--dry-run` org mode

SPIN's central claim is not just that one job can dispatch. It is that multiple
scoped project agents can stay context-isolated while the Navigator maintains the
organization-level view. The smoke test now proves the org protocol offline with
deterministic project-agent stubs for `example-app` and `workspace`, and the app
release checks prove first launch creates the `SPIN Onboarding` workspace through
the bundled cmux-compatible CLI.

For demos and tests: dispatcher prints what it *would* spawn; brain runs against
a sandbox copy of `org/`. CI covers plumbing, symlink/launcher paths, app
onboarding launch, and the multi-project org protocol. It still does not run live
OMP provider execution because that requires user accounts, credentials, and a
GUI session; those remain release validation items until there is an integration
rig for them.

## 4. Owner-facing action policy management

The broker has a strict machine-readable policy, pinned commands, exact targets,
and one-shot leases, but adding a new rule still requires editing JSON. Add a
local owner-only editor that previews the resolved executable hash, environment
names, target attestation, and final rule diff before it can enable or lease the
rule. Keep the seeded state deny-all and preserve the existing CLI for headless
operators.

## 5. Job-level provider/model overrides in the queue schema

`max_runtime_seconds` is honored per job; `provider`/`model` overrides still come
from job *type* tiering only. Let the Navigator request `"provider": "omp"` (e.g.
the OpenRouter lane) per job, with benching still able to veto.

## 6. Cross-platform reach

The supervisor is launchd (macOS) / systemd-user (Linux); Windows/WSL users fall
back to `spin start`. A scheduled-task path (or a documented WSL recipe) would
close the gap.

## Done (recently)

- ~~**Machine-gated sensitive actions**~~ — `spin action` denies by default,
  matches exact owner-enabled targets to fixed command vectors, and requires a
  one-shot lease bound to the policy, executable bytes, resolved working
  directory, allowlisted environment names, and exact target. Protected pushes
  additionally bind the resolved remote repository and destination branch.
  Shipped controller prompts also prohibit direct execution; hard bypass
  resistance still requires OS or credential isolation.
- ~~**Race-free singleton ownership**~~ — shell and Node runtimes acquire fully
  written locks with atomic hardlinks, bind them to the process start identity,
  reclaim stale locks without deleting a replacement owner's lock, and retain
  read compatibility with legacy one-line PID files.
- ~~**Outcome-aware job completion**~~ — newly dispatched jobs must write one
  semantic `completed` or `blocked` outcome sidecar. Missing or malformed
  evidence fails closed, and ordinary provider failures do not trigger a second
  provider that could repeat partial work.
- ~~**Visible execution and resource state**~~ — the Coordinator board and local
  control panel show running, queued, blocked, failed, stale-heartbeat, and live
  RSS/process data. The cmux dock includes a direct Control entry and the status
  watcher keeps a work chip current without an LLM call.
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
- ~~**Durability: the control plane stays truthful**~~ — `spin service` installs
  independent launchd/systemd supervision for the driver, live status roll-up,
  and wiki watcher. The driver regenerates the board at startup, status checks
  verify PID plus command identity, and the status service reconciles restored
  cmux floors after login/reboot while still showing an intentional STOP.
- ~~**Bounded detached jobs**~~ — normal background jobs default to 3072 MB RSS /
  16 processes, dispatch slows or pauses to preserve a 2048 MB system reserve,
  and broad tests/native builds use an exclusive `heavy` lease (6144 MB / 32
  processes). A breach kills the detached group, writes a `.resource` artifact,
  and fails the queue item with an actionable reason.
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
