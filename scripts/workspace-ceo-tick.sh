#!/usr/bin/env bash
# workspace-ceo-tick.sh — THE single top-level driver loop for the OMP workspace
# (cmux workspace:4 / surface:14). One loop, one place. Each tick it:
#
#   1. Renders org state for the visible cockpit pane.
#   2. Runs the queue dispatcher (omp-supervisor-once.sh): marks finished jobs,
#      dispatches queued AGENT_QUEUE.json jobs to project controller surfaces,
#      updates cmux status chips. This is how the CEO's staged work reaches
#      projects; projects report back via STATE/RECEIPTS/INBOX.
#   3. Invokes the Workspace CEO agent brain (workspace-ceo-agent.sh) — but only
#      when watched inputs changed since the last run, so idle ticks cost nothing.
#
# This REPLACES the old omp-supervisor-loop.sh (which looped + called a one-shot
# tick) and the per-project continuous loops. Run exactly one of these.

set -uo pipefail   # not -e: a single bad tick must not kill the loop

ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$ROOT/scripts/lib/ceo-waterfall.sh"

# --- kill switch ----------------------------------------------------------
# If org/ceo/runs/STOP exists, the owner has paused the whole system. Refuse to
# run (and exit any loop that finds it appear). Remove the file to resume.
if [[ -f "$CEO_RUN_DIR/STOP" ]]; then
  echo "[workspace-ceo-tick] STOP flag present ($CEO_RUN_DIR/STOP) — paused. Remove it to resume." >&2
  exit 0
fi

# --- singleton guard ------------------------------------------------------
# Only one workspace CEO driver may run, no matter how it's launched (cmux
# surface, nohup daemon, or a stray re-run). This is the root-cause fix for the
# recurring duplicate-driver problem. If another live instance holds the lock,
# exit immediately.
LOCKFILE="$CEO_RUN_DIR/.workspace-ceo-tick.lock"
# Atomic acquire via noclobber: only one process can create the lock. Prevents
# the race where two near-simultaneous launches both pass a non-atomic check.
while ! ( set -o noclobber; echo $$ > "$LOCKFILE" ) 2>/dev/null; do
  OTHER_PID="$(cat "$LOCKFILE" 2>/dev/null)"
  if [[ -n "$OTHER_PID" ]] && kill -0 "$OTHER_PID" 2>/dev/null; then
    echo "[workspace-ceo-tick] another driver is already running (PID $OTHER_PID); exiting." >&2
    exit 0
  fi
  rm -f "$LOCKFILE"   # stale lock (owner dead) — clear and retry the atomic acquire
done
trap 'rm -f "$LOCKFILE"' EXIT
trap 'rm -f "$LOCKFILE"; exit 0' INT TERM

STATE="$ROOT/org/state.json"
QUEUE="$ROOT/org/AGENT_QUEUE.json"
INBOX="$ROOT/org/ceo/INBOX.md"
RUN_DIR="$CEO_RUN_DIR"
INTERVAL="${WORKSPACE_CEO_INTERVAL:-900}"          # 15 min between ticks
AGENT_HASH="$RUN_DIR/.workspace-ceo-agent.hash"    # content-hash gate for the brain
FORCE_EVERY="${WORKSPACE_CEO_FORCE_EVERY:-4}"       # force a brain run every N ticks

mkdir -p "$RUN_DIR"
TICK_COUNT=0

# Inputs whose SUBSTANTIVE content should wake the CEO brain. We deliberately do
# NOT watch AGENT_QUEUE.json (the dispatcher rewrites its timestamp every tick) or
# org/state.json (the brain writes it itself) — those cause self-triggering. The
# real "something happened" signals are INBOX (project reports), project STATE
# files, and HUMAN_QUEUE. content_changed() also strips volatile timestamp fields,
# so refresh scripts touching STATE.json don't falsely wake the brain.
watched_inputs() {
  echo "$ROOT/org/ceo/APPROVALS.md" "$INBOX" "$ROOT/org/HUMAN_QUEUE.md"
  local p; for p in "$ROOT"/org/projects/*/STATE.json; do echo "$p"; done
}

while true; do
  clear
  echo "============================================================"
  echo "WORKSPACE CEO  |  $(date '+%Y-%m-%d %H:%M:%S %Z')   tick #$TICK_COUNT"
  echo "============================================================"
  echo

  # -- 1. Org state display ------------------------------------------------
  if [[ -f "$STATE" ]]; then
    node - "$STATE" <<'NODE' 2>/dev/null || echo "(state.json unreadable)"
const s = JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
console.log(`Master: ${s.master_orchestrator?.name}  [${s.master_orchestrator?.status}]`);
console.log('Project orchestrators:');
for (const p of s.project_orchestrators || []) {
  if (!String(p.status).startsWith('active')) continue;
  console.log(`  ${p.id}  [${p.status}]${p.cmux_workspace ? ' | '+p.cmux_workspace : ''}`);
}
const hq = s.human_queue || [];
if (hq.length) { console.log('\nHuman queue:'); hq.forEach(i => console.log(`  - ${i}`)); }
NODE
  fi
  echo
  if codex_is_blocked; then
    echo "Provider: claude (codex blocked until $(date -r "$(cat "$CEO_LOCKOUT_FILE")" '+%m-%d %H:%M'))"
  else
    echo "Provider: $(select_provider true)  (codex available for project jobs)"
  fi
  echo; echo "Inbox (recent):"; tail -4 "$INBOX" 2>/dev/null | sed 's/^/  /' || echo "  (empty)"

  # -- 2. Queue dispatch + job lifecycle -----------------------------------
  echo; echo "[dispatch] running queue tick…"
  "$ROOT/scripts/omp-supervisor-once.sh" 2>&1 | sed 's/^/  /' || echo "  (dispatch tick failed)"

  # -- 3. CEO agent brain (change-gated) -----------------------------------
  echo
  FORCE=0
  (( FORCE_EVERY > 0 && TICK_COUNT % FORCE_EVERY == 0 )) && FORCE=1
  # content_changed updates the hash as a side effect, so evaluate it once.
  GATE_OPEN=1; content_changed "$AGENT_HASH" $(watched_inputs) || GATE_OPEN=0
  if (( FORCE == 1 || GATE_OPEN == 1 )); then
    REASON=$([[ $FORCE == 1 ]] && echo "scheduled" || echo "content changed")
    echo "[ceo] invoking agent brain ($REASON)…"
    BRAIN_TIMEOUT="${WORKSPACE_CEO_BRAIN_TIMEOUT:-240}"
    run_with_timeout "$BRAIN_TIMEOUT" "$ROOT/scripts/workspace-ceo-agent.sh"; brc=$?
    if (( brc == 0 )); then
      echo "[ceo] agent run complete."
    elif (( brc == 124 || brc == 143 || brc == 137 )); then
      echo "[ceo] agent run TIMED OUT after ${BRAIN_TIMEOUT}s — killed, continuing loop."
    else
      echo "[ceo] agent run failed (rc=$brc; see org/ceo/runs/)."
    fi
  else
    echo "[ceo] no substantive input changes — skipping (free idle tick)."
  fi

  echo; echo "Latest CEO receipt:"
  LATEST="$(ls -t "$RUN_DIR"/workspace-ceo-agent-*.md 2>/dev/null | head -1)"
  [[ -n "$LATEST" ]] && tail -6 "$LATEST" | sed 's/^/  /' || echo "  (none yet)"

  echo; echo "Next tick in ${INTERVAL}s  (Ctrl-C to stop)"
  TICK_COUNT=$((TICK_COUNT + 1))
  sleep "$INTERVAL"
done
