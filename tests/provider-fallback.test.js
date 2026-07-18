'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-provider-fallback-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'home'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tmp'), { recursive: true });
  for (const name of ['ceo-waterfall.sh', 'spin-runtime.sh']) {
    fs.copyFileSync(path.join(repo, 'scripts', 'lib', name), path.join(root, 'scripts', 'lib', name));
  }
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function runBash(root, source, extraEnv = {}) {
  return spawnSync('/bin/bash', ['-c', source], {
    env: {
      ...process.env,
      CEO_ROOT: root,
      SPIN_ROOT: root,
      HOME: path.join(root, 'home'),
      TMPDIR: path.join(root, 'tmp'),
      ...extraEnv,
    },
    encoding: 'utf8',
    timeout: 15000,
  });
}

function processIsRunning(pid) {
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error.code === 'ESRCH') return false;
    throw error;
  }
  const status = spawnSync('/bin/ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' });
  if (status.status !== 0) return false;
  return !/^\s*Z/.test(status.stdout);
}

test('run_with_timeout reports the documented 124 status', t => {
  const root = fixture(t);
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    slow_provider() { sleep 5; }
    set +e
    run_with_timeout 1 slow_provider
    rc=$?
    set -e
    printf '%s\n' "$rc"
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '124');
});

test('run_with_timeout kills TERM-ignoring descendants created during teardown', t => {
  const root = fixture(t);
  const parentScript = path.join(root, 'stubborn-parent.js');
  const lateChildScript = path.join(root, 'late-child.js');
  const parentPidFile = path.join(root, 'stubborn-parent.pid');
  const latePidFile = path.join(root, 'late-child.pid');

  fs.writeFileSync(lateChildScript, [
    "'use strict';",
    "process.on('SIGTERM', () => {});",
    'setInterval(() => {}, 1000);',
    '',
  ].join('\n'));
  fs.writeFileSync(parentScript, [
    "'use strict';",
    "const fs = require('node:fs');",
    "const { spawn } = require('node:child_process');",
    'let lateChild = null;',
    "process.on('SIGTERM', () => {",
    '  if (lateChild) return;',
    '  lateChild = spawn(process.execPath, [process.env.LATE_CHILD_SCRIPT], {',
    '    env: process.env,',
    "    stdio: 'ignore',",
    '  });',
    "  fs.writeFileSync(process.env.LATE_PID_FILE, String(lateChild.pid) + '\\n');",
    '});',
    "fs.writeFileSync(process.env.PARENT_PID_FILE, String(process.pid) + '\\n');",
    'setInterval(() => {}, 1000);',
    '',
  ].join('\n'));

  let result;
  try {
    result = runBash(root, `
      source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
      stubborn_provider() { "$NODE_BIN" "$PARENT_SCRIPT"; }
      set +e
      run_with_timeout 1 stubborn_provider
      rc=$?
      set -e
      for ignored in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -s "$LATE_PID_FILE" ]] && break
        sleep 0.05
      done
      printf '%s\ncaller-survived\n' "$rc"
    `, {
      NODE_BIN: process.execPath,
      PARENT_SCRIPT: parentScript,
      PARENT_PID_FILE: parentPidFile,
      LATE_CHILD_SCRIPT: lateChildScript,
      LATE_PID_FILE: latePidFile,
    });

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stdout.trim().split('\n'), ['124', 'caller-survived']);
    assert.equal(fs.existsSync(parentPidFile), true, 'stubborn parent never recorded its PID');
    assert.equal(fs.existsSync(latePidFile), true, 'TERM handler never created the late descendant');
    const parentPid = Number(fs.readFileSync(parentPidFile, 'utf8').trim());
    const latePid = Number(fs.readFileSync(latePidFile, 'utf8').trim());
    assert.equal(processIsRunning(parentPid), false, `stubborn parent ${parentPid} survived timeout`);
    assert.equal(processIsRunning(latePid), false, `late descendant ${latePid} survived timeout`);
  } finally {
    for (const file of [parentPidFile, latePidFile]) {
      if (!fs.existsSync(file)) continue;
      const pid = Number(fs.readFileSync(file, 'utf8').trim());
      if (!Number.isInteger(pid) || pid <= 1) continue;
      try {
        process.kill(pid, 'SIGKILL');
      } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    }
  }
});

test('provider deadline is derived from the dispatched job budget', t => {
  const root = fixture(t);
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    agent_provider_timeout_seconds
  `, { OMP_JOB_MAX_RUNTIME_SECONDS: '900' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '260');
});

test('hard failure advances once and preserves each provider log', t => {
  const root = fixture(t);
  const sequence = path.join(root, 'sequence');
  const log = path.join(root, 'run.log');
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    probe_omp() { return 0; }
    probe_claude() { return 0; }
    probe_gemini() { return 1; }
    probe_ollama() { return 1; }
    run_agent() {
      printf '%s\n' "$1" >> "$SEQUENCE"
      printf 'output from %s\n' "$1" > "$3"
      [[ "$1" == omp ]] && return 127
      return 0
    }
    run_agent_resilient true '' prompt "$RUN_LOG"
  `, { SEQUENCE: sequence, RUN_LOG: log, CEO_PROVIDER_TIMEOUT_SECS: '5' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(sequence, 'utf8').trim().split('\n'), ['omp', 'claude']);
  const combined = fs.readFileSync(log, 'utf8');
  assert.match(combined, /provider: omp \(rc=127\)/);
  assert.match(combined, /output from omp/);
  assert.match(combined, /provider: claude \(rc=0\)/);
  assert.match(combined, /output from claude/);
});

