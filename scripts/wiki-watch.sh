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
LOCK="$ROOT/org/ceo/runs/.wiki-watch.lock"
STOP="$ROOT/org/ceo/runs/WIKI_WATCH_STOP"
INTERVAL=8   # poll interval in seconds (fallback mode)
DEBOUNCE=3   # seconds to wait after last change before rebuilding

mkdir -p "$ROOT/org/ceo/runs" "$ROOT/logs"

# ── singleton lock ────────────────────────────────────────────────────────────
if [[ "${1:-}" != "--rebuild-all" ]]; then
  while ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; do
    other="$(cat "$LOCK" 2>/dev/null)"
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
      echo "[wiki-watch] already running (PID $other); exiting." >&2; exit 0
    fi
    rm -f "$LOCK"
  done
  trap 'rm -f "$LOCK"' EXIT
  trap 'rm -f "$LOCK"; exit 0' INT TERM
  rm -f "$STOP"
fi

# ── project discovery ─────────────────────────────────────────────────────────
projects_to_watch() {
  if [[ -n "${1:-}" && "${1:-}" != "--rebuild-all" ]]; then
    echo "$1"
  else
    find -L "$ROOT/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
      | xargs -I{} basename {}
  fi
}

# ── rebuild one project ───────────────────────────────────────────────────────
rebuild() {
  local project="$1"
  bash "$SCRIPT_DIR/wiki-build.sh" "$project" 2>&1 \
    | tee -a "$ROOT/logs/wiki-watch.log"
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
if command -v fswatch &>/dev/null; then
  echo "[wiki-watch] using fswatch (PID $$)"

  # Build watch paths
  watch_paths=()
  while IFS= read -r p; do
    [[ -d "$ROOT/projects/$p" ]] && watch_paths+=("$ROOT/projects/$p")
  done < <(projects_to_watch "$PROJECT_FILTER")

  [[ ${#watch_paths[@]} -eq 0 ]] && { echo "[wiki-watch] no project dirs found; exiting." >&2; exit 0; }

  # Initial build
  for p in "${watch_paths[@]}"; do rebuild "$(basename "$p")"; done

  # Map path → project for fast lookup
  declare -A path_to_project
  for wp in "${watch_paths[@]}"; do
    path_to_project["$wp"]="$(basename "$wp")"
  done

  declare -A pending   # project → epoch of last change
  SKIP_RE='\.(git|next|node_modules|dist|build|out|cache)|\.min\.(js|css)|package-lock\.json'

  fswatch -r -l 0.5 "${watch_paths[@]}" | while IFS= read -r changed; do
    [[ "$changed" =~ $SKIP_RE ]] && continue
    [[ -f "$STOP" ]] && exit 0

    # Find which project this file belongs to
    for wp in "${watch_paths[@]}"; do
      if [[ "$changed" == "$wp"* ]]; then
        project="${path_to_project[$wp]}"
        pending["$project"]="$(date +%s)"
        break
      fi
    done
  done &
  FSWATCH_PID=$!

  # Debounce loop — flush pending rebuilds
  while true; do
    [[ -f "$STOP" ]] && { echo "[wiki-watch] STOP flag — exiting." >&2; rm -f "$STOP"; kill $FSWATCH_PID 2>/dev/null; exit 0; }
    now="$(date +%s)"
    for project in "${!pending[@]}"; do
      last="${pending[$project]}"
      if (( now - last >= DEBOUNCE )); then
        rebuild "$project"
        unset "pending[$project]"
      fi
    done
    sleep 1
  done

# ── polling fallback ──────────────────────────────────────────────────────────
else
  echo "[wiki-watch] fswatch not found — using polling (${INTERVAL}s interval)"
  echo "[wiki-watch] Install fswatch for instant rebuilds: brew install fswatch"

  # Initial build
  while IFS= read -r p; do
    [[ -d "$ROOT/projects/$p" ]] || continue
    rebuild "$p"
  done < <(projects_to_watch "$PROJECT_FILTER")

  while true; do
    [[ -f "$STOP" ]] && { echo "[wiki-watch] STOP flag — exiting." >&2; rm -f "$STOP"; exit 0; }
    sleep "$INTERVAL"

    while IFS= read -r p; do
      [[ -d "$ROOT/projects/$p" ]] || continue
      wiki="$ROOT/org/wiki/projects/$p.md"
      # Count files newer than the wiki (or if wiki doesn't exist)
      changed="$(find -L "$ROOT/projects/$p" \
        -newer "${wiki:-/dev/null}" \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.next/*" \
        -not -name "package-lock.json" \
        2>/dev/null | wc -l)"
      if (( changed > 0 )); then
        rebuild "$p"
      fi
    done < <(projects_to_watch "$PROJECT_FILTER")
  done
fi
