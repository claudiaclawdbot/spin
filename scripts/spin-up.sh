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

mkdir -p "$RUN"
STARTUP_LOCK="$RUN/.spin-up.lock"
if spin_lock_acquire "$STARTUP_LOCK" "spin-up.sh"; then
  STARTUP_LOCK_TOKEN="$SPIN_LOCK_OWNER_TOKEN"
else
  lock_rc=$?
  if (( lock_rc == 1 )); then
    echo "SPIN interface startup is already in progress."
    exit 0
  fi
  echo "Could not acquire the SPIN interface startup lock." >&2
  exit 1
fi
trap 'spin_lock_release "$STARTUP_LOCK" "$STARTUP_LOCK_TOKEN" >/dev/null 2>&1 || true' EXIT

spin_prepare_cmux_environment
spin_require_binary cmux "SPIN.app bundles it under Resources/bin/cmux, or install cmux for the development visual interface. Headless: spin start" || exit 1

if command -v node >/dev/null 2>&1; then
  bridge_status="$(node "$ROOT/scripts/omp-mcp-bootstrap.js" repair --json 2>/dev/null || true)"
  bridge_state="$(printf '%s' "$bridge_status" | node -e '
let raw=""; process.stdin.on("data", c => raw += c); process.stdin.on("end", () => {
  try { process.stdout.write(JSON.parse(raw).status || "error"); } catch { process.stdout.write("error"); }
});
' 2>/dev/null)"
  case "$bridge_state" in
    configured) echo "  ${c_g}✓${c_o} Codex Computer Use lane configured ${c_d}(probe: spin computer-use probe)${c_o}" ;;
    custom) echo "  ${c_g}✓${c_o} custom OMP computer-use bridge configured" ;;
    custom-disabled) echo "  ${c_d}· custom OMP computer-use bridge disabled${c_o}" ;;
    unavailable) echo "  ${c_d}· optional Codex Computer Use lane not installed${c_o}" ;;
    *)           echo "  ${c_d}· Computer Use routing needs attention ${c_o}(run: spin doctor)" ;;
  esac
fi

echo "${c_v}Opening the SPIN interface…${c_o}"

seed_spin_navigator_sidebar() {
  local source="$ROOT/app/cmux/sidebars/spin-navigator.swift"
  local target_dir="$HOME/.config/cmux/sidebars"
  local target="$target_dir/spin-navigator.swift"
  [ -f "$source" ] || return 0
  mkdir -p "$target_dir"
  if [ ! -s "$target" ] || grep -Fq 'Text("SPIN")' "$target" 2>/dev/null; then
    cp "$source" "$target"
    chmod 600 "$target" 2>/dev/null || true
  fi

  if [[ "$(uname -s)" == Darwin ]] && [ -x /usr/libexec/PlistBuddy ]; then
    local domain plist prefs_dir
    for domain in dev.spin.app com.cmuxterm.app; do
      prefs_dir="$HOME/Library/Preferences"
      plist="$prefs_dir/$domain.plist"
      mkdir -p "$prefs_dir"
      if [ ! -f "$plist" ]; then
        cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
      fi
      /usr/libexec/PlistBuddy -c "Delete :customSidebars.beta.enabled" "$plist" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :customSidebars.beta.enabled bool true" "$plist" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Delete :cmuxExtensionSidebar.providerId" "$plist" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :cmuxExtensionSidebar.providerId string cmux.sidebar.custom.spin-navigator" "$plist" >/dev/null 2>&1 || true
      chmod 600 "$plist" 2>/dev/null || true
      if command -v defaults >/dev/null 2>&1; then
        defaults write "$domain" customSidebars.beta.enabled -bool true >/dev/null 2>&1 || true
        defaults write "$domain" cmuxExtensionSidebar.providerId "cmux.sidebar.custom.spin-navigator" >/dev/null 2>&1 || true
      fi
    done
  fi
}

select_spin_navigator_sidebar() {
  spin_cmd cmux sidebar validate spin-navigator >/dev/null 2>&1 || true
  spin_cmd cmux sidebar select spin-navigator >/dev/null 2>&1
}

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

seed_spin_navigator_sidebar

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
if select_spin_navigator_sidebar; then
  echo "  ${c_g}✓${c_o} SPIN Navigator rail selected"
else
  echo "  ${c_d}· SPIN Navigator rail not selectable yet; right-click the sidebar switcher and choose spin-navigator${c_o}"
fi

# ── 2. driver ────────────────────────────────────────────────────────────────
lock="$RUN/.workspace-ceo-tick.lock"
if [[ "${SPIN_DISABLE_BACKGROUND_DAEMONS:-0}" == "1" ]]; then
  echo "  ${c_d}· background driver disabled for this run${c_o}"
elif [[ -f "$RUN/STOP" ]]; then
  echo "  ${c_d}· driver intentionally paused ${c_o}(resume: spin start)"
elif bash "$ROOT/scripts/spin-service.sh" installed >/dev/null 2>&1 \
  && ! bash "$ROOT/scripts/spin-service.sh" status >/dev/null 2>&1; then
  echo "  ${c_d}· repairing partial SPIN service installation…${c_o}"
  if bash "$ROOT/scripts/spin-service.sh" repair >/dev/null 2>&1; then
    echo "  ${c_g}✓${c_o} driver and live-state services supervised"
  else
    echo "  ${c_d}· service repair failed; continuing with foreground-compatible startup${c_o}"
  fi
