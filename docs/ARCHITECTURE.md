# Architecture

How the org actually works, layer by layer. If you're an agent reading this:
this describes the system you're part of.

## Product definition

SPIN is a lightweight harness above multiple scoped OMP project agents. It uses a
SPIN-branded cmux workspace for the human-visible multiplexer, OMP as the primary
agent/provider engine, and plain files as the org protocol.

The architecture exists to preserve context isolation. Each project agent keeps
its own repository, handoff, state, queue, memory, and receipts. The SPIN
Navigator keeps the organization-level map across those projects and routes work
without collapsing every project into one giant shared prompt.

The first target is OMP-backed project floors. Direct `codex`, `claude`,
`gemini`, and `ollama` lanes are outer fallback paths when OMP is unavailable or
hard-fails, not the main product identity.

## The five layers

1. **Human (owner).** Sets direction, answers the four gated asks, funds wallets.
   Interface: the `spin` command and (optionally) cmux floors.
2. **Chat assistant (optional).** Your conversational front door. It reads and
   writes the same org files as everything else — it is *not* the autonomous loop.
3. **SPIN Navigator.** The single driver loop (`scripts/workspace-ceo-tick.sh`).
   Coordinates, never codes. Only one instance can run: it claims a lock file
   at startup and a second launch exits immediately.
4. **Project orchestrators.** One per registered project. Run either as dispatched
   background jobs (`scripts/project-ceo-agent.sh <id>`) or as live cmux/omp floor
   agents for explicit human-visible handoffs. A canonical project-root resolver
   starts every provider in that project's configured code directory, while its
   own handoff, state, receipts, and provider overrides stay under
   `org/projects/<id>/`.
5. **Workers / subagents.** Per-task LLM invocations a project orchestrator spawns.

## One tick, in detail

`workspace-ceo-tick.sh` loops forever (default every 900 s). Each tick:

1. **Render** the cockpit — org state, provider status, inbox tail — to its pane.
2. **Dispatch** (`omp-supervisor-once.sh`):
   - detect exited jobs by PID liveness, then require an explicit semantic
     outcome for newly dispatched work;
   - spawn each `queued` job in `org/AGENT_QUEUE.json` as a **detached background
     process** with its own PID file and log under `org/jobs/`;
   - enforce one-job-per-project and a global parallelism cap (default 3);
   - enforce a per-job process-tree budget (default 3072 MB RSS and 16
     processes; 6144 MB and 32 processes for an exclusive heavy job), killing
     the detached group and recording the exact violation;
   - block jobs whose `project_id` isn't registered in `org/OMP_HARNESS.json`
     or whose type isn't in that project's `allowed_job_types`;
   - update cmux status chips (display only — never executes through cmux).
3. **Brain** (`workspace-ceo-agent.sh`) — *only if* watched inputs changed
   (content hash over APPROVALS, INBOX, HUMAN_QUEUE, project STATE files, with
   volatile timestamp fields stripped), or every Nth tick as a heartbeat. It calls
   the `org` CLI (never edits JSON by hand) to:
   - process human approvals (`org process-approval` moves them Pending → Processed);
   - decide each project's next step (`org queue-job`, `org set-handoff`, `org set-state`);
   - escalate *only* the four gated things (`org escalate` → `org/HUMAN_QUEUE.md`);
   - write a receipt (`org receipt` → `org/ceo/runs/`) — the audit trail.
   A timeout guard kills a hung brain so the loop never freezes.

## The `org` state CLI — why agents don't touch JSON

An LLM editing shared JSON is the least robust joint in any file-based org: one
mistyped bracket corrupts the queue. So every state mutation goes through
`scripts/org` (a small node CLI). Each verb **validates** (unknown project or
disallowed job type is rejected), takes an **exclusive lock** (atomic create,
stale-lock break-in by dead-PID check), writes **atomically** (temp + rename),
and is **append-only** where history matters. The brain's prompt forbids direct
JSON edits; its only freeform writes are receipts and project-prompt drafts.

