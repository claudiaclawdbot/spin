#!/usr/bin/env bash
# project-floor-watch.sh — live display for a project floor in cmux.
#
# Usage: project-floor-watch.sh <project-id>
#
# Watches:
#   - org/jobs/<project-id>-*.log  (most-recent job log, live tail)
#   - org/projects/<id>/STATE.json (status summary)
#   - org/ceo/INBOX.md             (project's recent reports)
#
# Run this in each project's controller_surface so the floor shows real activity
# instead of a blank prompt. When a new job is dispatched, the dispatcher sends
# a `tail -f <logfile>` command that interrupts this watch — that's intentional.

set -uo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
PROJECT_ID="${1:?usage: project-floor-watch.sh <project-id>}"
JOBS_DIR="$ROOT/org/jobs"
STATE="$ROOT/org/projects/$PROJECT_ID/STATE.json"
INBOX="$ROOT/org/ceo/INBOX.md"

while true; do
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $PROJECT_ID  |  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  # STATE summary
  if [[ -f "$STATE" ]]; then
    echo "── State ──"
    node -e "
const s = JSON.parse(require('fs').readFileSync('$STATE','utf8'));
console.log('  status:      ' + (s.status || 'unknown'));
console.log('  phase:       ' + (s.current_phase || '—'));
console.log('  next_action: ' + (s.next_action || '—'));
console.log('  updated:     ' + (s.updated_at || '—'));
" 2>/dev/null || cat "$STATE" | head -10
    echo
  fi

  # Recent inbox lines for this project
  echo "── Recent inbox ──"
  grep "$PROJECT_ID:" "$INBOX" 2>/dev/null | tail -4 | sed 's/^/  /' || echo "  (none)"
  echo

  # Latest job for THIS project — looked up from the queue (job IDs don't reliably
  # start with the full project id, so a glob would miss them).
  JOB_ID="$(node -e '
    try {
      const q = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const mine = (q.jobs||[]).filter(j => j.project_id === process.argv[2]
        && (j.started_at || j.status === "running"));
      mine.sort((a,b) => String(b.started_at||"").localeCompare(String(a.started_at||"")));
      if (mine[0]) process.stdout.write(mine[0].id);
    } catch (e) {}
  ' "$ROOT/org/AGENT_QUEUE.json" "$PROJECT_ID" 2>/dev/null)"
  LATEST_LOG=""
  [[ -n "$JOB_ID" && -f "$JOBS_DIR/$JOB_ID.log" ]] && LATEST_LOG="$JOBS_DIR/$JOB_ID.log"
  if [[ -n "$LATEST_LOG" ]]; then
    PID_FILE="$JOBS_DIR/$JOB_ID.pid"
    if [[ -f "$PID_FILE" ]]; then
      PID="$(cat "$PID_FILE")"
      if kill -0 "$PID" 2>/dev/null; then
        echo "── Live job log: $JOB_ID (running pid=$PID) ──"
        tail -n 20 "$LATEST_LOG" | sed 's/^/  /'
        echo "  ... (refresh in 5s)"
      else
        echo "── Last job log: $JOB_ID (completed) ──"
        tail -n 15 "$LATEST_LOG" | sed 's/^/  /'
      fi
    else
      echo "── Last job log: $JOB_ID ──"
      tail -n 15 "$LATEST_LOG" | sed 's/^/  /'
    fi
  else
    echo "── No jobs yet for $PROJECT_ID ──"
  fi

  echo
  echo "(auto-refresh 10s — dispatcher will tail live log when job starts)"
  sleep 10
done
