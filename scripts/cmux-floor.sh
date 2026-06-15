#!/usr/bin/env bash
# cmux-floor.sh — launch the omp agent for one cmux floor (interactive, visible).
#
# This is a "legit omp agent" sitting in a cmux pane: the workspace CEO on its floor,
# or a project orchestrator on its floor. It is INTERACTIVE and IDLE — it costs nothing
# sitting at the prompt and does NOTHING until you type to it (or a coordinator hands it
# work). Rides your Claude subscription: sonnet for work, haiku for cheap subtasks, no opus.
#
# Usage:
#   cmux-floor.sh ceo            # the workspace coordinator
#   cmux-floor.sh <project-id>   # a project orchestrator (fidget-play, built-by-ai, ...)

set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$HOME/.config/omp.env" 2>/dev/null || true
TARGET="${1:?usage: cmux-floor.sh ceo|<project-id>}"
MODEL=(--model anthropic/claude-sonnet-4-6 --smol anthropic/claude-haiku-4-5)

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
echo "  model:  sonnet-4-6   (cheap subtasks: haiku-4-5)"
echo "  auth:   your Claude subscription  ·  no opus, no API billing"
echo
echo "  IDLE until you type. Nothing runs on its own."
echo "  Type a request, or let the Workspace CEO hand it work."
echo "════════════════════════════════════════════════════════════"
echo
cd "$DIR"
exec omp "${MODEL[@]}" "${SYSARG[@]}"
