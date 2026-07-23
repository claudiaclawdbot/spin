#!/usr/bin/env node
// spin-web.js — tiny local web control panel for SPIN org files.
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');
const { URLSearchParams } = require('url');

const selfDir = path.dirname(fs.realpathSync(__filename));
const runtime = require(path.join(selfDir, 'lib', 'spin-runtime.js'));
const { jobNeedsAttention } = require(path.join(selfDir, 'lib', 'job-attention.js'));
const { summarizeHumanQueue } = require(path.join(selfDir, 'lib', 'human-queue-summary.js'));
const ROOT = process.env.SPIN_ROOT || process.env.OMP_ROOT || path.resolve(selfDir, '..');
const ORG = path.join(ROOT, 'org');
const RUNS = path.join(ORG, 'ceo', 'runs');
const APPROVALS_LOCK = path.join(RUNS, '.org-approvals.lock');
const APPROVALS = path.join(ORG, 'ceo', 'APPROVALS.md');
const HUMAN_QUEUE = path.join(ORG, 'HUMAN_QUEUE.md');
const QUEUE = path.join(ORG, 'AGENT_QUEUE.json');
const STATE = path.join(ORG, 'state.json');
const WORKSPACE_STATUS = path.join(ORG, 'ceo', 'WORKSPACE_STATUS.md');
const STATUS_HEARTBEAT = path.join(RUNS, '.status-watch.heartbeat');

const args = process.argv.slice(2);
const flagValue = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const HOST = flagValue('--host', process.env.SPIN_WEB_HOST || '127.0.0.1');
const PORT = Number(flagValue('--port', process.env.SPIN_WEB_PORT || '8787'));
const SHOULD_OPEN = args.includes('--open');
const VALID_PROJECT_ID = /^(?!\.{1,2}$)[A-Za-z0-9._:-]+$/;
const CSRF_TOKEN = crypto.randomBytes(32).toString('hex');
const SECURITY_HEADERS = {
  'cache-control': 'no-store',
  'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
};

function read(file, fallback = '') {
  try { return fs.readFileSync(file, 'utf8'); } catch { return fallback; }
}
function readJSON(file, fallback) {
  try { return JSON.parse(read(file)); } catch { return fallback; }
}
function escapeHTML(s) {
  return String(s ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[ch]));
}
function truncate(s, n) {
  s = String(s || '').replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}
function nowStamp() {
  return new Date().toISOString().slice(0, 16) + 'Z';
}

function loopbackHostname(value) {
  const hostname = String(value || '').toLowerCase().replace(/^\[|\]$/g, '');
  return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '::1';
}

const BIND_HOST = String(HOST).replace(/^\[([^\]]+)\]$/, '$1');
if (!loopbackHostname(BIND_HOST)) {
  console.error(`SPIN web error: refusing non-loopback --host ${JSON.stringify(HOST)}; use 127.0.0.1, localhost, or ::1`);
  process.exit(1);
}

