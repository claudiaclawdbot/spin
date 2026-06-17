#!/usr/bin/env bash
# ceo-waterfall.sh — shared provider-selection + agent-invocation library for the
# OMP CEO/orchestrator scripts. Source this; do not execute it.
#
#   source "$(dirname "$0")/lib/ceo-waterfall.sh"
#
# Provides:
#   codex_is_blocked            -> 0 if codex locked out
#   mark_codex_blocked [secs]   -> write lockout (default 24h)
#   probe_codex/claude/cursor/gemini/ollama
#   select_provider <skip_codex?> [override]  -> echoes provider name or "none"
#   run_agent <provider> <prompt> <logfile> [extra add-dirs...]  -> runs, returns exit
#
# Single source of truth for: lockout file path, lockout duration, model defaults,
# CLI flags. Edit here, every CEO script inherits it.

CEO_ROOT="${CEO_ROOT:-${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}}"
CEO_RUN_DIR="${CEO_RUN_DIR:-$CEO_ROOT/org/ceo/runs}"
CEO_LOCKOUT_FILE="${CEO_LOCKOUT_FILE:-$CEO_RUN_DIR/codex-blocked-until}"
CEO_LOCKOUT_SECS="${CEO_LOCKOUT_SECS:-86400}"   # 24h

# Owner-provided secrets (Gemini API key, etc.). Lives OUTSIDE the repo at
# ~/.config/omp.env (chmod 600), so the autonomous agents — which all source this
# lib — inherit GEMINI_API_KEY regardless of how the driver was launched (nohup,
# launchd, cmux pane). Never commit secrets to the repo.
[[ -f "$HOME/.config/omp.env" ]] && source "$HOME/.config/omp.env" 2>/dev/null || true

# Model defaults (override via env before sourcing, or per-call)
# Tier map: scout/read-only → flash (cheap); implementation → sonnet; judgment → sonnet
CEO_CLAUDE_MODEL="${CEO_CLAUDE_MODEL:-claude-sonnet-4-6}"
CEO_SCOUT_MODEL="${CEO_SCOUT_MODEL:-gemini-2.5-flash}"   # fast/cheap for read-only workers
CEO_CURSOR_MODEL="${CEO_CURSOR_MODEL:-sonnet-4}"
CEO_GEMINI_MODEL="${CEO_GEMINI_MODEL:-gemini-2.5-flash}"  # default to flash (cost control)
CEO_GEMINI_PRO_MODEL="${CEO_GEMINI_PRO_MODEL:-gemini-2.5-pro}"  # explicit override when needed
CEO_OLLAMA_MODEL="${CEO_OLLAMA_MODEL:-qwen2.5:14b}"

# The `omp` lane (oh-my-pi, headless `omp -p`) is the gateway to everything omp
# supports — OpenRouter, Groq, xAI, Mistral, Cerebras, z.ai, Azure, … — via one
# provider-prefixed model id. Opt-in: set CEO_OMP_MODEL to enable it (otherwise it
# isn't probed, so it never becomes a dead lane). The matching key goes in
# ~/.config/omp.env, e.g. OPENROUTER_API_KEY=… with CEO_OMP_MODEL="openrouter/anthropic/claude-sonnet-4".
CEO_OMP_MODEL="${CEO_OMP_MODEL:-}"

# model_for_job_type <job-type> → echoes the right MODEL env value
# Used by dispatchers when spawning project agents.
model_for_job_type() {
  case "${1:-}" in
    read-only-worker|scout) echo "$CEO_SCOUT_MODEL" ;;
    *)                      echo "$CEO_CLAUDE_MODEL" ;;
  esac
}

mkdir -p "$CEO_RUN_DIR" 2>/dev/null || true

# --- generic provider lockout (usage-limit fall-through) ------------------
# ANY provider that returns a usage/session/rate limit gets temporarily benched
# so the waterfall advances to the next available provider instead of dead-ending
# (the bug that stalled everything when Claude hit its session limit). Codex keeps
# its original lockout file path for back-compat with ceo.sh / the cockpit display.
_provider_lock_file() {
  case "$1" in
    codex) echo "$CEO_LOCKOUT_FILE" ;;                 # existing: codex-blocked-until
    *)     echo "$CEO_RUN_DIR/.${1}-blocked-until" ;;
  esac
}

provider_is_blocked() {
  local f; f="$(_provider_lock_file "$1")"
  [[ ! -f "$f" ]] && return 1
  local until; until="$(cat "$f" 2>/dev/null)"; [[ -z "$until" ]] && return 1
  (( $(date +%s) < until ))
}

mark_provider_blocked() {
  local provider="$1"; local secs="${2:-$CEO_LOCKOUT_SECS}"
  local f; f="$(_provider_lock_file "$provider")"
  echo $(( $(date +%s) + secs )) > "$f"
  echo "  [waterfall] $provider benched until $(date -r "$(cat "$f")" '+%m-%d %H:%M') (usage limit)" >&2
}