elif spin_locked_process_running "$lock" "$ROOT/scripts/workspace-ceo-tick.sh"; then
  echo "  ${c_g}✓${c_o} driver already running"
else
  bash "$ROOT/scripts/spin" start >/dev/null 2>&1 && echo "  ${c_g}✓${c_o} driver started ${c_d}(tip: 'spin service install' keeps it up across reboots)${c_o}"
fi

# ── 3. SPIN orchestrator floor (the omp agent you talk to) ───────────────────
startup_failures=0
coord_ref="$(spin_cmux_ensure_coordinator_floor true 2>/dev/null || true)"
if [[ -n "$coord_ref" ]] && spin_cmux_wait_for_floor_active "$coord_ref" ceo; then
  echo "  ${c_g}✓${c_o} SPIN orchestrator floor open → $coord_ref ${c_d}(talk to it there)${c_o}"
elif [[ -n "$coord_ref" ]]; then
  echo "  ${c_d}· SPIN orchestrator floor did not reach a live OMP prompt → $coord_ref${c_o}"
  startup_failures=$((startup_failures + 1))
else
  echo "  ${c_d}· couldn't open the SPIN orchestrator floor (is cmux running?)${c_o}"
  startup_failures=$((startup_failures + 1))
fi

# ── 4. live boards ───────────────────────────────────────────────────────────
rm -f "$RUN/STATUS_WATCH_STOP" "$RUN/WIKI_WATCH_STOP" 2>/dev/null
bash "$ROOT/scripts/workspace-status.sh" >/dev/null 2>&1 || true
if [[ -n "$coord_ref" ]] && spin_cmux_open_coordinator_board "$coord_ref"; then
  echo "  ${c_g}✓${c_o} Coordinator board visible"
elif [[ -n "$coord_ref" ]]; then
  echo "  ${c_d}· couldn't open the Coordinator board${c_o}"
  startup_failures=$((startup_failures + 1))
fi
# ── 5. re-open floors for active projects (after a cmux restart) ─────────────
while IFS= read -r id; do
  [ -z "$id" ] && continue
  ref="$(spin_cmux_ensure_project_floor "$id" false 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    if spin_cmux_wait_for_floor_active "$ref" "$id"; then
      echo "  ${c_g}✓${c_o} project floor ready: $id → $ref"
    else
      echo "  ${c_d}· project floor did not reach a live OMP prompt: $id → $ref${c_o}"
      startup_failures=$((startup_failures + 1))
    fi
    sf="$(spin_cmux_terminal_surface "$ref")"
    if spin_cmux_open_project_board "$ref" "$id" "$sf"; then
      echo "  ${c_g}✓${c_o} $id board visible"
    else
      echo "  ${c_d}· couldn't open project board: $id${c_o}"
      startup_failures=$((startup_failures + 1))
    fi
  else
    echo "  ${c_d}· couldn't open project floor: $id${c_o}"
    startup_failures=$((startup_failures + 1))
  fi
done < <(spin_cmux_project_floor_ids)

floor_tty_collisions="$(spin_cmux_duplicate_managed_floor_ttys 2>/dev/null || true)"
if [[ -n "$floor_tty_collisions" ]]; then
  echo "  ${c_d}· managed floors still share terminal sessions: $(printf '%s' "$floor_tty_collisions" | tr '\n' ';')${c_o}"
  startup_failures=$((startup_failures + 1))
fi

pruned_refs="$(spin_cmux_prune_stale_managed_workspaces 2>/dev/null || true)"
if [[ -n "$pruned_refs" ]]; then
  echo "  ${c_g}✓${c_o} removed stale duplicate floors: $(printf '%s' "$pruned_refs" | paste -sd, -)"
fi

# Start reconcilers only after the initial floor layout is complete. Otherwise
# their first pass can race session restoration and queue duplicate cmux work.
if [[ "${SPIN_DISABLE_BACKGROUND_DAEMONS:-0}" == "1" ]]; then
  echo "  ${c_d}· background board daemons disabled for this run${c_o}"
else
  if ! spin_locked_process_running "$RUN/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"; then
    start_daemon com.spin.status-watch "$ROOT/logs/status-watch.log" "$ROOT/scripts/workspace-status-watch.sh"
  fi
  echo "  ${c_g}✓${c_o} live status board running"
  if ! spin_locked_process_running "$RUN/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"; then
    start_daemon com.spin.wiki-watch "$ROOT/logs/wiki-watch.log" "$ROOT/scripts/wiki-watch.sh"
    echo "  ${c_g}✓${c_o} wiki-watch daemon started"
  else
    echo "  ${c_g}✓${c_o} wiki-watch daemon already running"
  fi
fi

if (( startup_failures > 0 )); then
  echo
  echo "${c_d}SPIN startup incomplete: $startup_failures required floor or board operation(s) failed.${c_o}"
  echo "Rerun: spin up"
  exit 1
fi

echo
echo "${c_v}SPIN is up.${c_o} Your cmux window is the interface — talk to the Coordinator floor,"
echo "and each project is a tab in the sidebar. New project any time:  ${c_d}spin new-project <id> \"<goal>\"${c_o}"
