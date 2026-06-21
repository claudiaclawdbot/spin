#!/usr/bin/env bash
# workspace-ceo-agent.sh — invoke the Workspace CEO as an LLM agent for one tick.
#
# Reads the Workspace Controller Prompt + curated org state, runs the agent
# (claude -> cursor -> gemini; codex skipped to preserve its quota for project
# work), and lets the agent write handoffs/state/receipts per its prompt.
#
# Usage: workspace-ceo-agent.sh
# Env:   WORKSPACE_CEO_PROVIDER=claude|cursor|gemini   (override)
#        MODEL=<model>                                  (override per provider)

set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$ROOT/scripts/lib/ceo-waterfall.sh"

PROMPT_FILE="$ROOT/org/ceo/WORKSPACE_CONTROLLER_PROMPT.md"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="$CEO_RUN_DIR/workspace-ceo-agent-${TS}.log"

# --- gather active projects from state.json -------------------------------
ACTIVE_PROJECTS=()
if command -v node >/dev/null 2>&1; then
  while IFS= read -r line; do [[ -n "$line" ]] && ACTIVE_PROJECTS+=("$line"); done < <(
    node -e '
      const s = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      for (const p of s.project_orchestrators || [])
        if (p.status === "active-cmux-project-ceo") console.log(p.project);
    ' "$ROOT/org/state.json" 2>/dev/null
  )
fi

# --- build curated context ------------------------------------------------
CONTEXT="$(mktemp)"
trap 'rm -f "$CONTEXT"' EXIT
{
  echo "# Workspace CEO Tick Context — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "## org/ceo/APPROVALS.md (human decisions — process Pending first)"; echo '```'
  cat "$ROOT/org/ceo/APPROVALS.md" 2>/dev/null || echo "(none)"; echo '```'; echo
  echo "## org/state.json"; echo '```json'; cat "$ROOT/org/state.json"; echo; echo '```'; echo
  echo "## org/AGENT_QUEUE.json (last 5 jobs)"; echo '```json'
  node -e '
    const q = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    console.log(JSON.stringify({version:q.version,updated_at:q.updated_at,jobs:(q.jobs||[]).slice(-5)},null,2));
  ' "$ROOT/org/AGENT_QUEUE.json" 2>/dev/null || echo '{}'
  echo '```'; echo
  echo "## org/HUMAN_QUEUE.md"; echo '```'; cat "$ROOT/org/HUMAN_QUEUE.md" 2>/dev/null || echo "(missing)"; echo '```'; echo
  echo "## org/ceo/INBOX.md (last 30 lines — project CEOs report here)"; echo '```'
  tail -30 "$ROOT/org/ceo/INBOX.md" 2>/dev/null || echo "(empty)"; echo '```'; echo
  for project in "${ACTIVE_PROJECTS[@]}"; do
    echo "## Project: $project"; echo
    echo "### STATE.json"; echo '```json'; cat "$ROOT/org/projects/$project/STATE.json" 2>/dev/null || echo '{}'; echo; echo '```'; echo
    echo "### Last 40 lines of RECEIPTS.md"; echo '```'; tail -40 "$ROOT/org/projects/$project/RECEIPTS.md" 2>/dev/null || echo "(none)"; echo '```'; echo
    echo "### Current WORKSPACE_HANDOFF.md (what you told them last tick)"; echo '```'; cat "$ROOT/org/projects/$project/WORKSPACE_HANDOFF.md" 2>/dev/null || echo "(none yet)"; echo '```'; echo
  done
  echo "## Codex lockout"
  codex_is_blocked && echo "BLOCKED until $(format_epoch_full "$(cat "$CEO_LOCKOUT_FILE")")" || echo "available"
  echo
  echo "## Your receipt for this tick goes to:"
  echo "$CEO_RUN_DIR/workspace-ceo-agent-${TS}.md"
} > "$CONTEXT"

PROMPT_BODY="$(cat "$PROMPT_FILE")

---

$(cat "$CONTEXT")
"

# --- run (resilient: falls through providers on usage-limit) --------------
echo "[workspace-ceo-agent] run=$RUN_LOG" >&2
run_agent_resilient true "${WORKSPACE_CEO_PROVIDER:-}" "$PROMPT_BODY" "$RUN_LOG" "$ROOT/org" "$ROOT/scripts"
rc=$?
echo "[workspace-ceo-agent] done (rc=$rc) — log=$RUN_LOG" >&2
exit $rc
