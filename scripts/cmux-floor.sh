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
source "$ROOT/scripts/lib/cmux-floor-layout.sh"
source "$ROOT/scripts/lib/project-root.sh"
TARGET="${1:?usage: cmux-floor.sh ceo|<project-id>}"

if [[ "$TARGET" == "ceo" ]]; then
  SYS="$ROOT/org/ceo/WORKSPACE_CONTROLLER_PROMPT.md"
  FLOOR_DOC="$ROOT/org/ceo/FLOOR.md"
  # Run the CEO in a CLEAN dir OUTSIDE the monorepo. Running in ~/clawd makes omp
  # inject the whole workspace's git context (hundreds of dirty files) into every
  # request, bloating it until Anthropic rejects it. The CEO reads/writes org files
  # by absolute path via tools, so it doesn't need to sit inside the repo.
  DIR="$HOME/.omp-ceo"; mkdir -p "$DIR"
  PROJECT_CODE_DIR=""
  OMP_CONFIG_LANE="coordinator-floor"
  TITLE="WORKSPACE CEO  ·  omp agent"
else
  SYS="$ROOT/org/projects/$TARGET/PROJECT_CONTROLLER_PROMPT.md"
  FLOOR_DOC="$ROOT/org/projects/$TARGET/FLOOR.md"
  PROJECT_CODE_DIR="$(spin_project_root "$TARGET")" || exit $?
  # Keep the long-lived OMP process in SPIN-owned state. Calling getcwd() from
  # Desktop/Documents/Downloads can block an ad-hoc app behind macOS privacy.
  DIR="$(spin_cmux_project_cwd "$TARGET")"
  mkdir -p "$DIR"
  spin_load_project_env "$ROOT/org/projects/$TARGET/project.env" || exit $?
  # Reassert the canonical control-plane boundary after project overrides.
  export SPIN_ROOT="$ROOT"
  export WORKSPACE_ROOT="$ROOT"
  export SPIN_PROJECT_ROOT="$PROJECT_CODE_DIR"
  OMP_CONFIG_LANE="project-floor:${TARGET}"
  TITLE="$TARGET  ·  omp orchestrator"
fi

OMP_CONFIG="$(ensure_spin_omp_config "$OMP_CONFIG_LANE")" || exit $?
MODEL=(--config "$OMP_CONFIG")

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

If this is the Workspace CEO / Coordinator floor and the human is asking live in
the app/cmux UI to create a project or have a project agent act, prefer the
visible floor path. Create projects with scripts/spin-new-project.sh so a cmux
terminal opens with that project's OMP orchestrator, then use scripts/delegate.sh
--wait --timeout 900 <project> \"<rewritten project-facing directive>\" to type
the task into that project agent's own terminal. Rewrite the human's request
before delegation so the isolated project agent receives a concrete goal, local
paths, constraints, acceptance checks, and reporting instructions. Use scripts/org
queue-job for routine background work or when cmux is unavailable; do not describe
a hidden queue item as a visible project agent handoff.

If this is a project floor and you receive a message beginning with
'SPIN delegation <id>', treat it as the active request. First read the durable
handoff at org/projects/$TARGET/WORKSPACE_HANDOFF.md. When the work is done or
blocked, close the handshake by running exactly one inbox command from the SPIN
root, for example:

cd \"\$SPIN_ROOT\" && scripts/org inbox $TARGET \"delegate <id> complete: <summary>\"
cd \"\$SPIN_ROOT\" && scripts/org inbox $TARGET \"delegate <id> blocked: <summary>\"

Do not report completion only in FLOOR.md or RECEIPTS.md. Before claiming a file,
artifact, or command output exists, verify it with a local command.

## Live floor status board (keep it current)
You have a status board at: $FLOOR_DOC
It is displayed live on this cmux floor and auto-reloads. Whenever you start, finish,
or change what you're working on, update the relevant section (Goal / In progress /
Recently done / Next / Waiting on human) and the 'Last updated' timestamp. Keep it terse —
it's the human's at-a-glance view of this floor."

if [[ -n "$PROJECT_CODE_DIR" ]]; then
  BOARD_INSTR="${BOARD_INSTR}

## Project code location
The real project code path is available as:

\`\$SPIN_PROJECT_ROOT\` = \`$PROJECT_CODE_DIR\`

Your long-lived floor intentionally starts in \`$DIR\` so an ad-hoc macOS app
does not block in \`getcwd()\` when a repository lives under a protected folder.
Use absolute project paths, \`git -C \"\$SPIN_PROJECT_ROOT\"\`, and tool-specific
working-directory options. Do not treat the floor directory as the product repo."
fi

SYS_CONTENT=""
[[ -f "$SYS" ]] && SYS_CONTENT="$(cat "$SYS")"
ACTION_POLICY_INSTR="$(cat "$ROOT/scripts/lib/action-policy-prompt.md" 2>/dev/null || true)"
COMPUTER_USE_INSTR="$(spin_omp_computer_use_prompt)"
SYS_CONTENT="${SYS_CONTENT}

${ACTION_POLICY_INSTR}${BOARD_INSTR}"
[[ -n "$COMPUTER_USE_INSTR" ]] && SYS_CONTENT="${SYS_CONTENT}

$COMPUTER_USE_INSTR"
SYSARG=(--append-system-prompt "$SYS_CONTENT")

clear
echo "════════════════════════════════════════════════════════════"
echo "  $TITLE"
echo "  floor:  $DIR"
[[ -n "$PROJECT_CODE_DIR" ]] && echo "  code:   $PROJECT_CODE_DIR"
echo "  model:  OMP default role   (cheap subtasks: OMP smol role)"
echo "  auth:   OMP-configured accounts with retry/fallback chains"
echo
echo "  IDLE until you type. Nothing runs on its own."
echo "  Type a request, or let the Workspace CEO hand it work."
echo "════════════════════════════════════════════════════════════"
echo
cd "$DIR"
OMP_BIN="$(spin_resolve_binary omp)" || { echo "omp not found; SPIN app bundles it under Resources/bin/omp or repo vendor/bin/omp"; exit 127; }
spin_cmux_write_floor_marker "$TARGET" "$TITLE" "$DIR"
exec "$OMP_BIN" "${MODEL[@]}" "${SYSARG[@]}"
