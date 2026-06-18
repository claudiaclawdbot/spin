# Architecture

How the org actually works, layer by layer. If you're an agent reading this:
this describes the system you're part of.

## The five layers

1. **Human (owner).** Sets direction, answers the four gated asks, funds wallets.
   Interface: the `spin` command and (optionally) cmux floors.
2. **Chat assistant (optional).** Your conversational front door. It reads and
   writes the same org files as everything else — it is *not* the autonomous loop.
3. **SPIN Navigator.** The single driver loop (`scripts/workspace-ceo-tick.sh`).
   Coordinates, never codes. Only one instance can run: it claims a lock file
   at startup and a second launch exits immediately.
4. **Project orchestrators.** One per registered project. Run as dispatched
   background jobs (`scripts/project-ceo-agent.sh <id>`); read their handoff, do
   the work, update `STATE.json` + `RECEIPTS.md`, report up to `org/ceo/INBOX.md`.
5. **Workers / subagents.** Per-task LLM invocations a project orchestrator spawns.

## One tick, in detail

`workspace-ceo-tick.sh` loops forever (default every 900 s). Each tick:

1. **Render** the cockpit — org state, provider status, inbox tail — to its pane.
2. **Dispatch** (`omp-supervisor-once.sh`):
   - mark finished jobs by *PID liveness* (not ps-grep);
   - spawn each `queued` job in `org/AGENT_QUEUE.json` as a **detached background
     process** with its own PID file and log under `org/jobs/`;
   - enforce one-job-per-project and a global parallelism cap (default 3);
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

```
Navigator brain ──appends──▶ AGENT_QUEUE.json (status: queued)
tick N+1 dispatcher ──spawns──▶ bash project-ceo-agent.sh <project>   (detached, env: OMP_JOB_*)
                                 │  log: org/jobs/<id>.log   pid: org/jobs/<id>.pid
agent ──writes──▶ project STATE.json + RECEIPTS.md ──appends──▶ org/ceo/INBOX.md
tick N+2 dispatcher ──sees pid dead──▶ status: completed
brain (gate sees INBOX change) ──reads receipt──▶ decides next step
```

Model tiering is automatic: `read-only-worker`/`scout` jobs start on a cheap
fast model (gemini-flash); `implementation-worker`/`project-ceo-run` start on
claude-sonnet. The waterfall handles fallback either way.

## The provider waterfall (`scripts/lib/ceo-waterfall.sh`)

A **provider** is one lane in the fallback chain: a command-line agent on your
PATH plus the account behind it. These are *tools*, not bare model names — each
wraps its own vendor's models: `codex` = OpenAI Codex CLI, `claude` = Claude Code,
`gemini` = Google Gemini CLI, `omp` = oh-my-pi (any of ~15 backends), `ollama` =
local model runtime.

```
codex → claude → gemini → omp → ollama   (the Navigator skips codex by default
                                          to preserve quota for project work)
```

- Each provider is probed before use; when its account returns a usage/session/rate
  limit the provider is **benched** via a lockout file
  (`org/ceo/runs/.<provider>-blocked-until`, epoch seconds) — 90 min for
  claude/gemini, 24 h for codex.
- A benched provider is skipped even when explicitly requested — a stale caller
  can't keep hammering a maxed-out account.
- Expired lockouts self-heal: the probe compares the epoch and unblocks.
- **The `omp` lane is the gateway to everything oh-my-pi supports** — OpenRouter,
  Groq, xAI, Mistral, Cerebras, Azure, z.ai, … — through one provider-prefixed
  model id. It's opt-in: set `CEO_OMP_MODEL` (e.g. `openrouter/anthropic/claude-sonnet-4.6`)
  and put the key in `~/.config/omp.env`. Want OpenRouter as the *default*? Pass it
  as the override (`PROJECT_CEO_PROVIDER=omp`) or move it earlier in `select_provider`.

## Watchdogs & failure modes

| Failure | Defense |
|---|---|
| duplicate driver loops (quota burn) | lock file claimed atomically at startup; a second copy sees it and exits |
| hung brain | per-run `timeout`, loop continues |
| agent exits 0 having done nothing | post-run content diff → one retry on claude |
| driver dies / forgotten STOP file | status-watch daemon paints a red chip + notification; `spin` shows ● / ○ |
| owner pauses the org | `touch org/ceo/runs/STOP` (resume: `rm`) — explicit, visible state |
| machine sleeps | ticks simply don't run; loop resumes on wake (use `caffeinate`/a server for 24/7) |

## cmux is display-only

Floors (one cmux workspace per project) show: a live markdown status board, a
log tail of the latest job, status chips, and an *idle interactive* agent REPL
you can talk to directly. **No job ever executes through a cmux pane.** Earlier
versions dispatched work by typing into panes; it was the #1 source of silent
failures. See [LESSONS.md](LESSONS.md).

## Security model

- Keys live outside the repo in `~/.config/omp.env` (chmod 600).
- The four gates are *behavioral*: enforced by every controller prompt, with
  HUMAN_QUEUE as the escalation path — not by an OS sandbox. An agent with
  shell access can read anything your user can. Therefore: dedicated low-value
  wallets only, private repos by default, no real-money keys on the machine.
- Receipts make every decision and action reconstructable after the fact.
