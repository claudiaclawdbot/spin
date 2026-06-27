#!/usr/bin/env bash
# Helpers for SPIN's cmux floor layout. Callers must source spin-runtime.sh first.

spin_cmux_list_workspaces_json() {
  CMUX_QUIET=1 spin_cmd cmux --json list-workspaces 2>/dev/null || true
}

spin_cmux_workspace_ref_by_name() {
  local name="$1" json ref
  json="$(spin_cmux_list_workspaces_json)"
  if [[ -n "$json" ]]; then
    ref="$(printf '%s\n' "$json" | node -e '
const fs = require("fs");
const wanted = process.argv[1];
let payload;
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
for (const ws of payload.workspaces || []) {
  const title = ws.title || ws.name || "";
  const ref = ws.ref || ws.workspace_ref || ws.workspace || ws.id || ws.workspace_id || "";
  if (title === wanted && ref) {
    console.log(ref);
    process.exit(0);
  }
}
process.exit(1);
' "$name" 2>/dev/null || true)"
    [[ -n "$ref" ]] && { printf '%s\n' "$ref"; return 0; }
  fi

  CMUX_QUIET=1 spin_cmd cmux list-workspaces 2>/dev/null | awk -v want="$name" '
    {
      line=$0
      sub(/^[*[:space:]]+/, "", line)
      if (line !~ /^workspace:[^[:space:]]+[[:space:]]+/) next
      ref=line
      sub(/[[:space:]].*$/, "", ref)
      label=line
      sub(/^workspace:[^[:space:]]+[[:space:]]+/, "", label)
      sub(/[[:space:]]+\[[^]]+\]$/, "", label)
      if (label == want) { print ref; exit }
    }
  '
}

spin_cmux_workspace_ref_exists() {
  local want="$1" json
  [[ -n "$want" ]] || return 1
  json="$(spin_cmux_list_workspaces_json)"
  if [[ -n "$json" ]]; then
    printf '%s\n' "$json" | node -e '
const fs = require("fs");
const wanted = process.argv[1];
let payload;
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
for (const ws of payload.workspaces || []) {
  const refs = [ws.ref, ws.workspace_ref, ws.workspace, ws.id, ws.workspace_id].filter(Boolean).map(String);
  if (refs.includes(wanted)) process.exit(0);
}
process.exit(1);
' "$want" 2>/dev/null && return 0
  fi

  CMUX_QUIET=1 spin_cmd cmux list-workspaces 2>/dev/null | awk -v want="$want" '
    {
      line=$0
      sub(/^[*[:space:]]+/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (parts[1] == want) found=1
    }
    END { exit found ? 0 : 1 }
  '
}

spin_cmux_floor_marker_key() {
  local key
  key="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | sed 's/^\.*//;s/\.*$//')"
  [[ -n "$key" ]] || key="floor"
  printf '%s\n' "$key"
}

spin_cmux_floor_marker_path() {
  local key
  key="$(spin_cmux_floor_marker_key "$1")"
  printf '%s\n' "$ROOT/org/ceo/runs/floors/$key.pid"
}

spin_cmux_write_floor_marker() {
  local target="$1" title="${2:-}" dir="${3:-}" marker tmp tty_name
  marker="$(spin_cmux_floor_marker_path "$target")"
  mkdir -p "$(dirname "$marker")"
  tty_name="$(tty 2>/dev/null || true)"
  tmp="$marker.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'target=%s\n' "$target"
    printf 'title=%s\n' "$title"
    printf 'cwd=%s\n' "$dir"
    printf 'tty=%s\n' "$tty_name"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$marker"
}

spin_cmux_floor_marker_running() {
  local target="$1" marker pid cmd
  marker="$(spin_cmux_floor_marker_path "$target")"
  [[ -f "$marker" ]] || return 1
  pid="$(awk -F= '$1=="pid"{print $2; exit}' "$marker" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$cmd" ]] || return 1
  printf '%s\n' "$cmd" | grep -Eqi '(omp|spin-agent|pi-coding-agent|bun|node).*(--config|spin-omp-config)|cmux-floor\.sh'
}

spin_cmux_floor_process_running_on_tty() {
  local tty_name="$1"
  [[ -n "$tty_name" ]] || return 1
  ps -t "$tty_name" -o command= 2>/dev/null \
    | grep -Eqi '(omp|spin-agent|pi-coding-agent|bun|node).*(--config|spin-omp-config)|cmux-floor\.sh'
}

spin_cmux_floor_running() {
  local target="$1" tty_name="${2:-}"
  spin_cmux_floor_marker_running "$target" && return 0
  spin_cmux_floor_process_running_on_tty "$tty_name"
}

spin_cmux_terminal_surface() {
  local workspace="$1"
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null | awk '
    /surface:[0-9]+/ && /\[terminal\]/ {
      match($0, /surface:[0-9]+/)
      ref=substr($0, RSTART, RLENGTH)
      if ($0 ~ /\[selected\]/) { print ref; found=1; exit }
      if (!first) first=ref
    }
    END { if (!found && first) print first }
  '
}

spin_cmux_project_board_path() {
  local project_id="$1"
  printf '%s\n' "$ROOT/org/projects/$project_id/FLOOR.md"
}

spin_cmux_ensure_project_board() {
  local project_id="$1" board project_dir
  project_dir="$ROOT/org/projects/$project_id"
  board="$project_dir/FLOOR.md"
  [[ -f "$board" ]] && return 0
  [[ -d "$project_dir" ]] || return 1
  cat > "$board" <<EOF
# $project_id — Floor Board

_Live at-a-glance board for this project's cmux floor. The status roll-up
daemon aggregates every project's board into \`org/ceo/WORKSPACE_STATUS.md\`._

Last updated: (never)

## Goal
Describe the win condition here.

## In progress
- (nothing yet)

## Recently done
- (nothing yet)

## Next
- (nothing yet)

## Waiting on human
- (nothing yet)
EOF
}

spin_cmux_project_board_visible() {
  local workspace="$1" board="$2" board_base
  board_base="$(basename "$board")"
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null \
    | grep -F -e "$board" -e "$board_base" >/dev/null 2>&1
}

spin_cmux_open_project_board() {
  local workspace="$1" project_id="$2" source_surface="${3:-}" board
  spin_cmux_ensure_project_board "$project_id" || return 1
  board="$(spin_cmux_project_board_path "$project_id")"
  spin_cmux_project_board_visible "$workspace" "$board" && return 0
  if [[ -z "$source_surface" ]]; then
    source_surface="$(spin_cmux_terminal_surface "$workspace")"
  fi
  if [[ -n "$source_surface" ]]; then
    CMUX_QUIET=1 spin_cmd cmux markdown open "$board" \
      --workspace "$workspace" --surface "$source_surface" \
      --direction right --focus false >/dev/null 2>&1
  else
    CMUX_QUIET=1 spin_cmd cmux markdown open "$board" \
      --workspace "$workspace" --direction right --focus false >/dev/null 2>&1
  fi
}
