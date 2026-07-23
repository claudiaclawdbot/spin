'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const broker = path.resolve(__dirname, '..', 'scripts', 'spin-action-broker.js');
const touch = ['/usr/bin/touch', '/bin/touch'].find(file => fs.existsSync(file));
const gitBin = ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git'].find(file => fs.existsSync(file));
const sleepBin = ['/bin/sleep', '/usr/bin/sleep'].find(file => fs.existsSync(file));

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
  return crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), 'utf8'))
    .digest('hex');
}

function executableDigest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(fs.realpathSync(file))).digest('hex');
}

function pinnedRule(rule, envAllowlist = []) {
  return {
    ...rule,
    executable_sha256: executableDigest(rule.command[0]),
    env_allowlist: envAllowlist,
  };
}

function writeLease(root, {
  ruleId,
  expiresAt,
  digest = policyDigest(root),
  mode = 0o600,
  executableRealpath,
  executableSha256,
  cwdRealpath,
  targetAttestation,
  version = 2,
} = {}) {
  const policy = JSON.parse(fs.readFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), 'utf8'));
  const rule = policy.rules.find(candidate => candidate.id === ruleId) || policy.rules[0];
  const lease = {
    version,
    owner_marked: true,
    rule_id: ruleId,
    policy_sha256: digest,
    executable_realpath: executableRealpath || fs.realpathSync(rule.command[0]),
    executable_sha256: executableSha256 || executableDigest(rule.command[0]),
    cwd_realpath: cwdRealpath || fs.realpathSync(rule.cwd || root),
    target_attestation: targetAttestation || {
      type: 'fixed-policy-target',
      category: rule.category,
      target: rule.target,
    },
    issued_at: new Date(Date.now() - 1000).toISOString(),
    expires_at: expiresAt || new Date(Date.now() + 60_000).toISOString(),
  };
  const file = path.join(root, 'org', 'ACTION_POLICY.lease.json');
  fs.writeFileSync(file, `${JSON.stringify(lease)}\n`, { mode });
  fs.chmodSync(file, mode);
  return file;
}

function armLease(root, ruleId, ttlSeconds = 60, env = {}) {
  return run(root, ['lease', 'arm', ruleId, '--ttl-seconds', String(ttlSeconds), '--owner-marked', '--json'], {
    SPIN_OWNER_CONFIRMED: '1',
    ...env,
  });
}

