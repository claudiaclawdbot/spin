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
RUN_DIR="$ROOT/org/ceo/runs"
LOCK="$RUN_DIR/.status-watch.lock"
STOP="$RUN_DIR/STATUS_WATCH_STOP"
INTERVAL="${1:-6}"
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
  bash "$ROOT/scripts/workspace-status.sh" 2>/dev/null || true
  bash "$ROOT/scripts/wiki-update.sh"       2>/dev/null || true   # keep wiki fresh alongside WORKSPACE_STATUS

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
  elif dpid="$(cat "$DRIVER_LOCK" 2>/dev/null)" && [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then DSTATE="up"
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
