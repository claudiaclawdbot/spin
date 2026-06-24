#!/usr/bin/env node
/* User-facing SPIN.app update surface backed by the checked app updater. */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = process.env.SPIN_ROOT || path.resolve(__dirname, '..');
const RELEASE_DIR = process.env.SPIN_RELEASE_DIR || path.join(ROOT, 'dist', 'release');

function fail(message) {
  console.error(`app-updates failed: ${message}`);
  process.exit(1);
}

function usage(exitCode = 0) {
  const out = exitCode === 0 ? console.log : console.error;
  out(`Usage: spin app-updates [--check|--install] [options] [SPIN-<version>-macos-<arch>.zip|.dmg]

Options:
  --check                  show the checked update plan; default action
  --install                install the candidate through spin app-update
  --candidate PATH         candidate .zip artifact or SPIN.app bundle
  --installed-app PATH     installed/current SPIN.app; defaults to app context or dist/SPIN.app
  --app-home PATH          app support root for rollback metadata
  --yes                    required for non-interactive install confirmation
  --allow-test-builds      allow ad-hoc/test release artifacts
  --allow-ad-hoc           alias for --allow-test-builds
  --allow-local-dev        allow local developer app bundles
  --allow-production       allow production artifacts after trust verification
  --force-channel          allow candidate channel downgrade
  --json                   print JSON when no candidate is available; otherwise pass through app-update JSON
  -h, --help               show this help`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const options = {
    action: 'check',
    candidate: '',
    installedApp: '',
    appHome: '',
    yes: false,
    allowTestBuilds: false,
    allowLocalDev: false,
    allowProduction: false,
    forceChannel: false,
    json: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--check') options.action = 'check';
    else if (arg === '--install') options.action = 'install';
    else if (arg === '--yes') options.yes = true;
    else if (arg === '--allow-test-builds' || arg === '--allow-ad-hoc') options.allowTestBuilds = true;
    else if (arg === '--allow-local-dev') options.allowLocalDev = true;
    else if (arg === '--allow-production') options.allowProduction = true;
    else if (arg === '--force-channel') options.forceChannel = true;
    else if (arg === '--json') options.json = true;
    else if (arg === '--candidate') {
      i += 1;
      if (!argv[i]) fail('--candidate requires a path');
      options.candidate = argv[i];
    } else if (arg === '--installed-app') {
      i += 1;
      if (!argv[i]) fail('--installed-app requires a path');
      options.installedApp = argv[i];
    } else if (arg === '--app-home') {
      i += 1;
      if (!argv[i]) fail('--app-home requires a path');
      options.appHome = argv[i];
    } else if (arg === '-h' || arg === '--help') usage(0);
    else if (arg.startsWith('-')) fail(`unknown option: ${arg}`);
    else if (!options.candidate) options.candidate = arg;
    else fail(`unexpected extra argument: ${arg}`);
  }
  return options;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function resolveAppFromResources(resources) {
  if (!resources) return '';
  const resolved = path.resolve(resources);
  if (path.basename(resolved) === 'Resources') {
    const app = path.resolve(resolved, '..', '..');
    if (fs.existsSync(path.join(app, 'Contents', 'Resources', 'app', 'release-compat.json'))) return app;
  }
  return '';
}

function defaultInstalledApp() {
  if (process.env.SPIN_APP_INSTALLED_APP) return process.env.SPIN_APP_INSTALLED_APP;
  const fromResources = resolveAppFromResources(process.env.SPIN_APP_RESOURCES || '');
  if (fromResources) return fromResources;
  const distApp = path.join(ROOT, 'dist', 'SPIN.app');
  if (fs.existsSync(path.join(distApp, 'Contents', 'Resources', 'app', 'release-compat.json'))) return distApp;
  return '';
}

function newestReleaseArtifact() {
  const explicit = process.env.SPIN_APP_UPDATE_CANDIDATE || process.env.SPIN_UPDATE_ARTIFACT || '';
  if (explicit) return explicit;
  if (!fs.existsSync(RELEASE_DIR)) return '';
  const candidates = fs.readdirSync(RELEASE_DIR)
    .filter((name) => /^SPIN-.+-macos-.+\.(zip|dmg)$/.test(name))
    .map((name) => {
      const file = path.join(RELEASE_DIR, name);
      return { file, mtimeMs: fs.statSync(file).mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
  return candidates.length ? candidates[0].file : '';
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: options.stdio || 'pipe',
    env: process.env,
  });
  if (result.status !== 0) {
    const detail = `${result.stderr || ''}${result.stdout || ''}`.trim();
    fail(`${command} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout || '';
}

function extractCandidate(candidatePath) {
  const absolute = path.resolve(candidatePath);
  if (!fs.existsSync(absolute)) fail(`candidate not found: ${absolute}`);
  if (absolute.endsWith('.app')) {
    return { artifact: absolute, app: absolute, cleanup: () => {} };
  }
  if (absolute.endsWith('.dmg')) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-updates-'));
    const mount = path.join(tmp, 'mount');
    const app = path.join(tmp, 'SPIN.app');
    fs.mkdirSync(mount, { recursive: true });
    run('hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mount, absolute]);
    try {
      if (process.platform === 'darwin') run('ditto', [path.join(mount, 'SPIN.app'), app]);
      else fail('dmg candidates require macOS hdiutil');
    } finally {
      run('hdiutil', ['detach', mount]);
    }
    if (!fs.existsSync(app)) fail(`candidate dmg did not contain SPIN.app: ${absolute}`);
    return {
      artifact: absolute,
      app,
      cleanup: () => fs.rmSync(tmp, { recursive: true, force: true }),
    };
  }
  if (!absolute.endsWith('.zip')) fail(`candidate must be a .zip/.dmg artifact or .app bundle: ${absolute}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-updates-'));
  if (process.platform === 'darwin') run('ditto', ['-x', '-k', absolute, tmp]);
  else run('unzip', ['-q', absolute, '-d', tmp]);
  const app = path.join(tmp, 'SPIN.app');
  if (!fs.existsSync(app)) fail(`candidate artifact did not contain SPIN.app: ${absolute}`);
  return {
    artifact: absolute,
    app,
    cleanup: () => fs.rmSync(tmp, { recursive: true, force: true }),
  };
}

function readManifestFromApp(app) {
  const manifestPath = path.join(app, 'Contents', 'Resources', 'app', 'release-compat.json');
  if (!fs.existsSync(manifestPath)) return null;
  return { path: manifestPath, manifest: readJson(manifestPath) };
}

function summaryLine(manifestInfo) {
  if (!manifestInfo || !manifestInfo.manifest) return 'unknown';
  const manifest = manifestInfo.manifest;
  const version = manifest.runtime && manifest.runtime.version ? manifest.runtime.version : 'unknown';
  const channel = manifest.release && manifest.release.channel ? manifest.release.channel : 'unknown';
  const mode = manifest.build && manifest.build.mode ? manifest.build.mode : 'unknown';
  return `${version} (${channel}, ${mode})`;
}

function printHeader(installedApp, installedManifest, candidateInfo, candidateManifest) {
  console.log('SPIN app updates');
  console.log(`  installed app: ${installedApp || 'not found'}`);
  console.log(`  installed:     ${summaryLine(installedManifest)}`);
  if (candidateInfo) {
    console.log(`  candidate:     ${candidateInfo.artifact}`);
    console.log(`  candidate app: ${candidateInfo.app}`);
    console.log(`  candidate build: ${summaryLine(candidateManifest)}`);
  } else {
    console.log('  candidate:     none');
  }
  console.log('');
}

function jsonNoCandidate(installedApp, installedManifest) {
  console.log(JSON.stringify({
    status: 'no-candidate',
    releaseDir: RELEASE_DIR,
    installedApp: installedApp || null,
    installed: installedManifest ? installedManifest.manifest : null,
    nextStep: 'Provide --candidate PATH or place a SPIN-<version>-macos-<arch>.zip/.dmg artifact in the release directory.',
  }, null, 2));
}

function confirmInstall(options, candidateManifest) {
  if (options.yes) return;
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    fail('install requires --yes when not running interactively');
  }
  const channel = candidateManifest && candidateManifest.manifest && candidateManifest.manifest.release
    ? candidateManifest.manifest.release.channel
    : 'unknown';
  process.stdout.write(`Install this ${channel} SPIN.app update? Type INSTALL to continue: `);
  const answer = fs.readFileSync(0, 'utf8').trim();
  if (answer !== 'INSTALL') fail('install cancelled');
}

function channelAllowArgs(options, candidateManifest) {
  const channel = candidateManifest && candidateManifest.manifest && candidateManifest.manifest.release
    ? candidateManifest.manifest.release.channel
    : '';
  if (channel === 'ad-hoc') {
    if (!options.allowTestBuilds) fail('candidate is an ad-hoc/test build; pass --allow-test-builds to install');
    return ['--allow-ad-hoc'];
  }
  if (channel === 'local-dev') {
    if (!options.allowLocalDev) fail('candidate is a local developer build; pass --allow-local-dev to install');
    return ['--allow-local-dev'];
  }
  if (channel === 'production') {
    if (!options.allowProduction) fail('candidate is production; pass --allow-production to install after trust verification');
    return ['--allow-production'];
  }
  fail(`candidate release channel is unsupported: ${channel || 'missing'}`);
}

function appUpdateArgs(options, candidate, candidateManifest) {
  const args = [
    path.join(ROOT, 'scripts', 'spin-app-update.js'),
    options.action === 'install' ? '--install' : '--dry-run',
  ];
  if (options.installedApp) args.push('--installed-app', options.installedApp);
  if (options.appHome) args.push('--app-home', options.appHome);
  if (options.forceChannel) args.push('--force-channel');
  if (options.json) args.push('--json');
  if (options.action === 'install') {
    args.push(...channelAllowArgs(options, candidateManifest));
  }
  args.push(candidate.artifact);
  return args;
}

const options = parseArgs(process.argv.slice(2));
const installedApp = options.installedApp || defaultInstalledApp();
const installedManifest = installedApp ? readManifestFromApp(path.resolve(installedApp)) : null;
const candidatePath = options.candidate || newestReleaseArtifact();

if (!candidatePath) {
  if (options.json) jsonNoCandidate(installedApp, installedManifest);
  else {
    printHeader(installedApp, installedManifest, null, null);
    console.log(`No local update artifact found in ${RELEASE_DIR}.`);
    console.log('Status: current app state only.');
  }
  process.exit(0);
}

const candidate = extractCandidate(candidatePath);
try {
  const candidateManifest = readManifestFromApp(candidate.app);
  if (!candidateManifest) fail(`candidate compatibility manifest not found in ${candidate.app}`);
  if (!options.json) printHeader(installedApp, installedManifest, candidate, candidateManifest);
  if (options.action === 'install') confirmInstall(options, candidateManifest);
  const args = appUpdateArgs(options, candidate, candidateManifest);
  const output = run(process.execPath, args);
  process.stdout.write(output);
} finally {
  candidate.cleanup();
}
