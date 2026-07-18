#!/usr/bin/env node
// ceo-dashboard.js — render ONE frame of the OMP live dashboard.
// Usage: node ceo-dashboard.js <root>
// Called in a loop by `ceo watch`. Reads org state; never writes anything.

const fs   = require('fs');
const path = require('path');
const { summarizeHumanQueue } = require('./lib/human-queue-summary.js');
const { processLockOwnerAlive, readProcessLock } = require('./lib/spin-runtime.js');

const root    = process.argv[2] || process.env.OMP_ROOT || require("path").resolve(__dirname, "..");
const ORG     = path.join(root, 'org');
const JOBS    = path.join(ORG, 'jobs');
const RUNS    = path.join(ORG, 'ceo', 'runs');

// ── ANSI ────────────────────────────────────────────────────────────────────
const c = {
  bold: '\x1b[1m', dim: '\x1b[2m', off: '\x1b[0m',
  grn: '\x1b[32m', yel: '\x1b[33m', cyn: '\x1b[36m', red: '\x1b[31m', gry: '\x1b[90m',
};
const trunc = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const readJSON = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

const out = [];
const W = '────────────────────────────────────────────────────────────';

// ── Header: driver status ─────────────────────────────────────────────────
const now = new Date();
const lock = path.join(RUNS, '.workspace-ceo-tick.lock');
let driver = `${c.yel}○ paused${c.off}`;
if (fs.existsSync(path.join(RUNS, 'STOP'))) {
  driver = `${c.yel}○ STOPPED (kill switch set)${c.off}`;
} else if (fs.existsSync(lock)) {
  const owner = readProcessLock(lock);
  driver = owner && processLockOwnerAlive(lock)
    ? `${c.grn}● running${c.off} (PID ${owner.pid})`
    : `${c.yel}○ not running${c.off}`;
} else {
  driver = `${c.yel}○ not running${c.off}`;
}

// codex lockout
let codex = '';
const codexFile = path.join(RUNS, 'codex-blocked-until');
if (fs.existsSync(codexFile)) {
  const until = parseInt(fs.readFileSync(codexFile, 'utf8').trim(), 10);
  if (Date.now() / 1000 < until) codex = `  |  codex benched → ${new Date(until * 1000).toLocaleString([], { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })}`;
}

out.push(`${c.bold}${c.cyn}═══ OMP LIVE ═══${c.off}  ${c.dim}${now.toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' })}${c.off}`);
out.push(`Driver: ${driver}${c.dim}${codex}${c.off}`);
out.push('');

// ── Projects ──────────────────────────────────────────────────────────────
const state = readJSON(path.join(ORG, 'state.json'));
const isActive = status => {
  const value = String(status || '').toLowerCase();
  return value && !/^(candidate|inactive|complete(?:d)?|archived|paused|disabled)(?:$|-)/.test(value);
};
out.push(`${c.bold}PROJECTS${c.off}`);
if (state && state.project_orchestrators) {
  for (const p of state.project_orchestrators) {
    if (!isActive(p.status)) continue;
    out.push(`  ${c.bold}${(p.project || p.id || '?').padEnd(14)}${c.off}${c.dim}${trunc(p.next_action || '—', 70)}${c.off}`);
  }
} else out.push(`  ${c.dim}(state unreadable)${c.off}`);
out.push('');

// ── Jobs ──────────────────────────────────────────────────────────────────
const queue = readJSON(path.join(ORG, 'AGENT_QUEUE.json')) || { jobs: [] };
const byId = Object.fromEntries((queue.jobs || []).map(j => [j.id, j]));

// running = live pid files
let running = [];
try {
  for (const f of fs.readdirSync(JOBS)) {
    if (!f.endsWith('.pid')) continue;
    const id = f.slice(0, -4);
    const pid = parseInt(fs.readFileSync(path.join(JOBS, f), 'utf8').trim(), 10);
    if (pidAlive(pid)) running.push({ id, pid, job: byId[id] });
  }
} catch {}

out.push(`${c.bold}RUNNING JOBS${c.off} ${c.dim}(${running.length})${c.off}`);
if (running.length === 0) out.push(`  ${c.dim}none${c.off}`);
for (const r of running) {
  const proj = r.job ? r.job.project_id : '?';
  const type = r.job ? r.job.type : '?';
  out.push(`  ${c.grn}●${c.off} ${c.bold}${r.id}${c.off}  ${c.dim}(${proj} · ${type} · pid ${r.pid})${c.off}`);
  // last 2 log lines
  try {
    const lines = fs.readFileSync(path.join(JOBS, r.id + '.log'), 'utf8').trim().split('\n');
    for (const ln of lines.slice(-2)) out.push(`      ${c.gry}${trunc(ln, 72)}${c.off}`);
  } catch {}
}
out.push('');

// queued
const queued = (queue.jobs || []).filter(j => j.status === 'queued');
out.push(`${c.bold}QUEUED${c.off} ${c.dim}(${queued.length})${c.off}`);
if (queued.length === 0) out.push(`  ${c.dim}none${c.off}`);
for (const j of queued.slice(0, 6)) out.push(`  ${c.yel}⏳${c.off} ${j.id} ${c.dim}${trunc(j.description, 50)}${c.off}`);
out.push('');

// ── Waiting on you ────────────────────────────────────────────────────────
const wait = summarizeHumanQueue(root, now);
out.push(`${c.bold}${c.yel}WAITING ON YOU${c.off}${wait.count ? ` ${c.dim}(${wait.summary})${c.off}` : ''}`);
if (wait.count === 0) out.push(`  ${c.grn}nothing — you're clear${c.off}`);
for (const item of wait.items) out.push(`  ${c.yel}⏳${c.off} ${trunc(item.text, 76)}`);
if (wait.count) out.push(`  ${c.dim}approve:  spin approve "<project> <what>"   ·   steer: spin chat${c.off}`);
out.push('');

// ── Last CEO decision ─────────────────────────────────────────────────────
out.push(`${c.bold}LAST CEO DECISION${c.off}`);
try {
  const receipts = fs.readdirSync(RUNS).filter(f => /^workspace-ceo-agent-.*\.md$/.test(f)).sort();
  const latest = receipts[receipts.length - 1];
  if (latest) {
    const body = fs.readFileSync(path.join(RUNS, latest), 'utf8');
    const dec = (body.split(/## Decision/)[1] || '').split(/## /)[0].trim();
    for (const ln of dec.split('\n').filter(Boolean).slice(0, 4)) out.push(`  ${c.dim}${trunc(ln, 76)}${c.off}`);
  } else out.push(`  ${c.dim}(no receipts yet)${c.off}`);
} catch { out.push(`  ${c.dim}(no receipts)${c.off}`); }

out.push('');
out.push(`${c.dim}${W}${c.off}`);
out.push(`${c.dim}refresh 5s · Ctrl-C to exit  ·  ceo chat (steer)  ·  ceo approve/decline/ask${c.off}`);

process.stdout.write(out.join('\n') + '\n');
