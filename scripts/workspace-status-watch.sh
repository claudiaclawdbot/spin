#!/usr/bin/env bash
# workspace-status-watch.sh — keep WORKSPACE_STATUS.md fresh by re-rolling the project
# floor boards every few seconds. Pure file I/O, NO LLM, zero usage. Singleton-locked
# and stoppable. cmux's markdown viewer auto-reloads the output, so the CEO floor shows
# a live workspace-wide status board.
#
#   start:  nohup scripts/workspace-status-watch.sh >/dev/null 2>&1 &
#   stop:   touch org/ceo/runs/STATUS_WATCH_STOP   (or: pkill -f workspace-status-watch)
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
source "$ROOT/scripts/lib/spin-runtime.sh"
source "$ROOT/scripts/lib/cmux-floor-layout.sh"
RUN_DIR="$ROOT/org/ceo/runs"
LOCK="$RUN_DIR/.status-watch.lock"
STOP="$RUN_DIR/STATUS_WATCH_STOP"
HEARTBEAT="$RUN_DIR/.status-watch.heartbeat"
INTERVAL="${1:-6}"
FLOOR_RECONCILE_SECONDS="${SPIN_FLOOR_RECONCILE_SECONDS:-60}"
FLOOR_RECONCILE_GRACE_SECONDS="${SPIN_FLOOR_RECONCILE_GRACE_SECONDS:-15}"
case "$FLOOR_RECONCILE_SECONDS" in ''|*[!0-9]*) FLOOR_RECONCILE_SECONDS=60 ;; esac
case "$FLOOR_RECONCILE_GRACE_SECONDS" in ''|*[!0-9]*) FLOOR_RECONCILE_GRACE_SECONDS=15 ;; esac
NEXT_FLOOR_RECONCILE=$(( $(date +%s) + FLOOR_RECONCILE_GRACE_SECONDS ))
mkdir -p "$RUN_DIR"
rm -f "$STOP"
CEO_WS="$(node -e 'const fs=require("fs"),f=process.argv[1];try{const h=JSON.parse(fs.readFileSync(f,"utf8"));process.stdout.write(h.workspace_ceo?.cmux_workspace||"workspace:1")}catch{process.stdout.write("workspace:1")}' "$ROOT/org/OMP_HARNESS.json" 2>/dev/null)"

# Atomic singleton: only one watcher, ever.
while ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; do
  other="$(cat "$LOCK" 2>/dev/null)"
  if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
    echo "[status-watch] already running (PID $other); exiting." >&2; exit 0
  fi
  rm -f "$LOCK"
done
trap 'rm -f "$LOCK"' EXIT
trap 'rm -f "$LOCK"; exit 0' INT TERM

