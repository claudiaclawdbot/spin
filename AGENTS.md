# SPIN Agent Context

This repo is SPIN: a lightweight orchestration harness for running a small AI
software org across multiple projects.

## Product Definition

SPIN is not primarily a generic multi-harness abstraction. The first-class
product is a SPIN-branded cmux workspace with OMP baked in:

- one Coordinator floor for the high-level SPIN Navigator;
- one project floor per workspace, each backed by its own scoped OMP agent;
- plain-file state for queues, approvals, receipts, inboxes, handoffs, and
  project status;
- a background Navigator/dispatcher loop that routes work and records decisions;
- an OMP-first provider/model fallback path, with direct CLI fallback only when
  OMP itself is unavailable or hard-fails.

The core design idea is context isolation. A project agent should stay focused on
its own repository, working directory, state, queue, memory, and receipts. SPIN
maintains the organization-level map across those agents so the human does not
become the router.

SPIN does not merge contexts. It orchestrates them.

## What Interoperable Means Here

In this repo, "interoperable" primarily means internal interoperability between
multiple otherwise isolated OMP project agents. Those agents cooperate through
SPIN's files, queues, receipts, and Navigator decisions without sharing every
working token.

OMP's provider/model interoperability is important runtime plumbing, but it is
not the novel product claim. Do not reframe SPIN as mainly a future generic
adapter for Claude Code, Codex CLI, Gemini CLI, Aider, or other harnesses unless
the maintainer explicitly asks for that direction.

## Engineering Expectations

- Preserve the hierarchy: human -> SPIN Navigator -> project OMP orchestrators
  -> workers.
- Keep the Navigator coordinating. It should not do inline project work that
  should be queued or delegated to a project floor.
- Keep project context isolated unless a task explicitly needs a cross-project
  summary or handoff.
- Use `scripts/org` for shared state changes. Do not hand-edit queue or state
  JSON in runtime flows.
- Keep public docs plain and concrete. README and `docs/index.html` should
  explain the OMP/cmux harness, context isolation, project floors, approvals,
  receipts, queues, and fallback behavior before implementation details.
- Avoid em dashes in README or website copy.

## Review Checklist

When auditing or extending SPIN, check whether the implementation still supports
the intended product:

- Can SPIN launch, track, and coordinate multiple OMP-backed project agents?
- Does each project agent retain isolated project context?
- Does the Navigator maintain a useful organization-level view across projects?
- Are queues, receipts, inboxes, logs, and project state wired together
  coherently?
- Does the cmux layer behave like a usable multiplexer for Coordinator and
  project floors?
- Does OMP-first fallback work as documented, with direct CLI fallback reserved
  for OMP hard failures?
- Are failures visible when an agent stalls, blocks, exits without useful work,
  or writes malformed state?
- Do tests or smoke checks prove the basic multi-project workflow?

Current automated coverage: `scripts/smoke-test.sh` validates install seeding,
org CLI plumbing, web approvals, app overlay checks, single-job dispatcher
plumbing, first-launch routing into `SPIN Onboarding`, and a deterministic
multi-project org proof across `example-app` and `workspace`. The project-agent
stub is test-only so CI can run without real OMP credentials or a GUI session;
live OMP provider runs and the cmux GUI floor-spawn remain manual/product
verification paths.
