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
// This is deliberately a sibling of ACTION_POLICY.json rather than another
// field in it.  The policy remains a stable, owner-reviewed allowlist while a
// short-lived lease is operational state that evaporates into a harmless deny
// after its expiry.
const LEASE_FILE = path.join(ORG, 'ACTION_POLICY.lease.json');
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
const LEASE_SCHEMA_VERSION = 1;
const LEASE_MAX_TTL_SECONDS = 3600;
const LEASE_MIN_REMAINING_MS = 1000;

function usage(code = 0) {
  const out = code === 0 ? process.stdout : process.stderr;
  out.write(`Usage:
  spin action status [--json]
  spin action check <category> --target <exact-target> [--rule <id>] [--amount <USD>]
  spin action request <category> --target <exact-target> --reason <text> [--amount <USD>]
  spin action execute <category> --target <exact-target> --reason <text> [--rule <id>] [--amount <USD>]
  spin action lease arm <rule-id> --ttl-seconds <1..${LEASE_MAX_TTL_SECONDS}> --owner-marked [--json]
  spin action lease revoke [--json]
  spin action lease status [--json]
  spin action lease recover [--json]

Categories: external-send, spend, production-deploy, protected-push

Execution uses the exact command and cwd stored in org/ACTION_POLICY.json.
Arbitrary command text is never accepted from the caller.
Enabled rules also need an unexpired, policy-bound lease before they can run.
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
    const raw = fs.readFileSync(POLICY_FILE, 'utf8');
    policy = JSON.parse(raw);
    Object.defineProperty(policy, '__spinPolicyDigest', {
      value: crypto.createHash('sha256').update(raw).digest('hex'),
      enumerable: false,
    });
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

function policyDigest(policy) {
  if (!policy || !/^[a-f0-9]{64}$/.test(String(policy.__spinPolicyDigest || ''))) {
    die(3, 'cannot determine ACTION_POLICY.json digest');
  }
  return policy.__spinPolicyDigest;
}

function ensureLeaseParent() {
  let stat;
  try { stat = fs.lstatSync(ORG); } catch (error) { die(3, `cannot inspect org directory for lease: ${error.message}`); }
  if (stat.isSymbolicLink() || !stat.isDirectory()) die(3, 'org directory for lease must be a real directory');
}

function syncOrgDirectory() {
  let fd;
  try {
    fd = fs.openSync(ORG, 'r');
    fs.fsyncSync(fd);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function parseLease(raw) {
  let lease;
  try { lease = JSON.parse(raw); } catch { return { state: 'invalid', message: 'lease is not valid JSON' }; }
  if (!lease || typeof lease !== 'object' || Array.isArray(lease)) return { state: 'invalid', message: 'lease must be an object' };
  if (lease.version !== LEASE_SCHEMA_VERSION) return { state: 'invalid', message: `lease version must be ${LEASE_SCHEMA_VERSION}` };
  if (lease.owner_marked !== true) return { state: 'invalid', message: 'lease must be owner-marked' };
  if (!/^[A-Za-z0-9._:-]+$/.test(String(lease.rule_id || ''))) return { state: 'invalid', message: 'lease rule_id is invalid' };
  if (!/^[a-f0-9]{64}$/.test(String(lease.policy_sha256 || ''))) return { state: 'invalid', message: 'lease policy_sha256 is invalid' };
  if (typeof lease.expires_at !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(lease.expires_at)) {
    return { state: 'invalid', message: 'lease expires_at must be an ISO-8601 UTC timestamp' };
  }
  const expiresAtMs = Date.parse(lease.expires_at);
  if (!Number.isFinite(expiresAtMs)) return { state: 'invalid', message: 'lease expires_at is invalid' };
  return { state: 'parsed', lease, expiresAtMs };
}

function inspectLease(policy) {
  const report = {
    state: 'missing',
    file: path.relative(ROOT, LEASE_FILE),
    required: true,
    max_ttl_seconds: LEASE_MAX_TTL_SECONDS,
  };
  if (!policy || !fs.existsSync(LEASE_FILE)) return report;
  let stat;
  try { stat = fs.lstatSync(LEASE_FILE); } catch (error) { return { ...report, state: 'untrusted', message: error.message }; }
  if (stat.isSymbolicLink() || !stat.isFile()) return { ...report, state: 'untrusted', message: 'lease must be a regular file' };
  if (process.platform !== 'win32') {
    if ((stat.mode & 0o777) !== 0o600) return { ...report, state: 'untrusted', message: 'lease permissions must be 0600' };
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
      return { ...report, state: 'untrusted', message: 'lease must be owned by the broker user' };
    }
  }
  let parsed;
  try { parsed = parseLease(fs.readFileSync(LEASE_FILE, 'utf8')); } catch (error) { return { ...report, state: 'untrusted', message: error.message }; }
  if (parsed.state !== 'parsed') return { ...report, state: 'untrusted', message: parsed.message };
  const { lease, expiresAtMs } = parsed;
  const details = {
    ...report,
    rule_id: lease.rule_id,
    expires_at: lease.expires_at,
    policy_sha256: lease.policy_sha256,
    remaining_ms: Math.max(0, expiresAtMs - Date.now()),
  };
  if (expiresAtMs <= Date.now()) return { ...details, state: 'expired', message: 'lease has expired' };
  if (lease.policy_sha256 !== policyDigest(policy)) return { ...details, state: 'policy_mismatch', message: 'lease does not bind this policy revision' };
  const rule = policy.rules.find(candidate => candidate.id === lease.rule_id && candidate.enabled === true);
  if (!rule) return { ...details, state: 'rule_mismatch', message: 'lease does not bind an enabled rule' };
  return { ...details, state: 'active', rule, expires_at_ms: expiresAtMs };
}

function assertLeaseForRule(policy, rule) {
  const lease = inspectLease(policy);
  if (lease.state !== 'active') die(2, `DENY: rule ${rule.id} requires an active lease (${lease.state})`);
  if (lease.rule.id !== rule.id) die(2, `DENY: rule ${rule.id} requires its own active lease (active lease is for ${lease.rule.id})`);
  if (lease.remaining_ms < LEASE_MIN_REMAINING_MS) die(2, `DENY: rule ${rule.id} lease expires too soon to start safely`);
  return lease;
}

function consumeLeaseForRule(policy, rule) {
  const lease = assertLeaseForRule(policy, rule);
  // This runs while withLock is held.  Remove the lease before spawning the
  // command, not after it returns: a crash on either side of spawn therefore
  // leaves the exact rule denied until an owner arms a new one-shot lease.
  try {
    const stat = fs.lstatSync(LEASE_FILE);
    if (stat.isSymbolicLink() || !stat.isFile()) die(2, `DENY: rule ${rule.id} lease became untrusted before execution`);
    fs.unlinkSync(LEASE_FILE);
    // Do not start the child until removal is durable. Otherwise a power loss
    // could resurrect a consumed lease and authorize a replay after reboot.
    syncOrgDirectory();
  } catch (error) {
    if (error && typeof error.code === 'number') die(2, `DENY: rule ${rule.id} lease could not be consumed`);
    throw error;
  }
  return lease;
}

function atomicWriteLease(lease) {
  ensureLeaseParent();
  const temp = `${LEASE_FILE}.tmp.${process.pid}.${crypto.randomUUID()}`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(lease, null, 2)}\n`, 'utf8');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temp, LEASE_FILE);
    syncOrgDirectory();
  } catch (error) {
    if (fd !== undefined) try { fs.closeSync(fd); } catch {}
    try { fs.unlinkSync(temp); } catch {}
    die(3, `could not write action lease: ${error.message}`);
  }
}

