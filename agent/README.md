# SPIN Agent Runtime

This directory is the product home for the OMP/Pi-derived internal agent
runtime.

Target state:

- Users launch SPIN, not `omp`.
- The app bundle carries an internal agent binary at `Resources/bin/omp`.
- SPIN defaults own model roles, fallback chains, Coordinator behavior, project
  agents, worker jobs, approvals, and receipts.
- Upstream OMP/Pi structure stays recognizable enough that security and feature
  updates can be merged deliberately.

Current milestone:

- Runtime scripts resolve `SPIN_OMP_BIN`, `Resources/bin/omp`, or
  `vendor/bin/omp` before PATH.
- `scripts/lib/ceo-waterfall.sh` still generates the SPIN OMP config overlay.
- `scripts/vendor-app-deps.sh` provides a repeatable place to fetch upstream
  OMP/Pi sources and the npm package for future bundled releases.

Do not commit provider credentials, auth stores, or user model config here.
