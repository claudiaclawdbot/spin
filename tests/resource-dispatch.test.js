'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const supervisor = path.join(repo, 'scripts', 'omp-supervisor-once.sh');
const runtime = require(path.join(repo, 'scripts', 'lib', 'spin-runtime.js'));

function fixture(t, jobs, projects = { app: { allowed_job_types: ['implementation-worker'] } }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-resource-dispatch-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'jobs'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'scripts', 'lib', 'spin-runtime.js'), path.join(root, 'scripts', 'lib', 'spin-runtime.js'));
  fs.copyFileSync(path.join(repo, 'scripts', 'lib', 'project-root.sh'), path.join(root, 'scripts', 'lib', 'project-root.sh'));
  const agent = path.join(root, 'scripts', 'project-ceo-agent.sh');
  fs.writeFileSync(agent, '#!/usr/bin/env bash\nprintf "%s %s %s\\n" "$OMP_RESOURCE_CLASS" "$OMP_JOB_MAX_RSS_MB" "$OMP_JOB_MAX_PROCESSES" > "$SPIN_ROOT/org/jobs/${OMP_JOB_ID}.env"\nexec /bin/sleep 30\n', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'org', 'OMP_HARNESS.json'), `${JSON.stringify({
    workspace_ceo: {},
    projects,
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
      OMP_ADAPTIVE_PARALLELISM: '0',
      OMP_RESOURCE_CHECK_INTERVAL: '1',
      OMP_HEARTBEAT_INTERVAL: '1',
      ...extraEnv,
    },
    encoding: 'utf8',
    timeout: 5000,
  });
}

function queued(id, resourceClass = 'normal', projectId = 'app') {
  return {
    id,
    project_id: projectId,
    type: 'implementation-worker',
    status: 'queued',
    description: id,
    resource_class: resourceClass,
    created_at: new Date().toISOString(),
  };
}

function running(root, id) {
  const child = spawn('/bin/sleep', ['30'], { detached: true, stdio: 'ignore' });
  child.unref();
  fs.writeFileSync(path.join(root, 'org', 'jobs', `${id}.pid`), String(child.pid));
  return child.pid;
}

function readQueue(root) {
  return JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
}

function waitUntil(predicate, timeoutMs = 7000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  }
  return predicate();
}

function readJobEnvironment(root, id) {
  const file = path.join(root, 'org', 'jobs', `${id}.env`);
  const deadline = Date.now() + 2000;
  while (!fs.existsSync(file) && Date.now() < deadline) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  }
  assert.ok(fs.existsSync(file), `timed out waiting for ${id} environment capture`);
  return fs.readFileSync(file, 'utf8');
}

function writeOutcome(root, id, outcome) {
  fs.writeFileSync(
    path.join(root, 'org', 'jobs', `${id}.outcome.json`),
    `${JSON.stringify({ version: 1, job_id: id, outcome, detail: `${outcome} for ${id}` })}\n`
  );
}

test('adaptive dispatch pauses before crossing the memory reserve', t => {
  const root = fixture(t, [queued('normal-job')]);
  const result = run(root, { OMP_ADAPTIVE_PARALLELISM: '1', OMP_AVAILABLE_MEMORY_MB: '1024' });
  assert.equal(result.status, 0, result.stderr);
  const queue = JSON.parse(fs.readFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), 'utf8'));
  assert.equal(queue.jobs[0].status, 'queued');
  assert.equal(queue.dispatch_state.status, 'memory-pressure');
  assert.equal(queue.dispatch_state.dispatch_slots, 0);
});

test('queued model tier overrides workspace defaults while missing values inherit them', t => {
  const id = 'read-only-model-tier';
  const root = fixture(t, [{ ...queued(id), type: 'read-only-worker' }], {
    app: { allowed_job_types: ['read-only-worker'] },
  });
  fs.mkdirSync(path.join(root, 'home', '.config'), { recursive: true });
  for (const name of ['ceo-waterfall.sh', 'spin-runtime.sh']) {
    fs.copyFileSync(path.join(repo, 'scripts', 'lib', name), path.join(root, 'scripts', 'lib', name));
  }
  fs.writeFileSync(path.join(root, 'home', '.config', 'omp.env'), [
    "export SPIN_OMP_DEFAULT_MODEL='global/default'",
    "export SPIN_OMP_DEFAULT_FALLBACKS='global/fallback'",
    "export SPIN_OMP_SMOL_MODEL='global/smol'",
    "export SPIN_OMP_PROVIDER_ORDER='global-first'",
    '',
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'org', 'ceo', 'workspace.env'), [
    "export SPIN_OMP_DEFAULT_MODEL='workspace/default'",
    "export SPIN_OMP_DEFAULT_FALLBACKS='workspace/fallback'",
    "export SPIN_OMP_SMOL_MODEL='workspace/smol'",
    "export SPIN_OMP_PROVIDER_ORDER='workspace-first'",
    '',
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'scripts', 'project-ceo-agent.sh'), `#!/usr/bin/env bash
set -euo pipefail
source "$SPIN_ROOT/scripts/lib/ceo-waterfall.sh"
printf '%s|%s|%s|%s\\n' \\
  "$SPIN_OMP_DEFAULT_MODEL" "$SPIN_OMP_DEFAULT_FALLBACKS" \\
  "$SPIN_OMP_SMOL_MODEL" "$SPIN_OMP_PROVIDER_ORDER" \\
  > "$SPIN_ROOT/org/jobs/\${OMP_JOB_ID}.env"
