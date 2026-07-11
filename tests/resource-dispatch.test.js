'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const supervisor = path.join(repo, 'scripts', 'omp-supervisor-once.sh');

function fixture(t, jobs) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-resource-dispatch-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'jobs'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'scripts', 'lib', 'spin-runtime.js'), path.join(root, 'scripts', 'lib', 'spin-runtime.js'));
  const agent = path.join(root, 'scripts', 'project-ceo-agent.sh');
  fs.writeFileSync(agent, '#!/usr/bin/env bash\nexec /bin/sleep 30\n', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'org', 'OMP_HARNESS.json'), `${JSON.stringify({
    workspace_ceo: {},
    projects: { app: { allowed_job_types: ['implementation-worker'] } },
  }, null, 2)}\n`);
  fs.writeFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), `${JSON.stringify({ jobs }, null, 2)}\n`);
  t.after(() => {
    for (const file of fs.existsSync(path.join(root, 'org', 'jobs')) ? fs.readdirSync(path.join(root, 'org', 'jobs')) : []) {
      if (!file.endsWith('.pid')) continue;
      const pid = Number.parseInt(fs.readFileSync(path.join(root, 'org', 'jobs', file), 'utf8'), 10);
      if (!Number.isInteger(pid)) continue;
      try { process.kill(-pid, 'SIGKILL'); } catch { try { process.kill(pid, 'SIGKILL'); } catch {} }
    }
    fs.rmSync(root, { recursive: true, force: true });
  });
  return root;
}

function run(root, extraEnv = {}) {
  return spawnSync('/bin/bash', [supervisor], {
    env: {
      ...process.env,
      SPIN_ROOT: root,
      OMP_RESOURCE_CHECK_INTERVAL: '1',
      OMP_HEARTBEAT_INTERVAL: '1',
      ...extraEnv,
    },
    encoding: 'utf8',
    timeout: 5000,
  });
}

function queued(id, resourceClass = 'normal') {
  return {
    id,
    project_id: 'app',
    type: 'implementation-worker',
    status: 'queued',
    description: id,
    resource_class: resourceClass,
    created_at: new Date().toISOString(),
  };
}

test('adaptive dispatch pauses before crossing the memory reserve', t => {
  const root = fixture(t, [queued('normal-job')]);
  const result = run(root, { OMP_AVAILABLE_MEMORY_MB: '1024' });
  assert.equal(result.status, 0, result.stderr);
  const queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  assert.equal(queue.jobs[0].status, 'queued');
  assert.equal(queue.dispatch_state.status, 'memory-pressure');
  assert.equal(queue.dispatch_state.dispatch_slots, 0);
});

test('a heavy job gets the exclusive lease and larger bounded limits', t => {
  const root = fixture(t, [queued('normal-job'), queued('heavy-job', 'heavy')]);
  const first = run(root, { OMP_ADAPTIVE_PARALLELISM: '0' });
  assert.equal(first.status, 0, first.stderr);
  let queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  const heavy = queue.jobs.find(job => job.id === 'heavy-job');
  const normal = queue.jobs.find(job => job.id === 'normal-job');
  assert.equal(heavy.status, 'running');
  assert.equal(normal.status, 'queued');
  assert.deepEqual(heavy.resource_limits, { max_rss_mb: 6144, max_processes: 32 });
  assert.equal(queue.dispatch_state.status, 'heavy-lease');

  const second = run(root, { OMP_ADAPTIVE_PARALLELISM: '0' });
  assert.equal(second.status, 0, second.stderr);
  queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  assert.equal(queue.jobs.find(job => job.id === 'normal-job').status, 'queued');
  assert.equal(queue.dispatch_state.status, 'heavy-lease');
});
