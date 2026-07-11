#!/usr/bin/env node
// Deny-by-default broker for SPIN's sensitive external actions.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const TRUSTED_HOME = os.userInfo().homedir;
const TRUSTED_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';

const selfDir = path.dirname(fs.realpathSync(__filename));
const ROOT = path.resolve(process.env.SPIN_ROOT || process.env.OMP_ROOT || path.join(selfDir, '..'));
const ORG = path.join(ROOT, 'org');
const POLICY_FILE = path.join(ORG, 'ACTION_POLICY.json');
const BROKER_DIR = path.join(ORG, 'action-broker');
const RECEIPTS_DIR = path.join(BROKER_DIR, 'receipts');
const EVENTS_FILE = path.join(BROKER_DIR, 'events.jsonl');
const LOCK_FILE = path.join(BROKER_DIR, '.lock');
const HUMAN_QUEUE = path.join(ORG, 'HUMAN_QUEUE.md');
const CATEGORIES = new Set([
  'external-send',
  'spend',
  'production-deploy',
  'protected-push',
]);

function usage(code = 0) {
  const out = code === 0 ? process.stdout : process.stderr;
  out.write(`Usage:
  spin action status [--json]
  spin action check <category> --target <exact-target> [--rule <id>] [--amount <USD>]
  spin action request <category> --target <exact-target> --reason <text> [--amount <USD>]
  spin action execute <category> --target <exact-target> --reason <text> [--rule <id>] [--amount <USD>]

Categories: external-send, spend, production-deploy, protected-push

Execution uses the exact command and cwd stored in org/ACTION_POLICY.json.
Arbitrary command text is never accepted from the caller.
`);
  process.exit(code);
}

function die(code, message) {
  process.stderr.write(`spin action: ${message}\n`);
  process.exit(code);
}

function parse(argv) {
  const pos = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      pos.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (Object.prototype.hasOwnProperty.call(flags, key)) die(1, `duplicate flag --${key}`);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) flags[key] = true;
    else {
      flags[key] = next;
      i += 1;
    }
  }
  return { pos, flags };
}

function flagValue(flags, name, required = false) {
  const value = flags[name];
  if (value === true) die(1, `--${name} requires a value`);
  if (required && (value === undefined || !String(value).trim())) die(1, `--${name} is required`);
  return value === undefined ? undefined : String(value).trim();
}

function oneLine(value, label, maxLength = 500) {
  const text = String(value || '').trim();
  if (!text) die(2, `${label} cannot be empty`);
  if (text.length > maxLength) die(2, `${label} exceeds ${maxLength} characters`);
  if (/[\0\r\n]/.test(text)) die(2, `${label} must be one line`);
  return text;
}

function parseMoney(raw, required = false, label = 'amount') {
  if (raw === undefined) {
    if (required) die(2, `--${label} is required for spend actions`);
    return null;
  }
  const value = String(raw).trim();
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(value)) die(2, `--${label} must be a non-negative USD amount with at most two decimals`);
  const cents = Math.round(Number(value) * 100);
  if (!Number.isSafeInteger(cents)) die(2, `--${label} is too large`);
  return cents;
}

function money(cents) {
  return (cents / 100).toFixed(2);
}

function expandPolicyValue(value) {
  const expanded = String(value)
    .split('${SPIN_ROOT}').join(ROOT)
    .split('${HOME}').join(TRUSTED_HOME);
  if (/\$\{[^}]+\}/.test(expanded)) die(2, `unsupported policy placeholder in ${JSON.stringify(value)}`);
  return expanded;
}