exec /bin/sleep 30
`, { mode: 0o755 });

  const result = spawnSync('/bin/bash', [supervisor], {
    env: {
      HOME: path.join(root, 'home'),
      PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
      SPIN_ROOT: root,
      OMP_ADAPTIVE_PARALLELISM: '0',
      OMP_RESOURCE_CHECK_INTERVAL: '1',
      OMP_HEARTBEAT_INTERVAL: '1',
      SPIN_OMP_SCOUT_MODEL: 'job/read-only',
      SPIN_OMP_SCOUT_FALLBACKS: 'job/fallback',
    },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    readJobEnvironment(root, id),
    'job/read-only|job/fallback|workspace/smol|workspace-first\n',
  );
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

test('blocked exit-0 work cannot unlock its dependent chain', t => {
  const release = 'release-worker';
  const followup = 'followup-worker';
  const root = fixture(t, [
    {
      ...queued(release),
      status: 'running',
      terminal_outcome: `org/jobs/${release}.outcome.json`,
      started_at: new Date().toISOString(),
    },
    { ...queued(followup), depends_on: [release] },
  ]);
  fs.writeFileSync(path.join(root, 'org', 'jobs', `${release}.exit`), '0\n');
  writeOutcome(root, release, 'blocked');

  const result = run(root);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(readQueue(root).jobs.map(job => job.status), ['blocked', 'blocked']);
});

test('semantic outcome metadata preserves success and fails closed', t => {
  const root = fixture(t, [
    { ...queued('success-job'), status: 'running', terminal_outcome: 'org/jobs/success-job.outcome.json', started_at: new Date().toISOString() },
    { ...queued('legacy-success-job'), status: 'running', started_at: new Date().toISOString() },
    { ...queued('nonzero-job'), status: 'running', terminal_outcome: 'org/jobs/nonzero-job.outcome.json', started_at: new Date().toISOString() },
    { ...queued('missing-outcome-job'), status: 'running', terminal_outcome: 'org/jobs/missing-outcome-job.outcome.json', started_at: new Date().toISOString() },
    { ...queued('malformed-outcome-job'), status: 'running', terminal_outcome: 'org/jobs/malformed-outcome-job.outcome.json', started_at: new Date().toISOString() },
  ]);
  for (const [id, code] of [['success-job', '0'], ['legacy-success-job', '0'], ['nonzero-job', '9'], ['missing-outcome-job', '0'], ['malformed-outcome-job', '0']]) {
    fs.writeFileSync(path.join(root, 'org', 'jobs', `${id}.exit`), `${code}\n`);
  }
  writeOutcome(root, 'success-job', 'completed');
  writeOutcome(root, 'nonzero-job', 'completed');
  fs.writeFileSync(path.join(root, 'org', 'jobs', 'malformed-outcome-job.outcome.json'), '{"version":1\n');

  const result = run(root);
  assert.equal(result.status, 0, result.stderr);
  const byId = Object.fromEntries(readQueue(root).jobs.map(job => [job.id, job]));
  assert.equal(byId['success-job'].status, 'completed');
  assert.equal(byId['legacy-success-job'].status, 'completed');
  assert.equal(byId['nonzero-job'].status, 'failed');
  assert.equal(byId['missing-outcome-job'].status, 'failed');
  assert.equal(byId['malformed-outcome-job'].status, 'failed');
  assert.match(byId['missing-outcome-job'].result, /outcome metadata is missing/i);
  assert.match(byId['malformed-outcome-job'].result, /outcome metadata is malformed/i);
});

test('project agent materializes a blocked receipt marker as JSON', t => {
  const root = fixture(t, []);
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# controller\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'STATE.json'), '{}\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `\
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
codex_is_blocked() { return 1; }
content_changed() { return 0; }
run_agent_resilient() {
  printf '%s\\n' '[receipt]' "Queue-Outcome: $OMP_JOB_ID BLOCKED" >> "$SPIN_ROOT/org/projects/app/RECEIPTS.md"
}
`);

  const jobId = 'blocked-receipt-job';
  const outcomeFile = path.join(root, 'org', 'jobs', `${jobId}.outcome.json`);
  const result = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'project-ceo-agent.sh'), 'app'], {
    env: { ...process.env, SPIN_ROOT: root, OMP_JOB_ID: jobId, OMP_JOB_DESCRIPTION: 'blocked test', OMP_OUTCOME_FILE: outcomeFile },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(outcomeFile, 'utf8')), {
    version: 1,
    job_id: jobId,
    outcome: 'blocked',
    detail: `Project receipt reported Queue-Outcome: ${jobId} BLOCKED.`,
  });
});

test('project agent rejects trailing text after a completed receipt marker', t => {
  const root = fixture(t, []);
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# controller\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'STATE.json'), '{}\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `\
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
codex_is_blocked() { return 1; }
content_changed() { return 0; }
run_agent_resilient() {
  printf '%s\\n' '[receipt]' "Queue-Outcome: $OMP_JOB_ID COMPLETED" 'Actually blocked on an owner approval.' >> "$SPIN_ROOT/org/projects/app/RECEIPTS.md"
}
`);

  const jobId = 'trailing-receipt-job';
  const outcomeFile = path.join(root, 'org', 'jobs', `${jobId}.outcome.json`);
  const result = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'project-ceo-agent.sh'), 'app'], {
    env: { ...process.env, SPIN_ROOT: root, OMP_JOB_ID: jobId, OMP_JOB_DESCRIPTION: 'trailing receipt test', OMP_OUTCOME_FILE: outcomeFile },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 0, result.stderr);
  const outcome = JSON.parse(fs.readFileSync(outcomeFile, 'utf8'));
  assert.equal(outcome.outcome, 'failed');
  assert.match(outcome.detail, /not the final non-empty appended receipt line/i);
});

test('project agent rejects duplicate terminal receipt markers', t => {
  const root = fixture(t, []);
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# controller\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'STATE.json'), '{}\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `\
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
codex_is_blocked() { return 1; }
content_changed() { return 0; }
run_agent_resilient() {
  printf '%s\\n' '[receipt]' "Queue-Outcome: $OMP_JOB_ID COMPLETED" "Queue-Outcome: $OMP_JOB_ID BLOCKED" >> "$SPIN_ROOT/org/projects/app/RECEIPTS.md"
}
`);

  const jobId = 'duplicate-receipt-job';
  const outcomeFile = path.join(root, 'org', 'jobs', `${jobId}.outcome.json`);
  const result = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'project-ceo-agent.sh'), 'app'], {
    env: { ...process.env, SPIN_ROOT: root, OMP_JOB_ID: jobId, OMP_JOB_DESCRIPTION: 'duplicate receipt test', OMP_OUTCOME_FILE: outcomeFile },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 0, result.stderr);
  const outcome = JSON.parse(fs.readFileSync(outcomeFile, 'utf8'));
  assert.equal(outcome.outcome, 'failed');
  assert.match(outcome.detail, /missing or ambiguous/i);
});

test('project agent rejects a marker joined to an unterminated existing receipt line', t => {
  const root = fixture(t, []);
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# controller\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'STATE.json'), '{}\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), 'unterminated prior receipt');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `\
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
codex_is_blocked() { return 1; }
content_changed() { return 0; }
run_agent_resilient() {
  printf '%s' "Queue-Outcome: $OMP_JOB_ID COMPLETED" >> "$SPIN_ROOT/org/projects/app/RECEIPTS.md"
}
`);

  const jobId = 'joined-receipt-job';
  const outcomeFile = path.join(root, 'org', 'jobs', `${jobId}.outcome.json`);
  const result = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'project-ceo-agent.sh'), 'app'], {
    env: { ...process.env, SPIN_ROOT: root, OMP_JOB_ID: jobId, OMP_JOB_DESCRIPTION: 'joined receipt test', OMP_OUTCOME_FILE: outcomeFile },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 0, result.stderr);
  const outcome = JSON.parse(fs.readFileSync(outcomeFile, 'utf8'));
  assert.equal(outcome.outcome, 'failed');
  assert.match(outcome.detail, /not the final non-empty appended receipt line/i);
});

test('a silent project-agent success fails once without a duplicate provider run', t => {
  const root = fixture(t, []);
  fs.mkdirSync(path.join(root, 'org', 'projects', 'app'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# controller\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'STATE.json'), '{}\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `\
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
codex_is_blocked() { return 1; }
content_changed() { return 1; }
run_agent_resilient() {
  count="$(cat "$SPIN_ROOT/provider-count" 2>/dev/null || printf '0')"
  printf '%s\n' "$((count + 1))" > "$SPIN_ROOT/provider-count"
  return 0
}
`);

  const jobId = 'silent-success-job';
  const outcomeFile = path.join(root, 'org', 'jobs', `${jobId}.outcome.json`);
  const result = spawnSync('/bin/bash', [path.join(repo, 'scripts', 'project-ceo-agent.sh'), 'app'], {
    env: { ...process.env, SPIN_ROOT: root, OMP_JOB_ID: jobId, OMP_JOB_DESCRIPTION: 'silent test', OMP_OUTCOME_FILE: outcomeFile },
    encoding: 'utf8',
    timeout: 5000,
  });

  assert.equal(result.status, 65, result.stderr);
  assert.equal(fs.readFileSync(path.join(root, 'provider-count'), 'utf8').trim(), '1');
  assert.match(result.stderr, /refusing a duplicate outer run/);
  assert.equal(JSON.parse(fs.readFileSync(outcomeFile, 'utf8')).outcome, 'failed');
});

test('resource classes are normalized before an exclusive heavy dispatch', t => {
  const heavy = queued('heavy-first', ' HEAVY ');
  const normal = queued('normal-after-heavy', 'normal', 'api');
  const root = fixture(t, [normal, heavy], {
    app: { allowed_job_types: ['implementation-worker'] },
    api: { allowed_job_types: ['implementation-worker'] },
  });

  const result = run(root);
  assert.equal(result.status, 0, result.stderr);
  const byId = Object.fromEntries(readQueue(root).jobs.map(job => [job.id, job]));
  assert.equal(byId[heavy.id].status, 'running');
  assert.equal(byId[heavy.id].resource_class, 'heavy');
  assert.deepEqual(byId[heavy.id].resource_limits, { max_rss_mb: 6144, max_processes: 32 });
  assert.equal(readJobEnvironment(root, heavy.id), 'heavy 6144 32\n');
  assert.equal(byId[normal.id].status, 'queued');
});

test('a running normalized heavy lease blocks queued normal dispatch', t => {
  const heavy = { ...queued('running-heavy', ' HEAVY '), status: 'running', started_at: new Date().toISOString() };
  const normal = queued('queued-normal', 'normal', 'api');
  const root = fixture(t, [heavy, normal], {
    app: { allowed_job_types: ['implementation-worker'] },
    api: { allowed_job_types: ['implementation-worker'] },
  });
  running(root, heavy.id);

  const result = run(root);
  assert.equal(result.status, 0, result.stderr);
  const byId = Object.fromEntries(readQueue(root).jobs.map(job => [job.id, job]));
  assert.equal(byId[heavy.id].status, 'running');
  assert.equal(byId[normal.id].status, 'queued');
});

test('normal jobs retain concurrent dispatch and explicit limits', t => {
  const projects = Object.fromEntries(['app', 'api', 'docs'].map(id => [id, {
    allowed_job_types: ['implementation-worker'],
  }]));
  const jobs = [
    queued('normal-app', 'normal', 'app'),
    queued('normal-api', 'normal', 'api'),
    queued('normal-docs', 'normal', 'docs'),
  ];
  const root = fixture(t, jobs, projects);

  const result = run(root, {
    OMP_JOB_MAX_RSS_MB: '4444',
    OMP_JOB_MAX_PROCESSES: '22',
  });
  assert.equal(result.status, 0, result.stderr);
  const byId = Object.fromEntries(readQueue(root).jobs.map(job => [job.id, job]));
  for (const job of jobs) {
    assert.equal(byId[job.id].status, 'running');
    assert.equal(byId[job.id].resource_class, 'normal');
    assert.deepEqual(byId[job.id].resource_limits, { max_rss_mb: 4444, max_processes: 22 });
    assert.equal(readJobEnvironment(root, job.id), 'normal 4444 22\n');
    const pid = Number(fs.readFileSync(path.join(root, 'org', 'jobs', `${job.id}.pid`), 'utf8'));
    assert.equal(byId[job.id].process_identity, runtime.processIdentity(pid));
  }
});

test('a recycled PID identity cannot hold a lane or receive timeout signals', t => {
  const id = 'identity-mismatch-job';
  const root = fixture(t, [{
    ...queued(id),
    status: 'running',
    terminal_outcome: `org/jobs/${id}.outcome.json`,
    process_identity: 'not-the-recorded-process-start',
    started_at: new Date(Date.now() - 60_000).toISOString(),
    max_runtime_seconds: 1,
  }]);
  const unrelatedPid = running(root, id);
  t.after(() => {
    try { process.kill(-unrelatedPid, 'SIGKILL'); } catch { try { process.kill(unrelatedPid, 'SIGKILL'); } catch {} }
  });

  const result = run(root);
  assert.equal(result.status, 0, result.stderr);
  const job = readQueue(root).jobs[0];
  assert.equal(job.status, 'failed');
  assert.match(job.result, /outcome metadata is missing/i);
  assert.doesNotThrow(() => process.kill(unrelatedPid, 0));
  assert.equal(fs.existsSync(path.join(root, 'org', 'jobs', `${id}.pid`)), false);
});

test('the resource governor kills an over-limit process group and records the violation', t => {
  const id = 'resource-limit-job';
  const root = fixture(t, [queued(id)]);
  fs.writeFileSync(
    path.join(root, 'scripts', 'project-ceo-agent.sh'),
    '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n',
    { mode: 0o755 }
  );

  const dispatched = run(root, { OMP_JOB_MAX_PROCESSES: '1' });
  assert.equal(dispatched.status, 0, dispatched.stderr);
  const pidFile = path.join(root, 'org', 'jobs', `${id}.pid`);
  const resourceFile = path.join(root, 'org', 'jobs', `${id}.resource`);
  const wrapperPid = Number.parseInt(fs.readFileSync(pidFile, 'utf8'), 10);

  assert.equal(waitUntil(() => fs.existsSync(resourceFile)), true, 'resource violation was not recorded');
  assert.match(fs.readFileSync(resourceFile, 'utf8'), /Resource limit exceeded: .*process count/);
  assert.equal(waitUntil(() => runtime.processIdentity(wrapperPid) === null), true, 'over-limit process group remained alive');

  const reconciled = run(root);
  assert.equal(reconciled.status, 0, reconciled.stderr);
  const job = readQueue(root).jobs[0];
  assert.equal(job.status, 'failed');
  assert.match(job.result, /Resource limit exceeded/);
  assert.deepEqual(job.resource_limits, { max_rss_mb: 3072, max_processes: 1 });
});
