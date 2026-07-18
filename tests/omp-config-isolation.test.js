'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repo = path.resolve(__dirname, '..');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-omp-config-'));
  fs.mkdirSync(path.join(root, 'scripts', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(root, 'org', 'ceo', 'runs'), { recursive: true });
  fs.mkdirSync(path.join(root, 'home'), { recursive: true });
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
      SPIN_OMP_MCP_BOOTSTRAP: '0',
      ...extraEnv,
    },
    encoding: 'utf8',
    timeout: 10000,
  });
}

test('concurrent execution lanes keep independent OMP model overlays', t => {
  const root = fixture(t);
  const workspaceResult = path.join(root, 'workspace.path');
  const projectResult = path.join(root, 'project.path');
  const result = runBash(root, `
    set -euo pipefail
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    generate_config() {
      local lane="$1" model="$2" result_file="$3"
      (
        SPIN_OMP_CONFIG_LANE="$lane"
        SPIN_OMP_DEFAULT_MODEL="$model"
        local config=""
        for _ in {1..20}; do
          config="$(ensure_spin_omp_config)"
        done
        printf '%s\n' "$config" > "$result_file"
      ) &
    }
    generate_config workspace-agent provider/model-alpha "$WORKSPACE_RESULT"
    generate_config project-job:app provider/model-beta "$PROJECT_RESULT"
    wait
  `, { WORKSPACE_RESULT: workspaceResult, PROJECT_RESULT: projectResult });

  assert.equal(result.status, 0, result.stderr);
  const workspaceConfig = fs.readFileSync(workspaceResult, 'utf8').trim();
  const projectConfig = fs.readFileSync(projectResult, 'utf8').trim();
  assert.notEqual(workspaceConfig, projectConfig);
  assert.equal(workspaceConfig, path.join(root, 'org', 'ceo', 'runs', 'omp-configs', 'workspace-agent.yml'));
  assert.equal(projectConfig, path.join(root, 'org', 'ceo', 'runs', 'omp-configs', 'project-job:app.yml'));
  const workspaceYaml = fs.readFileSync(workspaceConfig, 'utf8');
  const projectYaml = fs.readFileSync(projectConfig, 'utf8');
  assert.match(workspaceYaml, /default: 'provider\/model-alpha'/);
  assert.doesNotMatch(workspaceYaml, /provider\/model-beta/);
  assert.match(projectYaml, /default: 'provider\/model-beta'/);
  assert.doesNotMatch(projectYaml, /provider\/model-alpha/);
});

test('derived OMP config lanes reject unsafe paths', t => {
  const root = fixture(t);
  const result = runBash(root, `
    set -euo pipefail
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    for lane in '../escape' 'a/b' '.' '..' 'with space'; do
      if ensure_spin_omp_config "$lane" >/dev/null 2>&1; then
        echo "unsafe lane accepted: $lane" >&2
        exit 9
      fi
    done
  `);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(root, 'org', 'ceo', 'runs', 'omp-configs')), false);
  assert.equal(fs.existsSync(path.join(root, 'org', 'ceo', 'escape.yml')), false);
});

test('explicit SPIN_OMP_CONFIG remains an owner-controlled opt-out', t => {
  const root = fixture(t);
  const custom = path.join(root, 'custom configs', 'owner overlay.yml');
  const result = runBash(root, `
    set -euo pipefail
    source "$CEO_ROOT/scripts/lib/ceo-waterfall.sh"
    SPIN_OMP_CONFIG="$CUSTOM_CONFIG"
    resolved="$(ensure_spin_omp_config '../lane-is-ignored-for-explicit-path')"
    printf '%s\n' "$resolved"
  `, { CUSTOM_CONFIG: custom });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), custom);
  assert.match(fs.readFileSync(custom, 'utf8'), /modelRoles:/);
});
