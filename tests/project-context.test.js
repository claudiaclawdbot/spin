'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-project-context-'));
  for (const dir of [
    'scripts/lib',
    'org/ceo/runs',
    'org/action-broker',
    'org/jobs',
    'org/projects/app',
    'projects/app',
    'home',
    'bin',
  ]) fs.mkdirSync(path.join(root, dir), { recursive: true });
  for (const name of ['project-root.sh', 'spin-runtime.sh', 'ceo-waterfall.sh']) {
    fs.copyFileSync(path.join(repo, 'scripts', 'lib', name), path.join(root, 'scripts', 'lib', name));
  }
  writeJSON(path.join(root, 'org', 'OMP_HARNESS.json'), {
    projects: { app: { code_path: 'projects/app' } },
  });
  writeJSON(path.join(root, 'org', 'state.json'), {
    project_orchestrators: [{ id: 'app', code_path: 'wrong-state-path' }],
  });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function runBash(root, source, extraEnv = {}) {
  return spawnSync('/bin/bash', ['-c', source], {
    env: {
      ...process.env,
      ROOT: root,
      CEO_ROOT: root,
      SPIN_ROOT: root,
      HOME: path.join(root, 'home'),
      PATH: `${path.join(root, 'bin')}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
      ...extraEnv,
    },
    encoding: 'utf8',
    timeout: 10000,
  });
}

test('project roots resolve from the registry and preserve the workspace lane', t => {
  const root = fixture(t);
  const result = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    spin_project_root app
    printf '\n'
    spin_project_root workspace
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'), [
    fs.realpathSync(path.join(root, 'projects', 'app')),
    fs.realpathSync(root),
  ]);

  const invalid = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    spin_project_root '../other'
  `);
  assert.equal(invalid.status, 2);
  assert.match(invalid.stderr, /invalid project id/);

  const dotDot = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    spin_project_root '..'
  `);
  assert.equal(dotDot.status, 2);
  assert.match(dotDot.stderr, /invalid project id/);
});

test('direct provider fallback executes inside only the selected project root', t => {
  const root = fixture(t);
  const capture = path.join(root, 'claude-capture.json');
  const fakeClaude = path.join(root, 'bin', 'claude');
  fs.writeFileSync(fakeClaude, `#!/usr/bin/env bash
node - "$CLAUDE_CAPTURE" "$PWD" "$@" <<'NODE'
const fs = require('fs');
const [file, cwd, ...args] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ cwd, args }) + '\\n');
NODE
`, { mode: 0o755 });

  const result = runBash(root, `
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    SPIN_AGENT_CWD="$ROOT/projects/app"
    export SPIN_AGENT_CWD
    run_agent claude prompt "$ROOT/provider.log" "$ROOT/org/projects/app"
  `, { CLAUDE_CAPTURE: capture });
  assert.equal(result.status, 0, result.stderr);
  const observed = JSON.parse(fs.readFileSync(capture, 'utf8'));
  assert.equal(observed.cwd, fs.realpathSync(path.join(root, 'projects', 'app')));
  assert.deepEqual(observed.args, [
    '-p', 'prompt',
    '--model', 'claude-sonnet-4-6',
    '--permission-mode', 'dontAsk',
    '--add-dir', fs.realpathSync(path.join(root, 'projects', 'app')),
    '--add-dir', path.join(root, 'org', 'projects', 'app'),
  ]);
});

test('queued project agents export the canonical root and load project overrides', t => {
  const root = fixture(t);
  fs.copyFileSync(path.join(repo, 'scripts', 'project-ceo-agent.sh'), path.join(root, 'scripts', 'project-ceo-agent.sh'));
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'action-policy-prompt.md'), '');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# app\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'WORKSPACE_HANDOFF.md'), 'Do the task.\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'RECEIPTS.md'), '');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'project.env'), 'PROJECT_CEO_PROVIDER=claude\n');
  writeJSON(path.join(root, 'org', 'projects', 'app', 'STATE.json'), { status: 'active' });
  fs.writeFileSync(path.join(root, 'scripts', 'lib', 'ceo-waterfall.sh'), `