function readPolicy({ allowMissing = false } = {}) {
  if (!fs.existsSync(POLICY_FILE)) {
    if (allowMissing) return null;
    die(2, 'org/ACTION_POLICY.json is missing; run ./install.sh to seed a deny-all policy');
  }
  let policy;
  try {
    const stat = fs.lstatSync(POLICY_FILE);
    if (stat.isSymbolicLink()) die(2, 'ACTION_POLICY.json must not be a symlink');
    if (process.platform !== 'win32' && (stat.mode & 0o022) !== 0) {
      die(2, 'ACTION_POLICY.json must not be writable by group or other users');
    }
    policy = JSON.parse(fs.readFileSync(POLICY_FILE, 'utf8'));
  } catch (error) {
    if (error && typeof error.code === 'number') throw error;
    die(2, `cannot read ACTION_POLICY.json: ${error.message}`);
  }
  if (policy.version !== 1) die(2, 'ACTION_POLICY.json version must be 1');
  if (policy.mode !== 'deny-by-default') die(2, 'ACTION_POLICY.json mode must be "deny-by-default"');
  if (!Array.isArray(policy.rules)) die(2, 'ACTION_POLICY.json rules must be an array');

  const ids = new Set();
  for (const rule of policy.rules) {
    if (!rule || typeof rule !== 'object' || Array.isArray(rule)) die(2, 'every action rule must be an object');
    if (!/^[A-Za-z0-9._:-]+$/.test(String(rule.id || ''))) die(2, 'each action rule needs a stable id');
    if (ids.has(rule.id)) die(2, `duplicate action rule id "${rule.id}"`);
    ids.add(rule.id);
    if (!CATEGORIES.has(rule.category)) die(2, `rule ${rule.id} has an unknown category`);
    const target = oneLine(rule.target, `target for rule ${rule.id}`, 300);
    if (target !== rule.target) die(2, `rule ${rule.id} target must not have leading or trailing whitespace`);
    if (typeof rule.enabled !== 'boolean') die(2, `rule ${rule.id} enabled must be true or false`);
    if (!Array.isArray(rule.command) || rule.command.length < 1 || rule.command.length > 64) {
      die(2, `rule ${rule.id} command must be a non-empty argv array`);
    }
    for (const part of rule.command) {
      if (typeof part !== 'string' || !part || /\0/.test(part)) die(2, `rule ${rule.id} command contains an invalid argv value`);
    }
    const executable = expandPolicyValue(rule.command[0]);
    if (!path.isAbsolute(executable)) die(2, `rule ${rule.id} command must use an absolute executable path`);
    if (rule.cwd !== undefined && !path.isAbsolute(expandPolicyValue(rule.cwd))) {
      die(2, `rule ${rule.id} cwd must be absolute`);
    }
    const timeout = rule.timeout_seconds === undefined ? 900 : Number(rule.timeout_seconds);
    if (!Number.isInteger(timeout) || timeout < 1 || timeout > 86400) die(2, `rule ${rule.id} timeout_seconds must be 1..86400`);
    if (rule.category === 'spend') {
      const perAction = parseMoney(rule.per_action_usd, false, 'per_action_usd');
      const perDay = parseMoney(rule.per_day_usd, false, 'per_day_usd');
      if (perAction === null || perAction < 1 || perDay === null || perDay < 1) {
        die(2, `spend rule ${rule.id} needs positive per_action_usd and per_day_usd caps`);
      }
    }
  }
  return policy;
}

