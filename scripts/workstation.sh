#!/usr/bin/env bash
# workstation.sh — bring the omp+cmux workstation up/down, or health-check it.
#   workstation.sh up      # (re)launch each floor's omp agent + the roll-up daemon
#   workstation.sh down    # quit agents + stop daemon
#   workstation.sh status  # health check (default)
#
# NOTE: run with bash (shebang) — relies on word-splitting that zsh disables.
set -uo pipefail
ROOT="${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# floor map: "<workspace-ref> <floor-target>"
FLOORS=(
  "workspace:1 ceo"
  "workspace:2 fidget-play"
  "workspace:3 built-by-ai"
)

term_surface() {  # first terminal surface in a workspace (robust to ID drift)
  cmux tree --workspace "$1" 2>/dev/null \
    | grep -oE "surface:[0-9]+ \[terminal\]" | head -1 | grep -oE "surface:[0-9]+"
}

agent_cmd() {  # $1=ws $2=target $3=cmd
  local sf; sf="$(term_surface "$1")"
  [[ -z "$sf" ]] && { echo "  ✗ no terminal surface in $1 ($2)"; return 1; }
  cmux send     --workspace "$1" --surface "$sf" "$3" >/dev/null 2>&1
  cmux send-key --workspace "$1" --surface "$sf" enter >/dev/null 2>&1
  echo "  ✓ $2  ($1/$sf)"
}

daemon_up() {
  rm -f "$ROOT/org/ceo/runs/STATUS_WATCH_STOP" "$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
  if ! pgrep -f workspace-status-watch >/dev/null 2>&1; then
    nohup bash "$ROOT/scripts/workspace-status-watch.sh" >/dev/null 2>&1 &
  fi
  echo "  ✓ roll-up daemon running"
  if ! pgrep -f wiki-watch >/dev/null 2>&1; then
    mkdir -p "$ROOT/logs"
    WORKSPACE_ROOT="$ROOT" nohup bash "$ROOT/scripts/wiki-watch.sh" >"$ROOT/logs/wiki-watch.log" 2>&1 &
    echo "  ✓ wiki-watch daemon started (initial build running in background)"
  else
    echo "  ✓ wiki-watch daemon already running"
  fi
}
daemon_down() {
  touch "$ROOT/org/ceo/runs/STATUS_WATCH_STOP" "$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
  pkill -f workspace-status-watch 2>/dev/null && echo "  ✓ roll-up daemon stopped" || echo "  (roll-up daemon was not running)"
  pkill -f wiki-watch 2>/dev/null && echo "  ✓ wiki-watch stopped" || echo "  (wiki-watch was not running)"
}

case "${1:-status}" in
  up)
    echo "Workstation UP:"
    for f in "${FLOORS[@]}"; do set -- $f; agent_cmd "$1" "$2" "bash $ROOT/scripts/cmux-floor.sh $2"; done
    daemon_up
    echo "Give agents ~8s to boot, then: workstation.sh status"
    ;;
  down)
    echo "Workstation DOWN:"
    for f in "${FLOORS[@]}"; do set -- $f; agent_cmd "$1" "$2" "/quit"; done
    daemon_down
    ;;
  status|*)
    echo "Workstation status:"
    for f in "${FLOORS[@]}"; do
      set -- $f; sf="$(term_surface "$1")"
      scr="$(cmux read-screen --workspace "$1" --surface "$sf" 2>/dev/null | tail -3)"
      if echo "$scr" | grep -q "Sonnet"; then echo "  ✓ $2 agent idle on Sonnet ($1/$sf)"
      else echo "  ? $2 not at omp prompt ($1/$sf)"; fi
    done
    if pgrep -f workspace-status-watch >/dev/null 2>&1; then
      age=$(( $(date +%s) - $(stat -f %m "$ROOT/org/ceo/WORKSPACE_STATUS.md" 2>/dev/null || echo 0) ))
      echo "  ✓ roll-up daemon running (status doc refreshed ${age}s ago)"
    else
      echo "  ✗ roll-up daemon DOWN  (start: workstation.sh up)"
    fi
    if pgrep -f wiki-watch >/dev/null 2>&1; then
      wiki_count=$(find "$ROOT/org/wiki/projects" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      echo "  ✓ wiki-watch running ($wiki_count project wikis indexed)"
    else
      echo "  ✗ wiki-watch DOWN  (start: workstation.sh up  or  WORKSPACE_ROOT=$ROOT bash scripts/wiki-watch.sh --rebuild-all)"
    fi
    ;;
esac
