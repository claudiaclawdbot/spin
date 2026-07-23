#!/usr/bin/env bash
# wiki-watch.sh — watches project dirs for file changes and rebuilds their wiki indexes.
#
# Uses fswatch (macOS/Linux) or falls back to polling with find+mtime.
# Debounces: waits 3s after last change before rebuilding to avoid thrashing.
#
# Usage:
#   bash scripts/wiki-watch.sh                  # watch all projects
#   bash scripts/wiki-watch.sh built-by-ai      # watch one project
#   bash scripts/wiki-watch.sh --rebuild-all    # one-shot rebuild all, then exit
#
# Start in background:
#   nohup bash scripts/wiki-watch.sh >logs/wiki-watch.log 2>&1 &

set -uo pipefail
ROOT="${WORKSPACE_ROOT:-${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/scripts/lib/spin-runtime.sh"
LOCK="$ROOT/org/ceo/runs/.wiki-watch.lock"
STOP="$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
INTERVAL="${SPIN_WIKI_WATCH_INTERVAL_SECONDS:-8}"
DEBOUNCE="${SPIN_WIKI_WATCH_DEBOUNCE_SECONDS:-3}"
FSWATCH_BIN="${SPIN_FSWATCH_BIN:-}"
FSWATCH_PID=""
FSWATCH_READER_PID=""
EVENT_DIR=""
EVENT_FIFO=""

case "$INTERVAL" in
  ''|*[!0-9]*|0) echo "[wiki-watch] invalid reconciliation interval: $INTERVAL" >&2; exit 2 ;;
esac
case "$DEBOUNCE" in
  ''|*[!0-9]*) echo "[wiki-watch] invalid debounce interval: $DEBOUNCE" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/org/ceo/runs" "$ROOT/org/wiki/projects" "$ROOT/projects" "$ROOT/logs"

