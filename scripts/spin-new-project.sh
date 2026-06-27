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
source "$ROOT/scripts/lib/spin-runtime.sh"
source "$ROOT/scripts/lib/cmux-floor-layout.sh"
c_g=$'\e[32m'; c_v=$'\e[35m'; c_d=$'\e[2m'; c_o=$'\e[0m'

raw="${1:?usage: spin new-project <id> \"<goal>\" [--no-floor]}"
PID="$(echo "$raw" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/--*/-/g;s/^-//;s/-$//')"
GOAL="${2:-}"
FLOOR=1; [[ "${3:-}" == "--no-floor" ]] && FLOOR=0
[ -z "$PID" ] && { echo "invalid project id"; exit 1; }

# ── 1. create the project (bootstrap + charter + state + harness) ─────────────
PROJECT_DIR="$ORG/projects/$PID"
HAD_FLOOR=0; [[ -f "$PROJECT_DIR/FLOOR.md" ]] && HAD_FLOOR=1
bash "$ROOT/scripts/bootstrap-project.sh" "$PID" >/dev/null
CODE_DIR="$ROOT/projects/$PID"; mkdir -p "$CODE_DIR"
[ -f "$CODE_DIR/README.md" ] || printf '# %s\n\n%s\n' "$PID" "${GOAL:-Project workspace.}" > "$CODE_DIR/README.md"

if [[ "$HAD_FLOOR" == 0 ]]; then
  cat > "$PROJECT_DIR/FLOOR.md" <<EOF
# $PID — Floor Board

_Live at-a-glance board for this project's cmux floor. The status roll-up
daemon aggregates every project's board into \`org/ceo/WORKSPACE_STATUS.md\`._

Last updated: (never)

## Goal
${GOAL:-Describe the win condition here.}

## In progress
- (nothing yet)

## Recently done
- (nothing yet)

## Next
- First step toward the goal.

## Waiting on human
- (nothing yet)
EOF
fi

cat > "$ORG/projects/$PID/PROJECT_CONTROLLER_PROMPT.md" <<EOF
# $PID — Project Controller Prompt

You are \`$PID-ceo\`, the orchestrator for **$PID**, sitting on this cmux floor. You
take direction from the SPIN coordinator (WORKSPACE_HANDOFF.md) and the human typing here.
You are intentionally visible: the human may watch this terminal to see what input
the Coordinator sent, what context you used, and how you reported back.

## Mission
${GOAL:-TBD — set the goal in this file.}

## Working dir
\`projects/$PID/\` — the code lives here. Do local, reversible work freely.

## Live delegation
When this terminal receives \`SPIN delegation <id>\`, read
\`org/projects/$PID/WORKSPACE_HANDOFF.md\`, do the project-scoped work visibly in
this floor, update FLOOR.md/RECEIPTS.md, verify claimed artifacts, and close the
handshake with the exact reporting command for that delegate id.

## Hard Rules (only gate the 4 below)
Escalate (\`scripts/org inbox $PID "…"\`) only for: external sends · spending money ·
prod deploys · pushing to main/human repos.

## Reporting
- Append a receipt (with the job ID or delegate ID) to RECEIPTS.md; update STATE.json next_action.
- Before reporting completion, verify any file/artifact you claim with \`ls\`, \`test -f\`, or the relevant run/test command.
- For live delegations, preserve the delegate ID and report up from the SPIN root with exactly:
  \`cd "\$SPIN_ROOT" && scripts/org inbox $PID "delegate <id> complete: <summary>"\`
  or
  \`cd "\$SPIN_ROOT" && scripts/org inbox $PID "delegate <id> blocked: <summary>"\`.
- For non-delegate status, report up: \`cd "\$SPIN_ROOT" && scripts/org inbox $PID "<what was done / what's blocked>"\`.
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
if [[ "$FLOOR" == 1 ]] && spin_have_binary cmux; then
  ref="$(spin_cmux_workspace_ref_by_name "$PID")"
  if [[ -z "$ref" ]]; then
    ref="$(CMUX_QUIET=1 spin_cmd cmux new-workspace --name "$PID" --cwd "$CODE_DIR" \
          --command "bash '$ROOT/scripts/cmux-floor.sh' '$PID'" --focus false 2>/dev/null \
          | grep -oE 'workspace:[^[:space:]]+' | head -1)"
  fi
  if [ -n "$ref" ]; then
    node -e 'const fs=require("fs"),[f,id,w]=process.argv.slice(1);const h=JSON.parse(fs.readFileSync(f,"utf8"));h.projects[id].cmux_workspace=w;fs.writeFileSync(f,JSON.stringify(h,null,2)+"\n");' "$HARNESS" "$PID" "$ref" 2>/dev/null || true
    sf="$(spin_cmux_terminal_surface "$ref")"
    if spin_cmux_open_project_board "$ref" "$PID" "$sf"; then
      echo "${c_v}✓ opened cmux floor for '$PID' → $ref${c_o} ${c_d}(agent + live FLOOR.md board)${c_o}"
    else
      echo "${c_v}✓ opened cmux floor for '$PID' → $ref${c_o} ${c_d}(terminal only; board pane unavailable)${c_o}"
    fi
  else
    echo "${c_d}  (couldn't open a cmux floor — run 'spin up' later, or cmux isn't running)${c_o}"
  fi
else
  echo "${c_d}  (no cmux floor opened — headless. 'spin up' opens floors when you want them.)${c_o}"
fi
