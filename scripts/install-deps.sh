#!/usr/bin/env bash
# install-deps.sh — best-effort installer for everything SPIN wants present.
#
# Idempotent: anything already on PATH is skipped. Non-interactive (safe under
# `curl | bash`). Best-effort: if a package manager isn't available it prints the
# official command/link instead of failing the whole install.
#
#   scripts/install-deps.sh            # install what's missing
#   scripts/install-deps.sh --dry-run  # show what it WOULD do, change nothing
#
# Installs (when missing): node · omp (oh-my-pi) · cmux · one agent CLI (claude).
# Verified install methods (2026-06): omp = npm @oh-my-pi/pi-coding-agent,
# cmux = brew formula, claude = npm @anthropic-ai/claude-code.
set -uo pipefail

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
OS="$(uname -s)"
have(){ command -v "$1" >/dev/null 2>&1; }
c_g=$'\e[32m'; c_y=$'\e[33m'; c_d=$'\e[2m'; c_o=$'\e[0m'
note(){ printf '%s\n' "$*"; }
run(){ printf "${c_d}   + %s${c_o}\n" "$*"; [[ $DRY == 1 ]] || "$@"; }

installed=() skipped=() guided=()

# Pick an npm-style global installer (npm preferred; bun/pnpm as fallback).
node_global_install(){  # $1 = package, $2 = friendly name
  if have npm;  then run npm  install -g "$1"
  elif have bun;  then run bun  add -g "$1"
  elif have pnpm; then run pnpm add -g "$1"
  else return 1; fi
}

ensure_node(){
  have node && { skipped+=("node"); return; }
  note "${c_y}• node missing${c_o}"
  if [[ "$OS" == Darwin ]] && have brew; then run brew install node && installed+=("node")
  elif have apt-get; then run sudo apt-get update -qq && run sudo apt-get install -y nodejs npm && installed+=("node")
  elif have dnf; then run sudo dnf install -y nodejs && installed+=("node")
  else guided+=("node → https://nodejs.org (or your package manager)"); fi
}

ensure_omp(){
  have omp && { skipped+=("omp"); return; }
  note "${c_y}• omp (oh-my-pi) missing${c_o}"
  if node_global_install "@oh-my-pi/pi-coding-agent" omp; then installed+=("omp")
  else guided+=("omp → see https://omp.sh (needs npm, bun, or pnpm)"); fi
}

ensure_cmux(){
  have cmux && { skipped+=("cmux"); return; }
  note "${c_y}• cmux missing${c_o}"
  if [[ "$OS" == Darwin ]] && have brew; then run brew install cmux && installed+=("cmux")
  else guided+=("cmux → https://cmux.io (brew formula on macOS; optional display layer)"); fi
}

ensure_agent(){
  for a in claude codex gemini ollama; do have "$a" && { skipped+=("agent:$a"); return; }; done
  note "${c_y}• no agent CLI found — installing Claude Code${c_o}"
  if node_global_install "@anthropic-ai/claude-code" claude; then installed+=("claude")
  else guided+=("an agent CLI → Claude Code https://claude.com/claude-code · Codex · Gemini CLI · or Ollama"); fi
}

printf '%s\n' "${c_d}SPIN dependency check${DRY:+ (dry-run)}${c_o}"
ensure_node
ensure_omp
ensure_cmux
ensure_agent

echo
[[ ${#installed[@]} -gt 0 ]] && note "${c_g}installed:${c_o} ${installed[*]}"
[[ ${#skipped[@]}   -gt 0 ]] && note "${c_d}already present:${c_o} ${skipped[*]}"
if [[ ${#guided[@]} -gt 0 ]]; then
  note "${c_y}you still need to install (couldn't auto-install here):${c_o}"
  for g in "${guided[@]}"; do note "  - $g"; done
fi
exit 0