function ensureBrokerDir() {
  fs.mkdirSync(RECEIPTS_DIR, { recursive: true, mode: 0o700 });
  for (const dir of [BROKER_DIR, RECEIPTS_DIR]) {
    if (fs.lstatSync(dir).isSymbolicLink()) die(3, `${path.relative(ROOT, dir)} must not be a symlink`);
    try { fs.chmodSync(dir, 0o700); } catch {}
  }
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withLock(fn) {
  ensureBrokerDir();
  const deadline = Date.now() + 5000;
  for (;;) {
    try {
      fs.writeFileSync(LOCK_FILE, String(process.pid), { flag: 'wx', mode: 0o600 });
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') die(3, `cannot acquire broker lock: ${error.message}`);
      let holder = null;
      try { holder = Number.parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10); } catch {}
      let alive = false;
      if (Number.isInteger(holder)) {
        try { process.kill(holder, 0); alive = true; } catch {}
      }
      if (!alive) {
        try { fs.unlinkSync(LOCK_FILE); } catch {}
        continue;
      }
      if (Date.now() >= deadline) die(3, `broker is busy (PID ${holder})`);
      sleep(100);
    }
  }
  try {
    return fn();
  } finally {
    try {
      if (fs.readFileSync(LOCK_FILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(LOCK_FILE);
    } catch {}
  }
}

function readEvents() {
  if (!fs.existsSync(EVENTS_FILE)) return [];
  if (fs.lstatSync(EVENTS_FILE).isSymbolicLink()) die(3, 'events.jsonl must not be a symlink');
  const events = [];
  for (const line of fs.readFileSync(EVENTS_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { events.push(JSON.parse(line)); } catch { die(3, 'events.jsonl contains invalid JSON'); }
  }
  return events;
}

function appendEvent(event) {
  ensureBrokerDir();
  if (fs.existsSync(EVENTS_FILE) && fs.lstatSync(EVENTS_FILE).isSymbolicLink()) die(3, 'events.jsonl must not be a symlink');
  fs.appendFileSync(EVENTS_FILE, `${JSON.stringify(event)}\n`, { mode: 0o600 });
}

function resolveRule(policy, category, target, ruleId) {
  const matches = policy.rules.filter(rule =>
    rule.enabled === true &&
    rule.category === category &&
    rule.target === target &&
    (!ruleId || rule.id === ruleId));
  if (matches.length === 0) {
    const suffix = ruleId ? ` with rule ${ruleId}` : '';
    die(2, `DENY: no enabled exact-match rule for ${category} target ${JSON.stringify(target)}${suffix}`);
  }
  if (matches.length > 1) die(2, `DENY: multiple rules match; pass --rule with one exact rule id`);
  return matches[0];
}

function assertSpendBudget(rule, amountCents, events) {
  if (rule.category !== 'spend') {
    if (amountCents !== null) die(2, '--amount is only valid for spend actions');
    return;
  }
  if (amountCents === null || amountCents < 1) die(2, '--amount must be greater than zero for spend actions');
  const perAction = parseMoney(rule.per_action_usd, true, 'per_action_usd');
  const perDay = parseMoney(rule.per_day_usd, true, 'per_day_usd');
  if (amountCents > perAction) die(2, `DENY: $${money(amountCents)} exceeds rule ${rule.id} per-action cap $${money(perAction)}`);
  const today = new Date().toISOString().slice(0, 10);
  const used = events
    .filter(event => event.phase === 'started' && event.category === 'spend' && String(event.at || '').startsWith(today))
    .reduce((sum, event) => sum + Number(event.amount_cents || 0), 0);
  if (used + amountCents > perDay) {
    die(2, `DENY: today's conservative spend total would be $${money(used + amountCents)}; cap is $${money(perDay)}`);
  }
}

function commandFor(rule) {
  const argv = rule.command.map(expandPolicyValue);
  const executable = argv[0];
  let realExecutable;
  try { realExecutable = fs.realpathSync(executable); } catch { die(2, `rule ${rule.id} executable does not exist: ${executable}`); }
  try { fs.accessSync(realExecutable, fs.constants.X_OK); } catch { die(2, `rule ${rule.id} executable is not runnable: ${executable}`); }
  const cwd = expandPolicyValue(rule.cwd || ROOT);
  try {
    if (!fs.statSync(cwd).isDirectory()) die(2, `rule ${rule.id} cwd is not a directory: ${cwd}`);
  } catch (error) {
    if (error && typeof error.code === 'number') throw error;
    die(2, `rule ${rule.id} cwd is unavailable: ${cwd}`);
  }
  return { executable: realExecutable, args: argv.slice(1), cwd };
}

function executionEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/^(?:BASH_ENV|ENV|CDPATH|GIT_ASKPASS|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_\d+|GIT_CONFIG_VALUE_\d+|GIT_PROXY_COMMAND|GIT_SSH_COMMAND|NODE_OPTIONS|RUBYOPT|PYTHONPATH|SSH_ASKPASS|LD_PRELOAD|DYLD_.*)$/.test(key)) {
      delete env[key];
    }
  }
  env.HOME = TRUSTED_HOME;
  env.PATH = TRUSTED_PATH;
  return env;
}