function executable(root, name, body) {
  const file = path.join(root, name);
  fs.writeFileSync(file, `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o700 });
  fs.chmodSync(file, 0o700);
  return file;
}

function runGit(cwd, args) {
  const result = spawnSync(gitBin, args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result;
}

async function waitFor(predicate, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error('timed out waiting for broker state');
}

test('deny-all status and denied checks fail closed', t => {
  const root = fixture(t);
  const status = run(root, ['status', '--json']);
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).status, 'deny_all');
  const lease = JSON.parse(status.stdout).lease;
  assert.equal(lease.schema_version, 2);
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
    rules: [pinnedRule({
      id: 'send-test',
      category: 'external-send',
      target: 'test-recipient',
      enabled: true,
      command: [touch, marker],
      cwd: root,
      timeout_seconds: 10,
    })],
  }, null, 2)}\n`, { mode: 0o600 });

  const armed = armLease(root, 'send-test');
  assert.equal(armed.status, 0, armed.stderr);
  assert.equal(JSON.parse(armed.stdout).lease.state, 'active');

  const result = run(root, ['execute', 'external-send', '--target', 'test-recipient', '--rule', 'send-test', '--reason', 'Test exact execution']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(marker), true);
  const events = fs.readFileSync(path.join(root, 'org', 'action-broker', 'events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(events.map(event => event.phase), ['started', 'finished']);
  assert.equal(events[0].executable_realpath, fs.realpathSync(touch));
  assert.equal(events[0].executable_sha256, executableDigest(touch));
  assert.equal(events[0].cwd_realpath, fs.realpathSync(root));
  assert.equal(events[1].executable_realpath, fs.realpathSync(touch));
  const receipts = fs.readdirSync(path.join(root, 'org', 'action-broker', 'receipts'));
  assert.equal(receipts.length, 1);
  const receipt = JSON.parse(fs.readFileSync(path.join(root, 'org', 'action-broker', 'receipts', receipts[0]), 'utf8'));
  assert.equal(receipt.outcome, 'succeeded');
  assert.equal(receipt.target, 'test-recipient');
  assert.equal(receipt.executable_realpath, fs.realpathSync(touch));
  assert.equal(receipt.executable_sha256, executableDigest(touch));
  assert.equal(receipt.cwd_realpath, fs.realpathSync(root));
  assert.deepEqual(receipt.env_allowlist, []);
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
    rules: [pinnedRule({
      id: 'test-spend',
      category: 'spend',
      target: 'vendor:test',
      enabled: true,
      command: [touch, marker],
      cwd: root,
      timeout_seconds: 10,
      per_action_usd: '5.00',
      per_day_usd: '5.00',
    })],
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
    version: 1, mode: 'deny-by-default', rules: [pinnedRule({
      id: 'leased-rule', category: 'external-send', target: 'lease:test', enabled: true,
      command: [touch, marker], cwd: root, timeout_seconds: 10,
    })],
  }) + '\n', { mode: 0o600 });

  const args = ['check', 'external-send', '--target', 'lease:test', '--rule', 'leased-rule'];
  const missing = run(root, args);
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /active lease \(missing\)/);

  writeLease(root, { ruleId: 'leased-rule', version: 1 });
  const legacy = run(root, args);
  assert.equal(legacy.status, 2);
  assert.match(legacy.stderr, /active lease \(untrusted\)/);

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
    version: 1, mode: 'deny-by-default', rules: [pinnedRule({
      id: 'right-rule', category: 'external-send', target: 'digest:test', enabled: true,
      command: [touch, marker], cwd: root, timeout_seconds: 10,
    })],
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
    version: 1, mode: 'deny-by-default', rules: [pinnedRule({
      id: 'status-rule', category: 'external-send', target: 'status:test', enabled: true,
      command: [touch, path.join(root, 'status')], cwd: root, timeout_seconds: 10,
    })],
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
  assert.equal(after.lease.schema_version, 2);
  assert.equal(after.lease.state, 'active');
  assert.equal(after.lease.rule_id, 'status-rule');
  assert.ok(after.lease.expires_at);
  assert.equal(after.lease.executable_realpath, fs.realpathSync(touch));
  assert.equal(after.lease.executable_sha256, executableDigest(touch));
  assert.equal(after.lease.cwd_realpath, fs.realpathSync(root));
  assert.match(after.policy_sha256, /^[a-f0-9]{64}$/);
});

test('enabled rules require an executable digest and explicit environment allowlist', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [{
      id: 'unpinned', category: 'external-send', target: 'pin:test', enabled: true,
      command: [touch, path.join(root, 'never-created')], cwd: root,
    }],
  })}\n`, { mode: 0o600 });

  const missingPin = run(root, ['status', '--json']);
  assert.equal(missingPin.status, 2);
  assert.match(missingPin.stderr, /needs executable_sha256/);

  const policy = JSON.parse(fs.readFileSync(policyFile, 'utf8'));
  policy.rules[0].executable_sha256 = executableDigest(touch);
  fs.writeFileSync(policyFile, `${JSON.stringify(policy)}\n`, { mode: 0o600 });
  const missingAllowlist = run(root, ['status', '--json']);
  assert.equal(missingAllowlist.status, 2);
  assert.match(missingAllowlist.stderr, /explicit env_allowlist/);

  policy.rules[0].env_allowlist = ['NODE_OPTIONS'];
  fs.writeFileSync(policyFile, `${JSON.stringify(policy)}\n`, { mode: 0o600 });
  const unsafeAllowlist = run(root, ['status', '--json']);
  assert.equal(unsafeAllowlist.status, 2);
  assert.match(unsafeAllowlist.stderr, /cannot inherit NODE_OPTIONS/);

  for (const unsafeName of ['GIT_DIR', 'GIT_CONFIG_GLOBAL', 'XDG_CONFIG_HOME']) {
    policy.rules[0].env_allowlist = [unsafeName];
    fs.writeFileSync(policyFile, `${JSON.stringify(policy)}\n`, { mode: 0o600 });
    const unsafeSelector = run(root, ['status', '--json']);
    assert.equal(unsafeSelector.status, 2);
    assert.match(unsafeSelector.stderr, new RegExp(`cannot inherit ${unsafeName}`));
  }
});

test('execution denies a changed executable after its lease was armed', t => {
  const root = fixture(t);
  const marker = path.join(root, 'changed-executable-ran');
  const command = executable(root, 'scoped-command', ':');
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [pinnedRule({
      id: 'pinned-command', category: 'external-send', target: 'pin:changed', enabled: true,
      command: [command], cwd: root,
    })],
  })}\n`, { mode: 0o600 });
  assert.equal(armLease(root, 'pinned-command').status, 0);

  fs.writeFileSync(command, `#!/bin/sh\n: > ${JSON.stringify(marker)}\n`, { mode: 0o700 });
  fs.chmodSync(command, 0o700);
  const status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(status.status, 'lease_required');
  assert.equal(status.lease.state, 'attestation_mismatch');
  const denied = run(root, ['execute', 'external-send', '--target', 'pin:changed', '--rule', 'pinned-command', '--reason', 'must not run changed bytes']);
  assert.equal(denied.status, 2);
  assert.match(denied.stderr, /attestation_mismatch/);
  assert.equal(fs.existsSync(marker), false);
});

