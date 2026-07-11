'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-control-visibility-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'jobs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'scripts', 'lib', 'spin-runtime.sh'), path.join(root, 'scripts', 'lib', 'spin-runtime.sh'));
  const now = new Date().toISOString();
  writeJSON(path.join(root, 'org', 'state.json'), {
    project_orchestrators: [{ project: 'app', status: 'active', next_action: 'Ship the next verified change.' }],
  });
  writeJSON(path.join(root, 'org', 'OMP_HARNESS.json'), {
    workspace_ceo: { cmux_workspace: 'workspace:test' },
    projects: { app: { cmux_workspace: 'workspace:app' } },
  });
  writeJSON(path.join(root, 'org', 'ACTION_POLICY.json'), {
    version: 1,
    mode: 'deny-by-default',
    rules: [{ enabled: true }],
  });
  writeJSON(path.join(root, 'org', 'AGENT_QUEUE.json'), {
    dispatch_state: {
      status: 'memory-pressure',
      note: 'preserving the memory reserve',
      available_memory_mb: 1800,
    },
    jobs: [
      {
        id: 'heavy-build', project_id: 'app', type: 'implementation-worker', status: 'running',
        resource_class: 'heavy', started_at: now, heartbeat_at: now,
        resource_usage: 'org/jobs/heavy-build.usage.json',
        resource_limits: { max_rss_mb: 6144, max_processes: 32 },
      },
      {
        id: 'failed-check', project_id: 'app', type: 'scout', status: 'failed',
        failed_at: now, result: 'Focused check failed with a useful reason.',
      },
    ],
  });
  writeJSON(path.join(root, 'org', 'jobs', 'heavy-build.usage.json'), {
    observed_at: now,
    rss_mb: 128,
    processes: 3,
  });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'FLOOR.md'), '# app\n\n## In progress\n- Heavy build\n\n## Next\n- Verify\n\n## Waiting on human\n- Nothing\n');
  fs.writeFileSync(path.join(root, 'org', 'HUMAN_QUEUE.md'), '# Waiting on you\n');
  fs.writeFileSync(path.join(root, 'org', 'ceo', 'APPROVALS.md'), '# Approvals\n\n## Pending\n\n## Processed\n');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function get(url) {
  return new Promise((resolve, reject) => {
    http.get(url, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, body }));
    }).on('error', reject);
  });
}

function serverUrl(child) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error(`web server did not start: ${output}`)), 5000);
    child.stdout.on('data', chunk => {
      output += chunk;
      const match = output.match(/SPIN web: (http:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timeout);
        resolve(match[1]);
      }
    });
    child.once('exit', code => {
      clearTimeout(timeout);
      reject(new Error(`web server exited ${code}: ${output}`));
    });
  });
}

test('Coordinator board and control panel expose live work truth', async t => {
  const root = fixture(t);
  const rollup = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'workspace-status.sh')], {
    env: { ...process.env, SPIN_ROOT: root },
    encoding: 'utf8',
  });
  assert.equal(rollup.status, 0, rollup.stderr);
  const markdown = fs.readFileSync(path.join(root, 'org', 'ceo', 'WORKSPACE_STATUS.md'), 'utf8');
  assert.match(markdown, /Sensitive actions:\*\* ready - 1 exact rule enabled/);
  assert.match(markdown, /Dispatcher:\*\* memory-pressure/);
  assert.match(markdown, /heavy-build.*HEAVY/);
  assert.match(markdown, /128MB \/ 6144MB/);
  assert.match(markdown, /Needs attention/);

  const child = spawn(process.execPath, [path.join(repo, 'scripts', 'spin-web.js'), '--port', '0'], {
    env: { ...process.env, SPIN_ROOT: root },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));
  const response = await get(await serverUrl(child));
  assert.equal(response.status, 200);
  assert.match(response.body, /Control Plane/);
  assert.match(response.body, /memory-pressure/);
  assert.match(response.body, /128\/6144 MB/);
  assert.match(response.body, /heavy lease/);
  assert.match(response.body, /failed-check/);
});