# Phrases that mean "this provider is out of quota / rate-limited right now".
# Includes Claude's session-limit wording ("You've hit your session limit · resets …").
CEO_LIMIT_PATTERNS='usage limit|reached your .*(subscription|limit)|hit your .*(session )?limit|session limit|rate.?limit|too many requests|\b429\b|overloaded|quota|upgrade to pro|purchase more credits|insufficient_quota'

# Scan a run log; if it shows a limit message, bench that provider. Returns 0 if benched.
mark_blocked_if_limited() {
  local provider="$1"; local log="$2"
  local secs=$CEO_LOCKOUT_SECS                 # codex: long (weekly)
  [[ "$provider" != "codex" ]] && secs=5400    # others: 90min (session windows typically reset within 1-2h)
  if [[ -f "$log" ]] && tail -25 "$log" 2>/dev/null | grep -qiE "$CEO_LIMIT_PATTERNS"; then
    mark_provider_blocked "$provider" "$secs"
    return 0
  fi
  return 1
}

# Back-compat aliases (codex-specific names still used by other scripts)
codex_is_blocked()           { provider_is_blocked codex; }
mark_codex_blocked()         { mark_provider_blocked codex "${1:-$CEO_LOCKOUT_SECS}"; }
mark_codex_blocked_if_seen() { mark_blocked_if_limited codex "$1"; }

# --- provider probes (each respects its lockout) --------------------------
probe_codex()  { provider_is_blocked codex  && return 1; command -v codex        >/dev/null 2>&1 && codex        --version >/dev/null 2>&1; }
probe_claude() { provider_is_blocked claude && return 1; command -v claude       >/dev/null 2>&1 && claude       --version >/dev/null 2>&1; }
probe_cursor() { provider_is_blocked cursor && return 1; command -v cursor-agent >/dev/null 2>&1 && cursor-agent --version >/dev/null 2>&1; }
probe_gemini() { provider_is_blocked gemini && return 1; command -v gemini       >/dev/null 2>&1 && gemini       --version >/dev/null 2>&1; }
probe_ollama() { provider_is_blocked ollama && return 1; command -v ollama       >/dev/null 2>&1 && ollama list  >/dev/null 2>&1; }
# omp lane: only available when you've chosen a model for it (CEO_OMP_MODEL) — that's
# what makes OpenRouter/Groq/etc. a real fallback rather than a dead provider.
probe_omp()    { provider_is_blocked omp    && return 1; command -v omp          >/dev/null 2>&1 && [ -n "${CEO_OMP_MODEL:-}" ]; }

# select_provider <skip_codex(true|false)> [override]
# Auto order: codex -> claude -> gemini -> ollama.
# NOTE: cursor-agent is deliberately NOT in the auto-waterfall — it shares the
# owner's personal Cursor ($20) plan quota, so the 24/7 loop must never silently
# burn it. Cursor is only used when explicitly requested via override (a deliberate
# "cursor lane"), and only when it isn't benched.
# Strategic layers (workspace CEO) pass skip_codex=true to preserve codex quota.
#
# Any benched provider (usage limit) is skipped. An explicit override is also
# ignored while that provider is benched, so it falls through to the waterfall.
select_provider() {
  local skip_codex="${1:-false}"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    if provider_is_blocked "$override"; then
      echo "  [waterfall] ignoring $override override — it is benched (usage limit)" >&2
      # fall through to waterfall below
    else
      echo "$override"; return
    fi
  fi
  if [[ "$skip_codex" != "true" ]]; then
    probe_codex  && { echo "codex";  return; }
  fi
  probe_claude && { echo "claude"; return; }
  probe_gemini && { echo "gemini"; return; }
  probe_omp    && { echo "omp";    return; }   # OpenRouter/Groq/etc. via omp (if CEO_OMP_MODEL set)
  probe_ollama && { echo "ollama"; return; }
  echo "none"
}

# run_agent <provider> <prompt> <logfile> [extra --add-dir paths...]
# Routes to the right CLI with consistent flags. Output -> logfile.
# Returns the CLI's exit code (codex always treated as soft-fail + lockout scan).
run_agent() {
  local provider="$1"; local prompt="$2"; local log="$3"; shift 3
  local extra_dirs=("$@")
  local rc=0

  case "$provider" in
    codex)
      command -v omx >/dev/null 2>&1 || { echo "omx required for codex provider" >&2; return 1; }
      local add_args=()
      for d in "${extra_dirs[@]}"; do add_args+=(--add-dir "$d"); done
      echo "$prompt" | omx exec --cd "$CEO_ROOT" --sandbox workspace-write "${add_args[@]}" - \
        > "$log" 2>&1 || rc=$?
      ;;
    claude)
      local add_args=(--add-dir "$CEO_ROOT")
      for d in "${extra_dirs[@]}"; do add_args+=(--add-dir "$d"); done
      claude -p "$prompt" --model "${MODEL:-$CEO_CLAUDE_MODEL}" \
        --dangerously-skip-permissions "${add_args[@]}" \
        > "$log" 2>&1 || rc=$?
      ;;
    cursor)
      echo "$prompt" | cursor-agent -p --force --trust \
        --workspace "$CEO_ROOT" --model "${MODEL:-$CEO_CURSOR_MODEL}" \
        > "$log" 2>&1 || rc=$?
      ;;
    gemini)
      echo "$prompt" | gemini --model "${MODEL:-$CEO_GEMINI_MODEL}" > "$log" 2>&1 || rc=$?
      ;;
    omp)
      # omp -p (headless) takes the prompt as a positional arg. The model id selects
      # the backend: openrouter/…, groq/…, x-ai/…, mistral/…, or any omp provider.
      omp -p --model "${MODEL:-$CEO_OMP_MODEL}" "$prompt" > "$log" 2>&1 || rc=$?
      ;;
    ollama)
      echo "$prompt" | ollama run "${MODEL:-$CEO_OLLAMA_MODEL}" > "$log" 2>&1 || rc=$?
      ;;
    *)
      echo "run_agent: unknown provider '$provider'" >&2; return 1
      ;;
  esac
  # Bench this provider if it reported a usage/session/rate limit (any provider).
  mark_blocked_if_limited "$provider" "$log" || true
  return $rc
}

