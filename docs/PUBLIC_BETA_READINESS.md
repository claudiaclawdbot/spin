# Public Beta Readiness

Use this as the owner checklist before showing SPIN to a broader public
audience. The goal is to present a coherent product without overstating what is
already production hardened.

## Positioning

Lead with the job:

> SPIN is a local Mac app for running a small AI software org. One Navigator
> coordinates many isolated OMP project agents, refines your requests before
> delegation, and keeps approvals, queues, handoffs, and receipts inspectable on
> disk.

Keep these points explicit:

- SPIN.app is the main product.
- cmux is the workspace surface.
- OMP/Pi is the agent and model-provider engine.
- SPIN is the orchestration harness above them.
- "Interoperable" means both isolated project-agent cooperation and OMP
  model/provider fallback.

Avoid these traps:

- Do not describe SPIN as a cloud SaaS.
- Do not imply agents are sandboxed by the operating system.
- Do not imply one shared mega-agent context is the design.
- Do not market direct Codex, Claude, Gemini, or Ollama fallback as the primary
  product lane. OMP-backed project floors are the first-class path.

## Five-Minute Demo Script

1. Open `SPIN.app` from Applications and show the Navigator card above project
   floors.
2. Run `spin app-health` and show that bundled `cmux`, `omp`, and `spin-agent`
   resolve from inside the app.
3. Create or open a project floor, then ask the Coordinator for a concrete task.
4. Show the refined handoff: the project agent receives a prompt with goal,
   paths, constraints, acceptance checks, and reporting shape.
5. Show a receipt or project board update so viewers see that work is auditable.
6. Trigger or describe a gated action: external send, money, production deploy,
   or protected push.
7. Close by showing the plain files under the runtime state.

If a live provider account is not configured, make that explicit and show the
health check plus offline release proof instead of pretending the agent ran.

## What Is Ready To Show

- Branded Mac app shell with a SPIN Navigator above project floors.
- Bundled cmux-compatible UI, bundled OMP/Pi runtime, and `spin-agent` alias.
- First-launch onboarding route and normal relaunch route.
- Project floors with isolated OMP-backed context.
- Prompt refinement before project handoff.
- File-backed queues, handoffs, approvals, inboxes, receipts, and project state.
- OMP-first provider/model fallback policy with direct CLI fallback only when
  OMP is unavailable or hard-fails.
- Short demo assets at `docs/assets/spin-public-beta-demo.gif` and
  `docs/assets/spin-public-beta-demo.mp4`.
- Manual checked app update path for downloaded artifacts.
- Repeatable local and CI release checks.

## What Is Still Beta

- Current public DMG is ad-hoc signed and not notarized.
- Current public app artifact is Apple Silicon / arm64.
- Real provider execution requires user-owned OMP/provider setup.
- Live GUI plus provider integration is manual validation, not fully automated
  CI.
- Remote auto-update feed is not implemented yet.
- A narrated walkthrough would still make the first visit easier for nontechnical
  testers.
- Developer ID notarization would reduce first-launch friction for nontechnical
  testers.

## Pre-Presentation Checklist

Before a public post, run:

```bash
scripts/smoke-test.sh
scripts/check-app-release.sh dist/SPIN.app
scripts/check-app-release.sh /Applications/SPIN.app
spin app-health
test -s docs/assets/spin-public-beta-demo.gif
test -s docs/assets/spin-public-beta-demo.mp4
```

For a fresh release artifact, also run:

```bash
scripts/release-macos.sh --source-cmux
scripts/check-installed-app.sh dist/release/SPIN-*-macos-*
```

Then manually verify:

- A clean macOS user can install the DMG and open SPIN.
- The first screen routes to onboarding.
- The Navigator rail is selected.
- A first project floor can be created.
- A project handoff visibly uses the refined prompt shape.
- The receipt, inbox, and board agree about the result.
- Gatekeeper wording in public copy matches the actual signing state.
- The release page includes the DMG, checksum, manifest, tester notes, and the
  checksummed matching cmux corresponding-source archive.

## Public Feedback Loop

For the first public wave, ask for narrow feedback:

- install success or failure, with macOS version and chip type;
- whether the first screen makes the product understandable;
- whether OMP setup is clear;
- whether a project floor can be created;
- whether the Navigator versus project-floor distinction is obvious;
- what confused them in the README or website.

Route feedback through the GitHub issue templates so reports include the app
version, install path, health output, and whether the issue is app, OMP setup,
project floor, copy, or release packaging.
