# Contributing

Small project, simple rules.

- **Keep the dependency budget**: bash + node, no npm packages, no build step.
  If a change needs a package, it probably belongs in a separate tool the org
  *calls*, not in the engine.
- **Every long-running process must refuse to run twice** (copy the lock-file
  pattern at the top of `workspace-ceo-tick.sh`) and writes something a human
  can read when it acts.
- **Never let an agent mutate shared state destructively** — state changes go
  through the `org` CLI (validated, locked, atomic, append-only). Don't add a
  code path that writes `state.json` / `AGENT_QUEUE.json` by hand; add an `org`
  verb instead.
- Run the checks CI runs before pushing:

  ```bash
  for f in scripts/*.sh scripts/lib/*.sh install.sh; do bash -n "$f"; done
  node --check scripts/ceo-dashboard.js
  node --check scripts/org
  SPIN_INSTALL_SKIP_AGENT_CHECK=1 ./install.sh   # in a scratch clone
  ```

- Architecture context: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Why
  things are the way they are: [docs/LESSONS.md](docs/LESSONS.md). What's
  known-weak: [docs/ROADMAP.md](docs/ROADMAP.md).

