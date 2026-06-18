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

# ── 1. driver ────────────────────────────────────────────────────────────────
lock="$RUN/.workspace-ceo-tick.lock"
if [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
  echo "  ${c_g}✓${c_o} driver already running"
else
  bash "$ROOT/scripts/spin" start >/dev/null 2>&1 && echo "  ${c_g}✓${c_o} driver started ${c_d}(tip: 'spin service install' keeps it up across reboots)${c_o}"
fi

# ── 2. Coordinator floor (the omp agent you talk to) ─────────────────────────
if CMUX_QUIET=1 cmux list-workspaces 2>/dev/null | grep -qi "SPIN Coordinator"; then
  echo "  ${c_g}✓${c_o} Coordinator floor already open"
else
  ref="$(CMUX_QUIET=1 cmux workspace create --name "SPIN Coordinator" --cwd "$HOME" \
        --command "bash '$ROOT/scripts/cmux-floor.sh' ceo" --focus true 2>/dev/null \
        | grep -oE 'workspace:[0-9]+' | head -1)"
  [ -n "$ref" ] && echo "  ${c_g}✓${c_o} Coordinator floor open → $ref ${c_d}(talk to it there)${c_o}" \
                || echo "  ${c_d}· couldn't open the Coordinator floor (is cmux running?)${c_o}"
fi

# ── 3. live boards ───────────────────────────────────────────────────────────
rm -f "$RUN/STATUS_WATCH_STOP" "$RUN/WIKI_WATCH_STOP" 2>/dev/null
pgrep -f workspace-status-watch >/dev/null 2>&1 || nohup bash "$ROOT/scripts/workspace-status-watch.sh" >/dev/null 2>&1 &
echo "  ${c_g}✓${c_o} live status board running"

# ── 4. re-open floors for active projects (after a cmux restart) ─────────────
node -e '
  const fs=require("fs"),f=process.argv[1];try{const h=JSON.parse(fs.readFileSync(f,"utf8"));
  for(const[id,p]of Object.entries(h.projects||{}))if(p.cmux_workspace)console.log(id);}catch{}
' "$ROOT/org/OMP_HARNESS.json" 2>/dev/null | while read -r id; do
  [ -z "$id" ] && continue
  CMUX_QUIET=1 cmux list-workspaces 2>/dev/null | grep -qi "\b$id\b" && continue
  CMUX_QUIET=1 cmux workspace create --name "$id" --cwd "$ROOT/projects/$id" \
    --command "bash '$ROOT/scripts/cmux-floor.sh' '$id'" --focus false >/dev/null 2>&1 \
    && echo "  ${c_g}✓${c_o} re-opened floor: $id"
done

echo
echo "${c_v}SPIN is up.${c_o} Your cmux window is the interface — talk to the Coordinator floor,"
echo "and each project is a tab in the sidebar. New project any time:  ${c_d}spin new-project <id> \"<goal>\"${c_o}"
