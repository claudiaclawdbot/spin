#!/usr/bin/env bash
# spin-init.sh — first-run onboarding wizard. Turns "clone → read docs → edit 3
# files" into "answer a few prompts → you're running". Idempotent + re-runnable.
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
cd "$ROOT"
ORG="$ROOT/org"; HARNESS="$ORG/OMP_HARNESS.json"
c_v=$'\e[35m'; c_g=$'\e[32m'; c_c=$'\e[36m'; c_d=$'\e[2m'; c_b=$'\e[1m'; c_o=$'\e[0m'

# Read from the terminal even if stdin is redirected; bail if there's no usable TTY
# (so it can never hang in a pipe/CI). Test openability, not just existence.
TTY=/dev/tty; ( : <"$TTY" ) 2>/dev/null || { echo "spin init needs an interactive terminal — run it directly: spin init"; exit 1; }
ask(){ local p="$1" d="${2:-}" v; printf '%s' "$p" >"$TTY"; read -r v <"$TTY" || true; echo "${v:-$d}"; }
yes(){ local a; a="$(ask "$1 ${c_d}[y/N]${c_o} " n)"; [[ "$a" =~ ^[Yy] ]]; }

printf '%s\n' "${c_v}"'   ___ ___ ___ _  _' '  / __| _ \_ _| \| |   SPIN onboarding' '  \__ \  _/| || .` |' "  |___/_| |___|_|\\_|${c_o}"
echo

# ── 1. providers ─────────────────────────────────────────────────────────────
echo "${c_b}1. Providers${c_o} ${c_d}(an agent CLI runs the work)${c_o}"
present=()
for a in claude codex gemini ollama omp; do command -v "$a" >/dev/null 2>&1 && { echo "   ${c_g}✓${c_o} $a"; present+=("$a"); }; done
if [ ${#present[@]} -eq 0 ]; then
  echo "   ${c_d}none found.${c_o}"
  yes "   Install dependencies now (node, omp, cmux, an agent CLI)?" && bash "$ROOT/scripts/install-deps.sh"
fi
echo

# ── 2. OpenRouter (optional) ─────────────────────────────────────────────────
echo "${c_b}2. OpenRouter${c_o} ${c_d}(optional — one API key gives you a fallback to ~15 model providers)${c_o}"
echo "   ${c_d}If a provider runs out of quota, SPIN can fall back to any model on OpenRouter.${c_o}"
if yes "   Set up OpenRouter as a fallback?"; then
  ENVF="$HOME/.config/omp.env"; mkdir -p "$(dirname "$ENVF")"; touch "$ENVF"; chmod 600 "$ENVF"
  key="$(ask "   Paste your OpenRouter API key ${c_d}(from openrouter.ai/keys — or leave blank to skip)${c_o}: ")"
  if [ -n "$key" ]; then
    grep -q '^export OPENROUTER_API_KEY=' "$ENVF" 2>/dev/null \
      && sed -i.bak "s|^export OPENROUTER_API_KEY=.*|export OPENROUTER_API_KEY=$key|" "$ENVF" \
      || echo "export OPENROUTER_API_KEY=$key" >> "$ENVF"
    echo "   ${c_d}Which model should that fallback use? Press Enter to accept the default${c_o}"
    model="$(ask "   ${c_d}(a model from openrouter.ai/models)${c_o} model ${c_d}[openrouter/anthropic/claude-sonnet-4.6]${c_o}: " "openrouter/anthropic/claude-sonnet-4.6")"
    grep -q '^export CEO_OMP_MODEL=' "$ENVF" 2>/dev/null \
      && sed -i.bak "s|^export CEO_OMP_MODEL=.*|export CEO_OMP_MODEL=$model|" "$ENVF" \
      || echo "export CEO_OMP_MODEL=$model" >> "$ENVF"
    rm -f "$ENVF.bak"
    echo "   ${c_g}✓ OpenRouter fallback ready${c_o} — uses ${model} (saved to ~/.config/omp.env)"
  fi
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
echo "${c_c}Done. Talk to it any time:${c_o}  spin   ·   spin chat   ·   spin approve \"...\""