# run_agent_resilient <skip_codex> <override> <prompt> <log> [extra --add-dir paths...]
# Walks the provider waterfall (override first, then codex→claude→gemini→ollama),
# trying each AVAILABLE provider until one succeeds (rc==0). Falls through on ANY
# failure — usage limit, auth error, crash, missing CLI — not just limits. This is
# the core "no dead-end" guarantee: a broken/unauthed/benched provider (e.g. gemini
# without GEMINI_API_KEY) never kills a job; it just advances to the next one.
# Returns 0 on the first success, or 1 if every candidate is unavailable/failed.
run_agent_resilient() {
  local skip_codex="$1"; local override="$2"; local prompt="$3"; local log="$4"; shift 4
  local extra=("$@")

  # Candidate order: explicit override first, then the standard waterfall.
  # cursor is NOT included (protects the owner's $20 Cursor plan); use it only
  # by passing it as an explicit override.
  local candidates=()
  [[ -n "$override" ]] && candidates+=("$override")
  [[ "$skip_codex" != "true" ]] && candidates+=("codex")
  candidates+=("claude" "gemini" "ollama")

  local tried=" " provider rc
  for provider in "${candidates[@]}"; do
    [[ "$tried" == *" $provider "* ]] && continue   # de-dupe (override may repeat)
    tried+="$provider "

    if provider_is_blocked "$provider"; then
      echo "  [waterfall] skip $provider (benched until reset)" >&2; continue
    fi
    if ! "probe_$provider" 2>/dev/null; then
      echo "  [waterfall] skip $provider (CLI absent or not ready)" >&2; continue
    fi

    echo "  [waterfall] trying $provider" >&2
    run_agent "$provider" "$prompt" "$log" "${extra[@]}"; rc=$?

    if provider_is_blocked "$provider"; then
      echo "  [waterfall] $provider hit a usage limit — next provider" >&2; continue
    fi
    if (( rc == 0 )); then
      return 0
    fi
    echo "  [waterfall] $provider failed (rc=$rc, not a limit) — next provider" >&2
  done

  echo "  [waterfall] all providers exhausted (none succeeded)" >&2
  return 1
}

# run_with_timeout <seconds> <command...>  -> runs command, killing it if it
# exceeds the timeout. Returns the command's exit code, or 124 on timeout.
# Portable (no GNU `timeout` dependency). Used so a hung agent CLI call can never
# freeze the driver loop.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -0 "$cmd_pid" 2>/dev/null && kill -TERM "$cmd_pid" 2>/dev/null
    sleep 5; kill -0 "$cmd_pid" 2>/dev/null && kill -KILL "$cmd_pid" 2>/dev/null ) &
  local watcher=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true
  return $rc
}

# changed_since <stamp_file> <watched_file...>  -> 0 if any watched file is newer
# than the stamp (or stamp missing). Simple mtime gate.
changed_since() {
  local stamp="$1"; shift
  [[ ! -f "$stamp" ]] && return 0
  local f
  for f in "$@"; do
    [[ -f "$f" && "$f" -nt "$stamp" ]] && return 0
  done
  return 1
}

# content_changed <hash_stamp_file> <watched_file...>  -> 0 if the *substantive*
# content of the watched files changed since last call, ignoring volatile
# timestamp/metric fields that refresh scripts rewrite every tick (updated_at,
# last_update, last_receipt, reviewed_at, checked_at, *_at). Stores the new hash.
#
# This is the correct gate for LLM calls: mtime alone is fooled by refresh scripts
# that touch STATE.json/AGENT_QUEUE.json timestamps each tick.
content_changed() {
  local stamp="$1"; shift
  local volatile='updated_at|last_update|last_receipt|reviewed_at|checked_at|started_at|completed_at|_at"|Last set:|Last updated:'
  local newhash
  newhash="$(cat "$@" 2>/dev/null | grep -vaE "$volatile" | shasum 2>/dev/null | awk '{print $1}')"
  local oldhash=""
  [[ -f "$stamp" ]] && oldhash="$(cat "$stamp" 2>/dev/null)"
  if [[ "$newhash" != "$oldhash" ]]; then
    echo "$newhash" > "$stamp"
    return 0
  fi
  return 1
}
