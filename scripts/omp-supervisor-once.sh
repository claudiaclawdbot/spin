#!/usr/bin/env bash
# omp-supervisor-once.sh — one tick of the OMP job dispatcher (v2).
#
# WHAT CHANGED FROM v1:
#   - Removed cmux send / ps-grep dispatch. Jobs now run as detached background
#     processes with PID files. cmux is display-only (status chips + live log tail).
#   - Parallel execution: up to OMP_MAX_PARALLEL jobs across all projects (default 3).
#     Still enforces one-active-job-per-project.
#   - Model tiering: read-only-worker → OMP smol/fast; implementation-worker → OMP default.
#   - Per-job log at org/jobs/<job-id>.log; completion detected by PID liveness.
#
# Called by workspace-ceo-tick.sh every tick.

set -uo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
HARNESS="$ROOT/org/OMP_HARNESS.json"
QUEUE="$ROOT/org/AGENT_QUEUE.json"

if [[ ! -f "$HARNESS" ]]; then
  echo "Missing harness registry: $HARNESS" >&2; exit 1
fi

if [[ ! -f "$QUEUE" ]]; then
  printf '{\n  "version": 1,\n  "updated_at": "",\n  "jobs": []\n}\n' > "$QUEUE"
fi

mkdir -p "$ROOT/org/jobs"

node - "$ROOT" "$HARNESS" "$QUEUE" <<'NODE'
const fs   = require('fs');
const cp   = require('child_process');
const os   = require('os');
const path = require('path');

const root      = process.argv[2];
const queueFile = process.argv[4];
const runtime   = require(path.join(root, 'scripts', 'lib', 'spin-runtime.js'));
const harness   = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const now       = new Date().toISOString();
const jobsDir   = path.join(root, 'org', 'jobs');
const MAX_PAR   = parsePositiveInt(process.env.OMP_MAX_PARALLEL, 3);
const DEFAULT_JOB_MAX_RSS_MB = parsePositiveInt(process.env.OMP_JOB_MAX_RSS_MB, 3072);
const DEFAULT_JOB_MAX_PROCESSES = parsePositiveInt(process.env.OMP_JOB_MAX_PROCESSES, 16);
const HEAVY_JOB_MAX_RSS_MB = parsePositiveInt(process.env.OMP_HEAVY_JOB_MAX_RSS_MB, 6144);
const HEAVY_JOB_MAX_PROCESSES = parsePositiveInt(process.env.OMP_HEAVY_JOB_MAX_PROCESSES, 32);
const DISPATCH_MEMORY_RESERVE_MB = parsePositiveInt(process.env.OMP_DISPATCH_MEMORY_RESERVE_MB, 2048);
const DISPATCH_PLANNING_RSS_MB = parsePositiveInt(process.env.OMP_DISPATCH_PLANNING_RSS_MB, 2048);
const RESOURCE_CHECK_INTERVAL = parsePositiveInt(process.env.OMP_RESOURCE_CHECK_INTERVAL, 5);
const validJobId = (id) => /^[A-Za-z0-9._:-]+$/.test(String(id || ''));
const queueLock = path.join(root, 'org', 'ceo', 'runs', '.org-queue.lock');
let queueLockHeld = false;
let queueLockHandle = null;

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeResourceClass(job) {
  return String(job.resource_class || '').trim().toLowerCase() === 'heavy' ? 'heavy' : 'normal';
}

function jobIsHeavy(job) {
  return normalizeResourceClass(job) === 'heavy';
}

function availableMemoryMb() {
  if (process.env.OMP_AVAILABLE_MEMORY_MB) {
    return parsePositiveInt(process.env.OMP_AVAILABLE_MEMORY_MB, 0);
  }
  if (process.platform === 'darwin' && fs.existsSync('/usr/bin/memory_pressure')) {
    try {
      const output = cp.execFileSync('/usr/bin/memory_pressure', ['-Q'], { encoding: 'utf8', timeout: 2000 });
      const match = output.match(/memory free percentage:\s*(\d+)%/i);
      if (match) return Math.floor((os.totalmem() / 1024 / 1024) * Number(match[1]) / 100);
    } catch {}
  }
  if (process.platform === 'linux') {
    try {
      const match = fs.readFileSync('/proc/meminfo', 'utf8').match(/^MemAvailable:\s*(\d+)\s*kB/im);
      if (match) return Math.floor(Number(match[1]) / 1024);
    } catch {}
  }
  return Math.floor(os.freemem() / 1024 / 1024);
}

