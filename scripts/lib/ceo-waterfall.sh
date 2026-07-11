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
export SPIN_ROOT="${SPIN_ROOT:-$CEO_ROOT}"
CEO_RUN_DIR="${CEO_RUN_DIR:-$CEO_ROOT/org/ceo/runs}"
CEO_LOCKOUT_FILE="${CEO_LOCKOUT_FILE:-$CEO_RUN_DIR/codex-blocked-until}"
CEO_LOCKOUT_SECS="${CEO_LOCKOUT_SECS:-86400}"   # 24h

source "$CEO_ROOT/scripts/lib/spin-runtime.sh"

# Owner-provided secrets (Gemini API key, etc.). Lives OUTSIDE the repo at
# ~/.config/omp.env (chmod 600), so the autonomous agents — which all source this
# lib — inherit GEMINI_API_KEY regardless of how the driver was launched (nohup,
# launchd, cmux pane). Never commit secrets to the repo.
[[ -f "$HOME/.config/omp.env" ]] && source "$HOME/.config/omp.env" 2>/dev/null || true

# Organization-scoped model policy. This lets one SPIN installation choose its
# own defaults without changing global OMP behavior. Project agents source their
# project.env after this file, so per-project routes remain the final override.
[[ -f "$CEO_ROOT/org/ceo/workspace.env" ]] && source "$CEO_ROOT/org/ceo/workspace.env" 2>/dev/null || true

# Model defaults (override via env before sourcing, or per-call)
# OMP is the primary harness. It owns model/provider retry and fallback through
# a generated config overlay; the direct CLIs below are the outer compatibility
# fallback when OMP is missing or hard-fails.
CEO_CODEX_MODEL="${CEO_CODEX_MODEL:-}"                   # empty uses the subscription account default
CEO_CODEX_REASONING="${CEO_CODEX_REASONING:-low}"         # reasoning effort: low|medium|high
CEO_CLAUDE_MODEL="${CEO_CLAUDE_MODEL:-claude-sonnet-4-6}"
CEO_SCOUT_MODEL="${CEO_SCOUT_MODEL:-$CEO_CODEX_MODEL}"   # direct-CLI scout fallback model
CEO_CURSOR_MODEL="${CEO_CURSOR_MODEL:-sonnet-4}"
CEO_GEMINI_MODEL="${CEO_GEMINI_MODEL:-gemini-2.5-flash}"  # default to flash (cost control)
CEO_GEMINI_PRO_MODEL="${CEO_GEMINI_PRO_MODEL:-gemini-2.5-pro}"  # explicit override when needed
CEO_OLLAMA_MODEL="${CEO_OLLAMA_MODEL:-qwen2.5:14b}"

# Optional extra OMP fallback model. Historically this selected the single OMP
# lane model. Now SPIN writes an OMP config overlay and treats this as one entry
# in the fallback chain, so OMP can use the accounts you authenticated in setup.
CEO_OMP_MODEL="${CEO_OMP_MODEL:-}"
SPIN_OMP_CONFIG="${SPIN_OMP_CONFIG:-$CEO_RUN_DIR/spin-omp-config.yml}"

_yaml_quote() {
  local s="${1//\'/\'\'}"
  printf "'%s'" "$s"
}

_emit_yaml_list() {
  local indent="$1"; shift
  local raw="$*"
  raw="${raw//,/ }"
  local item
  for item in $raw; do
    [[ -n "$item" ]] || continue
    printf '%*s- ' "$indent" ''
    _yaml_quote "$item"
    printf '\n'
  done
}

