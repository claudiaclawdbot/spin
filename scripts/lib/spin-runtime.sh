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

# Return a boot-scoped process-start identity. PID alone is not sufficient for a
# long-lived daemon lock because the kernel can reuse it after the owner exits.
# Linux exposes a monotonic start tick; other platforms use the full ps start
# timestamp plus the current boot identity when available.
spin_process_identity() {
  local pid="$1" stat_tail start_ticks boot_marker started raw hex
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -r "/proc/$pid/stat" ]; then
    stat_tail="$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null || true)"
    start_ticks="$(printf '%s\n' "$stat_tail" | awk '{print $20}')"
    boot_marker="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [ -n "$start_ticks" ]; then
      printf 'linux:%s:%s\n' "${boot_marker:-unknown-boot}" "$start_ticks"
      return 0
    fi
  fi

  started="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
  [ -n "$started" ] || return 1
  boot_marker="$(sysctl -n kern.boottime 2>/dev/null || true)"
  [ -n "$boot_marker" ] || boot_marker="$(uname -sr 2>/dev/null || true)"
  raw="${boot_marker:-unknown-boot}|$started"
  hex="$(printf '%s' "$raw" | od -An -tx1 | tr -d ' \n')"
  [ -n "$hex" ] || return 1
  printf 'ps:%s\n' "$hex"
}

