#!/usr/bin/env bash
# project-ceo-agent.sh — invoke a single Project CEO as an LLM agent for one tick.
#
# Reads the project's controller prompt + its STATE/receipts + the latest
# workspace handoff, runs the agent (codex -> claude -> cursor -> gemini, codex
# skipped while locked out), and lets the agent update STATE/RECEIPTS and report
# up to org/ceo/INBOX.md per its prompt.
#
# Usage: project-ceo-agent.sh <project-id>
# Env:   PROJECT_CEO_PROVIDER=...   MODEL=...
#        OMP_JOB_ID / OMP_JOB_TYPE / OMP_JOB_DESCRIPTION  (optional worker job)

set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$ROOT/scripts/lib/ceo-waterfall.sh"

PROJECT_ID="${1:?usage: project-ceo-agent.sh <project-id>}"
PROJECT="$ROOT/org/projects/$PROJECT_ID"
PROMPT_FILE="$PROJECT/PROJECT_CONTROLLER_PROMPT.md"
HANDOFF_FILE="$PROJECT/WORKSPACE_HANDOFF.md"
STATE_FILE="$PROJECT/STATE.json"
RECEIPTS_FILE="$PROJECT/RECEIPTS.md"
INBOX="$ROOT/org/ceo/INBOX.md"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$CEO_RUN_DIR/${PROJECT_ID}-agent-${TS}.log"

[[ -f "$PROMPT_FILE" ]] || { echo "Missing controller prompt: $PROMPT_FILE" >&2; exit 1; }
[[ -f "$STATE_FILE"  ]] || { echo "Missing project STATE.json: $STATE_FILE"  >&2; exit 1; }

# --- compose context ------------------------------------------------------
HANDOFF_BLOCK="(none yet)"
[[ -f "$HANDOFF_FILE" ]] && HANDOFF_BLOCK="$(cat "$HANDOFF_FILE")"

JOB_BLOCK=""
if [[ -n "${OMP_JOB_ID:-}${OMP_JOB_DESCRIPTION:-}" ]]; then
  JOB_BLOCK="## Assigned worker job
- Job ID: ${OMP_JOB_ID:-unknown}
- Type: ${OMP_JOB_TYPE:-project-ceo-run}
- Description: ${OMP_JOB_DESCRIPTION:-none}

Execute this job within the project hard rules and write a receipt that includes the job ID.
"
fi

PROMPT_BODY="$(cat "$PROMPT_FILE")

---

## Latest workspace handoff (from omp-master-ceo)
\`\`\`
$HANDOFF_BLOCK
\`\`\`

$JOB_BLOCK

## STATE.json
\`\`\`json
$(cat "$STATE_FILE")
\`\`\`

## Last 40 lines of RECEIPTS.md
\`\`\`
$(tail -40 "$RECEIPTS_FILE" 2>/dev/null || echo "(none yet)")
\`\`\`

## Codex lockout
$(codex_is_blocked && echo "BLOCKED until $(format_epoch_full "$(cat "$CEO_LOCKOUT_FILE")")" || echo "available")

## Reporting
- Append a one-paragraph receipt to $RECEIPTS_FILE for any meaningful work.
- To ask the Workspace CEO for cross-project help or escalation, append ONE line to
  $INBOX in the form:  [$(date -u '+%Y-%m-%dT%H:%MZ')] $PROJECT_ID: <message>
"

# Pre-run hash: snapshot current state so post-run check can detect new changes.
DIFF_STAMP="$(mktemp)"
content_changed "$DIFF_STAMP" "$STATE_FILE" "$RECEIPTS_FILE" || true

# --- run (resilient: falls through providers on usage-limit) --------------
echo "[project-ceo-agent:$PROJECT_ID] run=$RUN_LOG" >&2
rc=0
run_agent_resilient false "${PROJECT_CEO_PROVIDER:-}" "$PROMPT_BODY" "$RUN_LOG" "$PROJECT" || rc=$?
echo "[project-ceo-agent:$PROJECT_ID] done (rc=$rc) — log=$RUN_LOG" >&2

# Post-run diff check: if agent exited 0 but changed no files, retry once with
# claude. Catches silent Gemini/Ollama exits that produce no file writes but
# exit 0, which the dispatcher would otherwise log as "Controller process exited".
if [[ $rc -eq 0 ]] && ! content_changed "$DIFF_STAMP" "$STATE_FILE" "$RECEIPTS_FILE"; then
  echo "[project-ceo-agent:$PROJECT_ID] WARNING silent exit — no changes to STATE.json or RECEIPTS.md; retrying once with claude" >&2
  RUN_LOG2="$CEO_RUN_DIR/${PROJECT_ID}-agent-${TS}-retry.log"
  rc=0
  run_agent_resilient false "claude" "$PROMPT_BODY" "$RUN_LOG2" "$PROJECT" || rc=$?
  if content_changed "$DIFF_STAMP" "$STATE_FILE" "$RECEIPTS_FILE"; then
    echo "[project-ceo-agent:$PROJECT_ID] retry produced changes (rc=$rc)" >&2
  else
    echo "[project-ceo-agent:$PROJECT_ID] retry also silent — done (rc=$rc)" >&2
  fi
fi
rm -f "$DIFF_STAMP"
exit $rc
