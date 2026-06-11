# workspace-ceo

**A file-based AI organization that runs your projects while you sleep — with a human-approval gate on anything that leaves the machine.**

A Workspace CEO loop coordinates per-project agent "floors" inside [cmux](https://cmux.io), dispatches work to detached background agents (Claude / Codex / Gemini / Ollama via an automatic fallback waterfall), and talks to you through a single `ceo` command. Everything the org knows, decides, and does lives in plain files you can read, grep, and audit.

```
you ──ceo approve──▶ APPROVALS.md ──▶ ┌─────────────────┐ ──▶ AGENT_QUEUE.json ──▶ detached agent jobs
                                      │  Workspace CEO   │                          (claude / codex / …)
you ◀── ceo status ◀── HUMAN_QUEUE ◀──│  tick loop       │ ◀── INBOX.md ◀────────── project receipts
                                      └─────────────────┘
```

## Why this exists

Running multiple AI-driven projects from chat sessions doesn't scale: context evaporates, agents step on each other, quotas burn silently, and you become the message bus. This kit replaces that with a small, inspectable org:

- **One driver loop** (`workspace-ceo-tick.sh`) — singleton-locked so duplicates can't silently burn quota.
- **An LLM "brain" that only runs when something changed** — idle ticks are free.
- **Detached background jobs** for real work — cmux is *display only* (a hard-won lesson; see [docs/LESSONS.md](docs/LESSONS.md)).
- **Four hard gates** — the org acts freely on local, reversible work and stops for exactly four things: external sends, spending money, production deploys, pushes to protected repos.
- **Receipts for everything** — every brain run and job writes an append-only audit trail.

## The five layers

```mermaid
flowchart TD
    H["1 · HUMAN<br/>sets direction · approves the 4 gated actions<br/>interface: the ceo command + cmux floors"]
    C["2 · CHAT ASSISTANT (optional)<br/>your conversational front door — reads/writes the same org files"]
    W["3 · WORKSPACE CEO<br/>tick loop: render cockpit → dispatch queue → change-gated LLM brain<br/>coordinates, never codes"]
    P["4 · PROJECT ORCHESTRATORS<br/>one per project — execute jobs, update STATE/RECEIPTS, report to INBOX"]
    S["5 · WORKERS / SUBAGENTS<br/>per-task LLM invocations: code edits, research, drafts, builds"]
    H -->|"ceo approve / decline / ask"| W
    C --> W
    W -->|"AGENT_QUEUE.json + WORKSPACE_HANDOFF.md"| P
    P -->|"INBOX.md + STATE.json"| W
    P --> S
    W -->|"HUMAN_QUEUE.md (only the 4 gated things)"| H
```

## Communication is just files

| File | Direction | Purpose |
|---|---|---|
| `org/projects/<p>/WORKSPACE_HANDOFF.md` | CEO → project | current directive |
| `org/ceo/INBOX.md` | project → CEO | progress reports, escalations |
| `org/HUMAN_QUEUE.md` | CEO → you | the *only* things needing a decision |
| `org/ceo/APPROVALS.md` | you → CEO | your approve/decline/ask answers |
| `org/state.json` | shared | org truth (projects, statuses) |
| `org/AGENT_QUEUE.json` | CEO → dispatcher | the job queue |
| `org/ceo/runs/` | append-only | receipts (audit trail) |

No database, no message broker, no daemon you can't `cat`.

## Quickstart

```bash
git clone https://github.com/claudiaclawdbot/workspace-ceo.git ~/workspace
cd ~/workspace && ./install.sh        # creates runtime org files, checks deps, links the `ceo` command

# register your first project
scripts/bootstrap-project.sh my-app    # creates org/projects/my-app/ (prompt, STATE, receipts)
$EDITOR org/projects/my-app/PROJECT_CONTROLLER_PROMPT.md   # give it a real charter
$EDITOR org/OMP_HARNESS.json                               # add my-app to "projects" (copy example-app)

# start the org
bash scripts/workspace-ceo-tick.sh     # ideally inside a cmux pane so you can watch it

# talk to it (from any terminal)
ceo                       # status: what's running, what's waiting on you
ceo approve "my-app …"    # answer an approval ask
ceo log                   # watch the brain's receipts live
```

**Requirements:** macOS/Linux, `bash`, `node`, and at least one agent CLI on `PATH` (`claude`, `codex`, `gemini`, or `ollama`). Optional but recommended: [cmux](https://cmux.io) for the visual floors, [`omp`](https://github.com/sst/opencode) for interactive floor agents.

## What runs where

| Piece | Script | Runs as |
|---|---|---|
| Driver loop (cockpit + dispatch + brain) | `workspace-ceo-tick.sh` | one foreground loop in a cmux pane |
| CEO brain (LLM decision pass) | `workspace-ceo-agent.sh` | invoked by the tick, change-gated |
| Job dispatcher | `omp-supervisor-once.sh` | invoked by the tick; spawns detached jobs |
| Project agent (one job) | `project-ceo-agent.sh <id>` | detached background process, PID + log in `org/jobs/` |
| Interactive floor agents | `cmux-floor.sh <id>` | idle `omp` REPL per floor — costs nothing until spoken to |
| Status roll-up + driver watchdog | `workspace-status-watch.sh` | tiny nohup daemon, no LLM |
| Wiki (per-project knowledge pages) | `wiki-watch.sh` | tiny nohup daemon, LLM only on change |
| Bring it all up/down | `workstation.sh up\|down\|status` | helper |

## Cost & reliability design

- **Change-gated brain** — the LLM only runs when watched inputs (INBOX, approvals, project STATE) actually changed (content hash, not mtime), or every Nth tick as a heartbeat. An idle org costs ~3 brain runs a day.
- **Provider waterfall with auto-benching** (`scripts/lib/ceo-waterfall.sh`) — `codex → claude → gemini → ollama`; any provider that hits a usage limit is benched (90 min–24 h) and the waterfall advances. An explicit provider override is *ignored* while that provider is benched — a stale caller can't resurrect a rate-limited CLI.
- **Singleton locks everywhere** — the driver, the watchers: duplicate loops are the #1 silent quota killer (ask us how we know).
- **Silent-exit retry** — if a job exits 0 but changed no files, it's retried once on claude. Catches agents that "succeed" without doing anything.
- **Kill switch** — `touch org/ceo/runs/STOP` pauses the whole org; `rm` it to resume. The watchdog paints a red chip + notification if the driver dies *without* a STOP file.

## The four gates (safety model)

The org does local, reversible work without asking. It must stop and queue a `HUMAN_QUEUE.md` item for:

1. **Sending anything external** — email, DM, form, public post.
2. **Spending money** — gas, wallets, paid APIs beyond your subscriptions.
3. **Production deploys.**
4. **Pushing to `main` or any human-owned repo.**

Keys stay out of the repo (`~/.config/omp.env`, chmod 600). The gate is *behavioral*, enforced by every prompt in the org — an agent with shell access can read anything you can, so never park real-money keys on an agent machine.

## Repo layout

```
scripts/            the whole engine (bash + a little node, no build step)
  lib/ceo-waterfall.sh   provider selection, benching, timeouts
org/
  OMP_HARNESS.json       registry: projects, job types, dispatch config
  ceo/                   CEO prompt, approvals, inbox, runs/ (receipts)
  projects/example-app/  what a registered project looks like
docs/
  ARCHITECTURE.md        the five layers + one tick, in detail
  LESSONS.md             v1 → v3: what broke and what fixed it
```

## License

MIT — see [LICENSE](LICENSE).
