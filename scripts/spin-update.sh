#!/usr/bin/env bash
# spin-update.sh - consumer-friendly SPIN upgrade command.
#
# Safety model:
#   - refuses to run with dirty tracked SPIN files;
#   - refuses to update while project jobs are running unless explicitly allowed;
#   - backs up local org state before changing code;
#   - pauses/restarts the driver if it was running;
#   - updates by fast-forward only, then reruns install.sh and migrations.
set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
cd "$ROOT"

CHECK_ONLY=0
DRY_RUN=0
NO_BACKUP=0
NO_FETCH="${SPIN_UPDATE_NO_FETCH:-0}"
NO_RESTART=0
ALLOW_RUNNING_JOBS=0
TARGET_REF="${SPIN_UPDATE_REF:-}"
RESUME_DRIVER=0
STOP_WAS_PRESENT=0

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_d=$'\e[2m'; c_o=$'\e[0m'

usage() {
  cat <<'EOF'
Usage: spin update [--check] [--dry-run] [--no-backup] [--no-fetch]
                   [--no-restart] [--allow-running-jobs] [--ref REF]

Updates this SPIN checkout safely:
  1. checks for local tracked edits and running jobs;
  2. backs up org/ and logs/ to .spin/backups/;
  3. pauses the driver if it is running;
  4. fast-forwards from the current branch upstream;
  5. reruns install.sh, migrations, and spin doctor;
  6. restarts the driver if it was running.

Common:
  spin update --check     show whether an update is available
  spin update --dry-run   show what would happen without changing files
EOF
}

