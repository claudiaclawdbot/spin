#!/usr/bin/env bash
# install.sh — one-time setup for a fresh workspace-ceo clone.
# Idempotent: safe to re-run. Creates the runtime org files the engine expects,
# checks dependencies, and (optionally) links the `ceo` command onto your PATH.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "workspace-ceo install — root: $ROOT"
echo

# ── 1. dependency check ─────────────────────────────────────────────────────
missing=0
need() { command -v "$1" >/dev/null 2>&1 && echo "  ✓ $1" || { echo "  ✗ $1  ($2)"; missing=1; }; }
echo "Required:"
need bash "the engine is bash"
need node "dispatcher + status roll-up use node (no npm packages needed)"
echo "Agent CLIs (need at least ONE on PATH):"
agents=0
for a in claude codex gemini ollama; do
  command -v "$a" >/dev/null 2>&1 && { echo "  ✓ $a"; agents=$((agents+1)); } || echo "  – $a (not found)"
done
if (( agents == 0 )); then
  if [[ "${OMP_INSTALL_SKIP_AGENT_CHECK:-}" == "1" ]]; then
    echo "  ! no agent CLI found — continuing anyway (OMP_INSTALL_SKIP_AGENT_CHECK=1)"
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

<!-- the CEO moves resolved decisions here, newest last -->
"
seed org/ceo/INBOX.md "# CEO Inbox — project → CEO reports
"
seed org/HUMAN_QUEUE.md "# Waiting on you

_(nothing yet — the CEO appends the gated items here)_
"
seed org/AGENT_QUEUE.json '{ "jobs": [] }
'
seed org/state.json '{
  "updated_at": null,
  "architecture_stage": "fresh-install",
  "master_orchestrator": { "name": "workspace-ceo", "status": "idle" },
  "project_orchestrators": [],
  "human_queue": [],
  "next_build": ["Register your first project: scripts/bootstrap-project.sh <id>"]
}
'
[[ -f org/OMP_HARNESS.json ]] || { cp org/OMP_HARNESS.example.json org/OMP_HARNESS.json; echo "  ✓ org/OMP_HARNESS.json (from example)"; }
[[ -f org/ceo/WORKSPACE_CONTROLLER_PROMPT.md ]] || { cp org/ceo/WORKSPACE_CONTROLLER_PROMPT.example.md org/ceo/WORKSPACE_CONTROLLER_PROMPT.md; echo "  ✓ org/ceo/WORKSPACE_CONTROLLER_PROMPT.md (from example — EDIT THIS)"; }

chmod +x scripts/*.sh 2>/dev/null || true

# ── 3. the `ceo` command ─────────────────────────────────────────────────────
echo
BIN="$HOME/.local/bin"
if [[ -d "$BIN" || -w "$HOME" ]]; then
  mkdir -p "$BIN"
  ln -sf "$ROOT/scripts/ceo.sh" "$BIN/ceo"
  echo "  ✓ linked: ceo → $BIN/ceo  $(case ":$PATH:" in *":$BIN:"*) ;; *) echo '(add ~/.local/bin to PATH)';; esac)"
fi

# ── 4. next steps ────────────────────────────────────────────────────────────
cat <<'EOF'

Done. Next:
  1. scripts/bootstrap-project.sh <your-project-id>     # register a project
  2. edit org/projects/<id>/PROJECT_CONTROLLER_PROMPT.md (its charter)
     and add the project to org/OMP_HARNESS.json (copy the example-app entry)
  3. edit org/ceo/WORKSPACE_CONTROLLER_PROMPT.md         (your org's charter)
  4. bash scripts/workspace-ceo-tick.sh                  # start the org (in a cmux pane, ideally)
  5. ceo                                                 # check on it any time

Keys for non-subscription providers go in ~/.config/omp.env (chmod 600), e.g.:
  export GEMINI_API_KEY=...
EOF
