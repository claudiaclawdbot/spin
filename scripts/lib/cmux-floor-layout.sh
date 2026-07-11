#!/usr/bin/env bash
# Helpers for SPIN's cmux floor layout. Callers must source spin-runtime.sh first.

spin_cmux_list_workspaces_json() {
  CMUX_QUIET=1 spin_cmd cmux --json list-workspaces 2>/dev/null || true
}

spin_cmux_workspace_ref_context() {
  local want="$1" json
  [[ -n "$want" ]] || return 1
  json="$(spin_cmux_list_workspaces_json)"
  [[ -n "$json" ]] || return 1
  printf '%s\n' "$json" | node -e '
const fs = require("fs");
const wanted = process.argv[1];
let payload;
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
for (const ws of payload.workspaces || []) {
  const refs = [ws.ref, ws.workspace_ref, ws.workspace, ws.id, ws.workspace_id].filter(Boolean).map(String);
  if (!refs.includes(wanted)) continue;
  const title = ws.title || ws.name || ws.custom_title || "";
  const cwd = ws.current_directory || ws.cwd || ws.path || "";
  console.log(JSON.stringify({ title, cwd }));
  process.exit(0);
}
process.exit(1);
' "$want" 2>/dev/null
}

spin_cmux_workspace_context_matches() {
  local workspace="$1" title="$2" cwd="${3:-}" ctx
  [[ -n "$workspace" && -n "$title" ]] || return 1
  ctx="$(spin_cmux_workspace_ref_context "$workspace")" || return 1
  printf '%s\n' "$ctx" | node -e '
const fs = require("fs");
const wantedTitle = process.argv[1];
const wantedCwd = process.argv[2] || "";
let ctx;
try { ctx = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
if ((ctx.title || "") !== wantedTitle) process.exit(1);
if (wantedCwd && (ctx.cwd || "") !== wantedCwd) process.exit(1);
' "$title" "$cwd" 2>/dev/null
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

spin_cmux_workspace_ref_by_context() {
  local title="$1" cwd="${2:-}" json ref
  json="$(spin_cmux_list_workspaces_json)"
  if [[ -n "$json" ]]; then
    ref="$(printf '%s\n' "$json" | node -e '
const fs = require("fs");
const [wantedTitle, wantedCwd] = process.argv.slice(1);
let payload;
try { payload = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
for (const ws of payload.workspaces || []) {
  const title = ws.title || ws.name || ws.custom_title || "";
  const cwd = ws.current_directory || ws.cwd || ws.path || "";
  const ref = ws.ref || ws.workspace_ref || ws.workspace || ws.id || ws.workspace_id || "";
  if (title === wantedTitle && ref && (!wantedCwd || cwd === wantedCwd)) {
    console.log(ref);
    process.exit(0);
  }
}
process.exit(1);
' "$title" "$cwd" 2>/dev/null || true)"
    [[ -n "$ref" ]] && { printf '%s\n' "$ref"; return 0; }
  fi

  [[ -z "$cwd" ]] && spin_cmux_workspace_ref_by_name "$title"
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

spin_cmux_floor_marker_value() {
  local target="$1" key="$2" marker
  marker="$(spin_cmux_floor_marker_path "$target")"
  [[ -f "$marker" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$marker" 2>/dev/null
}

spin_cmux_normalize_tty() {
  local tty_name="$1"
  tty_name="${tty_name#/dev/}"
  printf '%s\n' "$tty_name"
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
  local target="$1" tty_name="${2:-}" marker_tty
  if [[ -n "$target" ]]; then
    spin_cmux_floor_marker_running "$target" || return 1
    [[ -z "$tty_name" ]] && return 0
    marker_tty="$(spin_cmux_floor_marker_value "$target" tty 2>/dev/null || true)"
    if [[ -n "$marker_tty" ]] &&
      [[ "$(spin_cmux_normalize_tty "$marker_tty")" == "$(spin_cmux_normalize_tty "$tty_name")" ]]; then
      return 0
    fi
    return 1
  fi
  [[ -n "$tty_name" ]] && spin_cmux_floor_process_running_on_tty "$tty_name"
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

spin_cmux_surface_tty() {
  local workspace="$1" surface="$2"
  [[ -n "$workspace" && -n "$surface" ]] || return 1
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null | awk -v sf="$surface" '
    index($0, sf) && /tty=/ {
      match($0, /tty=[^[:space:]]+/)
      if (RSTART) { print substr($0, RSTART + 4, RLENGTH - 4); exit }
    }
  '
}

spin_cmux_floor_screen_active() {
  local workspace="$1" surface="$2"
  [[ -n "$workspace" && -n "$surface" ]] || return 1
  CMUX_QUIET=1 spin_cmd cmux read-screen --workspace "$workspace" --surface "$surface" 2>/dev/null \
    | tail -24 \
    | grep -Eiq '(^|[[:space:]])(omp|model:|WORKSPACE CEO|orchestrator|SPIN delegation|IDLE until you type)'
}

spin_cmux_terminal_has_agent_title() {
  local workspace="$1"
  [[ -n "$workspace" ]] || return 1
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null \
    | grep -Eq '\[terminal\].*"π: '
}

spin_cmux_terminal_title_matches_target() {
  local workspace="$1" target="$2"
  [[ -n "$workspace" && -n "$target" ]] || return 1
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null | awk -v target="$target" '
    /\[terminal\]/ {
      if (target == "ceo") {
        if (index($0, "\"π: .omp-ceo\"") || index($0, "WORKSPACE CEO")) found=1
      } else {
        if (index($0, "\"π: " target "\"") || index($0, target "  ·  omp")) found=1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

spin_cmux_floor_active_in_workspace() {
  local workspace="$1" target="$2" surface tty_name
  [[ -n "$workspace" && -n "$target" ]] || return 1
  surface="$(spin_cmux_terminal_surface "$workspace")"
  [[ -n "$surface" ]] || return 1
  tty_name="$(spin_cmux_surface_tty "$workspace" "$surface")"
  if [[ -n "$tty_name" ]]; then
    spin_cmux_floor_running "$target" "$tty_name"
    return
  fi
  spin_cmux_terminal_title_matches_target "$workspace" "$target" &&
    spin_cmux_floor_screen_active "$workspace" "$surface"
}

spin_cmux_start_floor_in_workspace() {
  local workspace="$1" target="$2" surface tty_name
  [[ -n "$workspace" && -n "$target" ]] || return 1
  surface="$(spin_cmux_terminal_surface "$workspace")"
  [[ -n "$surface" ]] || return 1
  spin_cmux_floor_active_in_workspace "$workspace" "$target" && return 0
  tty_name="$(spin_cmux_surface_tty "$workspace" "$surface")"
  # A restored surface can temporarily point at another floor's live PTY. Do
  # not type a launch command into that agent; let ensure_floor replace it.
  if [[ -n "$tty_name" ]] && spin_cmux_floor_process_running_on_tty "$tty_name"; then
    return 1
  fi
  if spin_cmux_terminal_has_agent_title "$workspace" && ! spin_cmux_terminal_title_matches_target "$workspace" "$target"; then
    return 1
  fi
  CMUX_QUIET=1 spin_cmd cmux send --workspace "$workspace" --surface "$surface" \
    "bash '$ROOT/scripts/cmux-floor.sh' '$target'" >/dev/null 2>&1 || return 1
  CMUX_QUIET=1 spin_cmd cmux send-key --workspace "$workspace" --surface "$surface" enter >/dev/null 2>&1
}

spin_cmux_saved_workspace_ref() {
  local target="$1"
  [[ -f "$ROOT/org/OMP_HARNESS.json" ]] || return 1
  node -e '
const fs = require("fs");
const [file, target] = process.argv.slice(1);
try {
  const h = JSON.parse(fs.readFileSync(file, "utf8"));
  if (target === "ceo") {
    if (h.workspace_ceo && h.workspace_ceo.cmux_workspace) console.log(h.workspace_ceo.cmux_workspace);
  } else if (h.projects && h.projects[target] && h.projects[target].cmux_workspace) {
    console.log(h.projects[target].cmux_workspace);
  }
} catch {}
' "$ROOT/org/OMP_HARNESS.json" "$target" 2>/dev/null
}

spin_cmux_managed_floor_ttys() {
  local target workspace surface tty_name
  for target in ceo $(spin_cmux_project_floor_ids); do
    workspace="$(spin_cmux_saved_workspace_ref "$target" 2>/dev/null || true)"
    [[ -n "$workspace" ]] || continue
    surface="$(spin_cmux_terminal_surface "$workspace")"
    [[ -n "$surface" ]] || continue
    tty_name="$(spin_cmux_surface_tty "$workspace" "$surface")"
    [[ -n "$tty_name" ]] || continue
    printf '%s\t%s\t%s\n' "$(spin_cmux_normalize_tty "$tty_name")" "$target" "$workspace"
  done
}

spin_cmux_duplicate_managed_floor_ttys() {
  spin_cmux_managed_floor_ttys | awk -F '\t' '
    seen[$1] { print $1 "\t" owner[$1] "\t" $2 }
    !seen[$1] { seen[$1]=1; owner[$1]=$2 }
  '
}

spin_cmux_remember_workspace_ref() {
  local target="$1" workspace="$2"
  [[ -n "$target" && -n "$workspace" && -f "$ROOT/org/OMP_HARNESS.json" ]] || return 1
  node -e '
const fs = require("fs");
const [file, target, workspace] = process.argv.slice(1);
const h = JSON.parse(fs.readFileSync(file, "utf8"));
if (target === "ceo") {
  h.workspace_ceo = h.workspace_ceo || {};
  h.workspace_ceo.cmux_workspace = workspace;
} else {
  h.projects = h.projects || {};
  h.projects[target] = h.projects[target] || {};
  h.projects[target].cmux_workspace = workspace;
}

const tmp = `${file}.tmp.${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(h, null, 2) + "\n");
fs.renameSync(tmp, file);
' "$ROOT/org/OMP_HARNESS.json" "$target" "$workspace" 2>/dev/null
}

spin_cmux_stale_managed_workspace_refs() {
  local json
  json="$(spin_cmux_list_workspaces_json)"
  [[ -n "$json" && -f "$ROOT/org/OMP_HARNESS.json" ]] || return 0
  printf '%s\n' "$json" | node -e '
const fs = require("fs");
const path = require("path");
const [root, harnessFile] = process.argv.slice(1);
let live;
let harness;
try {
  live = JSON.parse(fs.readFileSync(0, "utf8"));
  harness = JSON.parse(fs.readFileSync(harnessFile, "utf8"));
} catch {
  process.exit(0);
}
const canonical = new Map();
for (const [id, project] of Object.entries(harness.projects || {})) {
  if (project && project.cmux_workspace) canonical.set(id, String(project.cmux_workspace));
}
const coordinatorRef = String(harness.workspace_ceo?.cmux_workspace || "");
for (const workspace of live.workspaces || []) {
  const title = String(workspace.title || workspace.name || workspace.custom_title || "");
  const ref = String(workspace.ref || workspace.workspace_ref || workspace.workspace || workspace.id || workspace.workspace_id || "");
  const cwd = String(workspace.current_directory || workspace.cwd || workspace.path || "");
  if (title === "SPIN Coordinator") {
    if (coordinatorRef && ref && ref !== coordinatorRef) console.log(ref);
    continue;
  }
  const keep = canonical.get(title);
  if (!keep || !ref || ref === keep || !cwd) continue;
  const resolved = path.resolve(cwd);
  const managedPaths = [
    path.resolve(root, "projects", title),
    path.resolve(root, "org", "projects", title),
  ];
  if (managedPaths.includes(resolved)) console.log(ref);
}
' "$ROOT" "$ROOT/org/OMP_HARNESS.json" 2>/dev/null
}

spin_cmux_prune_stale_managed_workspaces() {
  local refs ref
  refs="$(spin_cmux_stale_managed_workspace_refs)"
  [[ -n "$refs" ]] || return 0
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if CMUX_QUIET=1 spin_cmd cmux close-workspace --workspace "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
    fi
  done <<< "$refs"
}

spin_cmux_project_floor_ids() {
  node -e '
const fs = require("fs");
const [harnessFile, stateFile] = process.argv.slice(1);
const ids = new Set();
const statusById = new Map();
const isActive = status => {
  const value = String(status || "").toLowerCase();
  return value && !/^(candidate|inactive|complete(?:d)?|archived|paused|disabled)(?:$|-)/.test(value);
};
try {
  const s = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  for (const p of s.project_orchestrators || []) {
    const id = p.project || p.id;
    if (!id) continue;
    const status = String(p.status || "");
    statusById.set(id, status);
    if (isActive(status)) ids.add(id);
  }
} catch {}
try {
  const h = JSON.parse(fs.readFileSync(harnessFile, "utf8"));
  for (const [id, p] of Object.entries(h.projects || {})) {
    const status = statusById.get(id);
    if (p.cmux_workspace && (!status || isActive(status))) ids.add(id);
  }
} catch {}
for (const id of ids) if (id) console.log(id);
' "$ROOT/org/OMP_HARNESS.json" "$ROOT/org/state.json" 2>/dev/null
}

spin_cmux_project_cwd() {
  local project_id="$1" cwd
  # Ghostty creates restored surfaces on the main thread. Starting one at a
  # symlink into a protected folder can block the entire cmux UI; the floor
  # launcher changes into the real project directory after the shell starts.
  cwd="$ROOT/org/projects/$project_id"
  [[ -d "$cwd" ]] || cwd="$ROOT"
  printf '%s\n' "$cwd"
}

spin_cmux_wait_for_workspace_context() {
  local title="$1" cwd="${2:-}" attempts delay workspace
  attempts="${SPIN_CMUX_ASYNC_CREATE_RETRIES:-10}"
  delay="${SPIN_CMUX_ASYNC_CREATE_DELAY:-0.5}"
  case "$attempts" in ''|*[!0-9]*) attempts=10 ;; esac
  while (( attempts > 0 )); do
    workspace="$(spin_cmux_workspace_ref_by_context "$title" "$cwd")"
    if [[ -n "$workspace" ]]; then
      printf '%s\n' "$workspace"
      return 0
    fi
    attempts=$((attempts - 1))
    (( attempts > 0 )) && sleep "$delay"
  done
  return 1
}

spin_cmux_ensure_floor() {
  local target="$1" title="$2" cwd="$3" focus="${4:-false}" workspace="" match_cwd="" created=0
  [[ -n "$target" && -n "$title" && -n "$cwd" ]] || return 1
  [[ "$target" != "ceo" ]] && match_cwd="$cwd"

  workspace="$(spin_cmux_saved_workspace_ref "$target")"
  if [[ -n "$workspace" ]] && ! spin_cmux_workspace_context_matches "$workspace" "$title" "$match_cwd"; then
    workspace=""
  fi
  [[ -n "$workspace" ]] || workspace="$(spin_cmux_workspace_ref_by_context "$title" "$match_cwd")"
  if [[ -z "$workspace" ]]; then
    workspace="$(CMUX_QUIET=1 spin_cmd cmux new-workspace --name "$title" --cwd "$cwd" \
      --command "bash '$ROOT/scripts/cmux-floor.sh' '$target'" --focus "$focus" 2>/dev/null \
      | grep -oE 'workspace:[^[:space:]]+' | head -1)"
    [[ -n "$workspace" ]] || workspace="$(spin_cmux_wait_for_workspace_context "$title" "$match_cwd")"
    [[ -n "$workspace" ]] && created=1
  fi
  [[ -n "$workspace" ]] || return 1
  spin_cmux_remember_workspace_ref "$target" "$workspace" >/dev/null 2>&1 || true
  if [[ "$created" != 1 ]] && ! spin_cmux_start_floor_in_workspace "$workspace" "$target" >/dev/null 2>&1; then
    workspace="$(CMUX_QUIET=1 spin_cmd cmux new-workspace --name "$title" --cwd "$cwd" \
      --command "bash '$ROOT/scripts/cmux-floor.sh' '$target'" --focus "$focus" 2>/dev/null \
      | grep -oE 'workspace:[^[:space:]]+' | head -1)"
    [[ -n "$workspace" ]] || workspace="$(spin_cmux_wait_for_workspace_context "$title" "$match_cwd")"
    [[ -n "$workspace" ]] || return 1
    spin_cmux_remember_workspace_ref "$target" "$workspace" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$workspace"
}

spin_cmux_ensure_coordinator_floor() {
  spin_cmux_ensure_floor ceo "SPIN Coordinator" "$HOME" "${1:-true}"
}

spin_cmux_ensure_project_floor() {
  local project_id="$1" focus="${2:-false}" cwd
  [[ -n "$project_id" ]] || return 1
  cwd="$(spin_cmux_project_cwd "$project_id")"
  spin_cmux_ensure_floor "$project_id" "$project_id" "$cwd" "$focus"
}

spin_cmux_project_board_path() {
  local project_id="$1"
  printf '%s\n' "$ROOT/org/projects/$project_id/FLOOR.md"
}

spin_cmux_coordinator_board_path() {
  printf '%s\n' "$ROOT/org/ceo/WORKSPACE_STATUS.md"
}

spin_cmux_coordinator_board_visible() {
  local workspace="$1"
  [[ -n "$workspace" ]] || return 1
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null \
    | grep -F '[markdown] "WORKSPACE_STATUS.md"' >/dev/null 2>&1
}

spin_cmux_stale_coordinator_board_surfaces() {
  local workspace="$1"
  [[ -n "$workspace" ]] || return 0
  CMUX_QUIET=1 spin_cmd cmux tree --workspace "$workspace" 2>/dev/null | awk '
    /surface:[0-9]+/ && /\[markdown\] "FLOOR\.md"/ {
      match($0, /surface:[0-9]+/)
      if (RSTART) print substr($0, RSTART, RLENGTH)
    }
  '
}

spin_cmux_open_coordinator_board() {
  local workspace="$1" source_surface="${2:-}" board stale_surface
  [[ -n "$workspace" ]] || return 1
  board="$(spin_cmux_coordinator_board_path)"
  [[ -f "$board" ]] || return 1

  while IFS= read -r stale_surface; do
    [[ -n "$stale_surface" ]] || continue
    CMUX_QUIET=1 spin_cmd cmux close-surface --workspace "$workspace" \
      --surface "$stale_surface" >/dev/null 2>&1 || true
  done < <(spin_cmux_stale_coordinator_board_surfaces "$workspace")

  spin_cmux_coordinator_board_visible "$workspace" && return 0

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

spin_cmux_reconcile_managed_floors() {
  local coordinator id workspace surface
  coordinator="$(spin_cmux_ensure_coordinator_floor false 2>/dev/null || true)"
  if [[ -n "$coordinator" ]]; then
    spin_cmux_open_coordinator_board "$coordinator" >/dev/null 2>&1 || true
  fi

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    workspace="$(spin_cmux_ensure_project_floor "$id" false 2>/dev/null || true)"
    [[ -n "$workspace" ]] || continue
    surface="$(spin_cmux_terminal_surface "$workspace")"
    spin_cmux_open_project_board "$workspace" "$id" "$surface" >/dev/null 2>&1 || true
  done < <(spin_cmux_project_floor_ids)

  spin_cmux_prune_stale_managed_workspaces >/dev/null 2>&1 || true
  [[ -n "$coordinator" ]]
}