say(){ printf '%s\n' "$*"; }
warn(){ printf '%s\n' "${c_y}!${c_o} $*" >&2; }
die(){ printf '%s\n' "${c_r}x${c_o} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    --no-fetch) NO_FETCH=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --allow-running-jobs) ALLOW_RUNNING_JOBS=1 ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref needs a value"
      TARGET_REF="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

require_git_repo() {
  command -v git >/dev/null 2>&1 || die "git is required for spin update"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "spin update needs a git checkout"
}

version_file() {
  [[ -f "$ROOT/VERSION" ]] && tr -d '[:space:]' < "$ROOT/VERSION" || printf 'unknown'
}

git_desc() {
  git describe --tags --always --dirty 2>/dev/null || printf 'unknown'
}

latest_tag() {
  git tag --sort=-v:refname 2>/dev/null | head -1
}

upstream_ref() {
  if [[ -n "$TARGET_REF" ]]; then
    printf '%s\n' "$TARGET_REF"
    return
  fi
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git rev-parse --abbrev-ref --symbolic-full-name '@{u}'
    return
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    printf 'origin/main\n'
    return
  fi
  die "no upstream branch found; pass --ref <branch-or-tag>"
}

remote_for_ref() {
  local ref="$1"
  if [[ "$ref" == */* ]]; then printf '%s\n' "${ref%%/*}"; else printf 'origin\n'; fi
}

fetch_updates() {
  local ref="$1" remote
  [[ "$NO_FETCH" == "1" ]] && { say "${c_d}fetch skipped (--no-fetch)${c_o}"; return; }
  remote="$(remote_for_ref "$ref")"
  say "Fetching latest SPIN refs from $remote..."
  git fetch --tags --prune "$remote"
}

target_commit() {
  local ref="$1"
  git rev-parse "$ref^{commit}" 2>/dev/null
}

tracked_dirty() {
  git status --porcelain --untracked-files=no
}

check_clean_tracked_files() {
  local dirty
  dirty="$(tracked_dirty)"
  [[ -z "$dirty" ]] && return
  say "$dirty" >&2
  die "tracked SPIN files have local edits. Commit/stash them first so update cannot overwrite your work."
}

running_driver_pid() {
  local lock="$ROOT/org/ceo/runs/.workspace-ceo-tick.lock" pid
  [[ -f "$lock" ]] || return 1
  pid="$(cat "$lock" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

running_jobs() {
  local pid_file pid job
  shopt -s nullglob
  for pid_file in "$ROOT"/org/jobs/*.pid; do
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      job="$(basename "$pid_file" .pid)"
      printf '%s pid=%s\n' "$job" "$pid"
    fi
  done
  shopt -u nullglob
}

check_no_running_jobs() {
  local jobs
  jobs="$(running_jobs)"
  [[ -z "$jobs" ]] && return
  if [[ "$ALLOW_RUNNING_JOBS" == "1" ]]; then
    warn "project jobs are still running; continuing because --allow-running-jobs was passed"
    say "$jobs"
    return
  fi
  say "$jobs" >&2
  die "project jobs are running. Wait for them to finish, or rerun with --allow-running-jobs if you accept that risk."
}

backup_state() {
  [[ "$NO_BACKUP" == "1" ]] && { say "${c_d}backup skipped (--no-backup)${c_o}"; return; }
  local ts dir archive paths=()
  ts="$(date -u +%Y%m%d-%H%M%S)"
  dir="$ROOT/.spin/backups"
  archive="$dir/spin-state-$ts.tgz"
  [[ -d "$ROOT/org" ]] && paths+=("org")
  [[ -d "$ROOT/logs" ]] && paths+=("logs")
  [[ ${#paths[@]} -gt 0 ]] || { say "No local state found to back up."; return; }
  mkdir -p "$dir"
  tar czf "$archive" "${paths[@]}"
  say "${c_g}backup:${c_o} $archive"
}

pause_driver_if_running() {
  local pid
  [[ -f "$ROOT/org/ceo/runs/STOP" ]] && STOP_WAS_PRESENT=1
  pid="$(running_driver_pid || true)"
  [[ -n "$pid" ]] || return
  RESUME_DRIVER=1
  say "Pausing SPIN driver (pid $pid)..."
  touch "$ROOT/org/ceo/runs/STOP"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
}

resume_driver_if_needed() {
  [[ "$RESUME_DRIVER" == "1" ]] || return
  [[ "$NO_RESTART" == "1" ]] && { warn "driver was running before update; left paused because --no-restart was passed"; RESUME_DRIVER=0; return; }
  [[ "$STOP_WAS_PRESENT" == "1" ]] && { warn "STOP file existed before update; leaving SPIN paused"; RESUME_DRIVER=0; return; }
  say "Restarting SPIN driver..."
  rm -f "$ROOT/org/ceo/runs/STOP"
  bash "$ROOT/scripts/spin" start >/dev/null || warn "could not restart driver; run: spin start"
  RESUME_DRIVER=0
}

cleanup() {
  if [[ "$RESUME_DRIVER" == "1" && "$DRY_RUN" != "1" ]]; then
    resume_driver_if_needed || true
  fi
}
trap cleanup EXIT

run_install_and_checks() {
  say "Running installer refresh..."
  bash "$ROOT/install.sh"
  say "Running spin doctor..."
  bash "$ROOT/scripts/spin" doctor || warn "spin doctor reported issues; see output above"
}

print_status() {
  local ref="$1" head target tag
  head="$(git rev-parse HEAD)"
  tag="$(latest_tag || true)"
  say "SPIN version file: $(version_file)"
  say "Current checkout:  $(git_desc) ($head)"
  [[ -n "$tag" ]] && say "Newest local tag:  $tag"
  if ! target="$(target_commit "$ref")"; then
    warn "cannot resolve update target: $ref"
    if [[ "$CHECK_ONLY" == "1" && "$NO_FETCH" == "1" ]]; then
      say "${c_d}Target unavailable in this checkout; rerun without --no-fetch to fetch update refs.${c_o}"
      return
    fi
    die "cannot resolve update target: $ref"
  fi
  say "Update target:     $ref ($target)"
  if [[ "$head" == "$target" ]]; then
    say "${c_g}Up to date.${c_o}"
  elif git merge-base --is-ancestor "$head" "$target"; then
    say "${c_y}Update available.${c_o}"
  elif git merge-base --is-ancestor "$target" "$head"; then
    say "${c_d}Local checkout is ahead of $ref; no fast-forward update needed.${c_o}"
  else
    say "${c_y}Local checkout has diverged from $ref; automatic update will refuse.${c_o}"
  fi
}

perform_update() {
  local ref="$1" head target
  head="$(git rev-parse HEAD)"
  target="$(target_commit "$ref")" || die "cannot resolve update target: $ref"
  if [[ "$head" == "$target" ]]; then
    say "${c_g}Already up to date.${c_o}"
  elif git merge-base --is-ancestor "$head" "$target"; then
    say "Fast-forwarding to $ref..."
    git merge --ff-only "$target"
  elif git merge-base --is-ancestor "$target" "$head"; then
    say "${c_d}Local checkout is ahead of $ref; skipping git update.${c_o}"
  else
    die "local checkout has diverged from $ref; resolve manually before using spin update"
  fi
}

require_git_repo
REF="$(upstream_ref)"
say "${c_g}SPIN update${c_o}  root: $ROOT"
say "Target: $REF"

fetch_updates "$REF"
print_status "$REF"

if [[ "$CHECK_ONLY" == "1" ]]; then
  exit 0
fi

check_clean_tracked_files
check_no_running_jobs

if [[ "$DRY_RUN" == "1" ]]; then
  say
  say "Dry run only. Would back up state, pause the driver if running, fast-forward, run install.sh, run migrations, and restart if needed."
  exit 0
fi

backup_state
pause_driver_if_running
perform_update "$REF"
run_install_and_checks
resume_driver_if_needed

say "${c_g}SPIN update complete.${c_o}"
