'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const broker = path.resolve(__dirname, '..', 'scripts', 'spin-action-broker.js');
const touch = ['/usr/bin/touch', '/bin/touch'].find(file => fs.existsSync(file));

function fixture(t, policy = { version: 1, mode: 'deny-by-default', rules: [] }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-action-broker-'));
  fs.mkdirSync(path.join(root, 'org'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), `${JSON.stringify(policy, null, 2)}\n`, { mode: 0o600 });
  fs.writeFileSync(path.join(root, 'org', 'HUMAN_QUEUE.md'), '# Waiting on you\n');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function run(root, args, env = {}) {
  return spawnSync(process.execPath, [broker, ...args], {
    env: { ...process.env, SPIN_ROOT: root, NODE_OPTIONS: '', ...env },
    encoding: 'utf8',
  });
}

function policyDigest(root) {
  return require('node:crypto')
    .createHash('sha256')
    .update(fs.readFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), 'utf8'))
    .digest('hex');
}

function writeLease(root, { ruleId, expiresAt, digest = policyDigest(root), mode = 0o600 } = {}) {
  const lease = {
    version: 1,
    owner_marked: true,
    rule_id: ruleId,
    policy_sha256: digest,
    issued_at: new Date(Date.now() - 1000).toISOString(),
    expires_at: expiresAt || new Date(Date.now() + 60_000).toISOString(),
  };
  const file = path.join(root, 'org', 'ACTION_POLICY.lease.json');
  fs.writeFileSync(file, `${JSON.stringify(lease)}\n`, { mode });
  fs.chmodSync(file, mode);
  return file;
}

function armLease(root, ruleId, ttlSeconds = 60) {
  return run(root, ['lease', 'arm', ruleId, '--ttl-seconds', String(ttlSeconds), '--owner-marked', '--json'], { SPIN_OWNER_CONFIRMED: '1' });
}

test('deny-all status and denied checks fail closed', t => {
  const root = fixture(t);
  const status = run(root, ['status', '--json']);
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).status, 'deny_all');
  const lease = JSON.parse(status.stdout).lease;
  assert.equal(lease.schema_version, 1);
  assert.equal(lease.state, 'missing');

  const denied = run(root, ['check', 'protected-push', '--target', 'example:main']);
  assert.equal(denied.status, 2);
  assert.match(denied.stderr, /DENY: no enabled exact-match rule/);
});

test('requests are deduplicated and never execute a command', t => {
  const root = fixture(t);
  const args = ['request', 'production-deploy', '--target', 'test.example', '--reason', 'Candidate is ready'];
  assert.equal(run(root, args).status, 0);
  assert.equal(run(root, args).status, 0);
  const queue = fs.readFileSync(path.join(root, 'org', 'HUMAN_QUEUE.md'), 'utf8');
  assert.equal((queue.match(/\[action:/g) || []).length, 1);
  assert.equal(fs.existsSync(path.join(root, 'org', 'action-broker', 'events.jsonl')), false);
});

test('an exact enabled rule executes fixed argv and writes a receipt', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const marker = path.join(root, 'executed');
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [{
      id: 'send-test',
      category: 'external-send',
      target: 'test-recipient',
      enabled: true,
      command: [touch, marker],
      cwd: root,
      timeout_seconds: 10,
    }],
  }, null, 2)}\n`, { mode: 0o600 });

  const armed = armLease(root, 'send-test');
  assert.equal(armed.status, 0, armed.stderr);
  assert.equal(JSON.parse(armed.stdout).lease.state, 'active');

  const result = run(root, ['execute', 'external-send', '--target', 'test-recipient', '--rule', 'send-test', '--reason', 'Test exact execution']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(marker), true);
  const events = fs.readFileSync(path.join(root, 'org', 'action-broker', 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(events.map(event => event.phase), ['started', 'finished']);
  const receipts = fs.readdirSync(path.join(root, 'org', 'action-broker', 'receipts'));
  assert.equal(receipts.length, 1);
  const receipt = JSON.parse(fs.readFileSync(path.join(root, 'org', 'action-broker', 'receipts', receipts[0]), 'utf8'));
  assert.equal(receipt.outcome, 'succeeded');
  assert.equal(receipt.target, 'test-recipient');
  assert.ok(receipt.lease_expires_at);
  assert.equal(receipt.lease_policy_sha256, policyDigest(root));
  assert.equal(fs.existsSync(path.join(root, 'org', 'ACTION_POLICY.lease.json')), false);
  const replay = run(root, ['execute', 'external-send', '--target', 'test-recipient', '--rule', 'send-test', '--reason', 'Attempt replay']);
  assert.equal(replay.status, 2);
  assert.match(replay.stderr, /active lease \(missing\)/);
});

test('spend rules enforce per-action and conservative daily caps', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const marker = path.join(root, 'spent');
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [{
      id: 'test-spend',
      category: 'spend',
      target: 'vendor:test',
      enabled: true,
      command: [touch, marker],
      cwd: root,
      timeout_seconds: 10,
      per_action_usd: '5.00',
      per_day_usd: '5.00',
    }],
  }, null, 2)}\n`, { mode: 0o600 });

  assert.equal(armLease(root, 'test-spend').status, 0);

  const tooLarge = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '6.00', '--reason', 'Over cap']);
  assert.equal(tooLarge.status, 2);
  const allowed = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '4.00', '--reason', 'Within cap']);
  assert.equal(allowed.status, 0, allowed.stderr);
  const daily = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '2.00', '--reason', 'Over daily cap']);
  assert.equal(daily.status, 2);
  assert.match(daily.stderr, /conservative spend total/);
});

