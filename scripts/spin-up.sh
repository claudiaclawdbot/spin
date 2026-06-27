#!/usr/bin/env bash
# spin-up.sh — open the SPIN interface in cmux.
#
# Ensures: (1) the driver loop is running (background/supervised), (2) a
# "SPIN Coordinator" cmux floor — the omp agent you talk to — exists, and
# (3) the live status board + wiki daemons are running. Run it once; it's
# idempotent. This is the "launch the GUI" entry point.
set -uo pipefail
__src="${BASH_SOURCE[0]}"
while [ -h "$__src" ]; do __d="$(cd -P "$(dirname "$__src")" && pwd)"; __src="$(readlink "$__src")"; [ "${__src#/}" = "$__src" ] && __src="$__d/$__src"; done
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd -P "$(dirname "$__src")/.." && pwd)}}"
RUN="$ROOT/org/ceo/runs"; c_v=$'\e[35m'; c_g=$'\e[32m'; c_d=$'\e[2m'; c_o=$'\e[0m'
source "$ROOT/scripts/lib/spin-runtime.sh"
source "$ROOT/scripts/lib/cmux-floor-layout.sh"

spin_prepare_cmux_environment
spin_require_binary cmux "SPIN.app bundles it under Resources/bin/cmux, or install cmux for the development visual interface. Headless: spin start" || exit 1

echo "${c_v}Opening the SPIN interface…${c_o}"

start_daemon() {
  local label="$1" log="$2" script="$3"; shift 3
  mkdir -p "$(dirname "$log")"
  if [[ "$(uname -s)" == Darwin ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$label" >/dev/null 2>&1 || true
    launchctl submit -l "$label" -o "$log" -e "$log" -- \
      /usr/bin/env SPIN_ROOT="$ROOT" WORKSPACE_ROOT="$ROOT" HOME="$HOME" PATH="$PATH" \
      /bin/bash "$script" "$@" >/dev/null 2>&1 && return 0
  fi
  SPIN_ROOT="$ROOT" WORKSPACE_ROOT="$ROOT" nohup bash "$script" "$@" >"$log" 2>&1 &
  disown $! 2>/dev/null || true
}

# ── 1. cmux app/socket ───────────────────────────────────────────────────────
cmux_ready(){ CMUX_QUIET=1 spin_cmd cmux ping >/dev/null 2>&1; }
if cmux_ready; then
  echo "  ${c_g}✓${c_o} cmux already running"
else
  echo "  ${c_d}· starting cmux…${c_o}"
  if [[ "$(uname -s)" == Darwin ]]; then spin_open_cmux_app || true; fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do cmux_ready && break; sleep 1; done
  cmux_ready || { echo "  ${c_d}· cmux app is not reachable yet — open cmux, then rerun: spin up${c_o}"; exit 1; }
  echo "  ${c_g}✓${c_o} cmux running"
fi

# ── 2. driver ────────────────────────────────────────────────────────────────
lock="$RUN/.workspace-ceo-tick.lock"
if [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
  echo "  ${c_g}✓${c_o} driver already running"
else
  bash "$ROOT/scripts/spin" start >/dev/null 2>&1 && echo "  ${c_g}✓${c_o} driver started ${c_d}(tip: 'spin service install' keeps it up across reboots)${c_o}"
fi

# ── 3. SPIN orchestrator floor (the omp agent you talk to) ───────────────────
coord_ref="$(spin_cmux_ensure_coordinator_floor true 2>/dev/null || true)"
if [[ -n "$coord_ref" ]]; then
  echo "  ${c_g}✓${c_o} SPIN orchestrator floor open → $coord_ref ${c_d}(talk to it there)${c_o}"
else
  echo "  ${c_d}· couldn't open the SPIN orchestrator floor (is cmux running?)${c_o}"
fi

# ── 4. live boards ───────────────────────────────────────────────────────────
rm -f "$RUN/STATUS_WATCH_STOP" "$RUN/WIKI_WATCH_STOP" 2>/dev/null
if ! pgrep -f workspace-status-watch >/dev/null 2>&1; then
  start_daemon com.spin.status-watch "$ROOT/logs/status-watch.log" "$ROOT/scripts/workspace-status-watch.sh"
fi
echo "  ${c_g}✓${c_o} live status board running"
if ! pgrep -f wiki-watch >/dev/null 2>&1; then
  start_daemon com.spin.wiki-watch "$ROOT/logs/wiki-watch.log" "$ROOT/scripts/wiki-watch.sh"
  echo "  ${c_g}✓${c_o} wiki-watch daemon started"
else
  echo "  ${c_g}✓${c_o} wiki-watch daemon already running"
fi

# ── 5. re-open floors for active projects (after a cmux restart) ─────────────
spin_cmux_project_floor_ids | while read -r id; do
  [ -z "$id" ] && continue
  ref="$(spin_cmux_ensure_project_floor "$id" false 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    echo "  ${c_g}✓${c_o} project floor ready: $id → $ref"
    sf="$(spin_cmux_terminal_surface "$ref")"
    if spin_cmux_open_project_board "$ref" "$id" "$sf"; then
      echo "  ${c_g}✓${c_o} $id board visible"
    fi
  else
    echo "  ${c_d}· couldn't open project floor: $id${c_o}"
  fi
done

echo
echo "${c_v}SPIN is up.${c_o} Your cmux window is the interface — talk to the Coordinator floor,"
echo "and each project is a tab in the sidebar. New project any time:  ${c_d}spin new-project <id> \"<goal>\"${c_o}"