CEO_RUN_DIR="$SPIN_ROOT/org/ceo/runs"
CEO_LOCKOUT_FILE="$CEO_RUN_DIR/codex-blocked-until"
codex_is_blocked() { return 1; }
content_changed() { return 0; }
run_agent_resilient() {
  printf '%s\\n' "$SPIN_AGENT_CWD|$SPIN_PROJECT_ROOT|$PROJECT_CEO_PROVIDER" > "$SPIN_ROOT/agent-context"
  printf '%s\\n' "Queue-Outcome: $OMP_JOB_ID COMPLETED" >> "$SPIN_ROOT/org/projects/app/RECEIPTS.md"
}
`);

  const jobId = 'isolated-job';
  const result = runBash(root, `
    bash "$ROOT/scripts/project-ceo-agent.sh" app
  `, {
    OMP_JOB_ID: jobId,
    OMP_JOB_DESCRIPTION: 'prove project isolation',
    OMP_OUTCOME_FILE: path.join(root, 'org', 'jobs', `${jobId}.outcome.json`),
  });
  assert.equal(result.status, 0, result.stderr);
  const projectRoot = fs.realpathSync(path.join(root, 'projects', 'app'));
  assert.equal(fs.readFileSync(path.join(root, 'agent-context'), 'utf8').trim(),
    `${projectRoot}|${projectRoot}|claude`);
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'org', 'jobs', `${jobId}.outcome.json`), 'utf8')).outcome,
    'completed');
});

test('legacy project path metadata cannot replace floor roots or OMP config lanes', t => {
  const root = fixture(t);
  fs.copyFileSync(path.join(repo, 'scripts', 'cmux-floor.sh'), path.join(root, 'scripts', 'cmux-floor.sh'));
  fs.copyFileSync(
    path.join(repo, 'scripts', 'lib', 'cmux-floor-layout.sh'),
    path.join(root, 'scripts', 'lib', 'cmux-floor-layout.sh'),
  );
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'PROJECT_CONTROLLER_PROMPT.md'), '# app\n');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'FLOOR.md'), '# app floor\n');

  const legacyConfig = path.join(root, 'project-controlled', 'legacy-omp.yml');
  const legacyCompanyRoot = path.join(root, 'project-controlled', 'company');
  const legacyProjectRoot = path.join(root, 'project-controlled', 'code');
  fs.writeFileSync(path.join(root, 'org', 'projects', 'app', 'project.env'), [
    `SPIN_OMP_CONFIG=${legacyConfig}`,
    `COMPANY_ROOT='${legacyCompanyRoot}'`,
    `PROJECT_CODE_PATH="${legacyProjectRoot}"`,
    'SPIN_OMP_DEFAULT_MODEL=provider/project-model',
    '',
  ].join('\n'));

  const fakeOmp = path.join(root, 'bin', 'omp');
  fs.writeFileSync(fakeOmp, `#!/usr/bin/env bash
