#!/usr/bin/env bash
# Roll active project floor boards into the visible Coordinator status document.
set -uo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
OUT="$ROOT/org/ceo/WORKSPACE_STATUS.md"
source "$ROOT/scripts/lib/spin-runtime.sh"

DRIVER_LOCK="$ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
if [[ -f "$ROOT/org/ceo/runs/STOP" ]]; then
  DRIVER="paused - STOP file present (run \`spin start\` to resume)"
elif spin_locked_process_running "$DRIVER_LOCK" "$ROOT/scripts/workspace-ceo-tick.sh"; then
  DRIVER="running (PID $(cat "$DRIVER_LOCK" 2>/dev/null))"
else
  DRIVER="DOWN - run \`spin service repair\`"
fi

if spin_locked_process_running "$ROOT/org/ceo/runs/.status-watch.lock" "$ROOT/scripts/workspace-status-watch.sh"; then
  STATUS_WATCH="running (PID $(cat "$ROOT/org/ceo/runs/.status-watch.lock" 2>/dev/null))"
else
  STATUS_WATCH="DOWN - live board refresh is not supervised"
fi

if spin_locked_process_running "$ROOT/org/ceo/runs/.wiki-watch.lock" "$ROOT/scripts/wiki-watch.sh"; then
  WIKI_WATCH="running (PID $(cat "$ROOT/org/ceo/runs/.wiki-watch.lock" 2>/dev/null))"
else
  WIKI_WATCH="DOWN - project indexes are not updating"
fi
export DRIVER STATUS_WATCH WIKI_WATCH

node - "$ROOT" "$OUT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const out = process.argv[3];

const active = value => {
  const status = String(value || '').toLowerCase();
  return status && !/^(candidate|inactive|complete(?:d)?|archived|paused|disabled)(?:$|-)/.test(status);
};
const activeProjectIds = () => {
  const ordered = [];
  const seen = new Set();
  const statuses = new Map();
  const add = id => {
    if (id && !seen.has(id)) {
      seen.add(id);
      ordered.push(id);
    }
  };
  try {
    const state = JSON.parse(fs.readFileSync(path.join(root, 'org', 'state.json'), 'utf8'));
    for (const project of state.project_orchestrators || []) {
      const id = project.project || project.id;
      if (!id) continue;
      statuses.set(id, project.status || '');
      if (active(project.status)) add(id);
    }
  } catch {}
  try {
    const harness = JSON.parse(fs.readFileSync(path.join(root, 'org', 'OMP_HARNESS.json'), 'utf8'));
    for (const [id, project] of Object.entries(harness.projects || {})) {
      const status = statuses.get(id);
      if (project && project.cmux_workspace && (!status || active(status))) add(id);
    }
  } catch {}
  return ordered;
};
const sections = markdown => {
  const map = {};
  let current = null;
  for (const line of markdown.split('\n')) {
    const match = line.match(/^##\s+(.*)/);
    if (match) {
      current = match[1].trim();
      map[current] = [];
    } else if (current) {
      map[current].push(line);
    }
  }
  for (const key of Object.keys(map)) map[key] = map[key].join('\n').trim();
  return map;
};
const firstLines = (value, count) => (value || '')
  .split('\n')
  .filter(line => line.trim())
  .slice(0, count)
  .join(' ')
  .replace(/^[-*]\s*/, '');
const normalize = value => value.replace(
  /_Rolled up from active project floor boards - refreshed [^_]*_/,
  '_Rolled up from active project floor boards - refreshed <dynamic>_',
);
const ageText = value => {
  const timestamp = Date.parse(value || '');
  if (!Number.isFinite(timestamp)) return 'unknown';
  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
};
const readUsage = job => {
  const relative = job.resource_usage || `org/jobs/${job.id}.usage.json`;
  try {
    const file = path.resolve(root, relative);
    if (file !== root && !file.startsWith(`${root}${path.sep}`)) return null;
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!Number.isFinite(Number(value.rss_mb)) || !Number.isFinite(Number(value.processes))) return null;
    return value;
  } catch { return null; }
};

const boards = [];
for (const id of activeProjectIds()) {
  const file = path.join(root, 'org', 'projects', id, 'FLOOR.md');
  if (!fs.existsSync(file)) continue;
  const markdown = fs.readFileSync(file, 'utf8');
  const updated = ((markdown.match(/Last updated:[ \t]*([^\n_]*)/) || [])[1] || '').trim();
  boards.push({ id, sections: sections(markdown), updated });
}