test('a lease binds the resolved executable and cwd, not mutable symlink labels', t => {
  const root = fixture(t);
  const commandOne = executable(root, 'command-one', ':');
  const commandTwo = executable(root, 'command-two', ':');
  const commandLink = path.join(root, 'command-link');
  const cwdOne = path.join(root, 'cwd-one');
  const cwdTwo = path.join(root, 'cwd-two');
  const cwdLink = path.join(root, 'cwd-link');
  fs.mkdirSync(cwdOne);
  fs.mkdirSync(cwdTwo);
  fs.symlinkSync(commandOne, commandLink);
  fs.symlinkSync(cwdOne, cwdLink);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [pinnedRule({
      id: 'resolved-identity', category: 'external-send', target: 'pin:resolved', enabled: true,
      command: [commandLink], cwd: cwdLink,
    })],
  })}\n`, { mode: 0o600 });
  assert.equal(armLease(root, 'resolved-identity').status, 0);

  fs.unlinkSync(commandLink);
  fs.symlinkSync(commandTwo, commandLink);
  let status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(status.lease.state, 'attestation_mismatch');

  fs.unlinkSync(commandLink);
  fs.symlinkSync(commandOne, commandLink);
  fs.unlinkSync(cwdLink);
  fs.symlinkSync(cwdTwo, cwdLink);
  status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(status.lease.state, 'attestation_mismatch');
});

test('execution inherits only fixed baseline variables and the rule allowlist', t => {
  const root = fixture(t);
  const captured = path.join(root, 'captured.env');
  const command = executable(root, 'capture-env', '/usr/bin/env > "$1"');
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [pinnedRule({
      id: 'scoped-env', category: 'external-send', target: 'env:test', enabled: true,
      command: [command, captured], cwd: root,
    }, ['SPIN_BROKER_ALLOWED'])],
  })}\n`, { mode: 0o600 });
  assert.equal(armLease(root, 'scoped-env').status, 0);

  const result = run(root, ['execute', 'external-send', '--target', 'env:test', '--rule', 'scoped-env', '--reason', 'verify isolated environment'], {
    SPIN_BROKER_ALLOWED: 'visible',
    SPIN_BROKER_SECRET: 'must-not-leak',
  });
  assert.equal(result.status, 0, result.stderr);
  const env = Object.fromEntries(fs.readFileSync(captured, 'utf8').trim().split('\n').map(line => {
    const split = line.indexOf('=');
    return [line.slice(0, split), line.slice(split + 1)];
  }));
  assert.equal(env.SPIN_BROKER_ALLOWED, 'visible');
  assert.equal(env.SPIN_BROKER_SECRET, undefined);
  assert.equal(env.SPIN_ROOT, undefined);
  assert.equal(env.NODE_OPTIONS, undefined);
  assert.equal(env.HOME, os.userInfo().homedir);
  assert.ok(env.PATH);
});

