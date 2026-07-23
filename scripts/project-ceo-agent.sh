#!/usr/bin/env bash
# project-ceo-agent.sh — invoke a single Project CEO as an LLM agent for one tick.
#
# Reads the project's controller prompt + its STATE/receipts + the latest
# workspace handoff, runs the agent (OMP first, direct CLIs as outer fallback),
# and lets the agent update STATE/RECEIPTS and report
# up to org/ceo/INBOX.md per its prompt.
#
# Usage: project-ceo-agent.sh <project-id>
# Env:   PROJECT_CEO_PROVIDER=...   SPIN_OMP_DEFAULT_MODEL=...
#        OMP_JOB_ID / OMP_JOB_TYPE / OMP_JOB_DESCRIPTION  (optional worker job)

set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$ROOT/scripts/lib/ceo-waterfall.sh"
source "$ROOT/scripts/lib/project-root.sh"

PROJECT_ID="${1:?usage: project-ceo-agent.sh <project-id>}"
PROJECT="$ROOT/org/projects/$PROJECT_ID"
PROJECT_CODE_ROOT="$(spin_project_root "$PROJECT_ID")" || exit $?
export SPIN_PROJECT_ROOT="$PROJECT_CODE_ROOT"
export SPIN_AGENT_CWD="$PROJECT_CODE_ROOT"
PROMPT_FILE="$PROJECT/PROJECT_CONTROLLER_PROMPT.md"
HANDOFF_FILE="$PROJECT/WORKSPACE_HANDOFF.md"
STATE_FILE="$PROJECT/STATE.json"
RECEIPTS_FILE="$PROJECT/RECEIPTS.md"
INBOX="$ROOT/org/ceo/INBOX.md"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$CEO_RUN_DIR/${PROJECT_ID}-agent-${TS}.log"

# Project-specific provider/model choices are the final override after the
# organization-wide defaults loaded by ceo-waterfall.sh.
spin_load_project_env "$PROJECT/project.env" || exit $?
# Keep the isolation boundary canonical even if the loader grows new allowed
# settings later.
export SPIN_ROOT="$ROOT"
export SPIN_PROJECT_ROOT="$PROJECT_CODE_ROOT"
export SPIN_AGENT_CWD="$PROJECT_CODE_ROOT"
if [[ -n "${OMP_JOB_ID:-}" ]]; then
  # The supervisor permits one queued job per project, so this lane stays
  # bounded while remaining separate from manual, floor, and one-shot runs.
  export SPIN_OMP_CONFIG_LANE="project-job:${PROJECT_ID}"
else
  export SPIN_OMP_CONFIG_LANE="project-agent:${PROJECT_ID}"
fi

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
- Resource class: ${OMP_RESOURCE_CLASS:-normal}
- Description: ${OMP_JOB_DESCRIPTION:-none}

Execute this job within the project hard rules and write a receipt that includes the job ID.
The appended receipt MUST end with exactly one terminal line in this form:
Queue-Outcome: ${OMP_JOB_ID} COMPLETED
or:
Queue-Outcome: ${OMP_JOB_ID} BLOCKED
Use COMPLETED only when the assigned business outcome was achieved. Use BLOCKED
for policy, authorization, or prerequisite blockers. A safe stop is not completion.
"
fi

PROMPT_BODY="$(cat "$PROMPT_FILE")

---

$(cat "$ROOT/scripts/lib/action-policy-prompt.md")

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