while true; do
  [[ -f "$STOP" ]] && { echo "[status-watch] STOP flag — exiting." >&2; rm -f "$STOP"; exit 0; }

  now_epoch="$(date +%s)"
  if (( FLOOR_RECONCILE_SECONDS > 0 && now_epoch >= NEXT_FLOOR_RECONCILE )); then
    NEXT_FLOOR_RECONCILE=$(( now_epoch + FLOOR_RECONCILE_SECONDS ))
    spin_prepare_cmux_environment
    if ! spin_locked_process_running "$RUN_DIR/.spin-up.lock" "spin-up.sh" \
      && CMUX_QUIET=1 spin_cmd cmux ping >/dev/null 2>&1; then
      spin_cmux_reconcile_managed_floors >/dev/null 2>&1 || true
    fi
  fi

  bash "$ROOT/scripts/workspace-status.sh" 2>/dev/null || true
  bash "$ROOT/scripts/wiki-update.sh"       2>/dev/null || true   # keep wiki fresh alongside WORKSPACE_STATUS
  touch "$HEARTBEAT"

  # ── driver watchdog: status chip + one-shot notification on state change ──
  # Catches the silent-halt situation (e.g. a STOP file or dead loop) that once
  # went unnoticed for 3 days. Chip targets the CEO floor; failures are silent
  # (cmux refs drift) — WORKSPACE_STATUS.md carries the same state as fallback.
  DRIVER_LOCK="$RUN_DIR/.workspace-ceo-tick.lock"
  DRIVER_STATE_F="$RUN_DIR/.driver-state"
  STALE_STOP_HRS="${SPIN_STALE_STOP_HOURS:-2}"   # a STOP older than this is probably forgotten
  if [[ -f "$RUN_DIR/STOP" ]]; then
    DSTATE="paused"
    # A STOP that's been sitting for hours is almost certainly forgotten, not a
    # deliberate pause (this once left the driver down ~20h silently). Escalate.
    age_s=$(( $(date +%s) - $(stat -f %m "$RUN_DIR/STOP" 2>/dev/null || stat -c %Y "$RUN_DIR/STOP" 2>/dev/null || echo "$(date +%s)") ))
    (( age_s > STALE_STOP_HRS * 3600 )) && DSTATE="paused-stale"
  elif spin_locked_process_running "$DRIVER_LOCK" "$ROOT/scripts/workspace-ceo-tick.sh"; then DSTATE="up"
  else DSTATE="down"; fi
  PREV_DSTATE="$(cat "$DRIVER_STATE_F" 2>/dev/null || echo unknown)"
  if [[ "$DSTATE" != "$PREV_DSTATE" ]]; then
    echo "$DSTATE" > "$DRIVER_STATE_F"
    case "$DSTATE" in
      up)     spin_cmd cmux set-status driver "SPIN loop UP"     --workspace "$CEO_WS" --icon checkmark.circle --color '#22c55e' --priority 90 >/dev/null 2>&1 || true ;;
      paused) spin_cmd cmux set-status driver "SPIN loop PAUSED" --workspace "$CEO_WS" --icon pause.circle     --color '#eab308' --priority 90 >/dev/null 2>&1 || true ;;
      paused-stale)
              spin_cmd cmux set-status driver "SPIN PAUSED ${STALE_STOP_HRS}h+ — forgotten?" --workspace "$CEO_WS" --icon exclamationmark.triangle --color '#f97316' --priority 95 >/dev/null 2>&1 || true
              spin_cmd cmux notify --title "SPIN paused for hours" \
                   --body "A STOP file has paused the driver for ${STALE_STOP_HRS}h+. Resume: rm org/ceo/runs/STOP (or spin start). If intentional, ignore." \
                   --workspace "$CEO_WS" >/dev/null 2>&1 || true ;;
      down)   spin_cmd cmux set-status driver "SPIN loop DOWN"   --workspace "$CEO_WS" --icon exclamationmark.triangle --color '#ef4444' --priority 95 >/dev/null 2>&1 || true
              spin_cmd cmux notify --title "SPIN driver DOWN" \
                   --body "tick loop not running — spin start (or rm org/ceo/runs/STOP if paused)" \
              --workspace "$CEO_WS" >/dev/null 2>&1 || true ;;
    esac
  fi

  # ── live work state: running/queued/failures + observed resource use ─────
  JOB_STATE_F="$RUN_DIR/.job-status-state"
  JOB_SUMMARY="$(node - "$ROOT" <<'NODE' 2>/dev/null || true
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
let jobs = [];
let dispatchStatus = '';
try {
  const queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  jobs = Array.isArray(queue) ? queue : (queue.jobs || []);
  dispatchStatus = Array.isArray(queue) ? '' : String(queue.dispatch_state?.status || '');
} catch {}
const running = jobs.filter(job => job.status === 'running');
const queued = jobs.filter(job => job.status === 'queued');
const blocked = jobs.filter(job => job.status === 'blocked');
const recentFailed = jobs.filter(job => {
  if (job.status !== 'failed') return false;
  const at = Date.parse(job.failed_at || job.updated_at || '');
  return !Number.isFinite(at) || Date.now() - at < 86400000;
});
let stale = 0;
let rss = 0;
let rssLimit = 0;
let processes = 0;
let processLimit = 0;
let sampled = 0;
for (const job of running) {
  const heartbeat = Date.parse(job.heartbeat_at || job.started_at || '');
  if (Number.isFinite(heartbeat) && Date.now() - heartbeat > 90000) stale += 1;
  rssLimit += Number(job.resource_limits?.max_rss_mb || 0);
  processLimit += Number(job.resource_limits?.max_processes || 0);
  const relative = job.resource_usage || `org/jobs/${job.id}.usage.json`;
  try {
    const file = path.resolve(root, relative);
    if (file !== root && !file.startsWith(`${root}${path.sep}`)) continue;
    const usage = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (Number.isFinite(Number(usage.rss_mb)) && Number.isFinite(Number(usage.processes))) {
      rss += Number(usage.rss_mb);
      processes += Number(usage.processes);
      sampled += 1;
    }
  } catch {}
}
process.stdout.write([running.length, queued.length, blocked.length + recentFailed.length, stale, rss, rssLimit, processes, processLimit, sampled, dispatchStatus].join('\t'));
NODE
)"
  if [[ -n "$JOB_SUMMARY" ]]; then
    IFS=$'\t' read -r JOB_RUNNING JOB_QUEUED JOB_ATTENTION JOB_STALE JOB_RSS JOB_RSS_LIMIT JOB_PROCESSES JOB_PROCESS_LIMIT JOB_SAMPLED JOB_DISPATCH <<< "$JOB_SUMMARY"
    PREV_JOB_SUMMARY="$(cat "$JOB_STATE_F" 2>/dev/null || true)"
    if [[ "$JOB_SUMMARY" != "$PREV_JOB_SUMMARY" ]]; then
      echo "$JOB_SUMMARY" > "$JOB_STATE_F"
      if (( JOB_ATTENTION > 0 )); then
        spin_cmd cmux set-status work "$JOB_RUNNING running - $JOB_QUEUED queued - $JOB_ATTENTION need attention" \
          --workspace "$CEO_WS" --icon exclamationmark.triangle --color '#ef4444' --priority 91 >/dev/null 2>&1 || true
      elif (( JOB_STALE > 0 )); then
        spin_cmd cmux set-status work "$JOB_RUNNING running - $JOB_STALE stale heartbeat" \
          --workspace "$CEO_WS" --icon exclamationmark.triangle --color '#f97316' --priority 89 >/dev/null 2>&1 || true
      elif [[ "$JOB_DISPATCH" == "memory-pressure" || "$JOB_DISPATCH" == "draining-for-heavy" ]]; then
        spin_cmd cmux set-status work "$JOB_DISPATCH - $JOB_RUNNING running - $JOB_QUEUED queued" \
          --workspace "$CEO_WS" --icon exclamationmark.triangle --color '#f97316' --priority 88 >/dev/null 2>&1 || true
      elif (( JOB_RUNNING > 0 )); then
        resource_text="resources sampling"
        (( JOB_SAMPLED > 0 )) && resource_text="${JOB_RSS}/${JOB_RSS_LIMIT:-?}MB - ${JOB_PROCESSES}/${JOB_PROCESS_LIMIT:-?} proc"
        spin_cmd cmux set-status work "$JOB_RUNNING running - $resource_text - $JOB_QUEUED queued" \
          --workspace "$CEO_WS" --icon gearshape.2 --color '#22c55e' --priority 80 >/dev/null 2>&1 || true
      elif (( JOB_QUEUED > 0 )); then
        spin_cmd cmux set-status work "$JOB_QUEUED jobs queued" \
          --workspace "$CEO_WS" --icon list.bullet --color '#38bdf8' --priority 70 >/dev/null 2>&1 || true
      else
        spin_cmd cmux clear-status work --workspace "$CEO_WS" >/dev/null 2>&1 || true
      fi
    fi
  fi

  # ── human-approval latency: chip + one-shot notification past threshold ──
  APPROVAL_STATE_F="$RUN_DIR/.approval-latency-state"
  if approval_env="$(node "$ROOT/scripts/lib/human-queue-summary.js" "$ROOT" --env 2>/dev/null)"; then
    eval "$approval_env"
    if (( ${SPIN_HUMAN_WAITING_COUNT:-0} > 0 )); then
      spin_cmd cmux set-status approvals "$SPIN_HUMAN_WAITING_SUMMARY" \
        --workspace "$CEO_WS" --icon exclamationmark.triangle \
        --color "${SPIN_HUMAN_WAITING_COLOR:-#eab308}" --priority 92 >/dev/null 2>&1 || true

      notify_minutes="${SPIN_APPROVAL_NOTIFY_MINUTES:-1440}"
      if [[ "$notify_minutes" =~ ^[0-9]+$ && "$notify_minutes" != "0" ]] && (( ${SPIN_HUMAN_WAITING_OLDEST_SECONDS:-0} >= notify_minutes * 60 )); then
        notify_key="${SPIN_HUMAN_WAITING_OLDEST_AT:-unknown}|${SPIN_HUMAN_WAITING_COUNT:-0}|$notify_minutes"
        prev_notify_key="$(cat "$APPROVAL_STATE_F" 2>/dev/null || true)"
        if [[ "$notify_key" != "$prev_notify_key" ]]; then
          echo "$notify_key" > "$APPROVAL_STATE_F"
          spin_cmd cmux notify --title "SPIN is waiting on you" \
            --body "$SPIN_HUMAN_WAITING_SUMMARY — ${SPIN_HUMAN_WAITING_OLDEST_TEXT:-open spin status}" \
            --workspace "$CEO_WS" >/dev/null 2>&1 || true
        fi
      fi
    else
      spin_cmd cmux clear-status approvals --workspace "$CEO_WS" >/dev/null 2>&1 || true
      rm -f "$APPROVAL_STATE_F" 2>/dev/null || true
    fi
  fi
  sleep "$INTERVAL"
done
