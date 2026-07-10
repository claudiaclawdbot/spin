#!/usr/bin/env bash
# workstation.sh — bring the omp+cmux workstation up/down, or health-check it.
#   workstation.sh up      # (re)launch each floor's omp agent + the roll-up daemon
#   workstation.sh down    # quit agents + stop daemon
#   workstation.sh status  # health check (default)
#
# NOTE: run with bash (shebang) — relies on word-splitting that zsh disables.
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
OS="$(uname -s)"
source "$ROOT/scripts/lib/spin-runtime.sh"
source "$ROOT/scripts/lib/cmux-floor-layout.sh"

FLOORS=()
MISSING_FLOORS=()
MISSING_FLOOR_COUNT=0
ceo_ref="$(spin_cmux_saved_workspace_ref ceo 2>/dev/null || true)"
if [[ -n "$ceo_ref" ]] && spin_cmux_workspace_context_matches "$ceo_ref" "SPIN Coordinator"; then
  FLOORS+=("$ceo_ref ceo")
else
  MISSING_FLOORS+=("ceo")
  MISSING_FLOOR_COUNT=$((MISSING_FLOOR_COUNT + 1))
fi
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  ref="$(spin_cmux_saved_workspace_ref "$id" 2>/dev/null || true)"
  cwd="$(spin_cmux_project_cwd "$id")"
  if [[ -n "$ref" ]] && spin_cmux_workspace_context_matches "$ref" "$id" "$cwd"; then
    FLOORS+=("$ref $id")
  else
    MISSING_FLOORS+=("$id")
    MISSING_FLOOR_COUNT=$((MISSING_FLOOR_COUNT + 1))
  fi
done < <(spin_cmux_project_floor_ids)

term_surface() {  # first terminal surface in a workspace (robust to ID drift)
  spin_cmd cmux tree --workspace "$1" 2>/dev/null | awk '
    /surface:[0-9]+/ && /\[terminal\]/ {
      match($0, /surface:[0-9]+/)
      ref=substr($0, RSTART, RLENGTH)
      if ($0 ~ /\[selected\]/) { print ref; found=1; exit }
      if (!first) first=ref
    }
    END { if (!found && first) print first }
  '
}

surface_tty() {
  local ws="$1" sf="$2"
  spin_cmd cmux tree --workspace "$ws" 2>/dev/null | awk -v sf="$sf" '
    index($0, sf) && /tty=/ {
      match($0, /tty=[^[:space:]]+/)
      if (RSTART) { print substr($0, RSTART + 4, RLENGTH - 4); exit }
    }
  '
}

agent_floor_active() {
  local ws="$1" sf="$2" target="${3:-}"
  [[ -n "$target" ]] || return 1
  spin_cmux_floor_active_in_workspace "$ws" "$target"
}

agent_cmd() {  # $1=ws $2=target $3=cmd
  local sf; sf="$(term_surface "$1")"
  [[ -z "$sf" ]] && { echo "  ✗ no terminal surface in $1 ($2)"; return 1; }
  spin_cmd cmux send     --workspace "$1" --surface "$sf" "$3" >/dev/null 2>&1
  spin_cmd cmux send-key --workspace "$1" --surface "$sf" enter >/dev/null 2>&1
  echo "  ✓ $2  ($1/$sf)"
}