# ── singleton lock ────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--rebuild-all" ]]; then
  if spin_lock_acquire "$LOCK" "$ROOT/scripts/wiki-watch.sh"; then
    LOCK_TOKEN="$SPIN_LOCK_OWNER_TOKEN"
  else
    lock_rc=$?
    if (( lock_rc == 1 )); then
      other="$(spin_lock_read_pid "$LOCK" 2>/dev/null || true)"
      echo "[wiki-watch] already running (PID ${other:-unknown}); exiting." >&2; exit 0
    fi
    echo "[wiki-watch] could not acquire singleton lock: $LOCK" >&2
    exit 1
  fi
  cleanup() {
    if [[ -n "$FSWATCH_PID" ]]; then
      kill "$FSWATCH_PID" 2>/dev/null || true
      wait "$FSWATCH_PID" 2>/dev/null || true
    fi
    if [[ -n "$FSWATCH_READER_PID" ]]; then
      kill "$FSWATCH_READER_PID" 2>/dev/null || true
      wait "$FSWATCH_READER_PID" 2>/dev/null || true
    fi
    if [[ -n "$EVENT_DIR" && -d "$EVENT_DIR" ]]; then
      rm -f "$EVENT_DIR"/* 2>/dev/null || true
      rmdir "$EVENT_DIR" 2>/dev/null || true
    fi
    spin_lock_release "$LOCK" "$LOCK_TOKEN" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM
  rm -f "$STOP"
fi

# ── project discovery ─────────────────────────────────────────────────────────
projects_to_watch() {
  local project_dir
  if [[ -n "${1:-}" && "${1:-}" != "--rebuild-all" ]]; then
    [[ -d "$ROOT/projects/$1" ]] && printf '%s\n' "$1"
  else
    for project_dir in "$ROOT"/projects/*; do
      [[ -d "$project_dir" ]] || continue
      basename "$project_dir"
    done
  fi
}

# ── rebuild one project ───────────────────────────────────────────────────────
rebuild() {
  local project="$1" rc
  bash "$SCRIPT_DIR/wiki-build.sh" "$project" 2>&1 \
    | tee -a "$ROOT/logs/wiki-watch.log"
  rc="${PIPESTATUS[0]}"
  return "$rc"
}

project_needs_rebuild() {
  local project="$1"
  local project_dir="$ROOT/projects/$project"
  local wiki="$ROOT/org/wiki/projects/$project.md"
  local changed

  [[ -d "$project_dir" ]] || return 1
  [[ -s "$wiki" ]] || return 0

  changed="$(
    find -L "$project_dir" \
      \( -type d \( \
        -name .git -o \
        -name node_modules -o \
        -name .next -o \
        -name dist -o \
        -name build -o \
        -name out -o \
        -name .turbo -o \
        -name coverage -o \
        -name __pycache__ -o \
        -name .cache -o \
        -name vendor -o \
        -name target -o \
        -name venv -o \
        -name .venv -o \
        -name cache \
      \) -prune \) -o \
      \( \( \
          -type d -o \
          \( -type f \
            -not -name package-lock.json \
            -not -name yarn.lock \
            -not -name pnpm-lock.yaml \
            -not -name Gemfile.lock \
            -not -name Cargo.lock \
            -not -name poetry.lock \
            -not -name '*.min.js' \
            -not -name '*.min.css' \
            -not -name '*.map' \
          \) \
        \) -newer "$wiki" \
        -print -quit \
      \) 2>/dev/null
  )"
  [[ -n "$changed" ]]
}

reconcile_projects() {
  local project failed=0
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    if project_needs_rebuild "$project"; then
      rebuild "$project" || failed=1
    fi
  done < <(projects_to_watch "$PROJECT_FILTER")
  return "$failed"
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

project_set_signature() {
  local project project_path target
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    project_path="$ROOT/projects/$project"
    target="$(readlink "$project_path" 2>/dev/null || printf '%s' "$project_path")"
    printf '%s\t%s\n' "$project" "$target"
  done < <(projects_to_watch "$PROJECT_FILTER")
}

rebuild_project_set_changes() {
  local previous="$1" current="$2"
  local project target signature failed=0
  while IFS=$'\t' read -r project target; do
    [[ -n "$project" ]] || continue
    signature="${project}"$'\t'"${target}"
    if ! printf '%s\n' "$previous" | grep -Fqx -- "$signature"; then
      [[ -n "$EVENT_DIR" ]] && rm -f "$EVENT_DIR/project.$project" 2>/dev/null || true
      rebuild "$project" || failed=1
    fi
  done <<< "$current"
  return "$failed"
}

stop_fswatch_children() {
  if [[ -n "$FSWATCH_PID" ]]; then
    kill "$FSWATCH_PID" 2>/dev/null || true
    wait "$FSWATCH_PID" 2>/dev/null || true
    FSWATCH_PID=""
  fi
  if [[ -n "$FSWATCH_READER_PID" ]]; then
    kill "$FSWATCH_READER_PID" 2>/dev/null || true
    wait "$FSWATCH_READER_PID" 2>/dev/null || true
    FSWATCH_READER_PID=""
  fi
  [[ -n "$EVENT_FIFO" ]] && rm -f "$EVENT_FIFO" 2>/dev/null || true
}

start_fswatch() {
  local project project_path link_target raw_target resolved
  local changed project_for_event prefix relative
  local i
  local -a watch_paths=()
  local -a event_prefixes=()
  local -a event_projects=()

  stop_fswatch_children

  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    project_path="$ROOT/projects/$project"
    [[ -d "$project_path" ]] || continue
    watch_paths+=("$project_path")
    event_prefixes+=("$project_path")
    event_projects+=("$project")

    link_target="$(readlink "$project_path" 2>/dev/null || true)"
    if [[ -n "$link_target" ]]; then
      if [[ "$link_target" == /* ]]; then
        raw_target="$link_target"
      else
        raw_target="$ROOT/projects/$link_target"
      fi
      event_prefixes+=("$raw_target")
      event_projects+=("$project")
    fi

    resolved="$(cd -P "$project_path" 2>/dev/null && pwd || true)"
    if [[ -n "$resolved" && "$resolved" != "$project_path" ]]; then
      # Some fswatch builds do not recurse through a symlink argument. Supply
      # the canonical target explicitly while retaining the project-link path.
      watch_paths+=("$resolved")
      event_prefixes+=("$resolved")
      event_projects+=("$project")
    fi
  done < <(projects_to_watch "$PROJECT_FILTER")

  # With no projects yet, the lightweight project-set check in the main loop
  # will start fswatch as soon as one is linked.
  (( ${#watch_paths[@]} > 0 )) || return 0

  EVENT_FIFO="$EVENT_DIR/events"
  mkfifo "$EVENT_FIFO" || {
    echo "[wiki-watch] could not create event channel" >&2
    return 1
  }

  while IFS= read -r changed; do
    [[ "$changed" =~ $SKIP_RE ]] && continue
    [[ -f "$STOP" ]] && break
    project_for_event=""

    for (( i=0; i<${#event_prefixes[@]}; i++ )); do
      prefix="${event_prefixes[$i]}"
      if [[ "$changed" == "$prefix" || "$changed" == "$prefix/"* ]]; then
        project_for_event="${event_projects[$i]}"
        break
      fi
    done

    # Some fswatch builds report a symlinked path below projects/ even when the
    # resolved target was supplied. Keep that form scoped to a valid project.
    if [[ -z "$project_for_event" && "$changed" == "$ROOT/projects/"* ]]; then
      relative="${changed#"$ROOT/projects/"}"
      project_for_event="${relative%%/*}"
    fi

    case "$project_for_event" in
      ''|'.'|'..'|*[!A-Za-z0-9._:-]*) continue ;;
    esac
    [[ -n "$PROJECT_FILTER" && "$project_for_event" != "$PROJECT_FILTER" ]] && continue
    [[ -d "$ROOT/projects/$project_for_event" ]] || continue
    : > "$EVENT_DIR/project.$project_for_event"
  done < "$EVENT_FIFO" &
  FSWATCH_READER_PID=$!

  "$FSWATCH_BIN" -r -l 0.5 "${watch_paths[@]}" \
    > "$EVENT_FIFO" 2>>"$ROOT/logs/wiki-watch.log" &
  FSWATCH_PID=$!
}

# ── one-shot rebuild all ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--rebuild-all" ]]; then
  echo "[wiki-watch] one-shot rebuild of all projects..."
  while IFS= read -r p; do rebuild "$p"; done < <(projects_to_watch "")
  echo "[wiki-watch] done."
  exit 0
fi

PROJECT_FILTER="${1:-}"

# ── fswatch mode (preferred) ──────────────────────────────────────────────────
if [[ -z "$FSWATCH_BIN" ]] && command -v fswatch >/dev/null 2>&1; then
  FSWATCH_BIN="$(command -v fswatch)"
fi

if [[ -n "$FSWATCH_BIN" && "${SPIN_WIKI_WATCH_FORCE_POLLING:-0}" != "1" ]]; then
  echo "[wiki-watch] using fswatch (PID $$)"

  # One startup reconciliation repairs missing or stale indexes. Steady-state
  # content changes are event-driven; only the cheap link set is polled.
  reconcile_projects || true
  project_set="$(project_set_signature)"

  EVENT_DIR="$(mktemp -d "$ROOT/org/ceo/runs/.wiki-watch-events.XXXXXX")" || {
    echo "[wiki-watch] could not create event directory" >&2
    exit 1
  }
  SKIP_RE='/(\.git|node_modules|\.next|dist|build|out|\.turbo|coverage|__pycache__|\.cache|vendor|target|venv|\.venv|cache)(/|$)|\.(min\.(js|css)|map)$|/(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|poetry\.lock)$'
  start_fswatch || exit 1

  last_project_set_check="$(date +%s)"
  while true; do
    if [[ -f "$STOP" ]]; then
      echo "[wiki-watch] STOP flag — exiting." >&2
      rm -f "$STOP"
      exit 0
    fi

    now="$(date +%s)"
    if (( now - last_project_set_check >= INTERVAL )); then
      current_project_set="$(project_set_signature)"
      if [[ "$current_project_set" != "$project_set" ]]; then
        rebuild_project_set_changes "$project_set" "$current_project_set" || true
        project_set="$current_project_set"
        start_fswatch || exit 1
      elif [[ -n "$FSWATCH_PID" ]] && ! kill -0 "$FSWATCH_PID" 2>/dev/null; then
        echo "[wiki-watch] fswatch exited; restarting." >&2
        start_fswatch || exit 1
      fi
      last_project_set_check="$now"
    fi

    for marker in "$EVENT_DIR"/project.*; do
      [[ -f "$marker" ]] || continue
      if (( now - $(file_mtime "$marker") >= DEBOUNCE )); then
        project="${marker##*/project.}"
        rm -f "$marker"
        [[ -d "$ROOT/projects/$project" ]] && rebuild "$project" || true
      fi
    done
    sleep 1
  done

# ── polling fallback ──────────────────────────────────────────────────────────
else
  echo "[wiki-watch] fswatch not found — using polling (${INTERVAL}s interval)"
  echo "[wiki-watch] Install fswatch for instant rebuilds: brew install fswatch"

  reconcile_projects || true

  while true; do
    [[ -f "$STOP" ]] && { echo "[wiki-watch] STOP flag — exiting." >&2; rm -f "$STOP"; exit 0; }
    sleep "$INTERVAL"
    reconcile_projects || true
  done
fi