function adaptiveDispatchBudget(runningCount) {
  const capacity = Math.max(0, MAX_PAR - runningCount);
  const available = availableMemoryMb();
  if (process.env.OMP_ADAPTIVE_PARALLELISM === '0') return { available, budget: capacity };
  const headroom = available - DISPATCH_MEMORY_RESERVE_MB;
  let memorySlots = Math.max(0, Math.floor(headroom / DISPATCH_PLANNING_RSS_MB));
  if (memorySlots === 0 && headroom >= 1536) memorySlots = 1;
  return { available, budget: Math.min(capacity, memorySlots) };
}

function acquireQueueLock() {
  queueLockHandle = runtime.acquireProcessLock(queueLock);
  queueLockHeld = true;
}

function releaseQueueLock() {
  if (!queueLockHeld) return;
  runtime.releaseProcessLock(queueLockHandle);
  queueLockHandle = null;
  queueLockHeld = false;
}

acquireQueueLock();
process.on('exit', releaseQueueLock);
const queue = JSON.parse(fs.readFileSync(queueFile, 'utf8'));

function persistQueue() {
  queue.updated_at = now;
  const tmp = `${queueFile}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(queue, null, 2) + '\n');
  fs.renameSync(tmp, queueFile);
}

// ── helper: send a cmux command silently ────────────────────────────────────
function cmux(args) {
  const bin = runtime.resolveBinary('cmux', root);
  if (!bin) return false;
  try { cp.execFileSync(bin, args, { cwd: root, stdio: 'ignore' }); return true; }
  catch { return false; }
}

// ── helper: is a PID still alive? ───────────────────────────────────────────
function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function jobProcessIdentity(job) {
  if (job.process_identity === undefined) return null;
  const identity = String(job.process_identity || '').trim();
  return identity || null;
}

function jobProcessAlive(job, pid) {
  const expectedIdentity = jobProcessIdentity(job);
  if (job.process_identity !== undefined) {
    return Boolean(expectedIdentity) && runtime.processIdentity(pid) === expectedIdentity;
  }
  // Jobs already running when process identities were introduced retain their
  // legacy PID-only behavior. Every newly dispatched job records an identity.
  return pidAlive(pid);
}

// ── helper: kill a job's whole process group (jobs spawn detached, so the
// bash PID is the group leader; -pid reaches the agent CLI grandchildren) ───
function killJobGroup(pid, expectedIdentity = null) {
  const originalOwnerAlive = () => expectedIdentity
    ? runtime.processIdentity(pid) === expectedIdentity
    : pidAlive(pid);
  if (!originalOwnerAlive()) return true;
  for (const sig of ['SIGTERM', 'SIGKILL']) {
    // Never signal a recycled PID or process group after the recorded owner has
    // exited. The identity check is repeated immediately before each signal.
    if (!originalOwnerAlive()) return true;
    try { process.kill(-pid, sig); } catch { try { process.kill(pid, sig); } catch {} }
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && originalOwnerAlive()) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    if (!originalOwnerAlive()) return true;
  }
  return !originalOwnerAlive();
}

function readTerminalOutcome(job) {
  // Jobs dispatched after this contract was introduced carry an explicit
  // semantic outcome. Older queue records retain their exit-code behavior.
  if (job.terminal_outcome === undefined) return { kind: 'legacy' };

  const expected = `org/jobs/${job.id}.outcome.json`;
  if (job.terminal_outcome !== expected) {
    return { kind: 'invalid', detail: `outcome metadata path must be ${expected}` };
  }

  const file = path.join(root, expected);
  if (!fs.existsSync(file)) return { kind: 'missing', detail: 'outcome metadata is missing' };

  let metadata;
  try {
    metadata = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return { kind: 'malformed', detail: 'outcome metadata is malformed JSON' };
  }
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata) ||
      metadata.version !== 1 || metadata.job_id !== String(job.id) ||
      !['completed', 'blocked', 'failed'].includes(metadata.outcome) ||
      typeof metadata.detail !== 'string' || !metadata.detail.trim()) {
    return { kind: 'malformed', detail: 'outcome metadata is malformed' };
  }
  return { kind: metadata.outcome, detail: metadata.detail.trim() };
}

function finishJob(job, rc, detail) {
  if (Number(rc) !== 0) {
    job.status = 'failed';
    job.failed_at = now;
    job.result = detail || `Exited ${rc}; log at org/jobs/${job.id}.log`;
    return;
  }

  const terminal = readTerminalOutcome(job);
  if (terminal.kind === 'legacy' || terminal.kind === 'completed') {
    job.status = 'completed';
    job.completed_at = now;
    job.result = terminal.kind === 'completed'
      ? terminal.detail
      : (detail || `Exited 0; log at org/jobs/${job.id}.log`);
    return;
  }
  if (terminal.kind === 'blocked') {
    job.status = 'blocked';
    job.blocked_at = now;
    job.result = terminal.detail;
    return;
  }

  job.status = 'failed';
  job.failed_at = now;
  job.result = `${terminal.detail}; refusing to treat exit 0 as success. Log: org/jobs/${job.id}.log`;
}

function readExitCode(job) {
  const rcFile = path.join(jobsDir, `${job.id}.exit`);
  if (!fs.existsSync(rcFile)) return null;
  const rc = parseInt(fs.readFileSync(rcFile, 'utf8').trim(), 10);
  return Number.isNaN(rc) ? null : rc;
}

function readResourceViolation(job) {
  const file = path.join(jobsDir, `${job.id}.resource`);
  if (!fs.existsSync(file)) return null;
  const detail = fs.readFileSync(file, 'utf8').trim();
  return detail || 'Resource limit exceeded; inspect the job log.';
}

function readHeartbeat(job) {
  const relative = job.heartbeat || `org/jobs/${job.id}.heartbeat`;
  const file = path.join(root, relative);
  if (!fs.existsSync(file)) return null;
  const value = fs.readFileSync(file, 'utf8').trim();
  return Number.isNaN(Date.parse(value)) ? null : value;
}

// ── 1. Mark completed jobs ──────────────────────────────────────────────────
// A "running" job is done when its PID file exists but the process is gone,
// or when there is no PID file at all (legacy / lost). A job that exceeds its
// max runtime is killed (whole process group) and marked failed — a hung agent
// must never hold its project lane forever.
const JOB_MAX_RUNTIME = parseInt(process.env.OMP_JOB_MAX_RUNTIME || '3600', 10); // seconds
function markRunningJobs() {
  for (const job of queue.jobs || []) {
    if (job.status !== 'running') continue;
    if (!validJobId(job.id)) {
      job.status = 'failed';
      job.failed_at = now;
      job.result = 'Invalid job id; only letters, numbers, dot, underscore, colon, and hyphen are allowed.';
      continue;
    }
    const heartbeat = readHeartbeat(job);
    if (heartbeat) job.heartbeat_at = heartbeat;
    const pidFile = path.join(jobsDir, `${job.id}.pid`);

    if (!fs.existsSync(pidFile)) {
      const rc = readExitCode(job);
      if (rc === null) {
        // Legacy job or PID file was never written → preserve old behavior.
        finishJob(job, 0, job.result || 'PID file not found; inspect project receipts.');
      } else {
        finishJob(job, rc, readResourceViolation(job));
      }
      continue;
    }

    const pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10);
    if (!isNaN(pid) && jobProcessAlive(job, pid)) {
      // Still running — enforce per-job timeout (job.max_runtime_seconds wins).
      const limit = parseInt(job.max_runtime_seconds || JOB_MAX_RUNTIME, 10);
      const started = Date.parse(job.started_at || now) || Date.parse(now);
      const ageSec = (Date.now() - started) / 1000;
      if (ageSec > limit) {
        const killed = killJobGroup(pid, jobProcessIdentity(job));
        job.status     = 'failed';
        job.failed_at  = now;
        job.result     = `Timed out after ${Math.round(ageSec)}s (limit ${limit}s); ` +
                         (killed ? 'process group killed.' : 'KILL FAILED — check manually.') +
                         ` Log: org/jobs/${job.id}.log`;
        console.log(`  TIMEOUT ${job.id} (${Math.round(ageSec)}s > ${limit}s) — ${killed ? 'killed' : 'kill failed'}`);
        try { fs.unlinkSync(pidFile); } catch {}
      }
      continue;
    }

    // Process dead → done; trust the wrapper's recorded exit code when present.
    const rc = readExitCode(job);
    finishJob(job, rc === null ? 0 : rc, readResourceViolation(job));
    try { fs.unlinkSync(pidFile); } catch {}
  }
}

// ── 2. Dispatch queued jobs ─────────────────────────────────────────────────
// Spawn each job as a detached background process. One job per project max.
// Honour MAX_PAR across all projects.
function dispatchQueuedJobs() {
  const dispatched = [];

  function dependenciesReady(job) {
    if (job.depends_on === undefined) return true;
    if (!Array.isArray(job.depends_on) || !job.depends_on.length) {
      job.status = 'blocked';
      job.blocked_at = now;
      job.result = 'Invalid depends_on value; expected a non-empty array of job IDs.';
      return false;
    }

    const dependencies = [...new Set(job.depends_on)];
    if (dependencies.length !== job.depends_on.length || dependencies.some(id => !validJobId(id) || id === job.id)) {
      job.status = 'blocked';
      job.blocked_at = now;
      job.result = 'Invalid depends_on value; dependencies must be unique valid job IDs and cannot reference the job itself.';
      return false;
    }

    for (const id of dependencies) {
      const dependency = (queue.jobs || []).find(candidate => candidate.id === id);
      if (!dependency) {
        job.status = 'blocked';
        job.blocked_at = now;
        job.result = `Dependency job not found: ${id}. Update dependencies and requeue.`;
        return false;
      }
      if (dependency.status === 'completed') continue;
      if (dependency.status === 'failed' || dependency.status === 'blocked') {
        job.status = 'blocked';
        job.blocked_at = now;
        job.result = `Dependency ${id} is ${dependency.status}. Update dependencies and requeue after recovery.`;
        return false;
      }
      if (dependency.status !== 'queued' && dependency.status !== 'running') {
        job.status = 'blocked';
        job.blocked_at = now;
        job.result = `Dependency ${id} has unsupported status ${dependency.status || '(missing)'}.`;
        return false;
      }
      return false;
    }
    return true;
  }

  // Model selection by job type. OMP is the primary harness, so we set its role
  // overlay vars. Direct-CLI model vars remain as the outer fallback path if OMP
  // is absent or hard-fails.
  function modelEnvFor(jobType) {
    switch (jobType) {
      case 'read-only-worker':
      case 'scout':
        return {
          SPIN_OMP_DEFAULT_MODEL: process.env.SPIN_OMP_SCOUT_MODEL || process.env.SPIN_OMP_SMOL_MODEL || 'anthropic/claude-haiku-4-5',
          SPIN_OMP_DEFAULT_FALLBACKS: process.env.SPIN_OMP_SCOUT_FALLBACKS || process.env.SPIN_OMP_SMOL_FALLBACKS || 'openai-codex/gpt-5.1-codex-mini openrouter/~anthropic/claude-haiku-latest openai/gpt-5-mini',
          CEO_CODEX_MODEL: process.env.CEO_CODEX_MODEL || '',
          CEO_CODEX_REASONING: 'low',
        };
      default:
        return {
          SPIN_OMP_DEFAULT_MODEL: process.env.SPIN_OMP_DEFAULT_MODEL || 'anthropic/claude-sonnet-4-6',
          SPIN_OMP_DEFAULT_FALLBACKS: process.env.SPIN_OMP_DEFAULT_FALLBACKS || `openai-codex/gpt-5-codex ${process.env.CEO_OMP_MODEL || 'openrouter/anthropic/claude-sonnet-4.6'} openai/gpt-5 cursor/claude-4.6-sonnet-medium`,
          CEO_CLAUDE_MODEL: 'claude-sonnet-4-6',
        };
    }
  }

  // Provider override: all queued jobs start in OMP. OMP owns provider/model
  // fallback through retry.fallbackChains; direct CLIs are only the outer safety net.
  function providerOverrideFor(jobType) {
    return { PROJECT_CEO_PROVIDER: 'omp' };
  }

  const runningAtStart = (queue.jobs || []).filter(job => job.status === 'running');
  const adaptive = adaptiveDispatchBudget(runningAtStart.length);
  queue.dispatch_state = {
    updated_at: now,
    status: 'ready',
    note: 'dispatch capacity available',
    max_parallel: MAX_PAR,
    available_memory_mb: adaptive.available,
    reserve_memory_mb: DISPATCH_MEMORY_RESERVE_MB,
    dispatch_slots: adaptive.budget,
  };
  if (runningAtStart.some(jobIsHeavy)) {
    queue.dispatch_state.status = 'heavy-lease';
    queue.dispatch_state.note = 'an exclusive heavy job is running';
    queue.dispatch_state.dispatch_slots = 0;
    console.log('  heavy-job lease active; no other jobs will start');
    return dispatched;
  }
  const queuedJobs = (queue.jobs || []).filter(job => job.status === 'queued');
  if (queuedJobs.length === 0) {
    queue.dispatch_state.status = runningAtStart.length ? 'running' : 'idle';
    queue.dispatch_state.note = runningAtStart.length ? 'no queued jobs waiting' : 'no work waiting';
    queue.dispatch_state.dispatch_slots = 0;
    return dispatched;
  }
  const dispatchBudget = adaptive.budget;
  if (dispatchBudget < 1) {
    queue.dispatch_state.status = 'memory-pressure';
    queue.dispatch_state.note = `${adaptive.available}MB available; preserving ${DISPATCH_MEMORY_RESERVE_MB}MB reserve`;
    console.log(`  adaptive dispatch paused: ${adaptive.available}MB available, ${DISPATCH_MEMORY_RESERVE_MB}MB reserve`);
    return dispatched;
  }
  const dependencyComplete = job => job.depends_on === undefined || (
    Array.isArray(job.depends_on) && job.depends_on.length > 0 &&
    job.depends_on.every(id => (queue.jobs || []).find(candidate => candidate.id === id)?.status === 'completed')
  );
  const readyHeavy = queuedJobs.find(job => jobIsHeavy(job) && dependencyComplete(job));
  if (readyHeavy && runningAtStart.length > 0) {
    queue.dispatch_state.status = 'draining-for-heavy';
    queue.dispatch_state.note = `waiting for ${runningAtStart.length} running job(s) before the heavy lease`;
    queue.dispatch_state.dispatch_slots = 0;
    console.log(`  heavy-job lease waiting for ${runningAtStart.length} running job(s) to drain`);
    return dispatched;
  }
  const candidates = readyHeavy
    ? [readyHeavy]
    : [...queuedJobs].sort((a, b) => Number(jobIsHeavy(b)) - Number(jobIsHeavy(a)));

  for (const job of candidates) {
    if (dispatched.length >= dispatchBudget) break;
    if (!validJobId(job.id)) {
      job.status = 'blocked'; job.blocked_at = now;
      job.result = 'Invalid job id; only letters, numbers, dot, underscore, colon, and hyphen are allowed.';
      continue;
    }
    if (!dependenciesReady(job)) continue;

    const project = harness.projects?.[job.project_id];
    if (!project) {
      job.status = 'blocked'; job.blocked_at = now;
      job.result = `Unknown project_id: ${job.project_id}`; continue;
    }
    if (!project.allowed_job_types?.includes(job.type)) {
      job.status = 'blocked'; job.blocked_at = now;
      job.result = `Job type not in allowed_job_types: ${job.type}`; continue;
    }

    // One-job-per-project guard
    const projectBusy = (queue.jobs || []).some(
      j => j.status === 'running' && j.project_id === job.project_id
    );
    if (projectBusy) continue;

    // Global parallelism cap
    const totalRunning = (queue.jobs || []).filter(j => j.status === 'running').length;
    if (totalRunning >= MAX_PAR) break;
    if (jobIsHeavy(job) && totalRunning > 0) continue;

    // ── Spawn ───────────────────────────────────────────────────────────────
    const logFile = path.join(jobsDir, `${job.id}.log`);
    const pidFile = path.join(jobsDir, `${job.id}.pid`);
    const rcFile = path.join(jobsDir, `${job.id}.exit`);
    const heartbeatFile = path.join(jobsDir, `${job.id}.heartbeat`);
    const resourceFile = path.join(jobsDir, `${job.id}.resource`);
    const resourceUsageFile = path.join(jobsDir, `${job.id}.usage.json`);
    const terminalOutcomeFile = path.join(jobsDir, `${job.id}.outcome.json`);
    const resourceClass = normalizeResourceClass(job);
    const maxRssMb = parsePositiveInt(job.max_rss_mb, jobIsHeavy(job) ? HEAVY_JOB_MAX_RSS_MB : DEFAULT_JOB_MAX_RSS_MB);
    const maxProcesses = parsePositiveInt(job.max_processes, jobIsHeavy(job) ? HEAVY_JOB_MAX_PROCESSES : DEFAULT_JOB_MAX_PROCESSES);
    const maxRuntimeSeconds = parsePositiveInt(job.max_runtime_seconds, parsePositiveInt(process.env.OMP_JOB_MAX_RUNTIME, 3600));

    let outFd, spawnedPid, spawnedIdentity, pidTmp;
    try {
      try { fs.unlinkSync(rcFile); } catch {}
      try { fs.unlinkSync(heartbeatFile); } catch {}
      try { fs.unlinkSync(resourceFile); } catch {}
      try { fs.unlinkSync(resourceUsageFile); } catch {}
      try { fs.unlinkSync(terminalOutcomeFile); } catch {}
      outFd = fs.openSync(logFile, 'a');
      const childEnv = Object.assign(
        {},
        process.env,
        {
          OMP_JOB_ID: String(job.id),
          OMP_JOB_TYPE: String(job.type),
          OMP_JOB_DESCRIPTION: String(job.description || ''),
          OMP_RESOURCE_CLASS: resourceClass,
          OMP_PROJECT_ID: String(job.project_id),
          OMP_RC_FILE: rcFile,
          OMP_OUTCOME_FILE: terminalOutcomeFile,
          OMP_HEARTBEAT_FILE: heartbeatFile,
          OMP_HEARTBEAT_INTERVAL: process.env.OMP_HEARTBEAT_INTERVAL || '30',
          OMP_RESOURCE_FILE: resourceFile,
          OMP_RESOURCE_USAGE_FILE: resourceUsageFile,
          OMP_RESOURCE_CHECK_INTERVAL: String(RESOURCE_CHECK_INTERVAL),
          OMP_JOB_MAX_RSS_MB: String(maxRssMb),
          OMP_JOB_MAX_PROCESSES: String(maxProcesses),
          OMP_JOB_MAX_RUNTIME_SECONDS: String(maxRuntimeSeconds),
          SPIN_PROJECT_AGENT: path.join(root, 'scripts', 'project-ceo-agent.sh'),
        },
        modelEnvFor(job.type),
        providerOverrideFor(job.type)
      );
      const wrapper = [
        'set -u',
        'heartbeat_once() {',
        '  heartbeat_tmp="${OMP_HEARTBEAT_FILE}.tmp.$$"',
        '  date -u "+%Y-%m-%dT%H:%M:%SZ" > "$heartbeat_tmp"',
        '  mv "$heartbeat_tmp" "$OMP_HEARTBEAT_FILE"',
        '}',
        'resource_monitor() {',
        '  max_rss_kb=$((OMP_JOB_MAX_RSS_MB * 1024))',
        '  while kill -0 "$agent_pid" 2>/dev/null; do',
        '    sleep "$OMP_RESOURCE_CHECK_INTERVAL"',
        '    kill -0 "$agent_pid" 2>/dev/null || break',
        "    stats=\"$(ps -axo pgid=,rss= 2>/dev/null | awk -v group=\"$$\" '$1 == group { rss += $2; count += 1 } END { print rss + 0, count + 0 }')\"",
        '    read -r rss_kb process_count <<< "$stats"',
        '    usage_tmp="${OMP_RESOURCE_USAGE_FILE}.tmp.$$"',
        '    printf \'{"observed_at":"%s","rss_mb":%s,"processes":%s}\\n\' "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" "$((rss_kb / 1024))" "$process_count" > "$usage_tmp"',
        '    mv "$usage_tmp" "$OMP_RESOURCE_USAGE_FILE"',
        '    reason=""',
        '    if (( rss_kb > max_rss_kb )); then',
        '      reason="RSS $((rss_kb / 1024))MB exceeded ${OMP_JOB_MAX_RSS_MB}MB"',
        '    fi',
        '    if (( process_count > OMP_JOB_MAX_PROCESSES )); then',
        '      reason="${reason:+$reason; }process count $process_count exceeded $OMP_JOB_MAX_PROCESSES"',
        '    fi',
        '    if [[ -n "$reason" ]]; then',
        '      detail="Resource limit exceeded: $reason. Process group killed; lower test workers or raise the explicit job limit."',
        '      resource_tmp="${OMP_RESOURCE_FILE}.tmp.$$"',
        '      rc_tmp="${OMP_RC_FILE}.tmp.$$"',
        '      printf "%s\\n" "$detail" > "$resource_tmp"',
        '      mv "$resource_tmp" "$OMP_RESOURCE_FILE"',
        '      printf "137\\n" > "$rc_tmp"',
        '      mv "$rc_tmp" "$OMP_RC_FILE"',
        '      printf "[resource] %s\\n" "$detail" >&2',
        '      kill -KILL -- "-$$" 2>/dev/null || kill -KILL "$agent_pid" 2>/dev/null || true',
        '      exit 137',
        '    fi',
        '  done',
        '}',
        '"$SPIN_PROJECT_AGENT" "$OMP_PROJECT_ID" &',
        'agent_pid=$!',
        'heartbeat_once',
        '(',
        '  while kill -0 "$agent_pid" 2>/dev/null; do',
        '    sleep "$OMP_HEARTBEAT_INTERVAL"',
        '    kill -0 "$agent_pid" 2>/dev/null || break',
        '    heartbeat_once',
        '  done',
        ') &',
        'heartbeat_pid=$!',
        'resource_monitor &',
        'resource_pid=$!',
        'wait "$agent_pid"',
        'rc=$?',
        'kill "$heartbeat_pid" "$resource_pid" 2>/dev/null || true',
        'wait "$heartbeat_pid" 2>/dev/null || true',
        'wait "$resource_pid" 2>/dev/null || true',
        'heartbeat_once',
        'printf "%s\\n" "$rc" > "$OMP_RC_FILE"',
        'exit "$rc"',
      ].join('\n');
      const child = cp.spawn('bash', ['-c', wrapper], {
        cwd: root,
        detached: true,
        stdio: ['ignore', outFd, outFd],
        env: childEnv,
      });
      child.unref();
      fs.closeSync(outFd); outFd = null;
      spawnedPid = child.pid;
      if (!spawnedPid) throw new Error('spawn returned no pid');
      spawnedIdentity = runtime.processIdentity(spawnedPid);
      if (!spawnedIdentity) throw new Error('could not determine spawned process identity');
      pidTmp = `${pidFile}.tmp.${process.pid}`;
      fs.writeFileSync(pidTmp, String(spawnedPid));
      fs.renameSync(pidTmp, pidFile);
      pidTmp = null;
    } catch (err) {
      if (outFd != null) try { fs.closeSync(outFd); } catch {}
      if (spawnedPid) {
        const identityToStop = spawnedIdentity || runtime.processIdentity(spawnedPid);
        if (identityToStop && runtime.processIdentity(spawnedPid) === identityToStop) {
          try { process.kill(-spawnedPid, 'SIGTERM'); } catch { try { process.kill(spawnedPid, 'SIGTERM'); } catch {} }
        }
      }
      if (pidTmp) try { fs.unlinkSync(pidTmp); } catch {}
      try { fs.unlinkSync(pidFile); } catch {}
      job.status = 'failed'; job.result = String(err); continue;
    }

    // ── Update job record ───────────────────────────────────────────────────
    job.status     = 'running';
    job.started_at = now;
    job.process_identity = spawnedIdentity;
    job.terminal_outcome = `org/jobs/${job.id}.outcome.json`;
    job.log        = `org/jobs/${job.id}.log`;
    job.heartbeat  = `org/jobs/${job.id}.heartbeat`;
    job.resource_usage = `org/jobs/${job.id}.usage.json`;
    job.resource_class = resourceClass;
    job.max_runtime_seconds = maxRuntimeSeconds;
    job.resource_limits = { max_rss_mb: maxRssMb, max_processes: maxProcesses };
    // Persist before any display work so a crash cannot leave a live detached
    // process represented as queued and eligible for duplicate dispatch.
    persistQueue();

    // ── cmux display: update the status CHIP only (non-blocking). ──────────
    // We deliberately do NOT push `tail -f` into the pane: tail -f blocks, so a
    // second dispatch to the same project would freeze the pane. Instead the pane
    // is expected to run `project-floor-watch.sh <project>`, a self-refreshing
    // loop that auto-finds the latest job log. The chip just signals "job started".
    if (project.cmux_workspace) {
      cmux(['set-status', 'last-dispatch', job.id,
            '--workspace', project.cmux_workspace,
            '--icon', 'send', '--color', '#22c55e', '--priority', '75']);
    }

    dispatched.push(job.id);
    console.log(`  dispatched ${job.id} (${job.type}) for ${job.project_id}  →  pid=${spawnedPid}`);
    if (jobIsHeavy(job)) {
      queue.dispatch_state.status = 'heavy-lease';
      queue.dispatch_state.note = `exclusive heavy job ${job.id} started`;
      queue.dispatch_state.dispatch_slots = 0;
      break;
    }
  }
  return dispatched;
}

// ── 3. Run ───────────────────────────────────────────────────────────────────
markRunningJobs();
const dispatched = dispatchQueuedJobs();
persistQueue();
releaseQueueLock();

// ── 4. Status chips (workspace CEO floor) ───────────────────────────────────
const ceoCfg = harness.workspace_ceo || {};
if (ceoCfg.cmux_workspace) {
  const queued  = (queue.jobs || []).filter(j => j.status === 'queued').length;
  const running = (queue.jobs || []).filter(j => j.status === 'running').length;
  cmux(['set-status', 'ceo',
        `OMP active | ${dispatched.length} dispatched`,
        '--workspace', ceoCfg.cmux_workspace, '--icon', 'network',
        '--color', '#22c55e', '--priority', '90']);
  cmux(['set-status', 'queue',
        `${queued} queued / ${running} running`,
        '--workspace', ceoCfg.cmux_workspace, '--icon', 'list-checks',
        '--color', '#0E6B8C', '--priority', '70']);
}

// ── 5. Summary ───────────────────────────────────────────────────────────────
console.log(`OMP supervisor tick: ${now}`);
console.log(`Dispatched: ${dispatched.length ? dispatched.join(', ') : 'none'}`);
console.log(`Queued:     ${(queue.jobs || []).filter(j => j.status === 'queued').length}`);
console.log(`Running:    ${(queue.jobs || []).filter(j => j.status === 'running').length}`);
console.log(`Completed:  ${(queue.jobs || []).filter(j => j.status === 'completed').length}`);
console.log(`Blocked:    ${(queue.jobs || []).filter(j => j.status === 'blocked').length}`);
NODE
