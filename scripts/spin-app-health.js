#!/usr/bin/env node
// App/runtime health checks for SPIN.app and developer checkouts.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const runtime = require('./lib/spin-runtime.js');

const args = new Set(process.argv.slice(2));
const jsonMode = args.has('--json');
const root = process.env.SPIN_ROOT || process.env.OMP_ROOT || path.resolve(__dirname, '..');
const appResources = process.env.SPIN_APP_RESOURCES || runtime.installedAppResources(root)[0] || '';
const internalBinDir = process.env.SPIN_INTERNAL_BIN_DIR || (appResources ? path.join(appResources, 'bin') : '');
const bundledRuntime = process.env.SPIN_BUNDLED_RUNTIME || (appResources ? path.join(appResources, 'runtime') : '');

const providerEnvVars = [
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_OAUTH_TOKEN',
  'OPENAI_API_KEY',
  'GEMINI_API_KEY',
  'COPILOT_GITHUB_TOKEN',
  'AZURE_OPENAI_API_KEY',
  'GROQ_API_KEY',
  'CEREBRAS_API_KEY',
  'XAI_API_KEY',
  'OPENROUTER_API_KEY',
  'KILO_API_KEY',
  'MISTRAL_API_KEY',
  'ZAI_API_KEY',
  'UMANS_AI_CODING_PLAN_API_KEY',
  'MINIMAX_API_KEY',
  'OPENCODE_API_KEY',
  'CURSOR_ACCESS_TOKEN',
  'AI_GATEWAY_API_KEY',
  'WAFER_SERVERLESS_API_KEY',
  'AWS_PROFILE',
  'GOOGLE_CLOUD_PROJECT',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'OMP_AUTH_BROKER_URL',
];

function pathExists(file) {
  try {
    fs.accessSync(file);
    return true;
  } catch {
    return false;
  }
}

