# Third-Party Notices

SPIN is designed to ship as a self-contained app with internal UI and agent
runtime foundations. Preserve these notices in source and binary releases.

## cmux

- Upstream: https://github.com/manaflow-ai/cmux
- Role: native terminal/workspace/browser/notification UI engine
- License posture: GPL-3.0-or-later for the public upstream, with a separate
  commercial license available from Manaflow for organizations that cannot
  comply with GPL.

Any SPIN app binary derived from cmux must be distributed in a GPL-compatible
way unless SPIN has a commercial cmux license.

## oh-my-pi / OMP

- Upstream: https://github.com/can1357/oh-my-pi
- Package: `@oh-my-pi/pi-coding-agent`
- Role: coding-agent runtime and model/provider harness
- License: MIT

Preserve upstream MIT copyright notices in OMP/Pi-derived source and binary
distributions.

## SPIN

- Upstream: this repository
- Role: app/runtime orchestration, plain-file org state, approvals, jobs,
  receipts, and CLI companion commands
- License: MIT
