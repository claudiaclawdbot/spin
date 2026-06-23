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

command -v cmux >/dev/null 2>&1 || { echo "cmux not found — install it (https://github.com/manaflow-ai/cmux) for the visual interface, or run headless with: spin start"; exit 1; }

echo "${c_v}Opening the SPIN interface…${c_o}"

workspace_ref_by_name() {
  local name="$1"
  CMUX_QUIET=1 cmux list-workspaces 2>/dev/null | awk -v want="$name" '
    {
      line=$0
      sub(/^[*[:space:]]+/, "", line)
      if (line !~ /^workspace:[0-9]+[[:space:]]+/) next
      ref=line
      sub(/[[:space:]].*$/, "", ref)
      label=line
      sub(/^workspace:[0-9]+[[:space:]]+/, "", label)
      sub(/[[:space:]]+\[selected\]$/, "", label)
      if (label == want) { print ref; exit }
    }
  '
}

term_surface() {
  CMUX_QUIET=1 cmux tree --workspace "$1" 2>/dev/null | awk '
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
  local ref="$1" sf="$2"
  CMUX_QUIET=1 cmux tree --workspace "$ref" 2>/dev/null | awk -v sf="$sf" '
    index($0, sf) && /tty=/ {
      match($0, /tty=[^[:space:]]+/)
      if (RSTART) { print substr($0, RSTART + 4, RLENGTH - 4); exit }
    }
  '
}

floor_running() {
  local ref="$1" sf="$2" tty
  tty="$(surface_tty "$ref" "$sf")"
  [[ -n "$tty" ]] || return 1
  ps -t "$tty" -o command= 2>/dev/null | grep -q '[o]mp --model'
}

start_floor_if_needed() {
  local ref="$1" target="$2" label="$3"
  local sf; sf="$(term_surface "$ref")"
  [[ -z "$sf" ]] && { echo "  ${c_d}· no terminal surface found for $label ($ref)${c_o}"; return 0; }
  if floor_running "$ref" "$sf"; then
    echo "  ${c_g}✓${c_o} $label floor running"
    return 0
  fi
  CMUX_QUIET=1 cmux send --workspace "$ref" --surface "$sf" "bash '$ROOT/scripts/cmux-floor.sh' '$target'" >/dev/null 2>&1
  CMUX_QUIET=1 cmux send-key --workspace "$ref" --surface "$sf" enter >/dev/null 2>&1
  echo "  ${c_g}✓${c_o} $label floor started"
}

remember_ceo_ref() {
  node -e 'const fs=require("fs"),[f,ref]=process.argv.slice(1);const h=JSON.parse(fs.readFileSync(f,"utf8"));h.workspace_ceo=h.workspace_ceo||{};h.workspace_ceo.cmux_workspace=ref;fs.writeFileSync(f,JSON.stringify(h,null,2)+"\n");' "$ROOT/org/OMP_HARNESS.json" "$1" 2>/dev/null || true
}

remember_project_ref() {
  node -e 'const fs=require("fs"),[f,id,ref]=process.argv.slice(1);const h=JSON.parse(fs.readFileSync(f,"utf8"));h.projects=h.projects||{};h.projects[id]=h.projects[id]||{};h.projects[id].cmux_workspace=ref;fs.writeFileSync(f,JSON.stringify(h,null,2)+"\n");' "$ROOT/org/OMP_HARNESS.json" "$1" "$2" 2>/dev/null || true
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

# ── 1. cmux app/socket ───────────────────────────────────────────────────────
cmux_ready(){ CMUX_QUIET=1 cmux ping >/dev/null 2>&1; }
if cmux_ready; then
  echo "  ${c_g}✓${c_o} cmux already running"
else
  echo "  ${c_d}· starting cmux…${c_o}"
  if [[ "$(uname -s)" == Darwin ]]; then open -a cmux >/dev/null 2>&1 || true; fi
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

# ── 3. Coordinator floor (the omp agent you talk to) ─────────────────────────
coord_ref="$(workspace_ref_by_name "SPIN Coordinator")"
if [[ -n "$coord_ref" ]]; then
  echo "  ${c_g}✓${c_o} Coordinator floor already open"
  remember_ceo_ref "$coord_ref"
  start_floor_if_needed "$coord_ref" ceo Coordinator
else
  ref="$(CMUX_QUIET=1 cmux new-workspace --name "SPIN Coordinator" --cwd "$HOME" \
        --command "bash '$ROOT/scripts/cmux-floor.sh' ceo" --focus true 2>/dev/null \
        | grep -oE 'workspace:[0-9]+' | head -1)"
  if [[ -n "$ref" ]]; then
    remember_ceo_ref "$ref"
    echo "  ${c_g}✓${c_o} Coordinator floor open → $ref ${c_d}(talk to it there)${c_o}"
  else
    echo "  ${c_d}· couldn't open the Coordinator floor (is cmux running?)${c_o}"
  fi
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
node -e '
  const fs=require("fs"), [hf,sf]=process.argv.slice(1);
  const ids=new Set();
  try {
    const s=JSON.parse(fs.readFileSync(sf,"utf8"));
    for (const p of s.project_orchestrators || [])
      if (String(p.status || "").startsWith("active")) ids.add(p.project || p.id);
  } catch {}
  try {
    const h=JSON.parse(fs.readFileSync(hf,"utf8"));
    for (const [id,p] of Object.entries(h.projects || {}))
      if (p.cmux_workspace) ids.add(id);
  } catch {}
  for (const id of ids) if (id) console.log(id);
' "$ROOT/org/OMP_HARNESS.json" "$ROOT/org/state.json" 2>/dev/null | while read -r id; do
  [ -z "$id" ] && continue
  ref="$(workspace_ref_by_name "$id")"
  if [[ -z "$ref" ]]; then
    cwd="$ROOT/projects/$id"; [[ -d "$cwd" ]] || cwd="$ROOT/org/projects/$id"
    ref="$(CMUX_QUIET=1 cmux new-workspace --name "$id" --cwd "$cwd" \
      --command "bash '$ROOT/scripts/cmux-floor.sh' '$id'" --focus false 2>/dev/null \
      | grep -oE 'workspace:[0-9]+' | head -1)"
    [[ -n "$ref" ]] && echo "  ${c_g}✓${c_o} re-opened floor: $id"
  fi
  if [[ -n "$ref" ]]; then
    remember_project_ref "$id" "$ref"
    start_floor_if_needed "$ref" "$id" "$id"
  fi
done

echo
echo "${c_v}SPIN is up.${c_o} Your cmux window is the interface — talk to the Coordinator floor,"
echo "and each project is a tab in the sidebar. New project any time:  ${c_d}spin new-project <id> \"<goal>\"${c_o}"