let jobs = [];
let dispatchState = null;
try {
  const queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  jobs = Array.isArray(queue) ? queue : (queue.jobs || []);
  dispatchState = Array.isArray(queue) ? null : (queue.dispatch_state || null);
} catch {}
const running = jobs.filter(job => job.status === 'running');
const queued = jobs.filter(job => job.status === 'queued');
const blocked = jobs.filter(job => job.status === 'blocked');
const failed = jobs.filter(job => job.status === 'failed');
const recentProblems = [...blocked, ...failed]
  .sort((a, b) => Date.parse(b.failed_at || b.blocked_at || b.updated_at || 0) - Date.parse(a.failed_at || a.blocked_at || a.updated_at || 0))
  .slice(0, 6);

let actionPolicy = 'missing (deny-all)';
try {
  const policy = JSON.parse(fs.readFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), 'utf8'));
  const enabled = Array.isArray(policy.rules) ? policy.rules.filter(rule => rule.enabled === true).length : 0;
  actionPolicy = policy.mode === 'deny-by-default'
    ? (enabled ? `ready - ${enabled} exact rule${enabled === 1 ? '' : 's'} enabled` : 'deny-all - 0 rules enabled')
    : 'INVALID - mode must be deny-by-default';
} catch {}

let output = '# Workspace - Live Status\n\n';
output += `_Rolled up from active project floor boards - refreshed ${new Date().toISOString()}_\n\n`;
output += '## Control plane\n';
output += `- **Driver:** ${process.env.DRIVER || '(unknown)'}\n`;
output += `- **Live status:** ${process.env.STATUS_WATCH || '(unknown)'}\n`;
output += `- **Project index:** ${process.env.WIKI_WATCH || '(unknown)'}\n`;
output += `- **Sensitive actions:** ${actionPolicy}\n\n`;
output += '## Work\n';
output += `- **Running:** ${running.length}\n`;
output += `- **Queued:** ${queued.length}\n`;
output += `- **Blocked:** ${blocked.length}\n`;
output += `- **Failed history:** ${failed.length}\n`;
if (dispatchState) {
  output += `- **Dispatcher:** ${dispatchState.status || 'unknown'} - ${dispatchState.note || 'no detail'} (${dispatchState.available_memory_mb || '?'}MB available)\n`;
}
for (const job of running.slice(0, 8)) {
  const limits = job.resource_limits || {};
  const usage = readUsage(job);
  const resource = usage
    ? ` - ${usage.rss_mb}MB / ${limits.max_rss_mb || '?'}MB; ${usage.processes} / ${limits.max_processes || '?'} processes`
    : (limits.max_rss_mb ? ` - awaiting sample; limit ${limits.max_rss_mb}MB / ${limits.max_processes || '?'} processes` : '');
  const heartbeat = job.heartbeat_at || job.started_at;
  const stale = Number.isFinite(Date.parse(heartbeat || '')) && Date.now() - Date.parse(heartbeat) > 90000;
  const resourceClass = job.resource_class === 'heavy' ? ' **HEAVY**' : '';
  output += `  - \`${job.id}\`${resourceClass} - ${job.project_id || 'unknown project'} - age ${ageText(job.started_at)}, heartbeat ${ageText(heartbeat)}${stale ? ' **STALE**' : ''}${resource}\n`;
}
if (recentProblems.length) {
  output += '- **Needs attention:**\n';
  for (const job of recentProblems) {
    output += `  - \`${job.id}\` (${job.status}) - ${String(job.result || 'No failure detail recorded.').replace(/\s+/g, ' ').slice(0, 180)}\n`;
  }
}
output += '\n';
if (!boards.length) output += '_(no active project floor boards found)_\n';
for (const board of boards) {
  const get = expression => {
    const key = Object.keys(board.sections).find(candidate => expression.test(candidate));
    return key ? board.sections[key] : '';
  };
  output += `## ${board.id}${board.updated ? ` - _${board.updated}_` : ''}\n`;
  output += `- **Now:** ${firstLines(get(/in progress/i), 2) || '-'}\n`;
  output += `- **Next:** ${firstLines(get(/next/i), 2) || '-'}\n`;
  output += `- **Waiting on you:** ${firstLines(get(/waiting|blocker/i), 2) || '-'}\n\n`;
}

fs.mkdirSync(path.dirname(out), { recursive: true });
if (fs.existsSync(out) && normalize(fs.readFileSync(out, 'utf8')) === normalize(output)) process.exit(0);
const temporary = `${out}.tmp.${process.pid}`;
fs.writeFileSync(temporary, output);
fs.renameSync(temporary, out);
NODE
