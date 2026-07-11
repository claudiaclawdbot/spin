#!/usr/bin/env bash
# Delegate a bounded macOS desktop task to the signed Codex runtime. OMP cannot
# directly inherit Codex Computer Use's native service trust chain.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKDIR="${SPIN_COMPUTER_USE_CWD:-$PWD}"
MODEL="${SPIN_CODEX_COMPUTER_USE_MODEL:-}"
READ_ONLY=0
PROBE=0

usage() {
  cat <<'EOF'
Usage:
  spin computer-use probe
  spin computer-use [--read-only] [--cwd DIR] [--model MODEL] -- "task"

The probe performs one read-only get_app_state on the running SPIN app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    probe|--probe) PROBE=1; READ_ONLY=1; shift ;;
    --read-only) READ_ONLY=1; shift ;;
    --cwd) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; WORKDIR="$2"; shift 2 ;;
    --model) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; MODEL="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

[[ -d "$WORKDIR" ]] || { echo "computer-use working directory does not exist: $WORKDIR" >&2; exit 2; }
if [[ "$PROBE" == "1" ]]; then
  TASK='Perform only a read-only sky.get_app_state({app:"dev.spin.app", disableDiff:true}) on the currently running SPIN app. Reply exactly VISIBLE_CODEX_CUA_OK followed by the observed window title.'
else
  [[ $# -gt 0 ]] || { usage >&2; exit 2; }
  TASK="$*"
fi

codex_is_trusted() {
  local candidate="$1" details
  [[ -x "$candidate" ]] || return 1
  "$candidate" --version >/dev/null 2>&1 || return 1
  [[ "$(uname -s)" != "Darwin" || "${SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE:-0}" == "1" ]] && return 0
  details="$(/usr/bin/codesign -d --verbose=4 "$candidate" 2>&1 || true)"
  grep -q 'TeamIdentifier=2DC432GLL2' <<<"$details"
}

CODEX_BIN=""
candidates=(
  "${SPIN_CODEX_BIN:-}"
  "${CODEX_CLI_PATH:-}"
  "/Applications/ChatGPT.app/Contents/Resources/codex"
  "/Applications/Codex.app/Contents/Resources/codex"
)
if command -v codex >/dev/null 2>&1; then candidates+=("$(command -v codex)"); fi
for candidate in "${candidates[@]}"; do
  [[ -n "$candidate" ]] || continue
  if codex_is_trusted "$candidate"; then CODEX_BIN="$candidate"; break; fi
done
[[ -n "$CODEX_BIN" ]] || {
  echo "signed OpenAI Codex CLI not found; an unsigned or broken codex binary cannot own the Computer Use service" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || { echo "node is required to inspect the Computer Use route" >&2; exit 1; }
bridge_json="$(node "$ROOT/scripts/omp-mcp-bootstrap.js" status --json 2>/dev/null || true)"
bridge_state="$(printf '%s' "$bridge_json" | node -e '
let raw=""; process.stdin.on("data", c => raw += c); process.stdin.on("end", () => {
  try { process.stdout.write(JSON.parse(raw).status || "error"); } catch { process.stdout.write("error"); }
});
')"
skill_path="$(printf '%s' "$bridge_json" | node -e '
let raw=""; process.stdin.on("data", c => raw += c); process.stdin.on("end", () => {
  try {
    const value = JSON.parse(raw).pluginRoot;
    if (value) process.stdout.write(value + "/skills/computer-use/SKILL.md");
  } catch {}
});
')"
[[ "$bridge_state" == "configured" && -f "$skill_path" ]] || {
  echo "Codex Computer Use delegation is not configured; run spin up and then spin doctor" >&2
  exit 1
}

scope='Use only the actions needed for the task. Do not infer permission for risky UI actions.'
if [[ "$READ_ONLY" == "1" ]]; then
  scope='Read-only scope: do not click, type, press keys, submit, change settings, or modify files.'
fi
PROMPT="You are a scoped desktop executor delegated by SPIN. Read $skill_path and use the connected node_repl MCP through its supported Computer Use wrapper. $scope Follow the skill's confirmation policy literally. Generic delegation is not confirmation; explicit user-authored pre-approval quoted in the task may be used only where that policy allows it. Return concise observed evidence and never claim an action or UI state you did not verify.

Task:
$TASK"

TMP_RUN="$(mktemp -d "${TMPDIR:-/tmp}/spin-codex-cua.XXXXXX")"
trap 'rm -rf "$TMP_RUN"' EXIT
LAST_MESSAGE="$TMP_RUN/last-message.txt"
RUN_LOG="$TMP_RUN/codex.log"
args=(exec --ephemeral -C "$WORKDIR" --sandbox danger-full-access --output-last-message "$LAST_MESSAGE")
[[ -d "$WORKDIR/.git" ]] || args+=(--skip-git-repo-check)
[[ -n "$MODEL" ]] && args+=(--model "$MODEL")

set +e
"$CODEX_BIN" "${args[@]}" "$PROMPT" </dev/null >"$RUN_LOG" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  cat "$RUN_LOG" >&2
  echo "Codex Computer Use delegation failed (exit $rc); no desktop result was accepted" >&2
  exit "$rc"
fi
if [[ -s "$LAST_MESSAGE" ]]; then
  cat "$LAST_MESSAGE"
  printf '\n'
else
  cat "$RUN_LOG"
fi