start_daemon() {
  local label="$1" log="$2" script="$3"; shift 3
  mkdir -p "$(dirname "$log")"
  if [[ "$OS" == Darwin ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$label" >/dev/null 2>&1 || true
    launchctl submit -l "$label" -o "$log" -e "$log" -- \
      /usr/bin/env SPIN_ROOT="$ROOT" WORKSPACE_ROOT="$ROOT" HOME="$HOME" PATH="$PATH" \
      /bin/bash "$script" "$@" >/dev/null 2>&1 && return 0
  fi
  SPIN_ROOT="$ROOT" WORKSPACE_ROOT="$ROOT" nohup bash "$script" "$@" >"$log" 2>&1 &
  disown $! 2>/dev/null || true
}

daemon_up() {
  rm -f "$ROOT/org/ceo/runs/STATUS_WATCH_STOP" "$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
  if ! spin_locked_process_running "$ROOT/org/ceo/runs/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"; then
    start_daemon com.spin.status-watch "$ROOT/logs/status-watch.log" "$ROOT/scripts/workspace-status-watch.sh"
  fi
  echo "  ✓ roll-up daemon running"
  if ! spin_locked_process_running "$ROOT/org/ceo/runs/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"; then
    start_daemon com.spin.wiki-watch "$ROOT/logs/wiki-watch.log" "$ROOT/scripts/wiki-watch.sh"
    echo "  ✓ wiki-watch daemon started (initial build running in background)"
  else
    echo "  ✓ wiki-watch daemon already running"
  fi
}
daemon_down() {
  touch "$ROOT/org/ceo/runs/STATUS_WATCH_STOP" "$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
  if [[ "$OS" == Darwin ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl remove com.spin.status-watch >/dev/null 2>&1 || true
    launchctl remove com.spin.wiki-watch >/dev/null 2>&1 || true
  fi
  spin_stop_locked_process "$ROOT/org/ceo/runs/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"
  spin_stop_locked_process "$ROOT/org/ceo/runs/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"
  echo "  ✓ root-scoped board daemons stopped"
}

case "${1:-status}" in
  up)
    echo "Workstation UP:"
    for id in "${MISSING_FLOORS[@]+"${MISSING_FLOORS[@]}"}"; do
      echo "  ✗ missing canonical floor: $id (run: spin up)"
    done
    for f in "${FLOORS[@]+"${FLOORS[@]}"}"; do
      set -- $f
      agent_cmd "$1" "$2" "bash $ROOT/scripts/cmux-floor.sh $2"
      if [[ "$2" != "ceo" ]]; then
        sf="$(term_surface "$1")"
        spin_cmux_open_project_board "$1" "$2" "$sf" >/dev/null 2>&1 && echo "  ✓ $2 board visible"
      fi
    done
    daemon_up
    echo "Give agents ~8s to boot, then: workstation.sh status"
    (( MISSING_FLOOR_COUNT == 0 ))
    ;;
  down)
    echo "Workstation DOWN:"
    for f in "${FLOORS[@]+"${FLOORS[@]}"}"; do set -- $f; agent_cmd "$1" "$2" "/quit"; done
    daemon_down
    ;;
  status|*)
    echo "Workstation status:"
    health_failures=0
    for id in "${MISSING_FLOORS[@]+"${MISSING_FLOORS[@]}"}"; do
      echo "  ✗ missing canonical floor: $id (run: spin up)"
      health_failures=$((health_failures + 1))
    done
    for f in "${FLOORS[@]+"${FLOORS[@]}"}"; do
      set -- $f; sf="$(term_surface "$1")"
      if [[ -n "$sf" ]] && agent_floor_active "$1" "$sf" "$2"; then echo "  ✓ $2 agent floor active ($1/$sf)"
      else
        echo "  ✗ $2 not at omp prompt ($1/$sf)"
        health_failures=$((health_failures + 1))
      fi
    done
    stale_refs="$(spin_cmux_stale_managed_workspace_refs 2>/dev/null || true)"
    if [[ -n "$stale_refs" ]]; then
      echo "  ✗ stale duplicate managed floors: $(printf '%s' "$stale_refs" | paste -sd, -)"
      health_failures=$((health_failures + 1))
    else
      echo "  ✓ no stale duplicate managed floors"
    fi
    ceo_ref="$(spin_cmux_saved_workspace_ref ceo 2>/dev/null || true)"
    if [[ -n "$ceo_ref" ]] && spin_cmux_coordinator_board_visible "$ceo_ref"; then
      echo "  ✓ Coordinator portfolio board visible ($ceo_ref)"
    else
      echo "  ✗ Coordinator portfolio board missing or stale (${ceo_ref:-no workspace})"
      health_failures=$((health_failures + 1))
    fi
    if spin_locked_process_running "$ROOT/org/ceo/runs/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"; then
      age=$(( $(date +%s) - $(stat -f %m "$ROOT/org/ceo/WORKSPACE_STATUS.md" 2>/dev/null || echo 0) ))
      if (( age <= 60 )); then
        echo "  ✓ roll-up daemon running (status doc refreshed ${age}s ago)"
      else
        echo "  ✗ roll-up daemon is stale (status doc refreshed ${age}s ago)"
        health_failures=$((health_failures + 1))
      fi
    else
      echo "  ✗ roll-up daemon DOWN  (start: workstation.sh up)"
      health_failures=$((health_failures + 1))
    fi
    if spin_locked_process_running "$ROOT/org/ceo/runs/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"; then
      wiki_count=$(find "$ROOT/org/wiki/projects" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      missing_wikis="$(while IFS= read -r id; do
        [[ -s "$ROOT/org/wiki/projects/$id.md" ]] || printf '%s\n' "$id"
      done < <(spin_cmux_project_floor_ids))"
      if [[ -n "$missing_wikis" ]]; then
        echo "  ✗ wiki-watch running but active indexes are missing: $(printf '%s' "$missing_wikis" | paste -sd, -)"
        health_failures=$((health_failures + 1))
      else
        echo "  ✓ wiki-watch running ($wiki_count project wikis indexed)"
      fi
    else
      echo "  ✗ wiki-watch DOWN  (start: workstation.sh up  or  WORKSPACE_ROOT=$ROOT bash scripts/wiki-watch.sh --rebuild-all)"
      health_failures=$((health_failures + 1))
    fi
    (( health_failures == 0 ))
    ;;
esac
