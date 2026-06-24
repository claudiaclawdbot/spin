#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function parseTimestamp(text) {
  const m = String(text || '').match(/(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?Z?/);
  if (!m) return null;
  const [, y, mo, d, h, mi, s = '0'] = m;
  const ms = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s));
  if (!Number.isFinite(ms)) return null;
  return new Date(ms);
}

function formatAge(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '';
  const mins = Math.floor(seconds / 60);
  const hours = Math.floor(mins / 60);
  const days = Math.floor(hours / 24);
  if (days > 0) return `${days}d ${hours % 24}h`;
  if (hours > 0) return `${hours}h ${mins % 60}m`;
  if (mins > 0) return `${mins}m`;
  return '<1m';
}

function cleanLine(line) {
  return String(line || '').replace(/^\s*-\s*/, '').replace(/\*\*/g, '').trim();
}

function activeItemFromLine(line, index, nowMs) {
  const checkbox = line.match(/^\s*-\s+\[([ xX])\]\s*(.*)$/);
  let body;
  if (checkbox) {
    if (checkbox[1].toLowerCase() === 'x') return null;
    body = checkbox[2];
  } else {
    const plain = line.match(/^\s*-\s+(?!\[[ xX]\]\s*)(.*)$/);
    if (!plain) return null;
    body = plain[1];
  }
  const createdAt = parseTimestamp(body);
  const ageSeconds = createdAt ? Math.max(0, Math.floor((nowMs - createdAt.getTime()) / 1000)) : null;
  return {
    index,
    text: cleanLine(line),
    createdAt: createdAt ? createdAt.toISOString() : null,
    ageSeconds,
    ageLabel: ageSeconds == null ? '' : formatAge(ageSeconds),
  };
}

function summarizeHumanQueueText(text, now = new Date()) {
  const nowMs = now.getTime();
  const items = String(text || '')
    .split(/\r?\n/)
    .map((line, index) => activeItemFromLine(line, index, nowMs))
    .filter(Boolean);

  const dated = items.filter(item => item.createdAt);
  dated.sort((a, b) => a.ageSeconds - b.ageSeconds);
  const oldest = dated[dated.length - 1] || items[0] || null;
  const oldestAgeSeconds = oldest && oldest.ageSeconds != null ? oldest.ageSeconds : 0;
  let severity = 'none';
  let color = '#22c55e';
  if (items.length > 0) {
    severity = oldestAgeSeconds >= 24 * 3600 ? 'stale' : oldestAgeSeconds >= 4 * 3600 ? 'warn' : 'waiting';
    color = severity === 'stale' ? '#ef4444' : severity === 'warn' ? '#f97316' : '#eab308';
  }
  const oldestAgeLabel = oldest && oldest.ageSeconds != null ? formatAge(oldest.ageSeconds) : '';
  return {
    count: items.length,
    oldestAt: oldest ? oldest.createdAt : null,
    oldestAgeSeconds,
    oldestAgeLabel,
    oldestText: oldest ? oldest.text : '',
    severity,
    color,
    summary: items.length === 0
      ? 'nothing waiting'
      : `${items.length} waiting${oldestAgeLabel ? `, oldest ${oldestAgeLabel}` : ''}`,
    items,
  };
}

function summarizeHumanQueue(root, now = new Date()) {
  const file = path.join(root, 'org', 'HUMAN_QUEUE.md');
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch {}
  return summarizeHumanQueueText(text, now);
}

function shellQuote(value) {
  return `'${String(value == null ? '' : value).replace(/'/g, `'\\''`)}'`;
}

function printEnv(summary) {
  const env = {
    SPIN_HUMAN_WAITING_COUNT: String(summary.count),
    SPIN_HUMAN_WAITING_SUMMARY: summary.summary,
    SPIN_HUMAN_WAITING_OLDEST_SECONDS: String(summary.oldestAgeSeconds || 0),
    SPIN_HUMAN_WAITING_OLDEST_AGE: summary.oldestAgeLabel || '',
    SPIN_HUMAN_WAITING_OLDEST_AT: summary.oldestAt || '',
    SPIN_HUMAN_WAITING_OLDEST_TEXT: summary.oldestText || '',
    SPIN_HUMAN_WAITING_SEVERITY: summary.severity,
    SPIN_HUMAN_WAITING_COLOR: summary.color,
  };
  for (const [key, value] of Object.entries(env)) console.log(`${key}=${shellQuote(value)}`);
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const root = args.find(arg => !arg.startsWith('--')) || process.env.SPIN_ROOT || process.env.OMP_ROOT || path.resolve(__dirname, '..', '..');
  const summary = summarizeHumanQueue(root);
  if (args.includes('--env')) printEnv(summary);
  else if (args.includes('--lines')) {
    for (const item of summary.items) console.log(item.text);
  } else if (args.includes('--text')) {
    console.log(summary.summary);
  } else {
    console.log(JSON.stringify(summary, null, 2));
  }
}

module.exports = {
  formatAge,
  summarizeHumanQueue,
  summarizeHumanQueueText,
};
