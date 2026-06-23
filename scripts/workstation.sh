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

# floor map: "<workspace-ref> <floor-target>", derived from org/OMP_HARNESS.json —
# the registry is the single source of truth (this list drifted when hardcoded).
# Candidate projects (status candidate*) don't get floors until activated.
FLOORS=()
while IFS= read -r line; do [[ -n "$line" ]] && FLOORS+=("$line"); done < <(node -e '
const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (h.workspace_ceo?.cmux_workspace) console.log(h.workspace_ceo.cmux_workspace + " ceo");
for (const [id, p] of Object.entries(h.projects || {}))
  if (p.cmux_workspace && !String(p.status || "").startsWith("candidate"))
    console.log(p.cmux_workspace + " " + id);
' "$ROOT/org/OMP_HARNESS.json" 2>/dev/null)
[[ ${#FLOORS[@]} -eq 0 ]] && { echo "no floors found in org/OMP_HARNESS.json" >&2; exit 1; }

term_surface() {  # first terminal surface in a workspace (robust to ID drift)
  cmux tree --workspace "$1" 2>/dev/null | awk '
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
  cmux tree --workspace "$ws" 2>/dev/null | awk -v sf="$sf" '
    index($0, sf) && /tty=/ {
      match($0, /tty=[^[:space:]]+/)
      if (RSTART) { print substr($0, RSTART + 4, RLENGTH - 4); exit }
    }
  '
}

agent_floor_active() {
  local ws="$1" sf="$2" tty
  tty="$(surface_tty "$ws" "$sf")"
  [[ -n "$tty" ]] || return 1
  ps -t "$tty" -o command= 2>/dev/null | grep -q '[o]mp --model'
}

agent_cmd() {  # $1=ws $2=target $3=cmd
  local sf; sf="$(term_surface "$1")"
  [[ -z "$sf" ]] && { echo "  ✗ no terminal surface in $1 ($2)"; return 1; }
  cmux send     --workspace "$1" --surface "$sf" "$3" >/dev/null 2>&1
  cmux send-key --workspace "$1" --surface "$sf" enter >/dev/null 2>&1
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
  if ! pgrep -f workspace-status-watch >/dev/null 2>&1; then
    start_daemon com.spin.status-watch "$ROOT/logs/status-watch.log" "$ROOT/scripts/workspace-status-watch.sh"
  fi
  echo "  ✓ roll-up daemon running"
  if ! pgrep -f wiki-watch >/dev/null 2>&1; then
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
      if [[ -n "$sf" ]] && agent_floor_active "$1" "$sf"; then echo "  ✓ $2 agent floor active ($1/$sf)"
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
