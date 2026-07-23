'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');
const runtime = path.join(repo, 'scripts', 'lib', 'spin-runtime.sh');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-process-lock-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return {
    root,
    lock: path.join(root, 'daemon.lock'),
    ready: path.join(root, 'ready'),
    stop: path.join(root, 'stop'),
    terminating: path.join(root, 'terminating'),
  };
}

function bash(script, args = []) {
  return spawnSync('/bin/bash', ['-c', script, '_', ...args], {
    encoding: 'utf8',
    timeout: 5000,
  });
}

function waitForFile(file, child) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 5000;
    const poll = () => {
      if (fs.existsSync(file)) return resolve();
      if (child.exitCode !== null) return reject(new Error(`lock holder exited early with ${child.exitCode}`));
      if (Date.now() >= deadline) return reject(new Error('timed out waiting for lock holder'));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function waitForExit(child) {
  return child.finished || Promise.resolve();
}

async function startHolder(t, files) {
  const script = String.raw`
source "$1"
spin_lock_acquire "$2" process-lock-holder || exit $?
owner_token="$SPIN_LOCK_OWNER_TOKEN"
lock_file="$2"
cleanup() { spin_lock_release "$lock_file" "$owner_token" || printf 'release failed: %s\n' "$?" >&2; }
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 0' INT TERM
printf '%s\n' "$owner_token" > "$3"
while [ ! -e "$4" ]; do sleep 0.05; done
`;
  const child = spawn('/bin/bash', ['-c', script, '_', runtime, files.lock, files.ready, files.stop], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stderrOutput = () => stderr;
  child.finished = new Promise(resolve => child.once('exit', resolve));
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  });
  await waitForFile(files.ready, child);
  return child;
}

test('concurrent hardlink acquisition admits only one live owner', async t => {
  const files = fixture(t);
  const holder = await startHolder(t, files);

  const contender = bash(String.raw`
source "$1"
spin_lock_acquire "$2" process-lock-holder
printf '%s\n' "$?"
`, [runtime, files.lock]);
  assert.equal(contender.status, 0, contender.stderr);
  assert.equal(contender.stdout.trim(), '1');

  const owner = bash('source "$1"; spin_lock_read_pid "$2"', [runtime, files.lock]);
  assert.equal(owner.status, 0, owner.stderr);
  assert.equal(Number(owner.stdout.trim()), holder.pid);

  fs.writeFileSync(files.stop, 'stop\n');
  await waitForExit(holder);
  assert.equal(fs.existsSync(files.lock), false, holder.stderrOutput());
});

test('a dead owner lock is reclaimed and replaced atomically', async t => {
  const files = fixture(t);
  const holder = await startHolder(t, files);
  holder.kill('SIGKILL');
  await waitForExit(holder);
  assert.equal(fs.existsSync(files.lock), true);

  const replacement = bash(String.raw`
source "$1"
spin_lock_acquire "$2" process-lock-holder
rc=$?
printf 'acquire=%s\n' "$rc"
if [ "$rc" -eq 0 ]; then
  token="$SPIN_LOCK_OWNER_TOKEN"
  printf 'pid=%s\n' "$(spin_lock_read_pid "$2")"
  spin_lock_release "$2" "$token"
fi
`, [runtime, files.lock]);
  assert.equal(replacement.status, 0, replacement.stderr);
  assert.match(replacement.stdout, /acquire=0/);
  assert.equal(fs.existsSync(files.lock), false, holder.stderrOutput());
});

test('a live PID with a mismatched process-start identity is rejected', t => {
  const files = fixture(t);
  fs.writeFileSync(files.lock, `${process.pid}\nversion=1\nidentity=not-this-process\ntoken=test\n`);

  const result = bash(String.raw`
source "$1"
spin_lock_identity_matches "$2" node
printf 'match=%s pid=%s\n' "$?" "$(spin_lock_read_pid "$2")"
`, [runtime, files.lock]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), `match=1 pid=${process.pid}`);
});

test('legacy plain-PID locks remain compatible', t => {
  const files = fixture(t);
  fs.writeFileSync(files.lock, `${process.pid}\n`);

  const result = bash(String.raw`
source "$1"
spin_locked_process_running "$2" node
printf 'running=%s pid=%s\n' "$?" "$(spin_lock_read_pid "$2")"
`, [runtime, files.lock]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), `running=0 pid=${process.pid}`);
});

test('release refuses a valid owner token presented by another process', async t => {
  const files = fixture(t);
  const holder = await startHolder(t, files);
  const token = fs.readFileSync(files.ready, 'utf8').trim();

  const attacker = bash(String.raw`
source "$1"
spin_lock_release "$2" "$3"
printf '%s\n' "$?"
`, [runtime, files.lock, token]);
  assert.equal(attacker.status, 0, attacker.stderr);
  assert.equal(attacker.stdout.trim(), '1');
  assert.equal(fs.existsSync(files.lock), true);

  const stillOwned = bash('source "$1"; spin_lock_identity_matches "$2"', [runtime, files.lock]);
  assert.equal(stillOwned.status, 0, stillOwned.stderr);
  fs.writeFileSync(files.stop, 'stop\n');
  await waitForExit(holder);
  assert.equal(fs.existsSync(files.lock), false, holder.stderrOutput());
});

