#!/usr/bin/env bash
# delegate.sh — the Workspace CEO uses this to hand a task to a live project floor agent.
# It types the task into that project's omp pane in cmux, so the project agent picks it up
# and works on it — and you can WATCH it happen in that floor. The project agent can itself
# fan out omp subagents (recursive), giving CEO → project agent → subagents.
#
# Usage:
#   delegate.sh [--wait] [--timeout SEC] [--id REQUEST_ID] <project-id> "<task text>"
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"

usage() {
  cat >&2 <<'EOF'
usage: delegate.sh [--wait] [--timeout SEC] [--id REQUEST_ID] [--force] <project-id> "<task>"

Types a task into a live project cmux/omp floor. With --wait, blocks until the
project reports back to org/ceo/INBOX.md with this request id.
EOF
}

WAIT=0
TIMEOUT=600
REQ_ID=""
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --timeout) [[ $# -ge 2 ]] || { echo "--timeout requires seconds" >&2; exit 1; }; TIMEOUT="$2"; shift 2 ;;
    --id) [[ $# -ge 2 ]] || { echo "--id requires a request id" >&2; exit 1; }; REQ_ID="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

PID="${1:?usage: delegate.sh <project-id> \"<task>\"}"; shift
TASK="$*"
[[ -z "$TASK" ]] && { echo "no task text given" >&2; exit 1; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--timeout must be seconds" >&2; exit 1; }
[[ -n "$REQ_ID" ]] || REQ_ID="delegate-$(date -u '+%Y%m%d%H%M%S')-$$"
[[ "$REQ_ID" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "--id may only contain letters, numbers, dot, underscore, colon, or hyphen" >&2; exit 1; }

# project-id → cmux workspace (the floor map lives in the harness registry)
[[ "$PID" == "ceo" ]] && { echo "refusing to delegate to self" >&2; exit 1; }
WS="$(node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const p=(h.projects||{})[process.argv[2]];if(p&&p.cmux_workspace)console.log(p.cmux_workspace);' "$ROOT/org/OMP_HARNESS.json" "$PID" 2>/dev/null)"
[[ -z "$WS" ]] && { echo "no cmux_workspace for '$PID' in org/OMP_HARNESS.json projects" >&2; exit 1; }

command -v cmux >/dev/null 2>&1 || { echo "cmux not found; run headless jobs with scripts/org queue-job instead" >&2; exit 1; }
CMUX_QUIET=1 cmux ping >/dev/null 2>&1 || { echo "cmux is not reachable; open cmux or run: scripts/spin up" >&2; exit 1; }

# find the omp agent's terminal surface in that workspace (robust to ID drift)
SF="$(cmux tree --workspace "$WS" 2>/dev/null | grep -oE "surface:[0-9]+ \[terminal\]" | head -1 | grep -oE "surface:[0-9]+")"
[[ -z "$SF" ]] && { echo "no agent pane found in $WS for $PID" >&2; exit 1; }

if [[ "$FORCE" != 1 ]]; then
  SCREEN="$(cmux read-screen --workspace "$WS" --surface "$SF" 2>/dev/null | tail -12)"
  if ! grep -Eiq 'omp|sonnet|haiku|claude|model:' <<<"$SCREEN"; then
    echo "terminal $WS/$SF does not look like an omp agent prompt; use --force to send anyway" >&2
    exit 1
  fi
fi

TASK_ONE_LINE="$(printf '%s' "$TASK" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
WRAPPED_TASK="SPIN delegation $REQ_ID from the Navigator. Task: $TASK_ONE_LINE. When done or blocked, update your project files/floor board as appropriate, then report back with exactly one of: scripts/org inbox $PID \"delegate $REQ_ID complete: <summary>\" OR scripts/org inbox $PID \"delegate $REQ_ID blocked: <summary>\"."

# type the task into the project agent and submit it
if ! cmux send --workspace "$WS" --surface "$SF" "$WRAPPED_TASK" >/dev/null 2>&1; then
  echo "failed to send task to $PID ($WS/$SF)" >&2
  exit 1
fi
if ! cmux send-key --workspace "$WS" --surface "$SF" enter >/dev/null 2>&1; then
  echo "failed to submit task to $PID ($WS/$SF)" >&2
  exit 1
fi

# log the handoff for the audit trail / roll-up
TS="$(date -u '+%Y-%m-%dT%H:%MZ')"
mkdir -p "$ROOT/org/ceo/runs"
echo "[$TS] ceo -> $PID: delegate $REQ_ID: $TASK_ONE_LINE" >> "$ROOT/org/ceo/runs/delegations.log"
echo "delegated $REQ_ID to $PID ($WS/$SF). Watch the $PID floor."

if [[ "$WAIT" == 1 ]]; then
  INBOX="$ROOT/org/ceo/INBOX.md"
  echo "waiting up to ${TIMEOUT}s for $PID to report delegate $REQ_ID..."
  deadline=$((SECONDS + TIMEOUT))
  while (( SECONDS <= deadline )); do
    line="$(grep -F -e "delegate $REQ_ID complete:" -e "delegate $REQ_ID blocked:" "$INBOX" 2>/dev/null | tail -1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line"
      exit 0
    fi
    sleep 5
  done
  echo "timed out waiting for delegate $REQ_ID; check the $PID floor or $INBOX" >&2
  exit 124
fi
