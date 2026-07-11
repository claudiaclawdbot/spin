#!/usr/bin/env bash
# spin-runtime.sh — resolve SPIN-owned app/runtime binaries before PATH fallbacks.
#
# The production app bundles cmux and the SPIN agent runtime internally. During
# the migration, CLI installs still work by falling back to globally installed
# cmux/omp. Source this file from shell entrypoints that invoke those tools.

_spin_runtime_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SPIN_RUNTIME_ROOT="${SPIN_RUNTIME_ROOT:-${SPIN_ROOT:-${OMP_ROOT:-$(cd "$_spin_runtime_dir/../.." >/dev/null 2>&1 && pwd)}}}"

_spin_upper() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

_spin_candidate_bin_dirs() {
  [ -n "${SPIN_APP_RESOURCES:-}" ] && printf '%s\n' "$SPIN_APP_RESOURCES/bin"
  [ -n "${SPIN_INTERNAL_BIN_DIR:-}" ] && printf '%s\n' "$SPIN_INTERNAL_BIN_DIR"
  if [ "$SPIN_RUNTIME_ROOT" = "$HOME/Library/Application Support/SPIN/runtime" ]; then
    [ -d "/Applications/SPIN.app/Contents/Resources/bin" ] && printf '%s\n' "/Applications/SPIN.app/Contents/Resources/bin"
    [ -d "$HOME/Applications/SPIN.app/Contents/Resources/bin" ] && printf '%s\n' "$HOME/Applications/SPIN.app/Contents/Resources/bin"
  fi
  printf '%s\n' "$SPIN_RUNTIME_ROOT/vendor/bin"
  printf '%s\n' "$SPIN_RUNTIME_ROOT/agent/bin"
  printf '%s\n' "$SPIN_RUNTIME_ROOT/app/bin"
}

spin_resolve_binary() {
  local name="$1" upper envvar override dir
  upper="$(_spin_upper "$name")"
  envvar="SPIN_${upper}_BIN"
  eval "override=\${$envvar:-}"
  if [ -n "$override" ] && [ -x "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done <<EOF
$(_spin_candidate_bin_dirs)
EOF

  command -v "$name" 2>/dev/null || return 1
}

_spin_codex_candidates() {
  local dir
  [ -n "${SPIN_CODEX_BIN:-}" ] && printf '%s\n' "$SPIN_CODEX_BIN"
  [ -n "${CODEX_CLI_PATH:-}" ] && printf '%s\n' "$CODEX_CLI_PATH"
  printf '%s\n' \
    "/Applications/ChatGPT.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/Resources/codex"
  while IFS= read -r dir; do
    [ -n "$dir" ] && printf '%s\n' "$dir/codex"
  done <<EOF
$(_spin_candidate_bin_dirs)
EOF
  command -v codex 2>/dev/null || true
}

# Resolve a working Codex CLI, not merely the first executable named `codex`.
# Homebrew/npm shims can survive after their architecture package is removed.
spin_resolve_codex_cli() {
  local candidate seen="|"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$seen" in *"|$candidate|"*) continue ;; esac
    seen="$seen$candidate|"
    [ -x "$candidate" ] || continue
    "$candidate" --version >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done <<EOF
$(_spin_codex_candidates)
EOF
  return 1
}

spin_have_binary() {
  spin_resolve_binary "$1" >/dev/null 2>&1
}

spin_cmd() {
  local name="$1" bin
  shift
  bin="$(spin_resolve_binary "$name")" || {
    printf '%s\n' "$name not found" >&2
    return 127
  }
  if [ "$name" = "cmux" ] && [ -x /usr/bin/perl ]; then
    local timeout="${SPIN_CMUX_COMMAND_TIMEOUT_SECONDS:-8}"
    case "$timeout" in ''|*[!0-9]*) timeout=8 ;; esac
    /usr/bin/perl -e '
      my $seconds = shift @ARGV;
      my $pid = fork();
      exit 127 unless defined $pid;
      if ($pid == 0) {
        exec @ARGV;
        exit 127;
      }
      $SIG{ALRM} = sub {
        kill "TERM", $pid;
        waitpid($pid, 0);
        exit 124;
      };
      alarm $seconds;
      waitpid($pid, 0);
      alarm 0;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$timeout" "$bin" "$@"
    return $?
  fi
  "$bin" "$@"
}

spin_require_binary() {
  local name="$1" hint="${2:-}"
  spin_have_binary "$name" && return 0
  if [ -n "$hint" ]; then
    printf '%s\n' "$name not found — $hint" >&2
  else
    printf '%s\n' "$name not found" >&2
  fi
  return 127
}

spin_locked_process_running() {
  local lock_file="$1" expected_command="$2" pid command
  [ -f "$lock_file" ] || return 1
  pid="$(cat "$lock_file" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command" ] && printf '%s\n' "$command" | grep -Fq "$expected_command"
}

