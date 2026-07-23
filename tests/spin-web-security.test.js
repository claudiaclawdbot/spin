'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-web-security-'));
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'org', 'HUMAN_QUEUE.md'), '# Waiting on you\n\n- [ ] Ship the verified release.\n');
  fs.writeFileSync(path.join(root, 'org', 'ceo', 'APPROVALS.md'), '# Approvals\n\n## Pending\n\n## Processed\n');
  fs.writeFileSync(path.join(root, 'org', 'AGENT_QUEUE.json'), '{"jobs":[]}\n');
  fs.writeFileSync(path.join(root, 'org', 'state.json'), '{"project_orchestrators":[]}\n');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function serverUrl(child) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => reject(new Error(`web server did not start: ${output}`)), 5000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
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

test('web server refuses a non-loopback bind address', t => {
  const root = fixture(t);
  const result = spawnSync(process.execPath, [
    path.join(repo, 'scripts', 'spin-web.js'),
    '--host', '0.0.0.0',
    '--port', '0',
  ], {
    env: { ...process.env, SPIN_ROOT: root },
    encoding: 'utf8',
    timeout: 3000,
  });

  assert.equal(result.signal, null, result.stderr);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /refusing non-loopback --host "0\.0\.0\.0"/);
  assert.doesNotMatch(result.stdout, /SPIN web:/);
});

test('decision writes require a loopback same-origin request and the process CSRF token', async t => {
  const root = fixture(t);
  const approvals = path.join(root, 'org', 'ceo', 'APPROVALS.md');
  const child = spawn(process.execPath, [path.join(repo, 'scripts', 'spin-web.js'), '--port', '0'], {
    env: { ...process.env, SPIN_ROOT: root },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGTERM'));

  const baseUrl = await serverUrl(child);
  const page = await request(baseUrl);
  assert.equal(page.status, 200);
  assert.equal(page.headers['cache-control'], 'no-store');
  assert.match(page.headers['content-security-policy'], /form-action 'self'/);

  const invalidFloor = await request(`${baseUrl}floor/%2e%2e%2fsecret`);
  assert.equal(invalidFloor.status, 400);
  assert.equal(invalidFloor.headers['cache-control'], 'no-store');
  assert.match(invalidFloor.headers['content-security-policy'], /frame-ancestors 'none'/);
  assert.equal(invalidFloor.headers['x-content-type-options'], 'nosniff');

  const tokenMatches = [...page.body.matchAll(/name="csrf" value="([a-f0-9]{64})"/g)];
  assert.ok(tokenMatches.length >= 4, 'every decision form should carry the CSRF token');
  const token = tokenMatches[0][1];
  assert.ok(tokenMatches.every(match => match[1] === token), 'forms should share one per-process token');

  const decisionUrl = new URL('/decision', baseUrl);
  const validHeaders = {
    host: decisionUrl.host,
    origin: decisionUrl.origin,
  };
  const before = fs.readFileSync(approvals, 'utf8');
  const rejectionCases = [
    {
      name: 'missing token',
      fields: { action: 'APPROVE', item: 'must not write missing token' },
      headers: validHeaders,
    },
    {
      name: 'bad token',
      fields: { csrf: `${token.slice(0, -1)}x`, action: 'APPROVE', item: 'must not write bad token' },
      headers: validHeaders,
    },
    {
      name: 'foreign Origin',
      fields: { csrf: token, action: 'APPROVE', item: 'must not write foreign origin' },
      headers: { ...validHeaders, origin: 'https://attacker.example' },
    },
    {
      name: 'missing Origin',
      fields: { csrf: token, action: 'APPROVE', item: 'must not write missing origin' },
      headers: { host: decisionUrl.host },
    },
    {
      name: 'non-loopback Host',
      fields: { csrf: token, action: 'APPROVE', item: 'must not write foreign host' },
      headers: { host: `attacker.example:${decisionUrl.port}`, origin: `http://attacker.example:${decisionUrl.port}` },
    },
  ];

  for (const rejection of rejectionCases) {
    const response = await request(decisionUrl, {
      method: 'POST',
      fields: rejection.fields,
      headers: rejection.headers,
    });
    assert.equal(response.status, 403, rejection.name);
    assert.equal(response.body, 'forbidden\n', rejection.name);
    assert.equal(fs.readFileSync(approvals, 'utf8'), before, `${rejection.name} must not mutate approvals`);
  }

  const accepted = await request(decisionUrl, {
    method: 'POST',
    fields: {
      csrf: token,
      action: 'APPROVE',
      item: 'Ship the verified release.',
      note: 'same-origin owner decision',
    },
    headers: validHeaders,
  });
  assert.equal(accepted.status, 303);
  assert.equal(accepted.headers.location, '/?ok=Decision%20recorded');
  const after = fs.readFileSync(approvals, 'utf8');
  assert.match(after, /APPROVE: Ship the verified release\. — same-origin owner decision/);
});