function loopbackPeer(value) {
  const address = String(value || '').toLowerCase();
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function requestOrigin(req) {
  const host = req.headers.host;
  if (typeof host !== 'string' || !host || host.includes(',')) return null;

  let authority;
  try {
    authority = new URL(`http://${host}`);
  } catch {
    return null;
  }

  const address = server.address();
  const expectedPort = address && typeof address === 'object' ? String(address.port) : String(PORT);
  const requestPort = authority.port || '80';
  if (
    authority.protocol !== 'http:'
    || authority.username
    || authority.password
    || authority.pathname !== '/'
    || authority.search
    || authority.hash
    || !loopbackHostname(authority.hostname)
    || requestPort !== expectedPort
  ) return null;

  return authority.origin;
}

function validDecisionRequest(req) {
  const expectedOrigin = requestOrigin(req);
  if (!expectedOrigin || !loopbackPeer(req.socket.remoteAddress)) return false;

  const originValue = req.headers.origin;
  if (typeof originValue !== 'string' || !originValue || originValue.includes(',')) return false;

  try {
    const origin = new URL(originValue);
    return (
      origin.protocol === 'http:'
      && !origin.username
      && !origin.password
      && origin.pathname === '/'
      && !origin.search
      && !origin.hash
      && loopbackHostname(origin.hostname)
      && origin.origin === expectedOrigin
    );
  } catch {
    return false;
  }
}

function validCsrfToken(value) {
  if (typeof value !== 'string') return false;
  const expected = Buffer.from(CSRF_TOKEN, 'utf8');
  const actual = Buffer.from(value, 'utf8');
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function forbidden(req, res) {
  req.resume();
  res.writeHead(403, {
    ...SECURITY_HEADERS,
    'content-type': 'text/plain; charset=utf-8',
  });
  res.end('forbidden\n');
}

function humanQueueItems() {
  return summarizeHumanQueue(ROOT).items
    .map(item => ({ ...item, text: item.text.replace(/^\[[ xX]\]\s*/, '') }))
    .filter(item => item.text && !/^_?\(nothing/i.test(item.text));
}

function pendingApprovals() {
  const txt = read(APPROVALS);
  const lines = txt.split('\n');
  const start = lines.findIndex(line => /^##\s+Pending/i.test(line));
  if (start < 0) return [];
  const end = lines.findIndex((line, i) => i > start && /^##\s+Processed/i.test(line));
  return lines.slice(start + 1, end < 0 ? lines.length : end)
    .filter(line => /\S/.test(line) && !line.trim().startsWith('<!--'))
    .map(line => line.trim());
}

function withApprovalsLock(fn) {
  let handle;
  try {
    handle = runtime.acquireProcessLock(APPROVALS_LOCK, { timeoutMs: 5000, pollMs: 100 });
  } catch (error) {
    throw new Error(`cannot acquire approvals lock: ${error.message}`);
  }
  try {
    return fn();
  } finally {
    runtime.releaseProcessLock(handle);
  }
}

function writeApproval(action, item, note = '') {
  const cleanAction = String(action || '').toUpperCase();
  if (!['APPROVE', 'DECLINE', 'ASK'].includes(cleanAction)) throw new Error('invalid decision action');
  const cleanItem = String(item || '').replace(/\s+/g, ' ').trim();
  if (!cleanItem) throw new Error('empty decision item');
  const cleanNote = String(note || '').replace(/\s+/g, ' ').trim();
  const message = `${cleanAction}: ${cleanItem}${cleanNote ? ` — ${cleanNote}` : ''}`;
  const line = `- [${nowStamp()}] ${message}`;
  return withApprovalsLock(() => {
    const txt = read(APPROVALS, '# Approvals\n\n## Pending\n\n## Processed\n');
    const lines = txt.split('\n');
    const pending = lines.findIndex(l => /^##\s+Pending/i.test(l));
    if (pending < 0) throw new Error('APPROVALS.md has no Pending section');
    lines.splice(pending + 1, 0, '', line);
    const tmp = `${APPROVALS}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, lines.join('\n'));
    fs.renameSync(tmp, APPROVALS);
  });
}

function projectFloor(projectId) {
  if (!VALID_PROJECT_ID.test(String(projectId || ''))) return '(invalid project id)';
  return read(path.join(ORG, 'projects', projectId, 'FLOOR.md'), '(no FLOOR.md yet)');
}

function latestReceipts(limit = 6) {
  try {
    return fs.readdirSync(RUNS)
      .filter(name => /^workspace-ceo-agent-.*\.md$/.test(name))
      .sort()
      .slice(-limit)
      .reverse()
      .map(name => ({ name, body: read(path.join(RUNS, name)) }));
  } catch {
    return [];
  }
}

function dateValue(value) {
  const parsed = Date.parse(value || '');
  return Number.isFinite(parsed) ? parsed : 0;
}

function ageText(value) {
  const parsed = dateValue(value);
  if (!parsed) return 'unknown';
  const seconds = Math.max(0, Math.floor((Date.now() - parsed) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

function newest(items) {
  return [...items].sort((a, b) => {
    const aTime = dateValue(a.failed_at || a.blocked_at || a.completed_at || a.started_at || a.created_at);
    const bTime = dateValue(b.failed_at || b.blocked_at || b.completed_at || b.started_at || b.created_at);
    return bTime - aTime;
  });
}

function resourceUsage(job) {
  const relative = job.resource_usage || path.join('org', 'jobs', `${job.id}.usage.json`);
  const file = path.resolve(ROOT, relative);
  if (file !== ROOT && !file.startsWith(`${ROOT}${path.sep}`)) return null;
  const usage = readJSON(file, null);
  if (!usage || !Number.isFinite(Number(usage.rss_mb)) || !Number.isFinite(Number(usage.processes))) return null;
  return { rssMb: Number(usage.rss_mb), processes: Number(usage.processes), observedAt: usage.observed_at || null };
}

function controlPlane() {
  const markdown = read(WORKSPACE_STATUS);
  const field = name => {
    const match = markdown.match(new RegExp(`^- \\*\\*${name}:\\*\\*\\s*(.+)$`, 'mi'));
    return match ? match[1].trim() : 'unknown';
  };
  let boardModified = 0;
  try { boardModified = fs.statSync(WORKSPACE_STATUS).mtimeMs; } catch {}
  let observedAt = 0;
  try {
    const heartbeat = readJSON(STATUS_HEARTBEAT, {});
    observedAt = dateValue(heartbeat.observed_at);
    if (!observedAt) observedAt = fs.statSync(STATUS_HEARTBEAT).mtimeMs;
  } catch {}
  const changedMatch = markdown.match(/^_Status changed at ([^_]+)_/mi);
  const statusChangedAt = dateValue(changedMatch && changedMatch[1]) || boardModified;
  const stale = !boardModified || !observedAt || Date.now() - observedAt > 45_000;
  return {
    driver: field('Driver'),
    status: field('Live status'),
    index: field('Project index'),
    actions: field('Sensitive actions'),
    observedAge: observedAt ? ageText(new Date(observedAt).toISOString()) : 'missing',
    changedAge: statusChangedAt ? ageText(new Date(statusChangedAt).toISOString()) : 'missing',
    stale,
  };
}

function jobItem(job) {
  const usage = resourceUsage(job);
  const limits = job.resource_limits || {};
  const heartbeat = job.heartbeat_at || job.started_at;
  const stale = job.status === 'running' && dateValue(heartbeat) && Date.now() - dateValue(heartbeat) > 90_000;
  const metadata = [job.project_id || 'unknown project', job.type || job.status || 'job'];
  if (job.resource_class === 'heavy') metadata.push('heavy lease');
  if (job.status === 'running') {
    metadata.push(`age ${ageText(job.started_at)}`);
    metadata.push(`heartbeat ${ageText(heartbeat)}${stale ? ' stale' : ''}`);
  } else if (job.status === 'queued') metadata.push(`waiting ${ageText(job.created_at)}`);
  else metadata.push(ageText(job.failed_at || job.blocked_at || job.completed_at));
  if (usage) metadata.push(`${usage.rssMb}/${limits.max_rss_mb || '?'} MB · ${usage.processes}/${limits.max_processes || '?'} proc`);
  else if (job.status === 'running' && limits.max_rss_mb) metadata.push(`limit ${limits.max_rss_mb} MB · ${limits.max_processes || '?'} proc`);
  const detail = job.result || job.description || '';
  const className = job.status === 'failed' || job.status === 'blocked' || stale ? 'job bad-job' : 'job';
  return `<div class="${className}"><div><strong>${escapeHTML(job.id)}</strong> <span class="status ${escapeHTML(job.status || '')}">${escapeHTML(job.status || '')}</span></div><div class="muted">${escapeHTML(metadata.join(' · '))}</div>${detail ? `<div>${escapeHTML(truncate(detail, 180))}</div>` : ''}</div>`;
}

function jobList(items, empty) {
  return items.length ? items.map(jobItem).join('') : `<p class="muted">${escapeHTML(empty)}</p>`;
}

function page(message = '') {
  const state = readJSON(STATE, {});
  const queue = readJSON(QUEUE, { jobs: [] });
  const projects = state.project_orchestrators || [];
  const jobs = queue.jobs || [];
  const dispatchState = queue.dispatch_state || null;
  const waiting = humanQueueItems();
  const pending = pendingApprovals();
  const receipts = latestReceipts();
  const isActive = status => {
    const value = String(status || '').toLowerCase();
    return value && !/^(candidate|inactive|complete(?:d)?|archived|paused|disabled)(?:$|-)/.test(value);
  };
  const active = projects.filter(p => isActive(p.status));
  const running = newest(jobs.filter(j => j.status === 'running'));
  const queued = newest(jobs.filter(j => j.status === 'queued'));
  const attention = newest(jobs.filter(jobNeedsAttention));
  const problems = attention.slice(0, 8);
  const completed = newest(jobs.filter(j => j.status === 'completed')).slice(0, 5);
  const control = controlPlane();
  const sampled = running.map(resourceUsage).filter(Boolean);
  const resourceUsed = sampled.reduce((sum, value) => sum + value.rssMb, 0);
  const resourceLimit = running.reduce((sum, job) => sum + Number(job.resource_limits?.max_rss_mb || 0), 0);
  const processUsed = sampled.reduce((sum, value) => sum + value.processes, 0);
  const processLimit = running.reduce((sum, job) => sum + Number(job.resource_limits?.max_processes || 0), 0);
  const resources = sampled.length
    ? `${resourceUsed}/${resourceLimit || '?'} MB · ${processUsed}/${processLimit || '?'} proc`
    : (running.length ? 'waiting for resource sample' : 'no active resource use');
  const dispatch = dispatchState
    ? `${dispatchState.status || 'unknown'} · ${dispatchState.note || 'no detail'} · ${dispatchState.available_memory_mb || '?'} MB available`
    : 'waiting for dispatcher state';
  const driverPaused = /paused/i.test(control.driver);
  const driverClass = /DOWN|unknown/i.test(control.driver) ? 'bad' : driverPaused ? 'warn' : 'ok';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SPIN Control</title>
<style>
:root{color-scheme:dark;--bg:#101418;--panel:#171d22;--line:#29323a;--text:#edf2f7;--muted:#98a6b3;--cyan:#38bdf8;--green:#34d399;--yellow:#facc15;--red:#fb7185}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header{display:flex;justify-content:space-between;gap:16px;align-items:center;padding:18px 24px;border-bottom:1px solid var(--line);background:#0c1115;position:sticky;top:0;z-index:2}
h1{font-size:18px;margin:0}main{max-width:1240px;margin:0 auto;padding:20px;display:grid;gap:16px}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}
section{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}h2{font-size:14px;margin:0 0 10px;color:#dbeafe}.muted{color:var(--muted)}.pill{display:inline-flex;border:1px solid var(--line);border-radius:999px;padding:2px 8px;margin-right:6px;color:var(--muted)}
ul{padding-left:18px;margin:8px 0}li{margin:6px 0}pre{white-space:pre-wrap;word-break:break-word;background:#0c1115;border:1px solid var(--line);border-radius:6px;padding:10px;max-height:360px;overflow:auto}
button{border:1px solid var(--line);border-radius:6px;background:#0f1720;color:var(--text);padding:6px 9px;cursor:pointer}button:hover{border-color:var(--cyan)}input{width:100%;border:1px solid var(--line);border-radius:6px;background:#0c1115;color:var(--text);padding:7px}
form.inline{display:inline-flex;gap:6px;margin:4px 4px 0 0;align-items:center}.decision{border-top:1px solid var(--line);padding-top:10px;margin-top:10px}.ok{color:var(--green)}.warn{color:var(--yellow)}.bad,.pill.bad{color:var(--red);border-color:#7f1d2d}.job-columns{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:0 18px}.lane h3{font-size:12px;text-transform:uppercase;color:var(--muted);margin:4px 0 8px}.job{border-top:1px solid var(--line);padding:9px 0;display:grid;gap:3px;overflow-wrap:anywhere}.bad-job{border-left:2px solid var(--red);padding-left:8px}.status{font-size:11px;color:var(--muted)}.status.running{color:var(--green)}.status.failed,.status.blocked{color:var(--red)}.project{border-top:1px solid var(--line);padding:10px 0}.project:first-child{border-top:0}.project h3{font-size:13px;margin:0}.resource-line{margin:0 0 12px}.completed-line{border-top:1px solid var(--line);margin-top:8px;padding-top:10px}a{color:var(--cyan);text-decoration:none}a:hover{text-decoration:underline}
@media(max-width:900px){.grid{grid-template-columns:1fr}header{align-items:flex-start;flex-direction:column}}
@media(max-width:900px){.job-columns{grid-template-columns:1fr}.lane{border-top:1px solid var(--line);padding-top:8px}.lane:first-child{border-top:0}}
</style>
</head>
<body>
<header><div><h1>SPIN Control</h1><div class="muted">${escapeHTML(ROOT)}</div></div><div><span class="pill ${control.stale ? 'bad' : ''}">${control.stale ? 'control stale' : 'control live'}</span>${driverPaused ? '<span class="pill warn">driver paused</span>' : ''}<span class="pill">${running.length} running</span><span class="pill">${queued.length} queued</span><span class="pill ${attention.length ? 'bad' : ''}">${attention.length} attention</span><span class="pill">${waiting.length} waiting</span></div></header>
<main>
${message ? `<section><strong class="ok">${escapeHTML(message)}</strong></section>` : ''}
<div class="grid">
<section><h2>Control Plane</h2><p><strong>Driver</strong><br><span class="${driverClass}">${escapeHTML(control.driver)}</span></p><p><strong>Live status</strong><br><span class="${control.stale ? 'bad' : 'muted'}">${escapeHTML(control.status)} · observed ${escapeHTML(control.observedAge)} ago</span><br><span class="muted">Status changed ${escapeHTML(control.changedAge)} ago.</span></p><p><strong>Sensitive actions</strong><br><span class="muted">${escapeHTML(control.actions)}</span></p></section>
<section><h2>Waiting On You</h2>${waiting.length ? waiting.map(item => `
  <div class="decision">
    <div>${escapeHTML(item.text)}</div>
    ${['APPROVE','DECLINE','ASK'].map(action => `<form class="inline" method="post" action="/decision"><input type="hidden" name="csrf" value="${escapeHTML(CSRF_TOKEN)}"><input type="hidden" name="item" value="${escapeHTML(item.text)}"><input type="hidden" name="action" value="${action}"><button>${action}</button></form>`).join('')}
  </div>`).join('') : '<p class="ok">Nothing waiting.</p>'}</section>
<section><h2>Pending Decisions</h2><ul>${pending.map(line => `<li>${escapeHTML(line)}</li>`).join('') || '<li class="muted">No pending approvals.</li>'}</ul>
<form method="post" action="/decision"><input type="hidden" name="csrf" value="${escapeHTML(CSRF_TOKEN)}"><input name="item" placeholder="Manual approval text"><div style="display:flex;gap:6px;margin-top:8px"><button name="action" value="APPROVE">Approve</button><button name="action" value="DECLINE">Decline</button><button name="action" value="ASK">Ask</button></div></form></section>
</div>
<section><h2>Jobs</h2><p class="resource-line"><strong>Dispatcher:</strong> <span class="muted">${escapeHTML(dispatch)}</span><br><strong>Current resources:</strong> <span class="muted">${escapeHTML(resources)}</span></p><div class="job-columns"><div class="lane"><h3>Running</h3>${jobList(running, 'No running jobs.')}</div><div class="lane"><h3>Queued</h3>${jobList(queued.slice(0, 8), 'No queued jobs.')}</div><div class="lane"><h3>Needs Attention</h3>${jobList(problems, 'Nothing needs attention.')}</div></div><div class="completed-line"><strong>Recently completed:</strong> <span class="muted">${completed.length ? completed.map(job => escapeHTML(job.id)).join(' · ') : 'none'}</span></div></section>
<section><h2>Projects</h2><div class="grid">${active.map(p => {
    const id = p.project || p.id || '?';
    return `<div class="project"><h3>${escapeHTML(id)}</h3><p class="muted">${escapeHTML(truncate(p.next_action || 'No next action.', 120))}</p><p><a href="/floor/${encodeURIComponent(id)}">Open floor board</a></p></div>`;
  }).join('') || '<p class="muted">No active projects.</p>'}</div></section>
<section><h2>Recent Receipts</h2>${receipts.map(r => `<details><summary>${escapeHTML(r.name)}</summary><pre>${escapeHTML(truncate(r.body, 1800))}</pre></details>`).join('') || '<p class="muted">No receipts yet.</p>'}</section>
</main>
</body>
</html>`;
}

function floorPage(projectId) {
  return `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHTML(projectId)} FLOOR</title><style>body{background:#101418;color:#edf2f7;font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;margin:24px}a{color:#38bdf8}pre{white-space:pre-wrap}</style></head><body><p><a href="/">← SPIN Control</a></p><pre>${escapeHTML(projectFloor(projectId))}</pre></body></html>`;
}

function readBody(req, limit = 16_384) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > limit) reject(new Error('request body too large'));
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { ...SECURITY_HEADERS, 'content-type': 'text/html; charset=utf-8' });
      res.end(page(url.searchParams.get('ok') || ''));
      return;
    }
    if (req.method === 'GET' && url.pathname.startsWith('/floor/')) {
      const projectId = decodeURIComponent(url.pathname.slice('/floor/'.length));
      if (!VALID_PROJECT_ID.test(projectId)) {
        res.writeHead(400, { ...SECURITY_HEADERS, 'content-type': 'text/plain; charset=utf-8' });
        res.end('invalid project id\n');
        return;
      }
      res.writeHead(200, { ...SECURITY_HEADERS, 'content-type': 'text/html; charset=utf-8' });
      res.end(floorPage(projectId));
      return;
    }
    if (req.method === 'POST' && url.pathname === '/decision') {
      if (!validDecisionRequest(req)) {
        forbidden(req, res);
        return;
      }
      const params = new URLSearchParams(await readBody(req));
      if (!validCsrfToken(params.get('csrf'))) {
        forbidden(req, res);
        return;
      }
      writeApproval(params.get('action'), params.get('item'), params.get('note') || '');
      res.writeHead(303, { ...SECURITY_HEADERS, location: '/?ok=Decision%20recorded' });
      res.end();
      return;
    }
    res.writeHead(404, { ...SECURITY_HEADERS, 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found\n');
  } catch (err) {
    res.writeHead(500, { ...SECURITY_HEADERS, 'content-type': 'text/plain; charset=utf-8' });
    res.end(`SPIN web error: ${err.message}\n`);
  }
});

server.listen(PORT, BIND_HOST, () => {
  const addr = server.address();
  const displayHost = BIND_HOST.includes(':') ? `[${BIND_HOST}]` : BIND_HOST;
  const url = `http://${displayHost}:${addr.port}/`;
  console.log(`SPIN web: ${url}`);
  if (SHOULD_OPEN && process.platform === 'darwin') {
    const child = spawn('open', [url], { stdio: 'ignore', detached: true });
    child.unref();
  }
});