function isDir(file) {
  try {
    return fs.statSync(file).isDirectory();
  } catch {
    return false;
  }
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function firstLine(text) {
  return String(text || '').split(/\r?\n/).find(Boolean) || '';
}

function run(command, argv = [], options = {}) {
  const result = spawnSync(command, argv, {
    cwd: options.cwd || root,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeoutMs || 4000,
    maxBuffer: 1024 * 1024,
  });
  return {
    ok: result.status === 0 && !result.error,
    status: result.status,
    signal: result.signal || null,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    error: result.error ? String(result.error.message || result.error) : null,
    timedOut: result.error && result.error.code === 'ETIMEDOUT',
  };
}

function commandPath(name) {
  const probe = run('/usr/bin/env', ['bash', '-lc', `command -v ${JSON.stringify(name)}`], { timeoutMs: 1500 });
  return probe.ok ? firstLine(probe.stdout) : null;
}

function classifyBinary(name, file) {
  if (!file) return 'missing';
  const override = process.env[`SPIN_${name.replace(/-/g, '_').toUpperCase()}_BIN`];
  if (override && path.resolve(override) === path.resolve(file)) return 'env-override';
  if (internalBinDir && file.startsWith(`${internalBinDir}${path.sep}`)) return 'app-bundled';
  if (appResources && file.startsWith(`${path.join(appResources, 'bin')}${path.sep}`)) return 'app-bundled';
  if (file.startsWith(`${path.join(root, 'vendor', 'bin')}${path.sep}`)) return 'repo-vendor';
  if (file.startsWith(`${path.join(root, 'agent', 'bin')}${path.sep}`)) return 'repo-agent';
  if (file.startsWith(`${path.join(root, 'app', 'bin')}${path.sep}`)) return 'repo-app';
  return 'path';
}

function checkWritableRuntime() {
  const targetDir = root;
  if (!isDir(targetDir)) {
    return { status: 'error', path: targetDir, writable: false, message: 'runtime root is missing' };
  }
  const file = path.join(targetDir, `.spin-health-${process.pid}-${Date.now()}`);
  try {
    fs.writeFileSync(file, 'ok\n', { mode: 0o600 });
    fs.unlinkSync(file);
    return { status: 'ok', path: targetDir, writable: true };
  } catch (error) {
    return { status: 'error', path: targetDir, writable: false, message: error.message };
  }
}

function cmuxAppPath() {
  const candidates = [
    process.env.SPIN_CMUX_APP || '',
    appResources ? path.join(appResources, 'SPIN.app') : '',
    path.join(root, 'vendor', 'cmux', 'SPIN.app'),
    path.join(root, 'vendor', 'cmux', 'cmux.app'),
    path.join(root, 'app', 'cmux', 'SPIN.app'),
    path.join(root, 'app', 'cmux', 'cmux.app'),
  ].filter(Boolean);
  return candidates.find(isDir) || null;
}

function checkTool(name, required = false) {
  const found = commandPath(name) || (name === 'node' ? process.execPath : null);
  if (!found) {
    return {
      status: required ? 'error' : 'warn',
      path: null,
      required,
      message: `${name} not found on PATH`,
    };
  }
  return { status: 'ok', path: found, required };
}

function checkXcode() {
  const found = commandPath('xcodebuild');
  if (!found) {
    return { status: 'warn', path: null, required: false, message: 'xcodebuild not found; source cmux releases need Xcode' };
  }
  const version = run(found, ['-version'], { timeoutMs: 3000 });
  return {
    status: version.ok ? 'ok' : 'warn',
    path: found,
    required: false,
    version: firstLine(version.stdout || version.stderr),
    message: version.ok ? undefined : 'xcodebuild exists but did not report a version',
  };
}

function checkBinary(name, argv) {
  const file = runtime.resolveBinary(name, root);
  if (!file) {
    if (name === 'spin-agent' && !appResources) {
      return {
        status: 'skip',
        path: null,
        source: 'missing',
        executable: false,
        message: 'created inside packaged SPIN.app',
      };
    }
    return { status: 'error', path: null, source: 'missing', executable: false };
  }
  const executable = isExecutable(file);
  if (!executable) {
    return { status: 'error', path: file, source: classifyBinary(name, file), executable: false };
  }
  const probe = run(file, argv, { timeoutMs: 4000 });
  return {
    status: probe.ok ? 'ok' : 'error',
    path: file,
    source: classifyBinary(name, file),
    executable,
    version: firstLine(probe.stdout || probe.stderr),
    message: probe.ok ? undefined : firstLine(probe.stderr || probe.stdout) || probe.error || 'probe failed',
  };
}

function checkOmp() {
  const omp = runtime.resolveBinary('omp', root);
  if (!omp) {
    return {
      status: 'error',
      owner: 'OMP',
      setupCommand: 'spin omp-setup',
      message: 'bundled OMP is missing',
      providerEnvVarsPresent: providerEnvVars.filter((name) => Boolean(process.env[name])),
    };
  }

  const setupHelp = run(omp, ['setup', '--help'], { timeoutMs: 4000 });
  const brokerStatus = run(omp, ['auth-broker', 'status', '--json'], { timeoutMs: 4000 });
  let broker = {
    status: 'unknown',
    ok: false,
    message: firstLine(brokerStatus.stderr || brokerStatus.stdout) || brokerStatus.error || 'auth-broker status unavailable',
  };
  if (brokerStatus.stdout.trim().startsWith('{')) {
    try {
      const parsed = JSON.parse(brokerStatus.stdout);
      broker = {
        status: parsed.ok ? 'ok' : (parsed.reason || 'not_configured'),
        ok: Boolean(parsed.ok),
        reason: parsed.reason || undefined,
        message: parsed.ok ? 'configured' : `OMP auth broker: ${parsed.reason || 'not configured'}`,
      };
    } catch {
      // Keep the generic unknown status.
    }
  }

  const envPresent = providerEnvVars.filter((name) => Boolean(process.env[name]));
  const needsSetup = !broker.ok && envPresent.length === 0;
  return {
    status: setupHelp.ok ? (needsSetup ? 'needs_setup' : 'ok') : 'warn',
    owner: 'OMP',
    setupCommand: 'spin omp-setup',
    directSetupCommand: 'omp setup',
    setupAvailable: setupHelp.ok,
    authBroker: broker,
    providerEnvVarsPresent: envPresent,
    message: needsSetup
      ? 'OMP runs, but no auth broker or provider env markers were detected. Use OMP setup when you are ready.'
      : 'OMP provider setup remains owned by OMP.',
  };
}

function checkActionBroker() {
  const script = path.join(root, 'scripts', 'spin-action-broker.js');
  if (!pathExists(script)) return { status: 'error', state: 'missing_code', message: 'sensitive action broker is missing' };
  const probe = run(process.execPath, [script, 'status', '--json'], { timeoutMs: 3000 });
  if (!probe.ok) {
    return {
      status: 'error',
      state: 'invalid',
      message: firstLine(probe.stderr || probe.stdout) || probe.error || 'action policy check failed',
    };
  }
  try {
    const report = JSON.parse(probe.stdout);
    return {
      status: report.status === 'missing' ? 'warn' : 'ok',
      state: report.status,
      secureDefault: report.secure_default === true,
      enabledRules: Number(report.enabled_rules || 0),
      policy: report.policy,
      message: report.status === 'missing'
        ? 'policy file missing; sensitive actions still fail closed'
        : (report.status === 'deny_all' ? 'deny-all policy active' : 'exact action rules configured'),
    };
  } catch {
    return { status: 'error', state: 'invalid', message: 'action broker returned invalid JSON' };
  }
}

function summarize(health) {
  const checks = [];
  checks.push(health.app.runtimeWritable);
  checks.push(health.binaries.cmux);
  checks.push(health.binaries.omp);
  checks.push(health.tools.bash);
  checks.push(health.tools.node);
  checks.push(health.tools.git);
  if (appResources) checks.push(health.binaries.spinAgent);
  checks.push(health.security.actionBroker);

  const errors = checks.filter((item) => item && item.status === 'error').length;
  const warnings = checks.filter((item) => item && item.status === 'warn').length;
  return {
    status: errors > 0 ? 'error' : (warnings > 0 || health.omp.status === 'needs_setup' ? 'warn' : 'ok'),
    errors,
    warnings: warnings + (health.omp.status === 'needs_setup' ? 1 : 0),
  };
}

function collectHealth() {
  const health = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    root,
    app: {
      inBundle: Boolean(appResources),
      resources: appResources || null,
      internalBinDir: internalBinDir || null,
      bundledRuntime: bundledRuntime || null,
      runtimeWritable: checkWritableRuntime(),
      orgDir: path.join(root, 'org'),
      orgExists: isDir(path.join(root, 'org')),
      onboarded: pathExists(path.join(root, 'org', '.spin-onboarded')),
      cmuxApp: (() => {
        const found = cmuxAppPath();
        return found ? { status: 'ok', path: found } : { status: appResources ? 'error' : 'warn', path: null };
      })(),
    },
    tools: {
      bash: checkTool('bash', true),
      node: checkTool('node', true),
      git: checkTool('git', true),
      xcodebuild: checkXcode(),
      shell: { status: 'ok', path: process.env.SHELL || null, name: path.basename(process.env.SHELL || 'shell') },
    },
    binaries: {
      cmux: checkBinary('cmux', ['version']),
      omp: checkBinary('omp', ['--version']),
      spinAgent: checkBinary('spin-agent', ['--version']),
    },
    omp: checkOmp(),
    security: {
      actionBroker: checkActionBroker(),
    },
    system: {
      platform: process.platform,
      arch: process.arch,
      hostname: os.hostname(),
    },
  };
  health.summary = summarize(health);
  return health;
}