# Writes a SPIN-specific OMP config overlay and echoes its path. OMP still owns
# credentials, per-account usage backoff, and model fallback at runtime; SPIN
# only declares the roles/chains it wants for coordinator/project work.
ensure_spin_omp_config() {
  if [[ "${SPIN_OMP_MCP_BOOTSTRAP:-1}" != "0" ]] && command -v node >/dev/null 2>&1; then
    node "$CEO_ROOT/scripts/omp-mcp-bootstrap.js" repair --quiet >/dev/null 2>&1 || true
  fi
  mkdir -p "$(dirname "$SPIN_OMP_CONFIG")" 2>/dev/null || true

  local default_model smol_model slow_model plan_model task_model
  default_model="${SPIN_OMP_DEFAULT_MODEL:-${MODEL:-anthropic/claude-sonnet-4-6}}"
  smol_model="${SPIN_OMP_SMOL_MODEL:-anthropic/claude-haiku-4-5}"
  slow_model="${SPIN_OMP_SLOW_MODEL:-openrouter/anthropic/claude-sonnet-4.6:high}"
  plan_model="${SPIN_OMP_PLAN_MODEL:-$slow_model}"
  task_model="${SPIN_OMP_TASK_MODEL:-$smol_model}"

  local default_fallbacks smol_fallbacks slow_fallbacks provider_order
  default_fallbacks="${SPIN_OMP_DEFAULT_FALLBACKS:-openai-codex/gpt-5-codex ${CEO_OMP_MODEL:-openrouter/anthropic/claude-sonnet-4.6} openai/gpt-5 cursor/claude-4.6-sonnet-medium}"
  smol_fallbacks="${SPIN_OMP_SMOL_FALLBACKS:-openai-codex/gpt-5.1-codex-mini openrouter/~anthropic/claude-haiku-latest openai/gpt-5-mini}"
  slow_fallbacks="${SPIN_OMP_SLOW_FALLBACKS:-anthropic/claude-sonnet-4-6 openai-codex/gpt-5-codex ${CEO_OMP_MODEL:-openrouter/anthropic/claude-sonnet-4.6} openai/gpt-5}"
  provider_order="${SPIN_OMP_PROVIDER_ORDER:-anthropic openai-codex openai openrouter cursor gemini ollama}"

  local tmp="$SPIN_OMP_CONFIG.$$"
  {
    echo "# Generated by SPIN. Safe to delete; it will be recreated."
    echo "# Secrets stay in OMP auth storage or ~/.config/omp.env, not here."
    echo "modelRoles:"
    printf '  default: '; _yaml_quote "$default_model"; printf '\n'
    printf '  smol: '; _yaml_quote "$smol_model"; printf '\n'
    printf '  slow: '; _yaml_quote "$slow_model"; printf '\n'
    printf '  plan: '; _yaml_quote "$plan_model"; printf '\n'
    printf '  task: '; _yaml_quote "$task_model"; printf '\n'
    echo "modelProviderOrder:"
    _emit_yaml_list 2 "$provider_order"
    echo "retry:"
    echo "  enabled: true"
    echo "  maxRetries: ${SPIN_OMP_RETRY_MAX_RETRIES:-10}"
    echo "  baseDelayMs: ${SPIN_OMP_RETRY_BASE_DELAY_MS:-500}"
    echo "  maxDelayMs: ${SPIN_OMP_RETRY_MAX_DELAY_MS:-300000}"
    echo "  modelFallback: true"
    echo "  fallbackRevertPolicy: ${SPIN_OMP_FALLBACK_REVERT_POLICY:-cooldown-expiry}"
    echo "  fallbackChains:"
    echo "    default:"
    _emit_yaml_list 6 "$default_fallbacks"
    echo "    smol:"
    _emit_yaml_list 6 "$smol_fallbacks"
    echo "    slow:"
    _emit_yaml_list 6 "$slow_fallbacks"
    echo "    plan:"
    _emit_yaml_list 6 "$slow_fallbacks"
    echo "    task:"
    _emit_yaml_list 6 "$smol_fallbacks"
  } > "$tmp"
  mv "$tmp" "$SPIN_OMP_CONFIG"
  echo "$SPIN_OMP_CONFIG"
}

spin_omp_computer_use_prompt() {
  command -v node >/dev/null 2>&1 || return 0
  node "$CEO_ROOT/scripts/omp-mcp-bootstrap.js" prompt 2>/dev/null || true
}

format_epoch() {
  local epoch="$1"
  if date -r "$epoch" '+%m-%d %H:%M' >/dev/null 2>&1; then
    date -r "$epoch" '+%m-%d %H:%M'
  else
    date -d "@$epoch" '+%m-%d %H:%M'
  fi
}

format_epoch_full() {
  local epoch="$1"
  if date -r "$epoch" '+%Y-%m-%d %H:%M %Z' >/dev/null 2>&1; then
    date -r "$epoch" '+%Y-%m-%d %H:%M %Z'
  else
    date -d "@$epoch" '+%Y-%m-%d %H:%M %Z'
  fi
}

# model_for_job_type <job-type> → echoes the legacy direct-CLI MODEL value.
# OMP-first dispatchers set SPIN_OMP_* role vars instead.
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
  echo "  [waterfall] $provider benched until $(format_epoch "$(cat "$f")") (usage limit)" >&2
}

# Phrases that mean "this provider is out of quota / rate-limited right now".
# Includes Claude's session-limit wording ("You've hit your session limit · resets …").
CEO_LIMIT_PATTERNS='usage limit|reached your .*(subscription|limit)|hit your .*(session )?limit|session limit|rate.?limit|too many requests|\b429\b|overloaded|quota|upgrade to pro|purchase more credits|insufficient_quota|PERMISSION_DENIED|denied access|\b403\b'

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
probe_codex()  {
  local codex_bin=""
  provider_is_blocked codex && return 1
  if codex_bin="$(spin_resolve_codex_cli 2>/dev/null)"; then "$codex_bin" --version >/dev/null 2>&1
  elif command -v omx >/dev/null 2>&1; then omx --version >/dev/null 2>&1
  else return 1
  fi
}
probe_claude() { provider_is_blocked claude && return 1; command -v claude       >/dev/null 2>&1 && claude       --version >/dev/null 2>&1; }
probe_cursor() { provider_is_blocked cursor && return 1; command -v cursor-agent >/dev/null 2>&1 && cursor-agent --version >/dev/null 2>&1; }
probe_gemini() { provider_is_blocked gemini && return 1; command -v gemini       >/dev/null 2>&1 && gemini       --version >/dev/null 2>&1; }
probe_ollama() { provider_is_blocked ollama && return 1; command -v ollama       >/dev/null 2>&1 && ollama list  >/dev/null 2>&1; }
probe_omp()    { provider_is_blocked omp    && return 1; spin_have_binary omp && spin_cmd omp --help >/dev/null 2>&1; }

