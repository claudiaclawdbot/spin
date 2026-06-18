#!/usr/bin/env bash
# spin-new-project.sh — create a project AND open its cmux floor.
#
# This is the "spawn a new project space" action behind the cmux-as-GUI experience:
# it registers the project (org files, charter, harness entry) and opens a new cmux
# workspace — a sidebar "tab" — running that project's omp orchestrator. Used by the
# onboarding wizard and by the SPIN coordinator agent to add projects conversationally.
#
#   spin new-project <id> "<one-line goal>"            # create + open a cmux floor
#   spin new-project <id> "<goal>" --no-floor          # create only (headless / no cmux)
set -uo pipefail
# resolve symlinks so ROOT is the real repo even via ~/.local/bin/spin
__src="${BASH_SOURCE[0]}"
while [ -h "$__src" ]; do __d="$(cd -P "$(dirname "$__src")" && pwd)"; __src="$(readlink "$__src")"; [ "${__src#/}" = "$__src" ] && __src="$__d/$__src"; done
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd -P "$(dirname "$__src")/.." && pwd)}}"
ORG="$ROOT/org"; HARNESS="$ORG/OMP_HARNESS.json"
c_g=$'\e[32m'; c_v=$'\e[35m'; c_d=$'\e[2m'; c_o=$'\e[0m'

raw="${1:?usage: spin new-project <id> \"<goal>\" [--no-floor]}"
PID="$(echo "$raw" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/--*/-/g;s/^-//;s/-$//')"
GOAL="${2:-}"
FLOOR=1; [[ "${3:-}" == "--no-floor" ]] && FLOOR=0
[ -z "$PID" ] && { echo "invalid project id"; exit 1; }

# ── 1. create the project (bootstrap + charter + state + harness) ─────────────
bash "$ROOT/scripts/bootstrap-project.sh" "$PID" >/dev/null
CODE_DIR="$ROOT/projects/$PID"; mkdir -p "$CODE_DIR"
[ -f "$CODE_DIR/README.md" ] || printf '# %s\n\n%s\n' "$PID" "${GOAL:-Project workspace.}" > "$CODE_DIR/README.md"

cat > "$ORG/projects/$PID/PROJECT_CONTROLLER_PROMPT.md" <<EOF
# $PID — Project Controller Prompt

You are \`$PID-ceo\`, the orchestrator for **$PID**, sitting on this cmux floor. You
take direction from the SPIN coordinator (WORKSPACE_HANDOFF.md) and the human typing here.

## Mission
${GOAL:-TBD — set the goal in this file.}

## Working dir
\`projects/$PID/\` — the code lives here. Do local, reversible work freely.

## Hard Rules (only gate the 4 below)
Escalate (\`scripts/org inbox $PID "…"\`) only for: external sends · spending money ·
prod deploys · pushing to main/human repos.

## Reporting
- Append a receipt (with the job ID) to RECEIPTS.md; update STATE.json next_action.
- Report up: \`scripts/org inbox $PID "<what was done / what's blocked>"\`.
EOF

node -e '
  const fs=require("fs"), [sf,hf,id,goal]=process.argv.slice(1);
  const s=JSON.parse(fs.readFileSync(sf,"utf8")); const p=s.project_orchestrators||(s.project_orchestrators=[]);
  let e=p.find(x=>x.id===id||x.project===id); if(!e){e={id,project:id};p.push(e);}
  e.status="active-cmux-project-ceo"; e.primary_goal=goal||""; e.next_action="First step toward the goal.";
  e.code_path="projects/"+id; s.updated_at=new Date().toISOString();
  fs.writeFileSync(sf,JSON.stringify(s,null,2)+"\n");
  const h=JSON.parse(fs.readFileSync(hf,"utf8")); h.projects=h.projects||{};
  h.projects[id]=Object.assign({project_ceo:id+"-ceo",prompt:"org/projects/"+id+"/PROJECT_CONTROLLER_PROMPT.md",handoff:"org/projects/"+id+"/WORKSPACE_HANDOFF.md",agent:"scripts/project-ceo-agent.sh "+id,display_cmd:"scripts/project-floor-watch.sh "+id,allowed_job_types:["project-ceo-run","read-only-worker","implementation-worker","scout"],external_action_gate:true}, h.projects[id]||{});
  fs.writeFileSync(hf,JSON.stringify(h,null,2)+"\n");
' "$ORG/state.json" "$HARNESS" "$PID" "$GOAL" 2>/dev/null || { echo "failed to register $PID"; exit 1; }
echo "${c_g}✓ created project '$PID'${c_o} ${c_d}(charter, state, harness entry, projects/$PID/)${c_o}"

# ── 2. open the cmux floor (the sidebar "tab") ───────────────────────────────
if [[ "$FLOOR" == 1 ]] && command -v cmux >/dev/null 2>&1; then
  ref="$(CMUX_QUIET=1 cmux workspace create --name "$PID" --cwd "$CODE_DIR" \
        --command "bash '$ROOT/scripts/cmux-floor.sh' '$PID'" --focus false 2>/dev/null \
        | grep -oE 'workspace:[0-9]+' | head -1)"
  if [ -n "$ref" ]; then
    node -e 'const fs=require("fs"),[f,id,w]=process.argv.slice(1);const h=JSON.parse(fs.readFileSync(f,"utf8"));h.projects[id].cmux_workspace=w;fs.writeFileSync(f,JSON.stringify(h,null,2)+"\n");' "$HARNESS" "$PID" "$ref" 2>/dev/null || true
    echo "${c_v}✓ opened cmux floor for '$PID' → $ref${c_o} ${c_d}(it's now a tab in your cmux sidebar)${c_o}"
  else
    echo "${c_d}  (couldn't open a cmux floor — run 'spin up' later, or cmux isn't running)${c_o}"
  fi
else
  echo "${c_d}  (no cmux floor opened — headless. 'spin up' opens floors when you want them.)${c_o}"
fi