function mark(status) {
  if (status === 'ok') return 'OK';
  if (status === 'error') return 'FAIL';
  if (status === 'skip') return 'SKIP';
  return 'WARN';
}

function binaryLine(label, item) {
  const detail = item.path ? `${item.path}${item.version ? ` (${item.version})` : ''}` : item.message || 'missing';
  return `  [${mark(item.status)}] ${label}: ${detail}`;
}

function renderText(health) {
  const lines = [];
  lines.push(`SPIN app health: ${health.summary.status.toUpperCase()}`);
  lines.push(`  root: ${health.root}`);
  lines.push(`  app bundle: ${health.app.inBundle ? health.app.resources : 'checkout/dev mode'}`);
  lines.push(`  runtime writable: ${mark(health.app.runtimeWritable.status)} ${health.app.runtimeWritable.path}`);
  lines.push(`  onboarded: ${health.app.onboarded ? 'yes' : 'no'}`);
  lines.push('');
  lines.push('Binaries');
  lines.push(binaryLine('cmux', health.binaries.cmux));
  lines.push(binaryLine('omp', health.binaries.omp));
  lines.push(binaryLine('spin-agent', health.binaries.spinAgent));
  lines.push('');
  lines.push('Local Tools');
  for (const name of ['bash', 'node', 'git', 'xcodebuild']) {
    const item = health.tools[name];
    lines.push(`  [${mark(item.status)}] ${name}: ${item.path || item.message}`);
  }
  lines.push('');
  lines.push('OMP');
  lines.push(`  [${mark(health.omp.status === 'needs_setup' ? 'warn' : health.omp.status)}] setup handoff: ${health.omp.setupCommand}`);
  lines.push(`  auth broker: ${health.omp.authBroker.status}`);
  if (health.omp.providerEnvVarsPresent.length > 0) {
    lines.push(`  provider env markers: ${health.omp.providerEnvVarsPresent.join(', ')}`);
  } else {
    lines.push('  provider env markers: none detected');
  }
  lines.push(`  note: ${health.omp.message}`);
  lines.push('');
  lines.push('Sensitive Actions');
  lines.push(`  [${mark(health.security.actionBroker.status)}] broker: ${health.security.actionBroker.state}`);
  lines.push(`  enabled exact rules: ${health.security.actionBroker.enabledRules || 0}`);
  lines.push(`  note: ${health.security.actionBroker.message}`);
  return `${lines.join('\n')}\n`;
}

const health = collectHealth();
if (jsonMode) {
  process.stdout.write(`${JSON.stringify(health, null, 2)}\n`);
} else {
  process.stdout.write(renderText(health));
}

process.exit(health.summary.status === 'error' ? 1 : 0);