## Project code root
\`$PROJECT_CODE_ROOT\`

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

# The provider exit code reports process health, not whether the assigned
# business outcome was achieved. Convert the newly appended receipt marker into
# an atomic, supervisor-readable sidecar. Missing or ambiguous markers fail
# closed in omp-supervisor-once.sh.
OUTCOME_FILE="${OMP_OUTCOME_FILE:-}"
RECEIPTS_START_BYTES="$(wc -c < "$RECEIPTS_FILE" 2>/dev/null || printf '0')"

write_terminal_outcome() {
  local final_rc="$1"
  [[ -n "$OUTCOME_FILE" && -n "${OMP_JOB_ID:-}" ]] || return 0

  local expected="$ROOT/org/jobs/${OMP_JOB_ID}.outcome.json"
  [[ "$OUTCOME_FILE" == "$expected" ]] || {
    echo "Refusing unexpected outcome path: $OUTCOME_FILE" >&2
    return 1
  }

  local outcome="" detail="" new_receipts line marker_count=0 receipt_last_nonempty_line="" expected_marker=""
  if [[ "$final_rc" -ne 0 ]]; then
    outcome="failed"
    detail="Project agent exited ${final_rc}."
  else
    new_receipts="$(tail -c "+$((RECEIPTS_START_BYTES + 1))" "$RECEIPTS_FILE" 2>/dev/null || true)"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$line" in
        "Queue-Outcome: ${OMP_JOB_ID} COMPLETED")
          outcome="completed"
          marker_count=$((marker_count + 1))
          ;;
        "Queue-Outcome: ${OMP_JOB_ID} BLOCKED")
          outcome="blocked"
          marker_count=$((marker_count + 1))
          ;;
      esac
    done <<< "$new_receipts"
    # Count markers only in the newly appended bytes, but validate terminal-line
    # shape against the whole file. Otherwise a marker appended to an existing
    # unterminated line could look standalone when viewed only at the byte delta.
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ [^[:space:]] ]] && receipt_last_nonempty_line="$line"
    done < "$RECEIPTS_FILE"

    case "$outcome" in
      completed) expected_marker="Queue-Outcome: ${OMP_JOB_ID} COMPLETED" ;;
      blocked)   expected_marker="Queue-Outcome: ${OMP_JOB_ID} BLOCKED" ;;
    esac

    if [[ "$marker_count" -ne 1 ]]; then
      outcome="failed"
      detail="Missing or ambiguous Queue-Outcome receipt marker for job ${OMP_JOB_ID}."
    elif [[ "$receipt_last_nonempty_line" != "$expected_marker" ]]; then
      outcome="failed"
      detail="Queue-Outcome marker for job ${OMP_JOB_ID} was not the final non-empty appended receipt line."
    elif [[ "$outcome" == "completed" ]]; then
      detail="Project receipt reported Queue-Outcome: ${OMP_JOB_ID} COMPLETED."
    else
      detail="Project receipt reported Queue-Outcome: ${OMP_JOB_ID} BLOCKED."
    fi
  fi

  mkdir -p "$(dirname "$OUTCOME_FILE")"
  local temporary="${OUTCOME_FILE}.tmp.$$"
  node - "$temporary" "$OMP_JOB_ID" "$outcome" "$detail" <<'NODE'
const fs = require('fs');
const [file, jobId, outcome, detail] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  version: 1,
  job_id: jobId,
  outcome,
  detail,
}) + '\n');
NODE
  mv "$temporary" "$OUTCOME_FILE"
}

# Pre-run hash: snapshot current state so post-run check can detect new changes.
DIFF_STAMP="$(mktemp)"
content_changed "$DIFF_STAMP" "$STATE_FILE" "$RECEIPTS_FILE" || true

# --- run (OMP-first; outer fallback only for preflight-safe failures) -------
echo "[project-ceo-agent:$PROJECT_ID] run=$RUN_LOG" >&2
rc=0
run_agent_resilient false "${PROJECT_CEO_PROVIDER:-omp}" "$PROMPT_BODY" "$RUN_LOG" \
  "$PROJECT" "$ROOT/org/ceo" "$ROOT/org/action-broker" || rc=$?
echo "[project-ceo-agent:$PROJECT_ID] done (rc=$rc) — log=$RUN_LOG" >&2

# A clean provider exit without a project state or receipt update is not a
# successful controller run. Do not retry through another outer provider here:
# the first attempt may have changed project code, and a second attempt could
# duplicate or conflict with that partial work.
if [[ $rc -eq 0 ]] && ! content_changed "$DIFF_STAMP" "$STATE_FILE" "$RECEIPTS_FILE"; then
  echo "[project-ceo-agent:$PROJECT_ID] ERROR silent exit — no STATE.json or RECEIPTS.md update; refusing a duplicate outer run" >&2
  rc=65
fi
write_terminal_outcome "$rc"
rm -f "$DIFF_STAMP"
exit $rc
