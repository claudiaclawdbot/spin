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
const path = require('path');

const root      = process.argv[2];
const runtime   = require(path.join(root, 'scripts', 'lib', 'spin-runtime.js'));
const harness   = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const queue     = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const now       = new Date().toISOString();
const jobsDir   = path.join(root, 'org', 'jobs');
const MAX_PAR   = parseInt(process.env.OMP_MAX_PARALLEL || '3', 10);
const validJobId = (id) => /^[A-Za-z0-9._:-]+$/.test(String(id || ''));

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

// ── helper: kill a job's whole process group (jobs spawn detached, so the
// bash PID is the group leader; -pid reaches the agent CLI grandchildren) ───
function killJobGroup(pid) {
  for (const sig of ['SIGTERM', 'SIGKILL']) {
    try { process.kill(-pid, sig); } catch { try { process.kill(pid, sig); } catch {} }
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && pidAlive(pid)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    if (!pidAlive(pid)) return true;
  }
  return !pidAlive(pid);
}

function finishJob(job, rc, detail) {
  const ok = Number(rc) === 0;
  job.status = ok ? 'completed' : 'failed';
  if (ok) job.completed_at = now;
  else job.failed_at = now;
  job.result = detail || (ok
    ? `Exited 0; log at org/jobs/${job.id}.log`
    : `Exited ${rc}; log at org/jobs/${job.id}.log`);
}

function readExitCode(job) {
  const rcFile = path.join(jobsDir, `${job.id}.exit`);
  if (!fs.existsSync(rcFile)) return null;
  const rc = parseInt(fs.readFileSync(rcFile, 'utf8').trim(), 10);
  return Number.isNaN(rc) ? null : rc;
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
    const pidFile = path.join(jobsDir, `${job.id}.pid`);

    if (!fs.existsSync(pidFile)) {
      const rc = readExitCode(job);
      if (rc === null) {
        // Legacy job or PID file was never written → preserve old behavior.
        finishJob(job, 0, job.result || 'PID file not found; inspect project receipts.');
      } else {
        finishJob(job, rc);
      }
      continue;
    }

    const pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10);
    if (!isNaN(pid) && pidAlive(pid)) {
      // Still running — enforce per-job timeout (job.max_runtime_seconds wins).
      const limit = parseInt(job.max_runtime_seconds || JOB_MAX_RUNTIME, 10);
      const started = Date.parse(job.started_at || now) || Date.parse(now);
      const ageSec = (Date.now() - started) / 1000;
      if (ageSec > limit) {
        const killed = killJobGroup(pid);
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
    finishJob(job, rc === null ? 0 : rc);
    try { fs.unlinkSync(pidFile); } catch {}
  }
}

// ── 2. Dispatch queued jobs ─────────────────────────────────────────────────
// Spawn each job as a detached background process. One job per project max.
// Honour MAX_PAR across all projects.
function dispatchQueuedJobs() {
  const dispatched = [];

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
          CEO_CODEX_MODEL: 'gpt-4.5-preview',
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

  for (const job of queue.jobs || []) {
    if (job.status !== 'queued') continue;
    if (!validJobId(job.id)) {
      job.status = 'blocked'; job.blocked_at = now;
      job.result = 'Invalid job id; only letters, numbers, dot, underscore, colon, and hyphen are allowed.';
      continue;
    }

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

    // ── Spawn ───────────────────────────────────────────────────────────────
    const logFile = path.join(jobsDir, `${job.id}.log`);
    const pidFile = path.join(jobsDir, `${job.id}.pid`);
    const rcFile = path.join(jobsDir, `${job.id}.exit`);

    let outFd, spawnedPid;
    try {
      try { fs.unlinkSync(rcFile); } catch {}
      outFd = fs.openSync(logFile, 'a');
      const childEnv = Object.assign(
        {},
        process.env,
        {
          OMP_JOB_ID: String(job.id),
          OMP_JOB_TYPE: String(job.type),
          OMP_JOB_DESCRIPTION: String(job.description || ''),
          OMP_PROJECT_ID: String(job.project_id),
          OMP_RC_FILE: rcFile,
          SPIN_PROJECT_AGENT: path.join(root, 'scripts', 'project-ceo-agent.sh'),
        },
        modelEnvFor(job.type),
        providerOverrideFor(job.type)
      );
      const wrapper = [
        'set -u',
        '"$SPIN_PROJECT_AGENT" "$OMP_PROJECT_ID"',
        'rc=$?',
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
      fs.writeFileSync(pidFile, String(spawnedPid));
    } catch (err) {
      if (outFd != null) try { fs.closeSync(outFd); } catch {}
      job.status = 'failed'; job.result = String(err); continue;
    }

    // ── Update job record ───────────────────────────────────────────────────
    job.status     = 'running';
    job.started_at = now;
    job.log        = `org/jobs/${job.id}.log`;

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
  }
  return dispatched;
}

// ── 3. Run ───────────────────────────────────────────────────────────────────
markRunningJobs();
const dispatched = dispatchQueuedJobs();
queue.updated_at = now;
fs.writeFileSync(process.argv[4], JSON.stringify(queue, null, 2) + '\n');

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
NODE
