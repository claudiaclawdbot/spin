#!/usr/bin/env bash
# bootstrap-project.sh — create org/projects/<id>/ directory structure for a new
# project_id so project-ceo-agent.sh can dispatch agent jobs against it.
#
# project-ceo-agent.sh requires:
#   org/projects/<id>/PROJECT_CONTROLLER_PROMPT.md  (hard required — script exits 1)
#   org/projects/<id>/STATE.json                     (hard required — script exits 1)
#   org/projects/<id>/WORKSPACE_HANDOFF.md           (optional — read if present)
#   org/projects/<id>/RECEIPTS.md                    (optional — read if present)
#
# Usage: bootstrap-project.sh <project-id>

set -euo pipefail

ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ID="${1:?usage: bootstrap-project.sh <project-id>}"
PROJECT_DIR="$ROOT/org/projects/$PROJECT_ID"

if [[ -d "$PROJECT_DIR" ]]; then
  # Already bootstrapped — check if required files exist; fill any gaps
  MISSING=()
  [[ -f "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.md" ]] || MISSING+=("PROJECT_CONTROLLER_PROMPT.md")
  [[ -f "$PROJECT_DIR/STATE.json" ]]                  || MISSING+=("STATE.json")
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "[bootstrap] $PROJECT_ID already fully bootstrapped: $PROJECT_DIR"
    exit 0
  fi
  echo "[bootstrap] $PROJECT_ID dir exists but missing: ${MISSING[*]} — filling gaps"
fi

mkdir -p "$PROJECT_DIR"

if [[ ! -f "$PROJECT_DIR/STATE.json" ]]; then
  cat > "$PROJECT_DIR/STATE.json" <<EOF
{
  "project": "$PROJECT_ID",
  "orchestrator": "${PROJECT_ID}-ceo",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stage": "candidate",
  "status": "candidate",
  "primary_goal": "TBD — populate PROJECT_CONTROLLER_PROMPT.md before running agents.",
  "next_action": "Awaiting controller prompt and workspace handoff from omp-master-ceo.",
  "blockers": [],
  "active_workers": []
}
EOF
  echo "[bootstrap]  wrote STATE.json"
fi

if [[ ! -f "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.md" ]]; then
  # If a .draft.md exists from a pre-activation scout, copy it as the active prompt.
  if [[ -f "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.draft.md" ]]; then
    cp "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.draft.md" "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.md"
    echo "[bootstrap]  promoted .draft.md → PROJECT_CONTROLLER_PROMPT.md"
  else
    cat > "$PROJECT_DIR/PROJECT_CONTROLLER_PROMPT.md" <<EOF
# Project CEO — $PROJECT_ID

STUB — replace with the actual controller prompt before running agent jobs.
See org/projects/built-by-ai/PROJECT_CONTROLLER_PROMPT.md for canonical format.
EOF
    echo "[bootstrap]  wrote stub PROJECT_CONTROLLER_PROMPT.md"
  fi
fi

[[ -f "$PROJECT_DIR/RECEIPTS.md" ]]       || { touch "$PROJECT_DIR/RECEIPTS.md";       echo "[bootstrap]  created RECEIPTS.md"; }
[[ -f "$PROJECT_DIR/WORKSPACE_HANDOFF.md" ]] || { touch "$PROJECT_DIR/WORKSPACE_HANDOFF.md"; echo "[bootstrap]  created WORKSPACE_HANDOFF.md"; }

echo "[bootstrap] $PROJECT_ID ready at $PROJECT_DIR"
echo "  Next: fill PROJECT_CONTROLLER_PROMPT.md with real charter, then queue agent jobs."