function writeReceipt(receipt) {
  ensureBrokerDir();
  const stamp = receipt.finished_at.replace(/[-:.TZ]/g, '').slice(0, 14);
  const relative = path.join('org', 'action-broker', 'receipts', `${stamp}-${receipt.action_id}.json`);
  const file = path.join(ROOT, relative);
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
  return relative;
}

function status(jsonMode) {
  const policy = readPolicy({ allowMissing: true });
  const events = readEvents();
  const enabled = policy ? policy.rules.filter(rule => rule.enabled) : [];
  const today = new Date().toISOString().slice(0, 10);
  const spendCents = events
    .filter(event => event.phase === 'started' && event.category === 'spend' && String(event.at || '').startsWith(today))
    .reduce((sum, event) => sum + Number(event.amount_cents || 0), 0);
  const report = {
    status: policy ? (enabled.length ? 'ready' : 'deny_all') : 'missing',
    secure_default: true,
    policy: path.relative(ROOT, POLICY_FILE),
    mode: policy ? policy.mode : 'deny-by-default',
    enabled_rules: enabled.length,
    enabled_by_category: Object.fromEntries([...CATEGORIES].map(category => [category, enabled.filter(rule => rule.category === category).length])),
    executions_recorded: events.filter(event => event.phase === 'finished').length,
    conservative_spend_today_usd: money(spendCents),
  };
  if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  else {
    process.stdout.write(`Action broker: ${report.status}\n`);
    process.stdout.write(`  policy: ${report.policy}\n`);
    process.stdout.write(`  enabled rules: ${report.enabled_rules}\n`);
    process.stdout.write(`  conservative spend today: $${report.conservative_spend_today_usd}\n`);
    if (!policy) process.stdout.write('  note: policy is missing, so every sensitive action is denied\n');
    else if (!enabled.length) process.stdout.write('  note: deny-all is active until the owner enables exact rules\n');
  }
}

function requestAction(category, target, amountCents, reason) {
  const seed = [category, target, amountCents ?? '', reason].join('\n');
  const id = crypto.createHash('sha256').update(seed).digest('hex').slice(0, 12);
  const amount = amountCents === null ? '' : ` $${money(amountCents)}`;
  const line = `- [ ] [action:${id}] ${category}${amount} -> ${target} | ${reason}`;
  try {
    withLock(() => {
      fs.mkdirSync(path.dirname(HUMAN_QUEUE), { recursive: true });
      let current = '';
      try { current = fs.readFileSync(HUMAN_QUEUE, 'utf8'); } catch {}
      if (current.includes(`[action:${id}]`)) return;
      if (!current.trim()) current = '# Waiting on you\n';
      fs.appendFileSync(HUMAN_QUEUE, `${current.endsWith('\n') ? '' : '\n'}${line}\n`);
    });
  } catch (error) {
    die(3, `could not record action request: ${error.message}`);
  }
  process.stdout.write(`requested action:${id}; no command was executed\n`);
}

function checkAction(category, target, ruleId, amountCents) {
  const policy = readPolicy();
  const rule = resolveRule(policy, category, target, ruleId);
  const events = readEvents();
  assertSpendBudget(rule, amountCents, events);
  const command = commandFor(rule);
  process.stdout.write(`ALLOW: ${rule.id}\n`);
  process.stdout.write(`  category: ${category}\n`);
  process.stdout.write(`  target: ${target}\n`);
  process.stdout.write(`  executable: ${path.basename(command.executable)}\n`);
  if (amountCents !== null) process.stdout.write(`  amount: $${money(amountCents)}\n`);
}

