#!/usr/bin/env bash
# workspace-status.sh — roll up every project's FLOOR.md into one workspace status
# doc for the CEO floor. Pure file I/O, no LLM, zero usage. Run once or via the watcher.
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
OUT="$ROOT/org/ceo/WORKSPACE_STATUS.md"
source "$ROOT/scripts/lib/spin-runtime.sh"

# Driver health (workspace-ceo-tick loop): up / paused (STOP) / DOWN
DRIVER_LOCK="$ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
if [[ -f "$ROOT/org/ceo/runs/STOP" ]]; then
  DRIVER="⏸ paused — STOP file present (\`rm org/ceo/runs/STOP\` to resume)"
elif spin_locked_process_running "$DRIVER_LOCK" "$ROOT/scripts/workspace-ceo-tick.sh"; then
  dpid="$(cat "$DRIVER_LOCK" 2>/dev/null)"
  DRIVER="🟢 running (PID $dpid)"
else
  DRIVER="🔴 **DOWN** — run \`spin service repair\`"
fi

if spin_locked_process_running "$ROOT/org/ceo/runs/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"; then
  status_pid="$(cat "$ROOT/org/ceo/runs/.status-watch.lock" 2>/dev/null)"
  STATUS_WATCH="🟢 running (PID $status_pid)"
else
  STATUS_WATCH="🔴 **DOWN** — live board refresh is not supervised"
fi

if spin_locked_process_running "$ROOT/org/ceo/runs/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"; then
  wiki_pid="$(cat "$ROOT/org/ceo/runs/.wiki-watch.lock" 2>/dev/null)"
  WIKI_WATCH="🟢 running (PID $wiki_pid)"
else
  WIKI_WATCH="🔴 **DOWN** — project indexes are not updating"
fi
export DRIVER STATUS_WATCH WIKI_WATCH

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
let jobs = [];
try {
  for (const id of fs.readdirSync(projectsDir).sort()) {
    const f = path.join(projectsDir, id, 'FLOOR.md');
    if (!fs.existsSync(f)) continue;
    const md = fs.readFileSync(f, 'utf8');
    const upd = ((md.match(/Last updated:[ \t]*([^\n_]*)/) || [])[1] || '').trim();
    boards.push({ id, s: sections(md), upd });
  }
} catch {}
try {
  const queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  jobs = Array.isArray(queue.jobs) ? queue.jobs : [];
} catch {}

const now = new Date().toISOString();
const driver = process.env.DRIVER || '(unknown)';
const statusWatch = process.env.STATUS_WATCH || '(unknown)';
const wikiWatch = process.env.WIKI_WATCH || '(unknown)';
let o = `# 🏢 Workspace — Live Status\n\n_Rolled up from each project's floor board · refreshed ${now}_\n\n`;
o += `## Control plane\n- **Driver:** ${driver}\n- **Live status:** ${statusWatch}\n- **Project index:** ${wikiWatch}\n\n`;
const running = jobs.filter(job => job.status === 'running');
const queued = jobs.filter(job => job.status === 'queued');
const blocked = jobs.filter(job => job.status === 'blocked');
const failed = jobs.filter(job => job.status === 'failed');
o += `## Work\n- **Running:** ${running.length}\n- **Queued:** ${queued.length}\n- **Blocked:** ${blocked.length}\n- **Failed history:** ${failed.length}\n`;
for (const job of running.slice(0, 8)) {
  const limits = job.resource_limits || {};
  const budget = limits.max_rss_mb ? ` · limit ${limits.max_rss_mb}MB / ${limits.max_processes || '?'} processes` : '';
  o += `  - \`${job.id}\` · ${job.project_id || 'unknown project'}${budget}\n`;
}
o += '\n';
if (!boards.length) o += '_(no project floor boards found yet)_\n';
for (const b of boards) {
  const get = (re) => { const k = Object.keys(b.s).find(k => re.test(k)); return k ? b.s[k] : ''; };
  const now_ = get(/in progress/i), next = get(/next/i), wait = get(/waiting|blocker/i);
  o += `## ${b.id}${b.upd ? `  ·  _${b.upd}_` : ''}\n`;
  o += `- **🔨 Now:** ${firstLines(now_, 2) || '—'}\n`;
  o += `- **⏭️ Next:** ${firstLines(next, 2) || '—'}\n`;
  o += `- **🚧 Waiting on you:** ${firstLines(wait, 2) || '—'}\n\n`;
}
fs.mkdirSync(path.dirname(out), { recursive: true });
const tmp = `${out}.tmp.${process.pid}`;
fs.writeFileSync(tmp, o);
fs.renameSync(tmp, out);
NODE
