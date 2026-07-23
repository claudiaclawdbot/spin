'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const org = path.join(repo, 'scripts', 'org');
const broker = path.join(repo, 'scripts', 'spin-action-broker.js');
const web = path.join(repo, 'scripts', 'spin-web.js');
const approve = path.join(repo, 'scripts', 'approve.sh');
const runtime = require(path.join(repo, 'scripts', 'lib', 'spin-runtime.js'));

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-shared-state-locks-'));
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'org', 'HUMAN_QUEUE.md'),
    '# Waiting on you\n\n- [ ] 2026-07-22 12:00 — Seed escalation\n',
  );
  fs.writeFileSync(
    path.join(root, 'org', 'ceo', 'APPROVALS.md'),
    '# Approvals\n\n## Pending\n\n- Needs owner review\n\n## Processed\n',
  );
  fs.writeFileSync(path.join(root, 'org', 'ACTION_POLICY.json'), '{"version":1,"mode":"deny-by-default","rules":[]}\n');
  fs.writeFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), '{"jobs":[]}\n');
  fs.writeFileSync(path.join(root, 'org', 'state.json'), '{"project_orchestrators":[]}\n');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function spawnCommand(t, command, args, root, env = {}) {
  const child = spawn(command, args, {
    env: { ...process.env, SPIN_ROOT: root, NODE_OPTIONS: '', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdoutOutput = () => stdout;
  child.stderrOutput = () => stderr;
  child.result = new Promise(resolve => child.once('exit', (code, signal) => {
    resolve({ status: code, signal, stdout, stderr });
  }));
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  });
  return child;
}

function spawnNode(t, file, args, root, env = {}) {
  return spawnCommand(t, process.execPath, [file, ...args], root, env);
}

async function waitFor(predicate, message, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(message);
}

function lockCandidatePids(lock) {
  const dir = path.dirname(lock);
  const prefix = `${path.basename(lock)}.candidate.`;
  try {
    return new Set(fs.readdirSync(dir)
      .filter(name => name.startsWith(prefix))
      .map(name => {
        try {
          return Number(fs.readFileSync(path.join(dir, name), 'utf8').split('\n')[0]);
        } catch {
          return NaN;
        }
      })
      .filter(Number.isInteger));
  } catch {
    return new Set();
  }
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
    child.stderr.on('data', chunk => { output += chunk; });
    child.once('exit', code => {
      clearTimeout(timeout);
      reject(new Error(`web server exited ${code}: ${output}`));
    });
  });
}