test('coordinated stop pins the owner lock until TERM cleanup exits', async t => {
  const files = fixture(t);
  const holderScript = String.raw`
source "$1"
spin_lock_acquire "$2" process-lock-holder || exit $?
owner_token="$SPIN_LOCK_OWNER_TOKEN"
lock_file="$2"
terminating_file="$4"
cleanup() { spin_lock_release "$lock_file" "$owner_token" >/dev/null 2>&1 || true; }
on_term() {
  spin_lock_release "$lock_file" "$owner_token" || exit $?
  printf 'terminating\n' > "$terminating_file"
  sleep 0.35
  exit 0
}
trap cleanup EXIT
trap on_term TERM
printf 'ready\n' > "$3"
while :; do sleep 0.05; done
`;
  const holder = spawn('/bin/bash', ['-c', holderScript, '_', runtime, files.lock, files.ready, files.terminating], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  holder.finished = new Promise(resolve => holder.once('exit', resolve));
  t.after(() => {
    if (holder.exitCode === null && holder.signalCode === null) holder.kill('SIGKILL');
  });
  await waitForFile(files.ready, holder);

  const stopperScript = String.raw`
source "$1"
spin_stop_locked_process "$2" process-lock-holder 100 0.02
printf 'stopped\n'
`;
  const stopper = spawn('/bin/bash', ['-c', stopperScript, '_', runtime, files.lock], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stopperOutput = '';
  let stopperError = '';
  stopper.stdout.on('data', chunk => { stopperOutput += chunk; });
  stopper.stderr.on('data', chunk => { stopperError += chunk; });
  stopper.finished = new Promise(resolve => stopper.once('exit', resolve));
  t.after(() => {
    if (stopper.exitCode === null && stopper.signalCode === null) stopper.kill('SIGKILL');
  });

  await waitForFile(files.terminating, stopper);
  assert.equal(fs.existsSync(files.lock), true, 'owner release exposed the lock during TERM cleanup');
  assert.equal(fs.existsSync(`${files.lock}.stopping`), true, 'stop marker did not pin the owner inode');
  const contender = bash('source "$1"; spin_lock_acquire "$2" process-lock-holder; printf "%s\\n" "$?"', [runtime, files.lock]);
  assert.equal(contender.status, 0, contender.stderr);
  assert.equal(contender.stdout.trim(), '1');

  await Promise.all([holder.finished, stopper.finished]);
  assert.equal(stopper.exitCode, 0, stopperError);
  assert.equal(stopperOutput.trim(), 'stopped');
  assert.equal(fs.existsSync(files.lock), false);
  assert.equal(fs.existsSync(`${files.lock}.stopping`), false);

  const replacement = bash(String.raw`
source "$1"
spin_lock_acquire "$2" process-lock-holder
rc=$?
if [ "$rc" -eq 0 ]; then spin_lock_release "$2" "$SPIN_LOCK_OWNER_TOKEN"; fi
printf '%s\n' "$rc"
`, [runtime, files.lock]);
  assert.equal(replacement.status, 0, replacement.stderr);
  assert.equal(replacement.stdout.trim(), '0');
});

test('the live dashboard reads the PID line from an identity-aware lock', t => {
  const files = fixture(t);
  const dashboardLock = path.join(files.root, 'org', 'ceo', 'runs', '.workspace-ceo-tick.lock');
  fs.mkdirSync(path.dirname(dashboardLock), { recursive: true });
  const identity = bash('source "$1"; spin_process_identity "$2"', [runtime, String(process.pid)]);
  assert.equal(identity.status, 0, identity.stderr);
  fs.writeFileSync(dashboardLock, `${process.pid}\nversion=1\nidentity=${identity.stdout.trim()}\ntoken=dashboard-test\n`);

  const dashboard = spawnSync(process.execPath, [path.join(repo, 'scripts', 'ceo-dashboard.js'), files.root], {
    encoding: 'utf8',
  });
  assert.equal(dashboard.status, 0, dashboard.stderr);
  assert.match(dashboard.stdout, new RegExp(`running.*PID ${process.pid}`));

  fs.writeFileSync(dashboardLock, `${process.pid}\nversion=1\nidentity=not-this-process\ntoken=dashboard-test\n`);
  const staleDashboard = spawnSync(process.execPath, [path.join(repo, 'scripts', 'ceo-dashboard.js'), files.root], {
    encoding: 'utf8',
  });
  assert.equal(staleDashboard.status, 0, staleDashboard.stderr);
  assert.match(staleDashboard.stdout, /Driver: .*not running/);
});
