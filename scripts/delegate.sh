#!/usr/bin/env bash
# delegate.sh — the Workspace CEO uses this to hand a task to a live project floor agent.
# It types the task into that project's omp pane in cmux, so the project agent picks it up
# and works on it — and you can WATCH it happen in that floor. The project agent can itself
# fan out omp subagents (recursive), giving CEO → project agent → subagents.
#
# Usage: delegate.sh <project-id> "<task text>"
set -uo pipefail
ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PID="${1:?usage: delegate.sh <project-id> \"<task>\"}"; shift
TASK="$*"
[[ -z "$TASK" ]] && { echo "no task text given" >&2; exit 1; }

# project-id → cmux workspace (the floor map lives in the harness registry)
[[ "$PID" == "ceo" ]] && { echo "refusing to delegate to self" >&2; exit 1; }
WS="$(node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const p=(h.projects||{})[process.argv[2]];if(p&&p.cmux_workspace)console.log(p.cmux_workspace);' "$ROOT/org/OMP_HARNESS.json" "$PID" 2>/dev/null)"
[[ -z "$WS" ]] && { echo "no cmux_workspace for '$PID' in org/OMP_HARNESS.json projects" >&2; exit 1; }

# find the omp agent's terminal surface in that workspace (robust to ID drift)
SF="$(cmux tree --workspace "$WS" 2>/dev/null | grep -oE "surface:[0-9]+ \[terminal\]" | head -1 | grep -oE "surface:[0-9]+")"
[[ -z "$SF" ]] && { echo "no agent pane found in $WS for $PID" >&2; exit 1; }

# type the task into the project agent and submit it
cmux send     --workspace "$WS" --surface "$SF" "$TASK" >/dev/null 2>&1
cmux send-key --workspace "$WS" --surface "$SF" enter    >/dev/null 2>&1

# log the handoff for the audit trail / roll-up
TS="$(date -u '+%Y-%m-%dT%H:%MZ')"
echo "[$TS] ceo → $PID: $TASK" >> "$ROOT/org/ceo/INBOX.md"
echo "delegated to $PID ($WS/$SF). Watch the $PID floor."