_spin_lock_field() {
  local lock_file="$1" wanted="$2" line
  [ -f "$lock_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$wanted="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "$lock_file"
  return 1
}

# New locks keep the PID on the first line so simple read-only tooling can still
# display it. A legacy lock is exactly that one numeric line.
spin_lock_read_pid() {
  local lock_file="$1" pid=""
  [ -f "$lock_file" ] || return 1
  IFS= read -r pid < "$lock_file" || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

_spin_lock_is_identity_aware() {
  [ "$(_spin_lock_field "$1" version 2>/dev/null || true)" = "1" ]
}

# Verify both PID and process-start identity for current locks. Plain-PID locks
# from older SPIN versions remain readable and retain the old command check.
spin_lock_identity_matches() {
  local lock_file="$1" expected_command="${2:-}" pid recorded current command
  pid="$(spin_lock_read_pid "$lock_file" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  if _spin_lock_is_identity_aware "$lock_file"; then
    recorded="$(_spin_lock_field "$lock_file" identity 2>/dev/null || true)"
    [ -n "$recorded" ] || return 1
    current="$(spin_process_identity "$pid" 2>/dev/null || true)"
    [ -n "$current" ] && [ "$current" = "$recorded" ]
    return $?
  fi

  [ -z "$expected_command" ] && return 0
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command" ] && printf '%s\n' "$command" | grep -Fq "$expected_command"
}

spin_locked_process_running() {
  spin_lock_identity_matches "$1" "${2:-}"
}

_spin_lock_unlink_if_same() {
  local lock_file="$1" snapshot="$2"
  if [ -e "$lock_file" ] && [ "$lock_file" -ef "$snapshot" ]; then
    rm -f "$lock_file" 2>/dev/null || return 1
  fi
}

# Acquire through an atomic hardlink. Contenders pin the existing inode before
# inspecting or reclaiming it, so one process cannot unlink a replacement lock
# installed by another process between the check and cleanup.
#
# Returns: 0 acquired, 1 held by a live owner, 2 local filesystem/identity error.
# On success SPIN_LOCK_OWNER_TOKEN contains the release token for this process.
spin_lock_acquire() {
  local lock_file="$1" expected_command="${2:-}" identity token candidate snapshot attempt=0
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 2
  identity="$(spin_process_identity "$$" 2>/dev/null || true)"
  [ -n "$identity" ] || return 2
  token="$$.$(date +%s).${RANDOM:-0}.${RANDOM:-0}"
  candidate="${lock_file}.candidate.$token"
  snapshot="${lock_file}.snapshot.$token"
  (
    umask 077
    printf '%s\nversion=1\nidentity=%s\ntoken=%s\n' "$$" "$identity" "$token" > "$candidate"
  ) || return 2

  while [ "$attempt" -lt 32 ]; do
    attempt=$((attempt + 1))
    if ln "$candidate" "$lock_file" 2>/dev/null; then
      rm -f "$candidate" "$snapshot" 2>/dev/null || true
      SPIN_LOCK_OWNER_TOKEN="$token"
      SPIN_LOCK_OWNER_FILE="$lock_file"
      return 0
    fi

    rm -f "$snapshot" 2>/dev/null || true
    if ! ln "$lock_file" "$snapshot" 2>/dev/null; then
      continue
    fi
    if spin_lock_identity_matches "$snapshot" "$expected_command"; then
      rm -f "$snapshot" "$candidate" 2>/dev/null || true
      return 1
    fi
    _spin_lock_unlink_if_same "$lock_file" "$snapshot" || true
    rm -f "$snapshot" 2>/dev/null || true
  done

  rm -f "$snapshot" "$candidate" 2>/dev/null || true
  return 2
}

# Release only the lock acquired by this process and token. The inode pin makes
# cleanup safe even if another owner replaces the pathname concurrently.
spin_lock_release() {
  local lock_file="$1" owner_token="${2:-}" snapshot stop_marker pid recorded_token identity current
  [ -e "$lock_file" ] || return 0
  snapshot="${lock_file}.release.$$.$RANDOM"
  ln "$lock_file" "$snapshot" 2>/dev/null || return 1
  pid="$(spin_lock_read_pid "$snapshot" 2>/dev/null || true)"

  if _spin_lock_is_identity_aware "$snapshot"; then
    recorded_token="$(_spin_lock_field "$snapshot" token 2>/dev/null || true)"
    identity="$(_spin_lock_field "$snapshot" identity 2>/dev/null || true)"
    current="$(spin_process_identity "$$" 2>/dev/null || true)"
    if [ "$pid" != "$$" ] || [ -z "$owner_token" ] || [ "$owner_token" != "$recorded_token" ] \
      || [ -z "$current" ] || [ "$current" != "$identity" ]; then
      rm -f "$snapshot" 2>/dev/null || true
      return 1
    fi
  elif [ "$pid" != "$$" ]; then
    rm -f "$snapshot" 2>/dev/null || true
    return 1
  fi

  # A coordinated stop owns removal once it has pinned this inode. Leaving the
  # public pathname in place prevents a replacement daemon from starting while
  # this exact owner is still unwinding its TERM/EXIT handlers.
  stop_marker="${lock_file}.stopping"
  if [ -e "$stop_marker" ] && [ "$stop_marker" -ef "$snapshot" ]; then
    rm -f "$snapshot" 2>/dev/null || true
    return 0
  fi

  _spin_lock_unlink_if_same "$lock_file" "$snapshot" || {
    rm -f "$snapshot" 2>/dev/null || true
    return 1
  }
  rm -f "$snapshot" 2>/dev/null || true
}

spin_stop_locked_process() {
  local lock_file="$1" expected_command="$2" attempts="${3:-30}" interval="${4:-0.1}"
  local snapshot stop_marker marker_snapshot pid count=0
  [ -e "$lock_file" ] || return 0
  case "$attempts" in ''|*[!0-9]*) attempts=30 ;; esac
  [ "$attempts" -gt 0 ] || attempts=1
  snapshot="${lock_file}.stop.$$.$RANDOM"
  stop_marker="${lock_file}.stopping"
  marker_snapshot="${stop_marker}.snapshot.$$.$RANDOM"
  ln "$lock_file" "$snapshot" 2>/dev/null || return 1

  if spin_lock_identity_matches "$snapshot" "$expected_command"; then
    pid="$(spin_lock_read_pid "$snapshot" 2>/dev/null || true)"

    # Let the owner's release path detect that shutdown cleanup now belongs to
    # this stopper. Reclaim only a stale marker, and never replace one that is
    # still pinning a different live owner.
    if ! ln "$snapshot" "$stop_marker" 2>/dev/null; then
      if ! { [ -e "$stop_marker" ] && [ "$stop_marker" -ef "$snapshot" ]; }; then
        rm -f "$marker_snapshot" 2>/dev/null || true
        if ln "$stop_marker" "$marker_snapshot" 2>/dev/null; then
          if spin_lock_identity_matches "$marker_snapshot" "$expected_command"; then
            rm -f "$marker_snapshot" "$snapshot" 2>/dev/null || true
            return 1
          fi
          _spin_lock_unlink_if_same "$stop_marker" "$marker_snapshot" || true
          rm -f "$marker_snapshot" 2>/dev/null || true
        fi
        if ! ln "$snapshot" "$stop_marker" 2>/dev/null \
          && ! { [ -e "$stop_marker" ] && [ "$stop_marker" -ef "$snapshot" ]; }; then
          rm -f "$snapshot" 2>/dev/null || true
          return 1
        fi
      fi
    fi

    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    while spin_lock_identity_matches "$snapshot" "$expected_command" && [ "$count" -lt "$attempts" ]; do
      sleep "$interval"
      count=$((count + 1))
    done

    if spin_lock_identity_matches "$snapshot" "$expected_command"; then
      kill -KILL "$pid" 2>/dev/null || true
      count=0
      while spin_lock_identity_matches "$snapshot" "$expected_command" && [ "$count" -lt "$attempts" ]; do
        sleep "$interval"
        count=$((count + 1))
      done
    fi

    # Fail closed if even KILL did not retire the recorded process identity.
    # Keeping both names pinned is safer than allowing an overlapping daemon.
    if spin_lock_identity_matches "$snapshot" "$expected_command"; then
      rm -f "$snapshot" 2>/dev/null || true
      return 1
    fi
  fi

  _spin_lock_unlink_if_same "$lock_file" "$snapshot" || true
  _spin_lock_unlink_if_same "$stop_marker" "$snapshot" || true
  rm -f "$snapshot" 2>/dev/null || true
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
