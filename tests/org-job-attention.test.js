'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const org = path.join(repo, 'scripts', 'org');
const { jobNeedsAttention } = require(path.join(repo, 'scripts', 'lib', 'job-attention.js'));

function fixture(t, jobs) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-org-job-attention-'));
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'org', 'AGENT_QUEUE.json'),
    `${JSON.stringify({ version: 1, jobs, preserved: 'queue metadata' }, null, 2)}\n`,
  );
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function runOrg(root, ...args) {
  return spawnSync(process.execPath, [org, ...args], {
    env: { ...process.env, SPIN_ROOT: root },
    encoding: 'utf8',
  });
}

function readQueue(root) {
  return JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
}

test('acknowledge-job rejects unknown and invalid job IDs without changing the queue', t => {
  const root = fixture(t, [
    { id: 'known-failure', project_id: 'app', status: 'failed', result: 'Known failure.' },
  ]);
  const queueFile = path.join(root, 'org', 'AGENT_QUEUE.json');
  const before = fs.readFileSync(queueFile, 'utf8');

  const unknown = runOrg(root, 'acknowledge-job', 'missing-job');
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /job id "missing-job" not found/);

  const invalid = runOrg(root, 'acknowledge-job', '../known-failure');
  assert.equal(invalid.status, 2);
  assert.match(invalid.stderr, /job id may only contain/);
  assert.equal(fs.readFileSync(queueFile, 'utf8'), before);
});

test('acknowledge-job rejects queued and active jobs', t => {
  const root = fixture(t, [
    { id: 'queued-job', project_id: 'app', status: 'queued' },
    { id: 'running-job', project_id: 'app', status: 'running' },
  ]);
  const queueFile = path.join(root, 'org', 'AGENT_QUEUE.json');
  const before = fs.readFileSync(queueFile, 'utf8');

  for (const [id, status] of [['queued-job', 'queued'], ['running-job', 'running']]) {
    const result = runOrg(root, 'acknowledge-job', id);
    assert.equal(result.status, 2);
    assert.match(result.stderr, new RegExp(`cannot be acknowledged while status is ${status}`));
  }
  assert.equal(fs.readFileSync(queueFile, 'utf8'), before);
});

test('acknowledge-job removes failed history from attention without deleting it', t => {
  const original = {
    id: 'failed-job',
    project_id: 'app',
    type: 'scout',
    status: 'failed',
    failed_at: '2026-07-22T12:00:00.000Z',
    result: 'The provider returned a bounded failure.',
  };
  const root = fixture(t, [original, { id: 'other-job', project_id: 'app', status: 'completed' }]);
  assert.equal(jobNeedsAttention(readQueue(root).jobs[0]), true);

  const result = runOrg(root, 'acknowledge-job', 'failed-job', '--note', 'Reviewed\nby the operator.');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^acknowledged failed-job\n$/);

  const queue = readQueue(root);
  assert.equal(queue.preserved, 'queue metadata');
  assert.equal(queue.jobs.length, 2);
  const acknowledged = queue.jobs.find(job => job.id === 'failed-job');
  assert.ok(acknowledged);
  assert.equal(acknowledged.status, 'failed');
  assert.equal(acknowledged.result, original.result);
  assert.equal(acknowledged.failed_at, original.failed_at);
  assert.equal(acknowledged.attention_status, 'acknowledged');
  assert.equal(acknowledged.acknowledgement_note, 'Reviewed by the operator.');
  assert.match(acknowledged.acknowledged_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
  assert.equal(acknowledged.updated_at, acknowledged.acknowledged_at);
  assert.equal(queue.updated_at, acknowledged.acknowledged_at);
  assert.equal(jobNeedsAttention(acknowledged), false);

  const beforeSecondAttempt = fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8');
  const secondAttempt = runOrg(root, 'acknowledge-job', 'failed-job');
  assert.equal(secondAttempt.status, 2);
  assert.match(secondAttempt.stderr, /does not currently require attention/);
  assert.equal(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'), beforeSecondAttempt);
});

test('acknowledge-job fails closed on malformed queue state', t => {
  const root = fixture(t, []);
  const queueFile = path.join(root, 'org', 'AGENT_QUEUE.json');
  fs.writeFileSync(queueFile, '{"jobs":{"failed-job":{"status":"failed"}}}\n');
  const before = fs.readFileSync(queueFile, 'utf8');

  const result = runOrg(root, 'acknowledge-job', 'failed-job');
  assert.equal(result.status, 3);
  assert.match(result.stderr, /AGENT_QUEUE\.json jobs must be an array/);
  assert.equal(fs.readFileSync(queueFile, 'utf8'), before);
});