test('protected-push attestation receives the same constrained allowlist as execution', t => {
  const root = fixture(t);
  const fakeGit = executable(root, 'git', `
if [ "\${SPIN_REMOTE_SELECTOR:-trusted}" = "alternate" ]; then
  printf '%s\\n' 'git@github.com:someone/else.git'
else
  printf '%s\\n' 'git@github.com:claudiaclawdbot/spin.git'
fi`);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [pinnedRule({
      id: 'push-env-bound',
      category: 'protected-push',
      target: 'github.com/claudiaclawdbot/spin:main',
      enabled: true,
      command: [fakeGit, 'push', 'origin', 'HEAD:main'],
      cwd: root,
    }, ['SPIN_REMOTE_SELECTOR'])],
  })}\n`, { mode: 0o600 });

  const mismatched = armLease(root, 'push-env-bound', 60, { SPIN_REMOTE_SELECTOR: 'alternate' });
  assert.equal(mismatched.status, 2);
  assert.match(mismatched.stderr, /does not match resolved git push/);
});

test('protected pushes bind the exact resolved remote repository and destination', t => {
  assert.ok(gitBin, 'git executable is required');
  const root = fixture(t);
  const repository = path.join(root, 'repository');
  fs.mkdirSync(repository);
  runGit(repository, ['init']);
  runGit(repository, ['remote', 'add', 'origin', 'git@github.com:claudiaclawdbot/spin.git']);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  const rule = pinnedRule({
    id: 'push-main',
    category: 'protected-push',
    target: 'github.com/claudiaclawdbot/spin:main',
    enabled: true,
    command: [gitBin, 'push', 'origin', 'HEAD:main'],
    cwd: repository,
    timeout_seconds: 30,
  });
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [rule],
  })}\n`, { mode: 0o600 });

  const armed = armLease(root, rule.id);
  assert.equal(armed.status, 0, armed.stderr);
  let status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.deepEqual(status.lease.target_attestation, {
    type: 'git-push',
    repository: 'github.com/claudiaclawdbot/spin',
    remote: 'origin',
    remote_url_sha256: crypto.createHash('sha256').update('git@github.com:claudiaclawdbot/spin.git').digest('hex'),
    source: 'HEAD',
    destination: 'main',
  });

  runGit(repository, ['remote', 'set-url', '--add', '--push', 'origin', 'git@github.com:claudiaclawdbot/spin.git']);
  runGit(repository, ['remote', 'set-url', '--add', '--push', 'origin', 'git@github.com:someone/else.git']);
  const multiplePushUrls = armLease(root, rule.id);
  assert.equal(multiplePushUrls.status, 2);
  assert.match(multiplePushUrls.stderr, /must resolve to exactly one push URL/);
  status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(status.lease.state, 'attestation_mismatch');
  assert.match(status.lease.message, /must resolve to exactly one push URL/);
  runGit(repository, ['config', '--unset-all', 'remote.origin.pushurl']);

  runGit(repository, ['remote', 'set-url', 'origin', 'git@github.com:someone/else.git']);
  status = JSON.parse(run(root, ['status', '--json']).stdout);
  assert.equal(status.lease.state, 'attestation_mismatch');
  assert.match(status.lease.message, /does not match resolved git push/);

  rule.target = 'github.com/incorrect/repository:main';
  rule.executable_sha256 = executableDigest(gitBin);
  fs.writeFileSync(policyFile, `${JSON.stringify({ version: 1, mode: 'deny-by-default', rules: [rule] })}\n`, { mode: 0o600 });
  const mismatched = armLease(root, rule.id);
  assert.equal(mismatched.status, 2);
  assert.match(mismatched.stderr, /does not match resolved git push/);
});

test('broker holds an identity-aware hardlink lock for the full action', async t => {
  assert.ok(sleepBin, 'sleep executable is required');
  const root = fixture(t);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, `${JSON.stringify({
    version: 1,
    mode: 'deny-by-default',
    rules: [pinnedRule({
      id: 'lock-proof', category: 'external-send', target: 'lock:test', enabled: true,
      command: [sleepBin, '0.6'], cwd: root, timeout_seconds: 5,
    })],
  })}\n`, { mode: 0o600 });
  assert.equal(armLease(root, 'lock-proof').status, 0);

  const child = spawn(process.execPath, [
    broker, 'execute', 'external-send', '--target', 'lock:test', '--rule', 'lock-proof',
    '--reason', 'inspect broker lock identity',
  ], {
    env: { ...process.env, SPIN_ROOT: root, NODE_OPTIONS: '' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const lock = path.join(root, 'org', 'action-broker', '.lock');
  await waitFor(() => fs.existsSync(lock));
  const lockText = fs.readFileSync(lock, 'utf8');
  assert.match(lockText, new RegExp(`^${child.pid}\\nversion=1\\nidentity=.+\\ntoken=.+\\n$`));
  const status = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', resolve);
  });
  assert.equal(status, 0, stderr);
  assert.match(stdout, /action succeeded/);
  assert.equal(fs.existsSync(lock), false);
});

test('arming requires an explicit owner marker and recovery only disables a safely stale rule', t => {
  assert.ok(touch, 'touch executable is required');
  const root = fixture(t);
  const policyFile = path.join(root, 'org', 'ACTION_POLICY.json');
  fs.writeFileSync(policyFile, JSON.stringify({
    version: 1, mode: 'deny-by-default', rules: [pinnedRule({
      id: 'recoverable-rule', category: 'external-send', target: 'recover:test', enabled: true,
      command: [touch, path.join(root, 'recover')], cwd: root, timeout_seconds: 10,
    })],
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
