#!/usr/bin/env bash
# workspace-status-watch.sh — keep WORKSPACE_STATUS.md fresh by re-rolling the project
# floor boards every few seconds. Pure file I/O, NO LLM, zero usage. Singleton-locked
# and stoppable. cmux's markdown viewer auto-reloads the output, so the CEO floor shows
# a live workspace-wide status board.
#
#   start:  nohup scripts/workspace-status-watch.sh >/dev/null 2>&1 &
#   stop:   touch org/ceo/runs/STATUS_WATCH_STOP   (or: pkill -f workspace-status-watch)
set -uo pipefail
ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUN_DIR="$ROOT/org/ceo/runs"
LOCK="$RUN_DIR/.status-watch.lock"
STOP="$RUN_DIR/STATUS_WATCH_STOP"
INTERVAL="${1:-6}"
mkdir -p "$RUN_DIR"
rm -f "$STOP"

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
  if [[ -f "$RUN_DIR/STOP" ]]; then DSTATE="paused"
  elif dpid="$(cat "$DRIVER_LOCK" 2>/dev/null)" && [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then DSTATE="up"
  else DSTATE="down"; fi
  PREV_DSTATE="$(cat "$DRIVER_STATE_F" 2>/dev/null || echo unknown)"
  if [[ "$DSTATE" != "$PREV_DSTATE" ]]; then
    echo "$DSTATE" > "$DRIVER_STATE_F"
    case "$DSTATE" in
      up)     cmux set-status driver "CEO loop UP"     --workspace workspace:1 --icon checkmark.circle --color '#22c55e' --priority 90 >/dev/null 2>&1 || true ;;
      paused) cmux set-status driver "CEO loop PAUSED" --workspace workspace:1 --icon pause.circle     --color '#eab308' --priority 90 >/dev/null 2>&1 || true ;;
      down)   cmux set-status driver "CEO loop DOWN"   --workspace workspace:1 --icon exclamationmark.triangle --color '#ef4444' --priority 95 >/dev/null 2>&1 || true
              cmux notify --title "Workspace CEO driver DOWN" \
                   --body "tick loop not running — bash scripts/workspace-ceo-tick.sh in the CEO pane (or rm org/ceo/runs/STOP if paused)" \
                   --workspace workspace:1 >/dev/null 2>&1 || true ;;
    esac
  fi
  sleep "$INTERVAL"
done
