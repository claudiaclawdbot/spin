#!/usr/bin/env node
// Resolve SPIN-owned app/runtime binaries before PATH fallbacks.

const fs = require('fs');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const os = require('os');
const path = require('path');

function processAlive(pid) {
  if (!Number.isInteger(Number(pid)) || Number(pid) < 1) return false;
  try { process.kill(Number(pid), 0); return true; } catch { return false; }
}

function processIdentity(pid = process.pid) {
  pid = Number(pid);
  if (!processAlive(pid)) return null;
  try {
    const raw = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const close = raw.lastIndexOf(')');
    const fields = raw.slice(close + 2).trim().split(/\s+/);
    const startTicks = fields[19];
    const boot = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim() || 'unknown-boot';
    if (startTicks) return `linux:${boot}:${startTicks}`;
  } catch {}

  const ps = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'lstart='], {
    encoding: 'utf8',
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL: 'C' },
  });
  const started = String(ps.stdout || '').trim();
  if (ps.status !== 0 || !started) return null;
  const sysctl = spawnSync('/usr/sbin/sysctl', ['-n', 'kern.boottime'], { encoding: 'utf8' });
  const boot = sysctl.status === 0 && String(sysctl.stdout || '').trim()
    ? String(sysctl.stdout).trim()
    : `${os.type()} ${os.release()}`;
  return `ps:${Buffer.from(`${boot}|${started}`).toString('hex')}`;
}

function readProcessLock(file) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const lines = raw.split('\n');
  if (!/^\d+$/.test(lines[0] || '')) return null;
  const fields = {};
  for (const line of lines.slice(1)) {
    const split = line.indexOf('=');
    if (split > 0) fields[line.slice(0, split)] = line.slice(split + 1);
  }
  return { pid: Number(lines[0]), fields };
}

function processLockOwnerAlive(file) {
  const lock = readProcessLock(file);
  if (!lock || !processAlive(lock.pid)) return false;
  if (lock.fields.version === '1') {
    return Boolean(lock.fields.identity) && processIdentity(lock.pid) === lock.fields.identity;
  }
  return true;
}

function sameInode(first, second) {
  try {
    const a = fs.statSync(first);
    const b = fs.statSync(second);
    return a.dev === b.dev && a.ino === b.ino;
  } catch { return false; }
}

function waitMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function acquireProcessLock(file, { timeoutMs = 5000, pollMs = 100 } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const identity = processIdentity(process.pid);
  if (!identity) throw new Error('could not determine current process identity');
  const token = `${process.pid}.${Date.now()}.${crypto.randomUUID()}`;
  const candidate = `${file}.candidate.${token}`;
  const snapshot = `${file}.snapshot.${token}`;
  fs.writeFileSync(candidate, `${process.pid}\nversion=1\nidentity=${identity}\ntoken=${token}\n`, {
    flag: 'wx',
    mode: 0o600,
  });
  const deadline = Date.now() + timeoutMs;
  try {
    for (;;) {
      try {
        fs.linkSync(candidate, file);
        fs.unlinkSync(candidate);
        return { file, pid: process.pid, identity, token };
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
      }

      try { fs.unlinkSync(snapshot); } catch {}
      try { fs.linkSync(file, snapshot); } catch (error) {
        if (error.code === 'ENOENT') continue;
        throw error;
      }
      const holder = readProcessLock(snapshot);
      if (processLockOwnerAlive(snapshot)) {
        try { fs.unlinkSync(snapshot); } catch {}
        if (Date.now() >= deadline) {
          const error = new Error(`lock is held by PID ${holder?.pid || 'unknown'}`);
          error.code = 'SPIN_LOCK_BUSY';
          throw error;
        }
        waitMs(pollMs);
        continue;
      }
      if (sameInode(file, snapshot)) {
        try { fs.unlinkSync(file); } catch {}
      }
      try { fs.unlinkSync(snapshot); } catch {}
    }
  } finally {
    try { fs.unlinkSync(candidate); } catch {}
    try { fs.unlinkSync(snapshot); } catch {}
  }
}

function releaseProcessLock(handle) {
  if (!handle || handle.pid !== process.pid || !handle.file || !handle.token) return false;
  const snapshot = `${handle.file}.release.${process.pid}.${crypto.randomUUID()}`;
  try {
    fs.linkSync(handle.file, snapshot);
    const lock = readProcessLock(snapshot);
    if (!lock || lock.pid !== process.pid || lock.fields.version !== '1' ||
        lock.fields.token !== handle.token || lock.fields.identity !== processIdentity(process.pid)) return false;
    if (!sameInode(handle.file, snapshot)) return false;
    fs.unlinkSync(handle.file);
    return true;
  } catch {
    return false;
  } finally {
    try { fs.unlinkSync(snapshot); } catch {}
  }
}

function runtimeRoot() {
  return process.env.SPIN_RUNTIME_ROOT ||
    process.env.SPIN_ROOT ||
    process.env.OMP_ROOT ||
    path.resolve(__dirname, '..', '..');
}

function envName(name) {
  return `SPIN_${String(name).replace(/-/g, '_').toUpperCase()}_BIN`;
}

function installedAppResources(root = runtimeRoot()) {
  const home = process.env.HOME || os.homedir();
  const installedRuntime = path.join(home, 'Library', 'Application Support', 'SPIN', 'runtime');
  if (path.resolve(root) !== path.resolve(installedRuntime)) return [];
  return [
    '/Applications/SPIN.app/Contents/Resources',
    path.join(home, 'Applications', 'SPIN.app', 'Contents', 'Resources'),
  ].filter((dir) => {
    try {
      return fs.statSync(dir).isDirectory();
    } catch {
      return false;
    }
  });
}

function candidateBinDirs(root = runtimeRoot()) {
  return [
    process.env.SPIN_APP_RESOURCES ? path.join(process.env.SPIN_APP_RESOURCES, 'bin') : '',
    process.env.SPIN_INTERNAL_BIN_DIR || '',
    ...installedAppResources(root).map((dir) => path.join(dir, 'bin')),
    path.join(root, 'vendor', 'bin'),
    path.join(root, 'agent', 'bin'),
    path.join(root, 'app', 'bin'),
  ].filter(Boolean);
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveBinary(name, root = runtimeRoot()) {
  const override = process.env[envName(name)];
  if (override && isExecutable(override)) return override;

  for (const dir of candidateBinDirs(root)) {
    const candidate = path.join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }

  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

function internalPath(root = runtimeRoot()) {
  return candidateBinDirs(root).filter((dir) => {
    try {
      return fs.statSync(dir).isDirectory();
    } catch {
      return false;
    }
  }).join(path.delimiter);
}

module.exports = {
  acquireProcessLock,
  candidateBinDirs,
  installedAppResources,
  internalPath,
  processIdentity,
  processLockOwnerAlive,
  readProcessLock,
  releaseProcessLock,
  resolveBinary,
  runtimeRoot,
};