## Job lifecycle

The durable background path uses the queue:

```
Navigator brain ──appends──▶ AGENT_QUEUE.json (status: queued)
tick N+1 dispatcher ──spawns──▶ bash project-ceo-agent.sh <project>   (detached, env: OMP_JOB_*)
                                 │  log: org/jobs/<id>.log   pid: org/jobs/<id>.pid
agent ──writes──▶ project STATE.json + RECEIPTS.md + Queue-Outcome marker
tick N+2 dispatcher ──sees pid dead + validates outcome sidecar──▶ completed | blocked | failed
brain (gate sees INBOX change) ──reads receipt──▶ decides next step
```

An exit code of zero is only process success. New jobs also carry
`org/jobs/<id>.outcome.json`, atomically derived from exactly one
`Queue-Outcome: <id> COMPLETED|BLOCKED` receipt marker. Missing, malformed, or
ambiguous outcome metadata fails closed, so blocked work cannot unlock a
dependent job merely because its provider exited cleanly. Queue records created
before this contract retain their legacy exit-code behavior.

Blocked and failed records stay in queue history. After the operator has
reviewed one, `org acknowledge-job <job-id> [--note "..."]` records that
acknowledgement atomically and removes the record from current attention views
without deleting it.

The live visual path is explicit: `spin delegate --wait <project> "<task>"`
types a stamped request into that project's cmux/omp floor and waits for a matching
`org inbox` report (`delegate <id> complete: ...` or `blocked: ...`). Use it when
the human asked to message or watch the project coordinator directly; use the queue
for autonomous/background work.

Model tiering is automatic: `read-only-worker`/`scout` jobs start OMP on a cheap
fast role; `implementation-worker`/`project-ceo-run` start OMP on the default
work role. OMP handles model/provider fallback inside the run.

## OMP-first fallback (`scripts/lib/ceo-waterfall.sh`)

SPIN treats **OMP as the primary agent harness**, not just another LLM provider.
For every execution lane, SPIN writes an ignored runtime overlay:

```
org/ceo/runs/omp-configs/<lane>.yml
```

Coordinator, project floor, queued job, one-shot, and Navigator chat lanes use
distinct files so concurrent model policies cannot overwrite one another. An
explicit owner-provided `SPIN_OMP_CONFIG` remains an intentional opt-out. Each
overlay declares OMP `modelRoles` plus `retry.fallbackChains`. OMP then owns:

- retrying transient/rate/usage/server/network failures,
- switching between authenticated credentials for the same provider,
- falling through configured models/providers such as Anthropic → OpenAI Codex → OpenRouter,
- restoring the primary model after cooldown when OMP says it is safe.

The outer SPIN fallback is only for cases where OMP is unavailable or cannot
produce a usable run:

```
omp → codex → claude → gemini → ollama
```

Each outer attempt has a deadline derived from the queued job's runtime budget
and keeps its own attempt log. SPIN advances only after a timeout, a missing or
non-executable CLI, OMP's fail-fast command-line usage status, or a direct
provider lockout already present before the attempt. It never infers retry safety
from provider log text. An
ordinary task failure stops the chain so another provider cannot duplicate
partial project work.

SPIN validates Codex candidates before using them and prefers an explicit
`SPIN_CODEX_BIN`/`CODEX_CLI_PATH` or the signed CLI inside ChatGPT/Codex.app over
a broken PATH shim. Unless `CEO_CODEX_MODEL` is explicitly set, the direct lane
uses the subscription account's current default instead of pinning a stale model.

Direct CLI providers still honor SPIN's old owner/control-plane bench files
(`org/ceo/runs/.<provider>-blocked-until`). OMP is deliberately not benched by
SPIN for provider 429s because OMP tracks those per account/provider internally;
benching the whole OMP harness would throw away the fallback chain.

### Desktop execution

