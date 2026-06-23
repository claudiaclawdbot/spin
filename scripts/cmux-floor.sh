#!/usr/bin/env bash
# cmux-floor.sh — launch the omp agent for one cmux floor (interactive, visible).
#
# This is a "legit omp agent" sitting in a cmux pane: the workspace CEO on its floor,
# or a project orchestrator on its floor. It is INTERACTIVE and IDLE — it costs nothing
# sitting at the prompt and does NOTHING until you type to it (or a coordinator hands it
# work). Uses OMP's configured model roles and fallback chains, so authenticated
# Anthropic/OpenAI/OpenRouter/etc. accounts can take over when one hits a limit.
#
# Usage:
#   cmux-floor.sh ceo            # the workspace coordinator
#   cmux-floor.sh <project-id>   # a project orchestrator (fidget-play, built-by-ai, ...)

set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
export SPIN_ROOT="$ROOT"
export WORKSPACE_ROOT="$ROOT"
source "$ROOT/scripts/lib/ceo-waterfall.sh"
TARGET="${1:?usage: cmux-floor.sh ceo|<project-id>}"
OMP_CONFIG="$(ensure_spin_omp_config)"
MODEL=(--config "$OMP_CONFIG")

if [[ "$TARGET" == "ceo" ]]; then
  SYS="$ROOT/org/ceo/WORKSPACE_CONTROLLER_PROMPT.md"
  FLOOR_DOC="$ROOT/org/ceo/FLOOR.md"
  # Run the CEO in a CLEAN dir OUTSIDE the monorepo. Running in ~/clawd makes omp
  # inject the whole workspace's git context (hundreds of dirty files) into every
  # request, bloating it until Anthropic rejects it. The CEO reads/writes org files
  # by absolute path via tools, so it doesn't need to sit inside the repo.
  DIR="$HOME/.omp-ceo"; mkdir -p "$DIR"
  TITLE="WORKSPACE CEO  ·  omp agent"
else
  SYS="$ROOT/org/projects/$TARGET/PROJECT_CONTROLLER_PROMPT.md"
  FLOOR_DOC="$ROOT/org/projects/$TARGET/FLOOR.md"
  # Project code repos now live under projects/ (consolidated).
  # Fallback chain: projects/<id> → org/projects/<id> (metadata-only project)
  DIR="$ROOT/projects/$TARGET"
  [[ -d "$DIR" ]] || DIR="$ROOT/org/projects/$TARGET"
  TITLE="$TARGET  ·  omp orchestrator"
fi

# Standing instruction: keep the live floor board current (it's shown on this cmux floor).
BOARD_INSTR="

## cmux floor runtime
This floor may be running outside the repository. The absolute SPIN root is:
$ROOT

For any repo-relative path or scripts/... command, use an absolute path or run
cd \"\$SPIN_ROOT\" first. Shell commands inherit SPIN_ROOT and WORKSPACE_ROOT with
this value.

If this is the Workspace CEO / Coordinator floor: after you run
scripts/org queue-job, stop. Do not create the worker's output, append the project
receipt, mark the job completed, or simulate worker results. The dispatcher and
project worker own execution and reporting.

## Live floor status board (keep it current)
You have a status board at: $FLOOR_DOC
It is displayed live on this cmux floor and auto-reloads. Whenever you start, finish,
or change what you're working on, update the relevant section (Goal / In progress /
Recently done / Next / Waiting on human) and the 'Last updated' timestamp. Keep it terse —
it's the human's at-a-glance view of this floor."

SYS_CONTENT=""
[[ -f "$SYS" ]] && SYS_CONTENT="$(cat "$SYS")"
SYS_CONTENT="${SYS_CONTENT}${BOARD_INSTR}"
SYSARG=(--append-system-prompt "$SYS_CONTENT")

clear
echo "════════════════════════════════════════════════════════════"
echo "  $TITLE"
echo "  dir:    $DIR"
echo "  model:  OMP default role   (cheap subtasks: OMP smol role)"
echo "  auth:   OMP-configured accounts with retry/fallback chains"
echo
echo "  IDLE until you type. Nothing runs on its own."
echo "  Type a request, or let the Workspace CEO hand it work."
echo "════════════════════════════════════════════════════════════"
echo
cd "$DIR"
exec omp "${MODEL[@]}" "${SYSARG[@]}"
