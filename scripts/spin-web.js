#!/usr/bin/env node
// spin-web.js — tiny local web control panel for SPIN org files.
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');
const { URLSearchParams } = require('url');

const selfDir = path.dirname(fs.realpathSync(__filename));
const ROOT = process.env.SPIN_ROOT || process.env.OMP_ROOT || path.resolve(selfDir, '..');
const ORG = path.join(ROOT, 'org');
const RUNS = path.join(ORG, 'ceo', 'runs');
const APPROVALS = path.join(ORG, 'ceo', 'APPROVALS.md');
const HUMAN_QUEUE = path.join(ORG, 'HUMAN_QUEUE.md');
const QUEUE = path.join(ORG, 'AGENT_QUEUE.json');
const STATE = path.join(ORG, 'state.json');

const args = process.argv.slice(2);
const flagValue = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const HOST = flagValue('--host', process.env.SPIN_WEB_HOST || '127.0.0.1');
const PORT = Number(flagValue('--port', process.env.SPIN_WEB_PORT || '8787'));
const SHOULD_OPEN = args.includes('--open');

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

function humanQueueItems() {
  return read(HUMAN_QUEUE).split('\n')
    .filter(line => /^-\s+(\[[ xX]\]\s*)?/.test(line))
    .map((line, index) => ({
      index,
      raw: line.replace(/^-+\s*/, '').trim(),
      text: line.replace(/^-+\s*(\[[ xX]\]\s*)?/, '').trim(),
    }))
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

function writeApproval(action, item, note = '') {
  const cleanAction = String(action || '').toUpperCase();
  if (!['APPROVE', 'DECLINE', 'ASK'].includes(cleanAction)) throw new Error('invalid decision action');
  const cleanItem = String(item || '').replace(/\s+/g, ' ').trim();
  if (!cleanItem) throw new Error('empty decision item');
  const cleanNote = String(note || '').replace(/\s+/g, ' ').trim();
  const message = `${cleanAction}: ${cleanItem}${cleanNote ? ` — ${cleanNote}` : ''}`;
  const line = `- [${nowStamp()}] ${message}`;
  const txt = read(APPROVALS, '# Approvals\n\n## Pending\n\n## Processed\n');
  const lines = txt.split('\n');
  const pending = lines.findIndex(l => /^##\s+Pending/i.test(l));
  if (pending < 0) throw new Error('APPROVALS.md has no Pending section');
  lines.splice(pending + 1, 0, '', line);
  const tmp = `${APPROVALS}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, lines.join('\n'));
  fs.renameSync(tmp, APPROVALS);
}

function projectFloor(projectId) {
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

function page(message = '') {
  const state = readJSON(STATE, {});
  const queue = readJSON(QUEUE, { jobs: [] });
  const projects = state.project_orchestrators || [];
  const jobs = queue.jobs || [];
  const waiting = humanQueueItems();
  const pending = pendingApprovals();
  const receipts = latestReceipts();
  const active = projects.filter(p => String(p.status || '').startsWith('active'));
  const running = jobs.filter(j => j.status === 'running');
  const queued = jobs.filter(j => j.status === 'queued');
  const completed = jobs.filter(j => j.status === 'completed').slice(-5).reverse();

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SPIN Control</title>
<style>
:root{color-scheme:dark;--bg:#101418;--panel:#171d22;--line:#29323a;--text:#edf2f7;--muted:#98a6b3;--cyan:#38bdf8;--green:#34d399;--yellow:#facc15;--red:#fb7185}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header{display:flex;justify-content:space-between;gap:16px;align-items:center;padding:18px 24px;border-bottom:1px solid var(--line);background:#0c1115;position:sticky;top:0}
h1{font-size:18px;margin:0}main{max-width:1180px;margin:0 auto;padding:20px;display:grid;gap:16px}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}
section{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}h2{font-size:14px;margin:0 0 10px;color:#dbeafe}.muted{color:var(--muted)}.pill{display:inline-flex;border:1px solid var(--line);border-radius:999px;padding:2px 8px;margin-right:6px;color:var(--muted)}
ul{padding-left:18px;margin:8px 0}li{margin:6px 0}pre{white-space:pre-wrap;word-break:break-word;background:#0c1115;border:1px solid var(--line);border-radius:6px;padding:10px;max-height:360px;overflow:auto}
button{border:1px solid var(--line);border-radius:6px;background:#0f1720;color:var(--text);padding:6px 9px;cursor:pointer}button:hover{border-color:var(--cyan)}input{width:100%;border:1px solid var(--line);border-radius:6px;background:#0c1115;color:var(--text);padding:7px}
form.inline{display:inline-flex;gap:6px;margin:4px 4px 0 0;align-items:center}.decision{border-top:1px solid var(--line);padding-top:10px;margin-top:10px}.ok{color:var(--green)}.warn{color:var(--yellow)}.bad{color:var(--red)}a{color:var(--cyan);text-decoration:none}a:hover{text-decoration:underline}
@media(max-width:900px){.grid{grid-template-columns:1fr}header{align-items:flex-start;flex-direction:column}}
</style>
</head>
<body>
<header><div><h1>SPIN Control</h1><div class="muted">${escapeHTML(ROOT)}</div></div><div><span class="pill">${active.length} projects</span><span class="pill">${queued.length} queued</span><span class="pill">${waiting.length} waiting</span></div></header>
<main>
${message ? `<section><strong class="ok">${escapeHTML(message)}</strong></section>` : ''}
<div class="grid">
<section><h2>Waiting On You</h2>${waiting.length ? waiting.map(item => `
  <div class="decision">
    <div>${escapeHTML(item.text)}</div>
    ${['APPROVE','DECLINE','ASK'].map(action => `<form class="inline" method="post" action="/decision"><input type="hidden" name="item" value="${escapeHTML(item.text)}"><input type="hidden" name="action" value="${action}"><button>${action}</button></form>`).join('')}
  </div>`).join('') : '<p class="ok">Nothing waiting.</p>'}</section>
<section><h2>Jobs</h2><p><span class="pill">${running.length} running</span><span class="pill">${queued.length} queued</span><span class="pill">${completed.length} recent done</span></p>
<ul>${queued.slice(0, 8).map(j => `<li><strong>${escapeHTML(j.id)}</strong> <span class="muted">${escapeHTML(j.project_id)} · ${escapeHTML(j.type)}</span><br>${escapeHTML(truncate(j.description, 110))}</li>`).join('') || '<li class="muted">No queued jobs.</li>'}</ul></section>
<section><h2>Pending Decisions</h2><ul>${pending.map(line => `<li>${escapeHTML(line)}</li>`).join('') || '<li class="muted">No pending approvals.</li>'}</ul>
<form method="post" action="/decision"><input name="item" placeholder="Manual approval text"><div style="display:flex;gap:6px;margin-top:8px"><button name="action" value="APPROVE">Approve</button><button name="action" value="DECLINE">Decline</button><button name="action" value="ASK">Ask</button></div></form></section>
</div>
<section><h2>Projects</h2><div class="grid">${active.map(p => {
    const id = p.project || p.id || '?';
    return `<section><h2>${escapeHTML(id)}</h2><p class="muted">${escapeHTML(truncate(p.next_action || 'No next action.', 120))}</p><p><a href="/floor/${encodeURIComponent(id)}">Open floor board</a></p></section>`;
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
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(page(url.searchParams.get('ok') || ''));
      return;
    }
    if (req.method === 'GET' && url.pathname.startsWith('/floor/')) {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(floorPage(decodeURIComponent(url.pathname.slice('/floor/'.length))));
      return;
    }
    if (req.method === 'POST' && url.pathname === '/decision') {
      const params = new URLSearchParams(await readBody(req));
      writeApproval(params.get('action'), params.get('item'), params.get('note') || '');
      res.writeHead(303, { location: '/?ok=Decision%20recorded' });
      res.end();
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found\n');
  } catch (err) {
    res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`SPIN web error: ${err.message}\n`);
  }
});

server.listen(PORT, HOST, () => {
  const addr = server.address();
  const url = `http://${HOST}:${addr.port}/`;
  console.log(`SPIN web: ${url}`);
  if (SHOULD_OPEN && process.platform === 'darwin') {
    const child = spawn('open', [url], { stdio: 'ignore', detached: true });
    child.unref();
  }
});