spin_stop_locked_process() {
  local lock_file="$1" expected_command="$2" pid
  if spin_locked_process_running "$lock_file" "$expected_command"; then
    pid="$(cat "$lock_file" 2>/dev/null || true)"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$lock_file" 2>/dev/null || true
}

spin_internal_path() {
  local out="" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    case ":$out:" in *":$dir:"*) ;; *) out="${out:+$out:}$dir" ;; esac
  done <<EOF
$(_spin_candidate_bin_dirs)
EOF
  printf '%s\n' "$out"
}

spin_prepend_internal_path() {
  local p
  p="$(spin_internal_path)"
  [ -n "$p" ] && PATH="$p:$PATH"
  export PATH
}

spin_cmux_socket_path() {
  local dir
  if [ -n "${CMUX_SOCKET_PATH:-}" ]; then
    printf '%s\n' "$CMUX_SOCKET_PATH"
    return 0
  fi
  dir="${SPIN_CMUX_SOCKET_DIR:-$HOME/.local/state/cmux}"
  mkdir -p "$dir"
  printf '%s\n' "$dir/spin.sock"
}

spin_prepare_cmux_environment() {
  CMUX_SOCKET_PATH="$(spin_cmux_socket_path)"
  export CMUX_SOCKET_PATH
  export CMUX_ALLOW_SOCKET_OVERRIDE="${CMUX_ALLOW_SOCKET_OVERRIDE:-1}"
  export CMUX_SOCKET_ENABLE="${CMUX_SOCKET_ENABLE:-1}"
  export CMUX_SOCKET_MODE="${CMUX_SOCKET_MODE:-allowall}"
  if [ -z "${CMUX_BUNDLED_CLI_PATH:-}" ]; then
    local cmux_bin=""
    cmux_bin="$(spin_resolve_binary cmux 2>/dev/null || true)"
    [ -n "$cmux_bin" ] && export CMUX_BUNDLED_CLI_PATH="$cmux_bin"
  fi
  return 0
}

spin_cmux_app_path() {
  local app
  if [ "$SPIN_RUNTIME_ROOT" = "$HOME/Library/Application Support/SPIN/runtime" ]; then
    for app in "/Applications/SPIN.app/Contents/Resources/SPIN.app" "$HOME/Applications/SPIN.app/Contents/Resources/SPIN.app"; do
      [ -d "$app" ] && { printf '%s\n' "$app"; return 0; }
    done
  fi
  for app in \
    "${SPIN_CMUX_APP:-}" \
    "${SPIN_APP_RESOURCES:-}/SPIN.app" \
    "$SPIN_RUNTIME_ROOT/vendor/cmux/SPIN.app" \
    "$SPIN_RUNTIME_ROOT/vendor/cmux/cmux.app" \
    "$SPIN_RUNTIME_ROOT/app/cmux/SPIN.app" \
    "$SPIN_RUNTIME_ROOT/app/cmux/cmux.app"; do
    [ -n "$app" ] || continue
    [ -d "$app" ] && { printf '%s\n' "$app"; return 0; }
  done
  return 1
}

spin_open_cmux_app() {
  local app
  spin_prepare_cmux_environment
  if app="$(spin_cmux_app_path 2>/dev/null)"; then
    if [ "${SPIN_OPEN_FRESH:-0}" = "1" ]; then
      open -F \
        --env "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH" \
        --env "CMUX_ALLOW_SOCKET_OVERRIDE=$CMUX_ALLOW_SOCKET_OVERRIDE" \
        --env "CMUX_SOCKET_ENABLE=$CMUX_SOCKET_ENABLE" \
        --env "CMUX_SOCKET_MODE=$CMUX_SOCKET_MODE" \
        --env "CMUX_BUNDLED_CLI_PATH=${CMUX_BUNDLED_CLI_PATH:-}" \
        --env "SPIN_ROOT=${SPIN_ROOT:-$SPIN_RUNTIME_ROOT}" \
        --env "WORKSPACE_ROOT=${WORKSPACE_ROOT:-${SPIN_ROOT:-$SPIN_RUNTIME_ROOT}}" \
        "$app" >/dev/null 2>&1 && return 0
    else
      open \
        --env "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH" \
        --env "CMUX_ALLOW_SOCKET_OVERRIDE=$CMUX_ALLOW_SOCKET_OVERRIDE" \
        --env "CMUX_SOCKET_ENABLE=$CMUX_SOCKET_ENABLE" \
        --env "CMUX_SOCKET_MODE=$CMUX_SOCKET_MODE" \
        --env "CMUX_BUNDLED_CLI_PATH=${CMUX_BUNDLED_CLI_PATH:-}" \
        --env "SPIN_ROOT=${SPIN_ROOT:-$SPIN_RUNTIME_ROOT}" \
        --env "WORKSPACE_ROOT=${WORKSPACE_ROOT:-${SPIN_ROOT:-$SPIN_RUNTIME_ROOT}}" \
        "$app" >/dev/null 2>&1 && return 0
    fi
    open "$app" >/dev/null 2>&1
    return $?
  fi
  open -a cmux >/dev/null 2>&1
}
