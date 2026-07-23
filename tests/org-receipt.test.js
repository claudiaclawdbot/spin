'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const org = path.join(repo, 'scripts', 'org');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-org-receipt-'));
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function writeReceipt(root, body) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [org, 'receipt'], {
      env: { ...process.env, SPIN_ROOT: root },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', status => resolve({ status, stdout, stderr }));
    child.stdin.end(`${body}\n`);
  });
}

test('concurrent org receipts are written once each without filename collisions', async t => {
  const root = fixture(t);
  const bodies = Array.from({ length: 20 }, (_, index) => `parallel receipt ${index + 1}`);
  const results = await Promise.all(bodies.map(body => writeReceipt(root, body)));

  for (const result of results) {
    assert.equal(result.status, 0, result.stderr);
    assert.match(
      result.stdout,
      /^receipt → org\/ceo\/runs\/workspace-ceo-agent-\d{8}-\d{6}-\d{3}-\d{4}\.md\n$/,
    );
  }

  const runs = path.join(root, 'org', 'ceo', 'runs');
  const receipts = fs.readdirSync(runs)
    .filter(name => /^workspace-ceo-agent-.*\.md$/.test(name));
  assert.equal(receipts.length, bodies.length);
  assert.equal(new Set(receipts).size, bodies.length);

  const writtenBodies = receipts
    .map(name => fs.readFileSync(path.join(runs, name), 'utf8').trim())
    .sort();
  assert.deepEqual(writtenBodies, [...bodies].sort());
});
