#!/usr/bin/env bash
# Resolve a registered project's code directory to one canonical, existing path.
# Explicit harness/state configuration wins; managed projects then fall back to
# projects/<id>. The workspace maintenance lane intentionally owns SPIN itself.

spin_project_root() {
  local project_id="${1:-}"
  case "$project_id" in
    ''|'.'|'..'|*[!A-Za-z0-9._:-]*)
      printf 'invalid project id: %s\n' "$project_id" >&2
      return 2
      ;;
  esac

  node - "$ROOT" "$project_id" <<'NODE'
const fs = require('fs');
const path = require('path');

const [rootInput, projectId] = process.argv.slice(2);
const root = fs.realpathSync(rootInput);
const readJSON = file => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch { return {}; }
};

const harness = readJSON(path.join(root, 'org', 'OMP_HARNESS.json'));
const state = readJSON(path.join(root, 'org', 'state.json'));
const stateProject = (state.project_orchestrators || []).find(entry =>
  entry && (entry.project === projectId || entry.id === projectId));
const configured = [
  harness.projects?.[projectId]?.code_path,
  stateProject?.code_path,
];
const candidates = [
  ...configured,
  ...(projectId === 'workspace' ? ['.'] : []),
  path.join('projects', projectId),
  path.join('org', 'projects', projectId),
];

for (const raw of candidates) {
  if (typeof raw !== 'string' || !raw.trim()) continue;
  const candidate = path.isAbsolute(raw)
    ? path.resolve(raw)
    : path.resolve(root, raw);
  let stat;
  try { stat = fs.statSync(candidate); }
  catch { continue; }
  if (!stat.isDirectory()) continue;
  process.stdout.write(fs.realpathSync(candidate));
  process.exit(0);
}

console.error(`no code directory found for registered project "${projectId}"`);
process.exit(2);
NODE
}

# Load only project-scoped provider/model settings. This is intentionally a
# small dotenv-style parser, not `source`: project state is writable by project
# agents, so evaluating it as shell code would create a persistent code path and
# could replace SPIN's canonical root/cwd variables on the next run.
spin_load_project_env() {
  local env_file="${1:-}" line content key value line_number=0
  [ -n "$env_file" ] || return 0
  [ -e "$env_file" ] || return 0
  [ -f "$env_file" ] && [ ! -L "$env_file" ] || {
    printf 'project env must be a regular non-symlink file: %s\n' "$env_file" >&2
    return 2
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    content="${line#"${line%%[![:space:]]*}"}"
    case "$content" in
      ''|'#'*) continue ;;
    esac

    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
    else
      printf 'invalid project env syntax at %s:%s\n' "$env_file" "$line_number" >&2
      return 2
    fi

    case "$key" in
      # Beta 4 project.env files recorded these paths as project metadata.
      # Canonical roots now come from the harness and OMP configs are selected
      # by an owner environment override or a trusted SPIN lane. Keep old
      # installations bootable without letting project-writable files choose
      # either path.
      SPIN_OMP_CONFIG|COMPANY_ROOT|PROJECT_CODE_PATH)
        continue
        ;;
      PROJECT_CEO_PROVIDER|MODEL|CEO_CODEX_MODEL|CEO_CODEX_REASONING|CEO_CLAUDE_MODEL|CEO_SCOUT_MODEL|CEO_CURSOR_MODEL|CEO_GEMINI_MODEL|CEO_GEMINI_PRO_MODEL|CEO_OLLAMA_MODEL|CEO_OMP_MODEL|CEO_PROVIDER_TIMEOUT_SECS|SPIN_OMP_DEFAULT_MODEL|SPIN_OMP_SMOL_MODEL|SPIN_OMP_SLOW_MODEL|SPIN_OMP_PLAN_MODEL|SPIN_OMP_TASK_MODEL|SPIN_OMP_DEFAULT_FALLBACKS|SPIN_OMP_SMOL_FALLBACKS|SPIN_OMP_SLOW_FALLBACKS|SPIN_OMP_PROVIDER_ORDER|SPIN_OMP_RETRY_MAX_RETRIES|SPIN_OMP_RETRY_BASE_DELAY_MS|SPIN_OMP_RETRY_MAX_DELAY_MS|SPIN_OMP_FALLBACK_REVERT_POLICY)
        ;;
      *)
        printf 'project env variable is not an allowed provider/model override at %s:%s: %s\n' \
          "$env_file" "$line_number" "$key" >&2
        return 2
        ;;
    esac

    # Whitespace around the assignment is syntax, not part of the value.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
      \"*|*\"|\'*|*\')
        printf 'unmatched project env quote at %s:%s\n' "$env_file" "$line_number" >&2
        return 2
        ;;
    esac

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$env_file"
}