# select_provider <skip_codex(true|false)> [override]
# Auto order: omp -> codex -> claude -> gemini -> ollama.
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
  probe_omp    && { echo "omp";    return; }
  if [[ "$skip_codex" != "true" ]]; then
    probe_codex  && { echo "codex";  return; }
  fi
  probe_claude && { echo "claude"; return; }
  probe_gemini && { echo "gemini"; return; }
  probe_ollama && { echo "ollama"; return; }
  echo "none"
}

# run_agent <provider> <prompt> <logfile> [extra --add-dir paths...]
# Routes to the right CLI with consistent flags. Output -> logfile.
# Returns the CLI's exit code (codex always treated as soft-fail + lockout scan).
run_agent() {
  local provider="$1"; local prompt="$2"; local log="$3"; shift 3
  local rc=0

  case "$provider" in
    codex)
      local codex_bin="" codex_cmd=()
      if codex_bin="$(spin_resolve_codex_cli 2>/dev/null)"; then
        codex_cmd=("$codex_bin" exec --cd "$CEO_ROOT" --full-auto)
        [[ -n "${CEO_CODEX_MODEL:-}" ]] && codex_cmd+=(--model "$CEO_CODEX_MODEL")
        for d in "$@"; do codex_cmd+=(--add-dir "$d"); done
        codex_cmd+=(-)
        echo "$prompt" | "${codex_cmd[@]}" > "$log" 2>&1 || rc=$?
      elif command -v omx >/dev/null 2>&1; then
        codex_cmd=(omx exec --cd "$CEO_ROOT" --sandbox workspace-write)
        [[ -n "${CEO_CODEX_MODEL:-}" ]] && codex_cmd+=(--model "$CEO_CODEX_MODEL")
        for d in "$@"; do codex_cmd+=(--add-dir "$d"); done
        codex_cmd+=(-)
        echo "$prompt" | "${codex_cmd[@]}" > "$log" 2>&1 || rc=$?
      else
        echo "codex CLI not found" >&2
        return 1
      fi
      ;;
    claude)
      local add_args=(--add-dir "$CEO_ROOT")
      for d in "$@"; do add_args+=(--add-dir "$d"); done
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
      local omp_config computer_use_prompt
      local omp_args=()
      omp_config="$(ensure_spin_omp_config)"
      computer_use_prompt="$(spin_omp_computer_use_prompt)"
      omp_args=(-p --config "$omp_config" --cwd "$CEO_ROOT" --no-session)
      [[ -n "$computer_use_prompt" ]] && omp_args+=(--append-system-prompt "$computer_use_prompt")
      spin_cmd omp "${omp_args[@]}" "$prompt" > "$log" 2>&1 || rc=$?
      ;;
    ollama)
      echo "$prompt" | ollama run "${MODEL:-$CEO_OLLAMA_MODEL}" > "$log" 2>&1 || rc=$?
      ;;
    *)
      echo "run_agent: unknown provider '$provider'" >&2; return 1
      ;;
  esac
  # OMP manages per-provider/account cooldown internally. The outer SPIN bench is
  # for direct CLI lanes only; otherwise one OpenRouter/Anthropic 429 could bench
  # the whole OMP harness even after it successfully fell through to another model.
  [[ "$provider" == "omp" ]] || mark_blocked_if_limited "$provider" "$log" || true
  return $rc
}

# run_agent_resilient <skip_codex> <override> <prompt> <log> [extra --add-dir paths...]
# Walks the outer execution fallback (override first, then omp→direct CLIs),
# trying each AVAILABLE harness/CLI until one succeeds (rc==0). Normal model
# fallback should happen inside OMP; this outer chain is for missing/broken OMP
# or compatibility with machines that only have direct vendor CLIs installed.
# Returns 0 on the first success, or 1 if every candidate is unavailable/failed.
run_agent_resilient() {
  local skip_codex="$1"; local override="$2"; local prompt="$3"; local log="$4"; shift 4

  # Candidate order: explicit override first, then the standard waterfall.
  # cursor is NOT included (protects the owner's $20 Cursor plan); use it only
  # by passing it as an explicit override.
  local candidates=()
  [[ -n "$override" ]] && candidates+=("$override")
  candidates+=("omp")
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
    rc=0
    run_agent "$provider" "$prompt" "$log" "$@" || rc=$?

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
  kill_tree() {
    local sig="$1" pid="$2" child
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      kill_tree "$sig" "$child"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
  }
  ( sleep "$secs"; kill -0 "$cmd_pid" 2>/dev/null && kill_tree TERM "$cmd_pid"
    sleep 5; kill -0 "$cmd_pid" 2>/dev/null && kill_tree KILL "$cmd_pid" ) &
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
