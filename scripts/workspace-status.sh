#!/usr/bin/env bash
# workspace-status.sh — roll up every project's FLOOR.md into one workspace status
# doc for the CEO floor. Pure file I/O, no LLM, zero usage. Run once or via the watcher.
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
OUT="$ROOT/org/ceo/WORKSPACE_STATUS.md"

# Driver health (workspace-ceo-tick loop): up / paused (STOP) / DOWN
DRIVER_LOCK="$ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
if [[ -f "$ROOT/org/ceo/runs/STOP" ]]; then
  DRIVER="⏸ paused — STOP file present (\`rm org/ceo/runs/STOP\` to resume)"
elif dpid="$(cat "$DRIVER_LOCK" 2>/dev/null)" && [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then
  DRIVER="🟢 running (PID $dpid)"
else
  DRIVER="🔴 **DOWN** — relaunch: \`bash scripts/workspace-ceo-tick.sh\` in the CEO pane"
fi
export DRIVER

node - "$ROOT" "$OUT" <<'NODE'
const fs = require('fs'), path = require('path');
const root = process.argv[2], out = process.argv[3];
const projectsDir = path.join(root, 'org', 'projects');

function sections(md) {
  const map = {}; let cur = null;
  for (const line of md.split('\n')) {
    const m = line.match(/^##\s+(.*)/);
    if (m) { cur = m[1].trim(); map[cur] = []; }
    else if (cur) map[cur].push(line);
  }
  for (const k in map) map[k] = map[k].join('\n').trim();
  return map;
}
const firstLines = (s, n) => (s || '').split('\n').filter(l => l.trim()).slice(0, n).join(' ').replace(/^[-*]\s*/, '');

let boards = [];
try {
  for (const id of fs.readdirSync(projectsDir).sort()) {
    const f = path.join(projectsDir, id, 'FLOOR.md');
    if (!fs.existsSync(f)) continue;
    const md = fs.readFileSync(f, 'utf8');
    const upd = ((md.match(/Last updated:[ \t]*([^\n_]*)/) || [])[1] || '').trim();
    boards.push({ id, s: sections(md), upd });
  }
} catch {}

const now = new Date().toLocaleString();
const driver = process.env.DRIVER || '(unknown)';
let o = `# 🏢 Workspace — Live Status\n\n_Rolled up from each project's floor board · refreshed ${now}_\n\n**CEO driver loop:** ${driver}\n\n`;
if (!boards.length) o += '_(no project floor boards found yet)_\n';
for (const b of boards) {
  const get = (re) => { const k = Object.keys(b.s).find(k => re.test(k)); return k ? b.s[k] : ''; };
  const now_ = get(/in progress/i), next = get(/next/i), wait = get(/waiting|blocker/i);
  o += `## ${b.id}${b.upd ? `  ·  _${b.upd}_` : ''}\n`;
  o += `- **🔨 Now:** ${firstLines(now_, 2) || '—'}\n`;
  o += `- **⏭️ Next:** ${firstLines(next, 2) || '—'}\n`;
  o += `- **🚧 Waiting on you:** ${firstLines(wait, 2) || '—'}\n\n`;
}
fs.writeFileSync(out, o);
NODE