function executeAction(category, target, ruleId, amountCents, reason) {
  let exitCode = 3;
  try {
    withLock(() => {
      const policy = readPolicy();
      const rule = resolveRule(policy, category, target, ruleId);
      const events = readEvents();
      assertSpendBudget(rule, amountCents, events);
      const command = commandFor(rule);
      const actionId = crypto.randomUUID();
      const startedAt = new Date().toISOString();
      appendEvent({
        version: 1,
        phase: 'started',
        action_id: actionId,
        at: startedAt,
        rule_id: rule.id,
        category,
        target,
        amount_cents: amountCents,
        executable: path.basename(command.executable),
      });

      const timeoutSeconds = rule.timeout_seconds === undefined ? 900 : Number(rule.timeout_seconds);
      const result = spawnSync(command.executable, command.args, {
        cwd: command.cwd,
        env: executionEnv(),
        stdio: 'inherit',
        timeout: timeoutSeconds * 1000,
        killSignal: 'SIGTERM',
      });
      const finishedAt = new Date().toISOString();
      const timedOut = Boolean(result.error && result.error.code === 'ETIMEDOUT');
      const success = !result.error && result.status === 0;
      const status = success ? 0 : (Number.isInteger(result.status) ? result.status : 1);
      const receipt = {
        version: 1,
        action_id: actionId,
        rule_id: rule.id,
        category,
        target,
        amount_usd: amountCents === null ? null : money(amountCents),
        reason,
        executable: path.basename(command.executable),
        started_at: startedAt,
        finished_at: finishedAt,
        outcome: success ? 'succeeded' : (timedOut ? 'timed_out' : 'failed'),
        exit_code: status,
        signal: result.signal || null,
      };
      const receiptFile = writeReceipt(receipt);
      appendEvent({
        version: 1,
        phase: 'finished',
        action_id: actionId,
        at: finishedAt,
        rule_id: rule.id,
        category,
        target,
        amount_cents: amountCents,
        outcome: receipt.outcome,
        exit_code: status,
        receipt: receiptFile,
      });
      process.stdout.write(`action ${receipt.outcome}: ${actionId}\nreceipt: ${receiptFile}\n`);
      exitCode = status;
    });
  } catch (error) {
    die(3, `broker execution record failed: ${error.message}`);
  }
  process.exit(exitCode);
}

const parsed = parse(process.argv.slice(2));
const verb = parsed.pos.shift() || 'status';
if (verb === 'help' || parsed.flags.help) usage(0);
const allowedFlags = {
  status: new Set(['json']),
  check: new Set(['target', 'rule', 'amount']),
  request: new Set(['target', 'reason', 'amount']),
  execute: new Set(['target', 'rule', 'reason', 'amount']),
};
if (allowedFlags[verb]) {
  for (const name of Object.keys(parsed.flags)) {
    if (!allowedFlags[verb].has(name)) die(1, `unknown flag --${name} for ${verb}`);
  }
}
if (verb === 'status') {
  if (parsed.pos.length) usage(1);
  status(Boolean(parsed.flags.json));
  process.exit(0);
}
if (!['check', 'request', 'execute'].includes(verb)) usage(1);
const category = parsed.pos.shift();
if (!category || parsed.pos.length) usage(1);
if (!CATEGORIES.has(category)) die(2, `unknown category ${JSON.stringify(category)}`);
const target = oneLine(flagValue(parsed.flags, 'target', true), 'target', 300);
const ruleIdRaw = flagValue(parsed.flags, 'rule');
const ruleId = ruleIdRaw === undefined ? undefined : oneLine(ruleIdRaw, 'rule id', 100);
const amountCents = parseMoney(flagValue(parsed.flags, 'amount'), category === 'spend');

if (verb === 'check') {
  checkAction(category, target, ruleId, amountCents);
  process.exit(0);
}
const reason = oneLine(flagValue(parsed.flags, 'reason', true), 'reason', 500);
if (verb === 'request') {
  requestAction(category, target, amountCents, reason);
  process.exit(0);
}
executeAction(category, target, ruleId, amountCents, reason);
