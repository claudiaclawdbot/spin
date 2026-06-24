#!/usr/bin/env bash
# Helpers for SPIN's cmux floor layout. Callers must source spin-runtime.sh first.

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