Desktop control is a separate Codex-owned lane, not an OMP MCP capability. OMP
delegates a bounded task through `scripts/codex-computer-use.sh`; the script
selects a working signed OpenAI Codex CLI, and that Codex process owns the
`node_repl` Computer Use wrapper and native service trust chain. SPIN suppresses
OMP's imported direct `computer-use` MCP because an OMP child cannot inherit
that trust relationship. `spin doctor` proves configuration only. A live
release gate must also pass `spin computer-use probe`.

Set `SPIN_CODEX_COMPUTER_USE_MODEL` to pin this lane to a separately selected
Codex model. Without it, the signed Codex CLI uses the account's configured
default, independently of OMP's model fallback chain.

Useful overrides in `~/.config/omp.env`:

```
export SPIN_OMP_DEFAULT_MODEL=anthropic/claude-sonnet-4-6
export SPIN_OMP_DEFAULT_FALLBACKS="openai-codex/gpt-5-codex openrouter/anthropic/claude-sonnet-4.6 openai/gpt-5"
export SPIN_OMP_SMOL_MODEL=anthropic/claude-haiku-4-5
export SPIN_OMP_SMOL_FALLBACKS="openai-codex/gpt-5.1-codex-mini openrouter/~anthropic/claude-haiku-latest openai/gpt-5-mini"
```

## Watchdogs & failure modes

| Failure | Defense |
|---|---|
| duplicate driver loops (quota burn) | fully written hardlink lock claimed atomically and bound to process-start identity; coordinated stop pins ownership until exit |
| hung brain | per-run `timeout`, loop continues |
| agent exits 0 without state or receipt evidence | post-run content diff fails closed without a duplicate provider run |
| agent exits 0 while the business outcome is blocked | semantic outcome sidecar marks the job blocked and prevents dependent dispatch |
| driver/status/wiki service dies | launchd/systemd independently restarts all three; the board verifies PID plus expected command |
| restored cmux session has stale/missing floors | status-watch periodically reconciles the Coordinator, active project floors, and boards |
| agent or test runner consumes the machine | adaptive dispatch preserves a memory reserve; heavy jobs run alone; process-group RSS/count governor kills a breach and records the reason |
| forgotten STOP file | status-watch remains alive and paints a paused/stale chip + notification |
| owner pauses the org | `touch org/ceo/runs/STOP` (resume: `rm`) — explicit, visible state |
| machine sleeps or reboots | supervised services resume on login/wake and regenerate visible process state |

## cmux and live delegation

Floors (one cmux workspace per project) show: a live markdown status board, a
log tail of the latest job, status chips, and an *idle interactive* agent REPL
you can talk to directly. The autonomous dispatcher does not depend on cmux panes:
queued jobs run as detached background processes with PID/log files. When the
human specifically wants a visual subagent interaction, `scripts/delegate.sh`
types a request into the live floor and uses an inbox request id as the completion
handshake. That keeps the watchable path explicit instead of silently replacing
the durable queue.

## Security model

- Keys live outside the repo in `~/.config/omp.env` (chmod 600).
- `spin action` is the executable gate for external sends, spending, production
  deploys, and protected pushes. It denies by default and requires an exact
  enabled rule plus a short-lived, one-shot owner lease. The lease binds the
  policy digest, resolved executable and hash, resolved working directory, and
  target attestation. Protected pushes additionally resolve the Git remote and
  destination branch. Commands run without a shell and inherit only a fixed
  baseline environment plus explicitly allowlisted variable names.
- Prompts forbid direct execution and tell agents to request denied targets in
  HUMAN_QUEUE. Agents must not edit `org/ACTION_POLICY.json`.
- This broker is machine-enforced for work routed through it, but it is not an
  OS sandbox. A same-user shell can still bypass user-space controls. Put
  high-value credentials behind a separate OS account, container, or scoped
  wrapper if bypass resistance is required.
- Receipts make brokered decisions and actions reconstructable after the fact.