test('OMP command-line usage failure advances before a session can run', t => {
  const root = fixture(t);
  const sequence = path.join(root, 'sequence');
  const log = path.join(root, 'run.log');
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    probe_omp() { return 0; }
    probe_claude() { return 0; }
    probe_gemini() { return 1; }
    probe_ollama() { return 1; }
    run_agent() {
      printf '%s\n' "$1" >> "$SEQUENCE"
      [[ "$1" == omp ]] && return 2
      return 0
    }
    run_agent_resilient true '' prompt "$RUN_LOG"
  `, { SEQUENCE: sequence, RUN_LOG: log, CEO_PROVIDER_TIMEOUT_SECS: '5' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(sequence, 'utf8').trim().split('\n'), ['omp', 'claude']);
});

test('ordinary task failure text cannot trigger a duplicate outer run', t => {
  const root = fixture(t);
  const sequence = path.join(root, 'sequence');
  const log = path.join(root, 'run.log');
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    probe_omp() { return 0; }
    probe_claude() { return 0; }
    probe_gemini() { return 1; }
    probe_ollama() { return 1; }
    run_agent() {
      printf '%s\n' "$1" >> "$SEQUENCE"
      printf '%s\n' \
        'task failed after partial work: No such file or directory' \
        'tool output: command not found' \
        'extension failed to start' \
        'project command reported unknown option' > "$3"
      return 42
    }
    set +e
    run_agent_resilient true '' prompt "$RUN_LOG"
    rc=$?
    set -e
    printf '%s\n' "$rc"
  `, { SEQUENCE: sequence, RUN_LOG: log, CEO_PROVIDER_TIMEOUT_SECS: '5' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '42');
  assert.equal(fs.readFileSync(sequence, 'utf8').trim(), 'omp');
});

test('real direct-provider task logs cannot create a lockout or authorize fallback', t => {
  const root = fixture(t);
  const bin = path.join(root, 'bin');
  const sequence = path.join(root, 'sequence');
  const log = path.join(root, 'run.log');
  fs.mkdirSync(bin, { recursive: true });
  const claude = path.join(bin, 'claude');
  const gemini = path.join(bin, 'gemini');
  fs.writeFileSync(claude, `#!/bin/bash
if [[ "\${1:-}" == "--version" ]]; then exit 0; fi
printf 'claude\\n' >> "$SEQUENCE"
printf 'task changed quota documentation and a 403 example before failing\\n'
exit 42
`);
  fs.writeFileSync(gemini, `#!/bin/bash
if [[ "\${1:-}" == "--version" ]]; then exit 0; fi
printf 'gemini\\n' >> "$SEQUENCE"
printf 'unexpected duplicate provider run\\n'
exit 0
`);
  fs.chmodSync(claude, 0o755);
  fs.chmodSync(gemini, 0o755);

  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    probe_omp() { return 1; }
    probe_ollama() { return 1; }
    set +e
    run_agent_resilient true claude prompt "$RUN_LOG"
    rc=$?
    set -e
    printf '%s\n' "$rc"
  `, {
    PATH: `${bin}:${process.env.PATH}`,
    SEQUENCE: sequence,
    RUN_LOG: log,
    CEO_PROVIDER_TIMEOUT_SECS: '5',
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '42');
  assert.equal(fs.readFileSync(sequence, 'utf8').trim(), 'claude');
  assert.equal(fs.existsSync(path.join(root, 'org', 'ceo', 'runs', '.claude-blocked-until')), false);
  assert.match(fs.readFileSync(log, 'utf8'), /quota documentation and a 403 example/);
});

test('a hung OMP attempt times out before the direct fallback runs', t => {
  const root = fixture(t);
  const sequence = path.join(root, 'sequence');
  const log = path.join(root, 'run.log');
  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    probe_omp() { return 0; }
    probe_claude() { return 0; }
    probe_gemini() { return 1; }
    probe_ollama() { return 1; }
    run_agent() {
      printf '%s\n' "$1" >> "$SEQUENCE"
      if [[ "$1" == omp ]]; then sleep 5; fi
      printf 'output from %s\n' "$1" > "$3"
      return 0
    }
    run_agent_resilient true '' prompt "$RUN_LOG"
  `, { SEQUENCE: sequence, RUN_LOG: log, CEO_PROVIDER_TIMEOUT_SECS: '1' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readFileSync(sequence, 'utf8').trim().split('\n'), ['omp', 'claude']);
  assert.match(result.stderr, /omp timed out after 1s/);
});