function atomicWritePolicy(policy) {
  ensureLeaseParent();
  const temp = `${POLICY_FILE}.tmp.${process.pid}.${crypto.randomUUID()}`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(policy, null, 2)}\n`, 'utf8');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temp, POLICY_FILE);
    syncOrgDirectory();
  } catch (error) {
    if (fd !== undefined) try { fs.closeSync(fd); } catch {}
    try { fs.unlinkSync(temp); } catch {}
    die(3, `could not write action policy during lease recovery: ${error.message}`);
  }
}

function armLease(ruleId, ttlSeconds, ownerMarked, jsonMode) {
  if (ownerMarked !== true) die(2, 'lease arming requires the explicit --owner-marked flag');
  if (process.env.SPIN_OWNER_CONFIRMED !== '1') die(2, 'lease arming requires SPIN_OWNER_CONFIRMED=1 from the owner-confirmed control path');
  const policy = readPolicy();
  const rule = policy.rules.find(candidate => candidate.id === ruleId && candidate.enabled === true);
  if (!rule) die(2, `cannot arm lease: ${ruleId} is not an enabled rule`);
  withLock(() => {
    // Re-read under the lock so a policy change can never be leased by its
    // previous digest.
    const currentPolicy = readPolicy();
    const currentRule = currentPolicy.rules.find(candidate => candidate.id === ruleId && candidate.enabled === true);
    if (!currentRule) die(2, `cannot arm lease: ${ruleId} is not an enabled rule`);
    const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
    atomicWriteLease({
      version: LEASE_SCHEMA_VERSION,
      owner_marked: true,
      rule_id: currentRule.id,
      policy_sha256: policyDigest(currentPolicy),
      issued_at: new Date().toISOString(),
      expires_at: expiresAt,
    });
  });
  const lease = inspectLease(readPolicy());
  if (lease.state !== 'active' || lease.rule_id !== ruleId) die(3, 'lease was written but did not verify');
  const report = { status: 'armed', lease: leaseStatusContract(lease, false) };
  if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  else process.stdout.write(`lease armed: ${ruleId} until ${lease.expires_at}\n`);
}

function safeRecoveryAvailable(policy, lease) {
  return Boolean(
    policy &&
    lease.state === 'expired' &&
    lease.policy_sha256 === policyDigest(policy) &&
    lease.rule_id &&
    policy.rules.some(rule => rule.id === lease.rule_id && rule.enabled === true)
  );
}

function recoverLease(jsonMode) {
  let report;
  withLock(() => {
    const policy = readPolicy({ allowMissing: true });
    const lease = inspectLease(policy);
    const recoverable = safeRecoveryAvailable(policy, lease);
    if (!recoverable) {
      report = { status: 'not_recovered', lease: leaseStatusContract(lease, false) };
      return;
    }
    const rule = policy.rules.find(candidate => candidate.id === lease.rule_id);
    rule.enabled = false;
    atomicWritePolicy(policy);
    // Policy is already fail-closed if this unlink is interrupted.  Removing
    // the expired record keeps status unambiguous after recovery.
    try { fs.unlinkSync(LEASE_FILE); syncOrgDirectory(); } catch (error) { die(3, `lease recovery disabled ${rule.id} but could not remove stale lease: ${error.message}`); }
    report = {
      status: 'recovered',
      disabled_rule_id: rule.id,
      lease: leaseStatusContract(inspectLease(readPolicy()), false),
    };
  });
  if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  else process.stdout.write(report.status === 'recovered' ? `lease recovery disabled: ${report.disabled_rule_id}\n` : 'lease recovery not needed\n');
}

function revokeLease(jsonMode) {
  withLock(() => {
    if (!fs.existsSync(LEASE_FILE)) return;
    const stat = fs.lstatSync(LEASE_FILE);
    if (stat.isSymbolicLink() || !stat.isFile()) die(3, 'refusing to revoke an untrusted lease file');
    fs.unlinkSync(LEASE_FILE);
    syncOrgDirectory();
  });
  const policy = readPolicy({ allowMissing: true });
  const report = { status: 'revoked', lease: leaseStatusContract(inspectLease(policy), false) };
  if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  else process.stdout.write('lease revoked\n');
}

function leaseStatusContract(lease, recoveryAvailable = false) {
  return {
    schema_version: 1,
    supports_expiring_one_shot_leases: true,
    required_for_enabled_rules: true,
    owner_mark_required: true,
    owner_confirmation_required: true,
    consume_before_spawn: true,
    file: lease.file,
    state: lease.state,
    active: lease.state === 'active',
    execution_allowed: lease.state === 'active' && lease.remaining_ms >= LEASE_MIN_REMAINING_MS,
    owner_marked: lease.state !== 'missing' && lease.state !== 'untrusted' ? true : null,
    recovery_available: recoveryAvailable,
    rule_id: lease.rule_id || null,
    expires_at: lease.expires_at || null,
    remaining_ms: Number.isInteger(lease.remaining_ms) ? lease.remaining_ms : null,
    policy_sha256: lease.policy_sha256 || null,
    max_ttl_seconds: lease.max_ttl_seconds,
    message: lease.message || null,
  };
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
    if (/^(?:BASH_ENV|ENV|CDPATH|GIT_ASKPASS|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_\d+|GIT_CONFIG_VALUE_\d+|GIT_PROXY_COMMAND|GIT_SSH_COMMAND|NODE_OPTIONS|RUBYOPT|PYTHONPATH|SPIN_OWNER_CONFIRMED|SSH_ASKPASS|LD_PRELOAD|DYLD_.*)$/.test(key)) {
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
  const lease = inspectLease(policy);
  const executable = lease.state === 'active' && lease.remaining_ms >= LEASE_MIN_REMAINING_MS ? [lease.rule] : [];
  const today = new Date().toISOString().slice(0, 10);
  const spendCents = events
    .filter(event => event.phase === 'started' && event.category === 'spend' && String(event.at || '').startsWith(today))
    .reduce((sum, event) => sum + Number(event.amount_cents || 0), 0);
  const report = {
    // The values below are the stable machine-readable contract for callers
    // such as the Company CLI.  `ready` means at least one exact enabled rule
    // can execute now, not merely that policy has an enabled bit.
    status: policy ? (enabled.length ? (executable.length ? 'ready' : 'lease_required') : 'deny_all') : 'missing',
    secure_default: true,
    policy: path.relative(ROOT, POLICY_FILE),
    policy_sha256: policy ? policyDigest(policy) : null,
    lease_support: {
      version: 1,
      policy_rule_expiry: true,
      rejects_expired_execution: true,
      recovers_expired_policy: true,
      owner_marked_arm: true,
      one_shot_consume_before_spawn: true,
    },
    mode: policy ? policy.mode : 'deny-by-default',
    enabled_rules: enabled.length,
    executable_rules: executable.length,
    enabled_by_category: Object.fromEntries([...CATEGORIES].map(category => [category, enabled.filter(rule => rule.category === category).length])),
    executable_by_category: Object.fromEntries([...CATEGORIES].map(category => [category, executable.filter(rule => rule.category === category).length])),
    lease: leaseStatusContract(lease, safeRecoveryAvailable(policy, lease)),
    executions_recorded: events.filter(event => event.phase === 'finished').length,
    conservative_spend_today_usd: money(spendCents),
  };
  if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  else {
    process.stdout.write(`Action broker: ${report.status}\n`);
    process.stdout.write(`  policy: ${report.policy}\n`);
    process.stdout.write(`  enabled/executable rules: ${report.enabled_rules}/${report.executable_rules}\n`);
    process.stdout.write(`  lease: ${report.lease.state}${report.lease.rule_id ? ` (${report.lease.rule_id})` : ''}\n`);
    process.stdout.write(`  conservative spend today: $${report.conservative_spend_today_usd}\n`);
    if (!policy) process.stdout.write('  note: policy is missing, so every sensitive action is denied\n');
    else if (!enabled.length) process.stdout.write('  note: deny-all is active until the owner enables exact rules\n');
    else if (!executable.length) process.stdout.write('  note: enabled rules remain denied until an exact active lease is armed\n');
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
  const lease = assertLeaseForRule(policy, rule);
  const events = readEvents();
  assertSpendBudget(rule, amountCents, events);
  const command = commandFor(rule);
  process.stdout.write(`ALLOW: ${rule.id}\n`);
  process.stdout.write(`  category: ${category}\n`);
  process.stdout.write(`  target: ${target}\n`);
  process.stdout.write(`  executable: ${path.basename(command.executable)}\n`);
  process.stdout.write(`  lease expires: ${lease.expires_at}\n`);
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
      const lease = consumeLeaseForRule(policy, rule);
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

      // The lease is start authority and has already been durably consumed.
      // The fixed policy timeout, not remaining lease time, governs the child.
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
        lease_expires_at: lease.expires_at,
        lease_policy_sha256: lease.policy_sha256,
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
  lease: new Set(['ttl-seconds', 'owner-marked', 'json']),
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
if (verb === 'lease') {
  const leaseVerb = parsed.pos.shift();
  if (!leaseVerb || parsed.pos.length > (leaseVerb === 'arm' ? 1 : 0)) usage(1);
  const jsonMode = Boolean(parsed.flags.json);
  if (leaseVerb === 'status') {
    if (parsed.pos.length || parsed.flags['ttl-seconds'] !== undefined || parsed.flags['owner-marked'] !== undefined) usage(1);
    const policy = readPolicy({ allowMissing: true });
    const lease = inspectLease(policy);
    const report = { schema_version: 1, lease: leaseStatusContract(lease, safeRecoveryAvailable(policy, lease)) };
    if (jsonMode) process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    else process.stdout.write(`lease: ${report.lease.state}\n`);
    process.exit(0);
  }
  if (leaseVerb === 'revoke') {
    if (parsed.pos.length || parsed.flags['ttl-seconds'] !== undefined || parsed.flags['owner-marked'] !== undefined) usage(1);
    revokeLease(jsonMode);
    process.exit(0);
  }
  if (leaseVerb === 'recover') {
    if (parsed.pos.length || parsed.flags['ttl-seconds'] !== undefined || parsed.flags['owner-marked'] !== undefined) usage(1);
    recoverLease(jsonMode);
    process.exit(0);
  }
  if (leaseVerb !== 'arm' || parsed.pos.length !== 1) usage(1);
  if (parsed.flags['owner-marked'] !== true) die(2, 'lease arming requires the explicit --owner-marked flag');
  const rawTtl = flagValue(parsed.flags, 'ttl-seconds', true);
  if (!/^\d+$/.test(rawTtl)) die(2, '--ttl-seconds must be an integer');
  const ttlSeconds = Number(rawTtl);
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > LEASE_MAX_TTL_SECONDS) {
    die(2, `--ttl-seconds must be 1..${LEASE_MAX_TTL_SECONDS}`);
  }
  armLease(oneLine(parsed.pos[0], 'rule id', 100), ttlSeconds, true, jsonMode);
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