node - "$FLOOR_CAPTURE" "$PWD" "\${SPIN_PROJECT_ROOT:-}" "\${SPIN_OMP_CONFIG:-}" "$@" <<'NODE'
const fs = require('fs');
const [file, cwd, projectRoot, ownerConfig, ...args] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({ cwd, projectRoot, ownerConfig, args }) + '\\n');
NODE
`, { mode: 0o755 });

  const generatedCapture = path.join(root, 'generated-floor.json');
  const generated = runBash(root, `
    bash "$ROOT/scripts/cmux-floor.sh" app
  `, {
    FLOOR_CAPTURE: generatedCapture,
    SPIN_OMP_BIN: fakeOmp,
    SPIN_OMP_CONFIG: '',
    SPIN_OMP_MCP_BOOTSTRAP: '0',
    TERM: 'xterm',
  });
  assert.equal(generated.status, 0, generated.stderr);
  const generatedFloor = JSON.parse(fs.readFileSync(generatedCapture, 'utf8'));
  const generatedConfig = path.join(
    root, 'org', 'ceo', 'runs', 'omp-configs', 'project-floor:app.yml',
  );
  assert.equal(generatedFloor.cwd, path.join(root, 'org', 'projects', 'app'));
  assert.equal(generatedFloor.projectRoot, fs.realpathSync(path.join(root, 'projects', 'app')));
  assert.equal(generatedFloor.ownerConfig, '');
  assert.equal(generatedFloor.args[generatedFloor.args.indexOf('--config') + 1], generatedConfig);
  assert.match(fs.readFileSync(generatedConfig, 'utf8'), /default: 'provider\/project-model'/);
  assert.equal(fs.existsSync(legacyConfig), false);
  assert.equal(fs.existsSync(legacyCompanyRoot), false);
  assert.equal(fs.existsSync(legacyProjectRoot), false);

  const ownerConfig = path.join(root, 'owner-controlled', 'omp.yml');
  const ownerCapture = path.join(root, 'owner-floor.json');
  const owner = runBash(root, `
    bash "$ROOT/scripts/cmux-floor.sh" app
  `, {
    FLOOR_CAPTURE: ownerCapture,
    SPIN_OMP_BIN: fakeOmp,
    SPIN_OMP_CONFIG: ownerConfig,
    SPIN_OMP_MCP_BOOTSTRAP: '0',
    TERM: 'xterm',
  });
  assert.equal(owner.status, 0, owner.stderr);
  const ownerFloor = JSON.parse(fs.readFileSync(ownerCapture, 'utf8'));
  assert.equal(ownerFloor.ownerConfig, ownerConfig);
  assert.equal(ownerFloor.args[ownerFloor.args.indexOf('--config') + 1], ownerConfig);
  assert.match(fs.readFileSync(ownerConfig, 'utf8'), /default: 'provider\/project-model'/);
  assert.equal(fs.existsSync(legacyConfig), false);
});

test('project env parsing cannot execute shell or replace canonical context', t => {
  const root = fixture(t);
  const envFile = path.join(root, 'org', 'projects', 'app', 'project.env');
  const marker = path.join(root, 'project-env-executed');
  fs.writeFileSync(envFile, [
    `PROJECT_CEO_PROVIDER=$(touch ${marker})`,
    'SPIN_AGENT_CWD=/tmp/escaped-project-root',
    '',
  ].join('\n'));

  const denied = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    SPIN_AGENT_CWD="$ROOT/projects/app"
    export SPIN_AGENT_CWD
    spin_load_project_env "$ROOT/org/projects/app/project.env"
  `);
  assert.equal(denied.status, 2);
  assert.match(denied.stderr, /SPIN_AGENT_CWD/);
  assert.equal(fs.existsSync(marker), false);

  fs.writeFileSync(envFile, [
    `PROJECT_CEO_PROVIDER='$(touch ${marker})'`,
    'SPIN_OMP_DEFAULT_MODEL="anthropic/project-model"',
    '',
  ].join('\n'));
  const literal = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    SPIN_AGENT_CWD="$ROOT/projects/app"
    export SPIN_AGENT_CWD
    spin_load_project_env "$ROOT/org/projects/app/project.env"
    printf '%s|%s|%s\\n' "$SPIN_AGENT_CWD" "$PROJECT_CEO_PROVIDER" "$SPIN_OMP_DEFAULT_MODEL"
  `);
  assert.equal(literal.status, 0, literal.stderr);
  assert.equal(literal.stdout.trim(),
    `${path.join(root, 'projects', 'app')}|$(touch ${marker})|anthropic/project-model`);
  assert.equal(fs.existsSync(marker), false);

  fs.writeFileSync(envFile, [
    'SPIN_OMP_CONFIG=/tmp/project-controlled.yml',
    'COMPANY_ROOT=/tmp/project-controlled-company',
    'PROJECT_CODE_PATH=/tmp/project-controlled-code',
    `OPENAI_API_KEY=$(touch ${marker})`,
    '',
  ].join('\n'));
  const unknownSecret = runBash(root, `
    source "$ROOT/scripts/lib/project-root.sh"
    spin_load_project_env "$ROOT/org/projects/app/project.env"
  `);
  assert.equal(unknownSecret.status, 2);
  assert.match(unknownSecret.stderr, /OPENAI_API_KEY/);
  assert.equal(fs.existsSync(marker), false);
});
