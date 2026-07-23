'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const runtimeFile = path.join(repo, 'scripts', 'lib', 'spin-runtime.js');
const shellRuntime = path.join(repo, 'scripts', 'lib', 'spin-runtime.sh');
const runtime = require(runtimeFile);

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-node-process-lock-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return {
    lock: path.join(root, 'queue.lock'),
    ready: path.join(root, 'ready'),
    stop: path.join(root, 'stop'),
  };
}

function waitForFile(file, child) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const poll = () => {
      if (fs.existsSync(file)) return resolve();
      if (child.exitCode !== null) return reject(new Error(`holder exited early: ${child.exitCode}`));
      if (Date.now() >= deadline) return reject(new Error('timed out waiting for lock holder'));
      setTimeout(poll, 20);
    };
    poll();
  });
}

test('Node hardlink locks interoperate with shell identity readers', async t => {
  const files = fixture(t);
  const holderSource = `
    const fs = require('fs');
    const runtime = require(process.argv[1]);
    const handle = runtime.acquireProcessLock(process.argv[2]);
    fs.writeFileSync(process.argv[3], 'ready\\n');
    while (!fs.existsSync(process.argv[4])) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    if (!runtime.releaseProcessLock(handle)) process.exit(3);
  `;
  const holder = spawn(process.execPath, ['-e', holderSource, runtimeFile, files.lock, files.ready, files.stop], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let holderError = '';
  holder.stderr.on('data', chunk => { holderError += chunk; });
  const finished = new Promise(resolve => holder.once('exit', resolve));
  t.after(() => { if (holder.exitCode === null && holder.signalCode === null) holder.kill('SIGKILL'); });
  await waitForFile(files.ready, holder);

  const shell = spawnSync('/bin/bash', ['-c', `
    source "$1"
    spin_locked_process_running "$2" node
    printf 'pid=%s\\n' "$(spin_lock_read_pid "$2")"
  `, '_', shellRuntime, files.lock], { encoding: 'utf8' });
  assert.equal(shell.status, 0, shell.stderr);
  assert.equal(shell.stdout.trim(), `pid=${holder.pid}`);

  assert.throws(
    () => runtime.acquireProcessLock(files.lock, { timeoutMs: 0 }),
    error => error && error.code === 'SPIN_LOCK_BUSY' && String(error.message).includes(String(holder.pid)),
  );

  fs.writeFileSync(files.stop, 'stop\n');
  assert.equal(await finished, 0, holderError);
  assert.equal(fs.existsSync(files.lock), false);
});

test('Node acquisition reclaims a live PID with the wrong start identity', t => {
  const files = fixture(t);
  fs.writeFileSync(files.lock, `${process.pid}\nversion=1\nidentity=wrong-start\ntoken=stale\n`);
  const handle = runtime.acquireProcessLock(files.lock, { timeoutMs: 100 });
  assert.equal(runtime.readProcessLock(files.lock).fields.identity, runtime.processIdentity(process.pid));
  assert.equal(runtime.releaseProcessLock(handle), true);
  assert.equal(fs.existsSync(files.lock), false);
});