function request(url, { method = 'GET', fields, headers = {} } = {}) {
  const body = fields ? new URLSearchParams(fields).toString() : '';
  return new Promise((resolve, reject) => {
    const req = http.request(url, {
      method,
      headers: {
        ...headers,
        ...(fields ? {
          'content-type': 'application/x-www-form-urlencoded',
          'content-length': Buffer.byteLength(body),
        } : {}),
      },
    }, response => {
      let responseBody = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { responseBody += chunk; });
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: responseBody,
      }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

test('all HUMAN_QUEUE writers wait on the shared org-human lock and preserve each update', async t => {
  const root = fixture(t);
  const queue = path.join(root, 'org', 'HUMAN_QUEUE.md');
  const before = fs.readFileSync(queue, 'utf8');
  const lock = path.join(root, 'org', 'ceo', 'runs', '.org-human.lock');
  const handle = runtime.acquireProcessLock(lock);
  let released = false;
  t.after(() => {
    if (!released) runtime.releaseProcessLock(handle);
  });

  const resolver = spawnNode(t, org, ['resolve-escalation', 'Seed escalation', '--note', 'handled'], root);
  const escalator = spawnNode(t, org, ['escalate', 'Parallel escalation'], root);
  const requester = spawnNode(t, broker, [
    'request',
    'production-deploy',
    '--target', 'example.test',
    '--reason', 'Parallel broker request',
  ], root);
  const duplicateRequester = spawnNode(t, broker, [
    'request',
    'production-deploy',
    '--target', 'example.test',
    '--reason', 'Parallel broker request',
  ], root);

  await waitFor(
    () => {
      const candidates = lockCandidatePids(lock);
      return [resolver, escalator, requester, duplicateRequester]
        .every(child => candidates.has(child.pid));
    },
    'HUMAN_QUEUE writers did not all enter the shared lock',
  );
  const statusesWhileLocked = [resolver, escalator, requester, duplicateRequester].map(child => child.exitCode);
  const contentWhileLocked = fs.readFileSync(queue, 'utf8');
  runtime.releaseProcessLock(handle);
  released = true;

  const results = await Promise.all([
    resolver.result,
    escalator.result,
    requester.result,
    duplicateRequester.result,
  ]);
  assert.deepEqual(statusesWhileLocked, [null, null, null, null]);
  assert.equal(contentWhileLocked, before);
  for (const result of results) assert.equal(result.status, 0, result.stderr);

  const after = fs.readFileSync(queue, 'utf8');
  assert.match(after, /\[x\].*Seed escalation.*resolved.*handled/);
  assert.match(after, /\[ \].*Parallel escalation/);
  assert.match(after, /\[ \] \[action:[a-f0-9]{12}\].*Parallel broker request/);
  assert.equal((after.match(/Parallel escalation/g) || []).length, 1);
  assert.equal((after.match(/Parallel broker request/g) || []).length, 1);
});

test('web, org, and shell approval writers share org-approvals lock without losing updates', async t => {
  const root = fixture(t);
  const approvals = path.join(root, 'org', 'ceo', 'APPROVALS.md');
  const child = spawnNode(t, web, ['--port', '0'], root);
  const baseUrl = await serverUrl(child);
  const page = await request(baseUrl);
  assert.equal(page.status, 200);
  const token = page.body.match(/name="csrf" value="([a-f0-9]{64})"/)?.[1];
  assert.ok(token, 'web page should expose its per-process CSRF token in decision forms');

  const decisionUrl = new URL('/decision', baseUrl);
  const lock = path.join(root, 'org', 'ceo', 'runs', '.org-approvals.lock');
  const handle = runtime.acquireProcessLock(lock);
  let released = false;
  t.after(() => {
    if (!released) runtime.releaseProcessLock(handle);
  });

  let webSettled = false;
  const webWrite = request(decisionUrl, {
    method: 'POST',
    fields: {
      csrf: token,
      action: 'APPROVE',
      item: 'Parallel web decision',
      note: 'preserve this update',
    },
    headers: {
      host: decisionUrl.host,
      origin: decisionUrl.origin,
    },
  }).then(response => {
    webSettled = true;
    return response;
  });
  const processor = spawnNode(t, org, ['process-approval', 'Needs owner review', 'ask', '--note', 'need detail'], root);
  const shellWriter = spawnCommand(t, '/bin/bash', ['-x',
    approve,
    'ASK: Parallel shell decision',
  ], root);

  const before = fs.readFileSync(approvals, 'utf8');
  await waitFor(
    () => {
      const candidates = lockCandidatePids(lock);
      return candidates.has(child.pid)
        && candidates.has(processor.pid)
        && /spin_lock_acquire .*\.org-approvals\.lock/.test(shellWriter.stderrOutput());
    },
    'web, org, and shell approval writers did not enter the shared lock',
  );
  const processorStatusWhileLocked = processor.exitCode;
  const shellStatusWhileLocked = shellWriter.exitCode;
  const webSettledWhileLocked = webSettled;
  const contentWhileLocked = fs.readFileSync(approvals, 'utf8');
  runtime.releaseProcessLock(handle);
  released = true;

  const [webResponse, processorResult, shellResult] = await Promise.all([
    webWrite,
    processor.result,
    shellWriter.result,
  ]);
  assert.equal(processorStatusWhileLocked, null);
  assert.equal(shellStatusWhileLocked, null);
  assert.equal(webSettledWhileLocked, false);
  assert.equal(contentWhileLocked, before);
  assert.equal(webResponse.status, 303);
  assert.equal(processorResult.status, 0, processorResult.stderr);
  assert.equal(shellResult.status, 0, shellResult.stderr);

  const after = fs.readFileSync(approvals, 'utf8');
  assert.match(after, /APPROVE: Parallel web decision — preserve this update/);
  assert.match(after, /Needs owner review → \[ASK .* — need detail\]/);
  assert.match(after, /ASK: Parallel shell decision/);
  assert.equal((after.match(/Parallel web decision/g) || []).length, 1);
  assert.equal((after.match(/Needs owner review/g) || []).length, 1);
  assert.equal((after.match(/Parallel shell decision/g) || []).length, 1);
});

test('shell approval writer fails closed when the Pending section is absent', async t => {
  const root = fixture(t);
  const approvals = path.join(root, 'org', 'ceo', 'APPROVALS.md');
  const malformed = '# Approvals\n\n## Processed\n\n- historical decision\n';
  fs.writeFileSync(approvals, malformed);

  const writer = spawnCommand(t, '/bin/bash', [
    approve,
    'APPROVE: Must not be recorded',
  ], root);
  const result = await writer.result;
  assert.equal(result.status, 2, result.stderr);
  assert.match(result.stderr, /APPROVALS\.md has no Pending section; no decision was recorded/);
  assert.doesNotMatch(result.stdout, /Recorded under Pending/);
  assert.equal(fs.readFileSync(approvals, 'utf8'), malformed);
  assert.equal(fs.existsSync(path.join(root, 'org', 'ceo', 'runs', '.org-approvals.lock')), false);
  assert.deepEqual(
    fs.readdirSync(path.dirname(approvals)).filter(name => name.startsWith('APPROVALS.md.tmp.')),
    [],
  );
});