test('enabled rules fail closed when their lease is missing, expired, or untrusted', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const marker = path.join(root, 'should-not-exist');
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), JSON.stringify({
    version: 1, mode: 'deny-by-default', rules: [{
      id: 'leased-rule', category: 'external-send', target: 'lease:test', enabled: true,
      command: [touch, marker], cwd: root, timeout_seconds: 10,
    }],
  }) + '\n', { mode: 0o600 });

  const args = ['check', 'external-send', '--target', 'lease:test', '--rule', 'leased-rule'];
  const missing = run(root, args);
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /active lease \(missing\)/);

  writeLease(root, { ruleId: 'leased-rule', expiresAt: new Date(Date.now() - 1_000).toISOString() });
  const expired = run(root, args);
  assert.equal(expired.status, 2);
  assert.match(expired.stderr, /active lease \(expired\)/);

  writeLease(root, { ruleId: 'leased-rule', mode: 0o644 });
  const untrusted = run(root, args);
  assert.equal(untrusted.status, 2);
  assert.match(untrusted.stderr, /active lease \(untrusted\)/);
  assert.equal(fs.existsSync(marker), false);
});

test('a lease is bound to the exact policy digest and exact enabled rule', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const marker = path.join(root, 'executed');
  const policy = {
    version: 1, mode: 'deny-by-default', rules: [{
      id: 'right-rule', category: 'external-send', target: 'digest:test', enabled: true,
      command: [touch, marker], cwd: root, timeout_seconds: 10,
    }],
  };
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), JSON.stringify(policy) + '\n', { mode: 0o600 });
  const args = ['check', 'external-send', '--target', 'digest:test', '--rule', 'right-rule'];

  writeLease(root, { ruleId: 'right-rule', digest: '0'.repeat(64) });
  const wrongDigest = run(root, args);
  assert.equal(wrongDigest.status, 2);
  assert.match(wrongDigest.stderr, /active lease \(policy_mismatch\)/);

  writeLease(root, { ruleId: 'another-rule' });
  const wrongRule = run(root, args);
  assert.equal(wrongRule.status, 2);
  assert.match(wrongRule.stderr, /active lease \(rule_mismatch\)/);

  writeLease(root, { ruleId: 'right-rule' });
  const allowed = run(root, args);
  assert.equal(allowed.status, 0, allowed.stderr);
  assert.match(allowed.stdout, /lease expires:/);
});

test('status exposes the lease capability contract and active executable count', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), JSON.stringify({
    version: 1, mode: 'deny-by-default', rules: [{
      id: 'status-rule', category: 'external-send', target: 'status:test', enabled: true,
      command: [touch, path.join(root, 'status')], cwd: root, timeout_seconds: 10,
    }],
  }) + '\n', { mode: 0o600 });

  const before = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(before.status, 'lease_required');
  assert.equal(before.enabled_rules, 1);
  assert.equal(before.executable_rules, 0);
  assert.equal(before.lease.state, 'missing');

  assert.equal(armLease(root, 'status-rule').status, 0);
  const after = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(after.status, 'ready');
  assert.equal(after.executable_rules, 1);
  assert.equal(after.lease.schema_version, 1);
  assert.equal(after.lease.state, 'active');
  assert.equal(after.lease.rule_id, 'status-rule');
  assert.ok(after.lease.expires_at);
  assert.match(after.policy_sha256, /^[a-f0-9]{64}$/);
});

test('arming requires an explicit owner marker and recovery only disables a safely stale rule', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, JSON.stringify({
    version: 1, mode: 'deny-by-default', rules: [{
      id: 'recoverable-rule', category: 'external-send', target: 'recover:test', enabled: true,
      command: [touch, path.join(root, 'recover')], cwd: root, timeout_seconds: 10,
    }],
  }) + '\n', { mode: 0o600 });

  const unmarked = run(root, ['lease', 'arm', 'recoverable-rule', '--ttl-seconds', '60', '--json']);
  assert.equal(unmarked.status, 2);
  assert.match(unmarked.stderr, /--owner-marked/);
  const missingConfirmation = run(root, ['lease', 'arm', 'recoverable-rule', '--ttl-seconds', '60', '--owner-marked', '--json'], { SPIN_OWNER_CONFIRMED: '' });
  assert.equal(missingConfirmation.status, 2);
  assert.match(missingConfirmation.stderr, /SPIN_OWNER_CONFIRMED=1/);
  const tooLong = run(root, ['lease', 'arm', 'recoverable-rule', '--ttl-seconds', '3601', '--owner-marked']);
  assert.equal(tooLong.status, 2);
  assert.match(tooLong.stderr, /1\.\.3600/);

  writeLease(root, { ruleId: 'recoverable-rule', expiresAt: new Date(Date.now() - 1_000).toISOString() });
  const before = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(before.lease.state, 'expired');
  assert.equal(before.lease.recovery_available, true);
  const recovered = run(root, ['lease', 'recover', '--json']);
  assert.equal(recovered.status, 0, recovered.stderr);
  assert.equal(JSON.parse(recovered.stdout).status, 'recovered');
  const policy = JSON.parse(fs.readFileSync(policyFile, 'utf8'));
  assert.equal(policy.rules[0].enabled, false);
  assert.equal(fs.existsSync(path.join(root, 'org', 'ACTION_POLICY.lease.json')), false);
});
