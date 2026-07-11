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

function run(root, args) {
  return spawnSync(process.execPath, [broker, ...args], {
    env: { ...process.env, SPIN_ROOT: root, NODE_OPTIONS: '' },
    encoding: 'utf8',
  });
}

test('deny-all status and denied checks fail closed', t => {
  const root = fixture(t);
  const status = run(root, ['status', '--json']);
  assert.equal(status.status, 0, status.stderr);
  assert.equal(JSON.parse(status.stdout).status, 'deny_all');

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

  const tooLarge = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '6.00', '--reason', 'Over cap']);
  assert.equal(tooLarge.status, 2);
  const allowed = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '4.00', '--reason', 'Within cap']);
  assert.equal(allowed.status, 0, allowed.stderr);
  const daily = run(root, ['execute', 'spend', '--target', 'vendor:test', '--amount', '2.00', '--reason', 'Over daily cap']);
  assert.equal(daily.status, 2);
  assert.match(daily.stderr, /conservative spend total/);
});
