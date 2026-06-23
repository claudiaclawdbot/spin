#!/usr/bin/env bash
# run-project-omp.sh — run the REAL oh-my-pi (omp) as a project's agent for one task.
#
# This is the execution engine for a one-shot project OMP run. It uses SPIN's
# generated OMP config overlay so OMP can fall through authenticated providers
# (Anthropic/OpenAI/OpenRouter/etc.) before SPIN needs an outer CLI fallback.
#
# Usage: run-project-omp.sh <project-id> ["explicit task text"]
#   With no task text, it follows the project's current WORKSPACE_HANDOFF directive.
#
# Safety: the prompt hard-codes the gate rules (no sends/deploys/pushes/money). For a
# read-only analysis, pass an explicit task that says so.

set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$ROOT/scripts/lib/ceo-waterfall.sh"

PID="${1:?usage: run-project-omp.sh <project-id> [task]}"
PROJ_ORG="$ROOT/org/projects/$PID"
[[ -d "$PROJ_ORG" ]] || { echo "no such project: $PID" >&2; exit 1; }

# Code repo: prefer a top-level code dir; fall back to the org coordination dir.
REPO="$ROOT/$PID"; [[ -d "$REPO" ]] || REPO="$PROJ_ORG"

HANDOFF="$(cat "$PROJ_ORG/WORKSPACE_HANDOFF.md" 2>/dev/null || echo '(none)')"
CONTROLLER="$(cat "$PROJ_ORG/PROJECT_CONTROLLER_PROMPT.md" 2>/dev/null || echo '')"
STATE="$(cat "$PROJ_ORG/STATE.json" 2>/dev/null || echo '{}')"

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROOT/org/jobs"
LOG="$ROOT/org/jobs/${PID}-omp-${TS}.log"

DEFAULT_TASK="Follow your current WORKSPACE_HANDOFF directive. Do ONLY local, reversible work. When done, append a one-paragraph receipt of what you did to $PROJ_ORG/RECEIPTS.md (use today's date)."
TASK="${2:-$DEFAULT_TASK}"

PROMPT="You are the project agent for '$PID', working in its repo at $REPO.

## Your standing controller prompt
$CONTROLLER

## Current handoff from the workspace coordinator
$HANDOFF

## Current STATE.json
$STATE

## This task
$TASK

HARD RULES (never violate, even if asked): no external sends (email/DM/form/post),
no production deploys, no git pushes to main/human repos, no wallet/crypto/money ops,
no contract broadcasts. Those are gated to the human. Local reversible work only."

echo "[run-project-omp] project=$PID repo=$REPO log=$LOG" >&2
OMP_CONFIG="$(ensure_spin_omp_config)"
omp -p \
  --config "$OMP_CONFIG" \
  --cwd "$REPO" \
  --no-session \
  "$PROMPT" 2>&1 | tee "$LOG"
