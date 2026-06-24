#!/usr/bin/env bash
# spin-init.sh — first-run onboarding wizard. Turns "clone → read docs → edit 3
# files" into "answer a few prompts → you're running". Idempotent + re-runnable.
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
cd "$ROOT"
ORG="$ROOT/org"; HARNESS="$ORG/OMP_HARNESS.json"
source "$ROOT/scripts/lib/spin-runtime.sh"
c_v=$'\e[35m'; c_g=$'\e[32m'; c_c=$'\e[36m'; c_d=$'\e[2m'; c_b=$'\e[1m'; c_o=$'\e[0m'

# Read from the terminal even if stdin is redirected; bail if there's no usable TTY
# (so it can never hang in a pipe/CI). Test openability, not just existence.
TTY=/dev/tty; ( : <"$TTY" ) 2>/dev/null || { echo "spin init needs an interactive terminal — run it directly: spin init"; exit 1; }
ask(){ local p="$1" d="${2:-}" v; printf '%s' "$p" >"$TTY"; read -r v <"$TTY" || true; echo "${v:-$d}"; }
yes(){ local a; a="$(ask "$1 ${c_d}[y/N]${c_o} " n)"; [[ "$a" =~ ^[Yy] ]]; }

printf '%s\n' "${c_v}"'   ___ ___ ___ _  _' '  / __| _ \_ _| \| |   SPIN onboarding' '  \__ \  _/| || .` |' "  |___/_| |___|_|\\_|${c_o}"
echo

# ── 1. app/runtime health ────────────────────────────────────────────────────
echo "${c_b}1. App health${c_o} ${c_d}(SPIN-owned runtime checks)${c_o}"
node "$ROOT/scripts/spin-app-health.js" 2>/dev/null | sed 's/^/   /' || true
echo

# ── 2. OMP setup handoff ─────────────────────────────────────────────────────
# OMP owns model/provider onboarding. SPIN only verifies the bundled runtime and
# launches OMP's own setup wizard when the user wants to configure accounts.
echo "${c_b}2. OMP setup${c_o} ${c_d}(model/provider setup stays inside OMP)${c_o}"
if spin_have_binary omp; then
  OMP_BIN="$(spin_resolve_binary omp)"
  echo "   ${c_g}✓${c_o} bundled OMP ready: $OMP_BIN"
  echo "   ${c_d}SPIN will not ask for provider keys here. Use OMP's setup wizard for accounts, OAuth, and model/provider choices.${c_o}"
  echo "   ${c_d}SPIN still writes a small runtime overlay for model roles and fallback chains; secrets stay in OMP auth storage or your environment.${c_o}"
  if yes "   Run OMP setup now?"; then
    "$OMP_BIN" setup
  else
    echo "   ${c_d}Skipped. Run it later with: spin omp-setup${c_o}"
  fi
else
  echo "   ${c_d}OMP not found. SPIN.app should bundle it; developer checkouts can run scripts/vendor-app-deps.sh --omp-only.${c_o}"
  yes "   Install developer dependencies now?" && bash "$ROOT/scripts/install-deps.sh"
fi
echo

# ── 3. first project ─────────────────────────────────────────────────────────
echo "${c_b}3. Your first project${c_o}"
pid="$(ask "   Project id ${c_d}(lowercase-with-dashes, e.g. my-app)${c_o}: ")"
if [ -z "$pid" ]; then
  echo "   ${c_d}(skipped — add one later with: spin new-project <id> \"<goal>\")${c_o}"
else
  goal="$(ask "   One-line goal: ")"
  # spin-new-project registers it AND opens a cmux floor (a tab in your sidebar)
  bash "$ROOT/scripts/spin-new-project.sh" "$pid" "$goal" 2>&1 | sed 's/^/   /'
fi
echo

# ── 4. durability + start ────────────────────────────────────────────────────
echo "${c_b}4. Run it${c_o}"
if yes "   Install the supervisor so the driver stays up (recommended)?"; then
  bash "$ROOT/scripts/spin-service.sh" install
elif yes "   Start the driver loop now?"; then
  bash "$ROOT/scripts/spin" start
fi
echo
{
  echo "initialized_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -f "$ROOT/VERSION" ]] && echo "version=$(tr -d '[:space:]' < "$ROOT/VERSION")"
} > "$ORG/.spin-onboarded"
echo "${c_c}Done. Talk to it any time:${c_o}  spin   ·   spin chat   ·   spin approve \"...\""
