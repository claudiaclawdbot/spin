#!/usr/bin/env bash
# spin-bootstrap.sh — SPIN installer, safe for `curl … | bash`.
#
#   curl -fsSL https://raw.githubusercontent.com/claudiaclawdbot/spin/main/spin-bootstrap.sh | bash
#   curl -fsSL …/spin-bootstrap.sh | bash -s -- ~/somewhere     # custom dir
#
# This is a TINY clone-launcher on purpose. It carries no embedded payload, no
# heredocs, and no line-continuations — the three things that desync when bash
# reads a large script byte-by-byte from a network pipe. It clones SPIN and runs
# the installer (which installs any missing deps: node, omp, cmux, an agent CLI).
#
# Want a fully-offline single file that embeds everything? Download spin-offline.sh
# and run `bash spin-offline.sh` — it self-extracts with no network/git needed.
set -euo pipefail

DEST="${1:-$HOME/spin}"
REPO="https://github.com/claudiaclawdbot/spin.git"

printf '\033[35m%s\033[0m\n' '   ___ ___ ___ _  _'
printf '\033[35m%s\033[0m\n' '  / __| _ \_ _| \| |   Super Pi Interoperable Navigator'
printf '\033[35m%s\033[0m\n' '  \__ \  _/| || .` |   installer'
printf '\033[35m%s\033[0m\n' '  |___/_| |___|_|\_|'
printf '\033[35m→ installing to %s\033[0m\n' "$DEST"

command -v git >/dev/null 2>&1 || { echo "✗ git is required for the one-liner (or use spin-offline.sh)"; exit 1; }

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null || true)" ]; then
  echo "✗ $DEST exists and is not empty — choose a fresh dir:  … | bash -s -- ~/new-dir"
  exit 1
fi

git clone --depth 1 "$REPO" "$DEST"
cd "$DEST"
exec bash ./install.sh
