#!/usr/bin/env bash
# install.sh — one-time setup for a fresh SPIN clone.
# Idempotent: safe to re-run. Creates the runtime org files the engine expects,
# checks dependencies, and links the `spin` and `org` commands onto your PATH.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

cat <<'BANNER'
   ___ ___ ___ _  _
  / __| _ \_ _| \| |   Super Pi Interoperable Navigator
  \__ \  _/| || .` |   a file-based AI org that runs your projects
  |___/_| |___|_|\_|   while you sleep — gated on the 4 things that matter
BANNER
echo "install — root: $ROOT"
echo

# ── 0. auto-install dependencies (node, omp, cmux, an agent CLI) ─────────────
# On by default so the one-liner gives you a working setup. Skip with SPIN_NO_DEPS=1
# (CI sets it). Best-effort + idempotent — anything present is left alone.
if [[ "${SPIN_NO_DEPS:-}" != "1" ]]; then
  echo "Checking dependencies (set SPIN_NO_DEPS=1 to skip auto-install)…"
  bash "$ROOT/scripts/install-deps.sh" || echo "  (dependency auto-install hit a snag — continuing; see notes above)"
  echo
fi

# ── 1. dependency check ─────────────────────────────────────────────────────
missing=0
need() { command -v "$1" >/dev/null 2>&1 && echo "  ✓ $1" || { echo "  ✗ $1  ($2)"; missing=1; }; }
echo "Required:"
need bash "the engine is bash"
need node "dispatcher, the org CLI, and status roll-up use node (no npm packages needed)"
echo "Agent CLIs (need at least ONE on PATH):"
agents=0
for a in claude codex gemini ollama; do
  command -v "$a" >/dev/null 2>&1 && { echo "  ✓ $a"; agents=$((agents+1)); } || echo "  – $a (not found)"
done
if (( agents == 0 )); then
  if [[ "${SPIN_INSTALL_SKIP_AGENT_CHECK:-${OMP_INSTALL_SKIP_AGENT_CHECK:-}}" == "1" ]]; then
    echo "  ! no agent CLI found — continuing anyway (SPIN_INSTALL_SKIP_AGENT_CHECK=1)"
  else
    echo "  ✗ no agent CLI found — install claude, codex, gemini, or ollama"; missing=1
  fi
fi
echo "Optional:"
for a in cmux omp; do
  command -v "$a" >/dev/null 2>&1 && echo "  ✓ $a" || echo "  – $a (optional: visual floors / interactive agents)"
done
(( missing )) && { echo; echo "Install the missing required pieces, then re-run ./install.sh"; exit 1; }

# ── 2. runtime org files (never overwrites existing state) ──────────────────
echo; echo "Creating runtime files:"
mkdir -p org/ceo/runs org/jobs org/projects org/wiki logs
seed() { [[ -f "$1" ]] && echo "  · $1 (exists, kept)" || { printf '%s' "$2" > "$1"; echo "  ✓ $1"; }; }

seed org/ceo/APPROVALS.md "# Approvals

## Pending

<!-- write decisions below this line: APPROVE: <project> <what> — <notes> -->

## Processed

<!-- the Navigator moves resolved decisions here, newest last -->
"
seed org/ceo/INBOX.md "# Navigator Inbox — project → Navigator reports
"
seed org/HUMAN_QUEUE.md "# Waiting on you

_(nothing yet — the Navigator appends the gated items here)_
"
seed org/AGENT_QUEUE.json '{ "jobs": [] }
'
seed org/state.json '{
  "updated_at": null,
  "architecture_stage": "fresh-install",
  "master_orchestrator": { "name": "spin-navigator", "status": "idle" },
  "project_orchestrators": [],
  "human_queue": [],
  "next_build": ["Register your first project: scripts/bootstrap-project.sh <id>"]
}
'
[[ -f org/OMP_HARNESS.json ]] || { cp org/OMP_HARNESS.example.json org/OMP_HARNESS.json; echo "  ✓ org/OMP_HARNESS.json (from example)"; }
[[ -f org/ceo/WORKSPACE_CONTROLLER_PROMPT.md ]] || { cp org/ceo/WORKSPACE_CONTROLLER_PROMPT.example.md org/ceo/WORKSPACE_CONTROLLER_PROMPT.md; echo "  ✓ org/ceo/WORKSPACE_CONTROLLER_PROMPT.md (from example — EDIT THIS)"; }

chmod +x scripts/*.sh scripts/org scripts/spin 2>/dev/null || true

# ── 3. the `spin` and `org` commands ─────────────────────────────────────────
echo
BIN="${SPIN_BIN_DIR:-$HOME/.local/bin}"
if mkdir -p "$BIN" 2>/dev/null && ln -sf "$ROOT/scripts/spin" "$BIN/spin" 2>/dev/null \
   && ln -sf "$ROOT/scripts/org" "$BIN/org" 2>/dev/null; then
  note=""; [[ ":$PATH:" == *":$BIN:"* ]] || note="(add $BIN to PATH)"
  echo "  ✓ linked: spin, org → $BIN/  $note"
else
  echo "  · couldn't link to $BIN — call scripts/spin and scripts/org directly"
fi

# ── 4. next steps ────────────────────────────────────────────────────────────
cat <<'EOF'

Done. Next:
  1. scripts/bootstrap-project.sh <your-project-id>     # register a project
  2. edit org/projects/<id>/PROJECT_CONTROLLER_PROMPT.md (its charter)
     and add the project to org/OMP_HARNESS.json (copy the example-app entry)
  3. edit org/ceo/WORKSPACE_CONTROLLER_PROMPT.md         (your org's charter)
  4. spin start                                          # launch the driver loop
  5. spin                                                # check on it any time

Keys for non-subscription providers go in ~/.config/omp.env (chmod 600), e.g.:
  export GEMINI_API_KEY=...
  export OPENROUTER_API_KEY=...   # then set CEO_OMP_MODEL=openrouter/anthropic/claude-sonnet-4
                                  # to add a fallback lane to ~15 model backends via omp
EOF
