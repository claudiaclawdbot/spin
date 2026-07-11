#!/usr/bin/env node
/* Plan or install SPIN.app updates from checked release artifacts. */
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const ROOT = process.env.SPIN_ROOT || path.resolve(__dirname, '..');
const CHANNEL_RANK = { 'local-dev': 0, 'ad-hoc': 1, production: 2 };
const PRESERVED_STATE = [
  'org/',
  'logs/',
  'org/.spin-onboarded',
  'org/OMP_HARNESS.json',
  'org/ceo/APPROVALS.md',
  'org/HUMAN_QUEUE.md',
  'org/ceo/runs/',
  'provider credentials and model account state',
];
const REPLACEABLE_CODE = [
  'SPIN.app bundle payload',
  'Resources/runtime code except org/ and logs/',
  'Resources/bin/cmux',
  'Resources/bin/omp',
  'Resources/bin/spin-agent',
  'Resources/SPIN.app bundled UI engine',
];

function usage(exitCode = 0) {
  const out = exitCode === 0 ? console.log : console.error;
  out(`Usage: spin app-update --dry-run|--install [options] SPIN-<version>-macos-<arch>.zip|.dmg

Options:
  --dry-run                 print the update plan without changing app code
  --install                 replace the installed app with the candidate app
  --installed-app PATH      installed/current SPIN.app; defaults to current app context or dist/SPIN.app
  --app-home PATH           app support root for rollback metadata; default: SPIN_APP_HOME or ~/Library/Application Support/SPIN
  --record-rollback         write rollback metadata under <app-home>/updates/
  --allow-ad-hoc            allow installing ad-hoc signed/test artifacts
  --allow-local-dev         allow installing local-dev app bundles
  --allow-production        allow production candidates after trust verification
  --force-channel           allow candidate channel to downgrade installed channel
  --json                    print machine-readable plan JSON
  -h, --help                show this help

Production installs require Developer ID/notary verification.`);
  process.exit(exitCode);
}

function fail(message) {
  console.error(`app-update failed: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = {
    dryRun: false,
    install: false,
    installedApp: '',
    appHome: process.env.SPIN_APP_HOME || path.join(os.homedir(), 'Library', 'Application Support', 'SPIN'),
    recordRollback: false,
    allowAdHoc: false,
    allowLocalDev: false,
    allowProduction: false,
    forceChannel: false,
    json: false,
    candidate: '',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--install') options.install = true;
    else if (arg === '--record-rollback') options.recordRollback = true;
    else if (arg === '--allow-ad-hoc') options.allowAdHoc = true;
    else if (arg === '--allow-local-dev') options.allowLocalDev = true;
    else if (arg === '--allow-production') options.allowProduction = true;
    else if (arg === '--force-channel') options.forceChannel = true;
    else if (arg === '--json') options.json = true;
    else if (arg === '--installed-app') {
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
  if (options.dryRun && options.install) fail('choose only one of --dry-run or --install');
  if (!options.dryRun && !options.install && !options.recordRollback) {
    fail('pass --dry-run, --install, or --record-rollback');
  }
  if (!options.candidate) usage(2);
  return options;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
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
  const fromResources = resolveAppFromResources(process.env.SPIN_APP_RESOURCES || '');
  if (fromResources) return fromResources;
  const distApp = path.join(ROOT, 'dist', 'SPIN.app');
  if (fs.existsSync(path.join(distApp, 'Contents', 'Resources', 'app', 'release-compat.json'))) return distApp;
  return '';
}

function requireManifest(app, label) {
  const manifestPath = path.join(app, 'Contents', 'Resources', 'app', 'release-compat.json');
  if (!fs.existsSync(manifestPath)) fail(`${label} compatibility manifest not found: ${manifestPath}`);
  return {
    app,
    manifestPath,
    manifest: readJson(manifestPath),
    manifestSha256: sha256(manifestPath),
  };
}

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    fail(`${command} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}

function runStatus(command, args) {
  return spawnSync(command, args, { encoding: 'utf8' });
}

function codesignDetails(app) {
  const result = runStatus('codesign', ['-dv', '--verbose=4', app]);
  const output = `${result.stdout || ''}${result.stderr || ''}`;
  const authorities = [];
  let teamIdentifier = '';
  let signature = '';
  let flags = '';
  for (const line of output.split(/\r?\n/)) {
    let match = line.match(/^Authority=(.*)$/);
    if (match) authorities.push(match[1]);
    match = line.match(/^TeamIdentifier=(.*)$/);
    if (match) teamIdentifier = match[1];
    match = line.match(/^Signature=(.*)$/);
    if (match) signature = match[1];
    match = line.match(/^CodeDirectory .* flags=.*\(([^)]*)\)/);
    if (match) flags = match[1];
  }
  return {
    ok: result.status === 0,
    output,
    authorities,
    teamIdentifier,
    signature,
    runtime: flags.split(',').includes('runtime'),
  };
}

function verifyCodeSignature(app, label) {
  if (process.platform !== 'darwin') return;
  const verify = runStatus('codesign', ['--verify', '--deep', '--strict', '--verbose=2', app]);
  if (verify.status !== 0) {
    const detail = (verify.stderr || verify.stdout || '').trim();
    fail(`${label} code signature verification failed${detail ? `: ${detail}` : ''}. Rebuild the app with scripts/build-app-proof.sh or use a checked release artifact.`);
  }
  const nested = path.join(app, 'Contents', 'Resources', 'SPIN.app');
  const nestedVerify = runStatus('codesign', ['--verify', '--strict', '--verbose=2', nested]);
  if (nestedVerify.status !== 0) {
    const detail = (nestedVerify.stderr || nestedVerify.stdout || '').trim();
    fail(`${label} nested SPIN app signature verification failed${detail ? `: ${detail}` : ''}`);
  }
}

function copyApp(source, destination) {
  fs.rmSync(destination, { recursive: true, force: true });
  if (process.platform === 'darwin') {
    run('ditto', [source, destination]);
    return;
  }
  fs.cpSync(source, destination, { recursive: true, preserveTimestamps: true });
}

function archiveApp(source, destination) {
  if (process.platform !== 'darwin') fail('SPIN.app rollback archives require macOS ditto');
  fs.rmSync(destination, { recursive: true, force: true });
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', source, destination]);

  const verifyRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-backup-check-'));
  try {
    run('ditto', ['-x', '-k', destination, verifyRoot]);
    const archivedApp = path.join(verifyRoot, path.basename(source));
    requireManifest(archivedApp, 'rollback backup');
  } finally {
    fs.rmSync(verifyRoot, { recursive: true, force: true });
  }
}

function restoreAppArchive(archive, destination) {
  const restoreRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-restore-'));
  try {
    run('ditto', ['-x', '-k', archive, restoreRoot]);
    const restoredApp = path.join(restoreRoot, 'SPIN.app');
    requireManifest(restoredApp, 'rollback restore');
    copyApp(restoredApp, destination);
  } finally {
    fs.rmSync(restoreRoot, { recursive: true, force: true });
  }
}

function extractCandidate(candidate) {
  const absolute = path.resolve(candidate);
  if (!fs.existsSync(absolute)) fail(`candidate not found: ${absolute}`);
  if (absolute.endsWith('.app')) {
    return { root: '', app: absolute, artifact: absolute, cleanup: () => {} };
  }
  if (absolute.endsWith('.dmg')) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-update-'));
    const mount = path.join(tmp, 'mount');
    const app = path.join(tmp, 'SPIN.app');
    fs.mkdirSync(mount, { recursive: true });
    run('hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mount, absolute]);
    try {
      copyApp(path.join(mount, 'SPIN.app'), app);
    } finally {
      run('hdiutil', ['detach', mount]);
    }
    if (!fs.existsSync(app)) fail(`candidate dmg did not contain SPIN.app: ${absolute}`);
    return {
      root: tmp,
      app,
      artifact: absolute,
      cleanup: () => fs.rmSync(tmp, { recursive: true, force: true }),
    };
  }
  if (!absolute.endsWith('.zip')) fail(`candidate must be a .zip/.dmg artifact or .app bundle: ${absolute}`);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'spin-app-update-'));
  run('ditto', ['-x', '-k', absolute, tmp]);
  const app = path.join(tmp, 'SPIN.app');
  if (!fs.existsSync(app)) fail(`candidate artifact did not contain SPIN.app: ${absolute}`);
  return {
    root: tmp,
    app,
    artifact: absolute,
    cleanup: () => fs.rmSync(tmp, { recursive: true, force: true }),
  };
}

function compareValues(before, after) {
  if (before === after) return 'unchanged';
  return `${before || 'missing'} -> ${after || 'missing'}`;
}

function channelDowngrade(installed, candidate) {
  const installedChannel = installed.release && installed.release.channel;
  const candidateChannel = candidate.release && candidate.release.channel;
  if (!(installedChannel in CHANNEL_RANK)) fail(`installed channel is unsupported: ${installedChannel}`);
  if (!(candidateChannel in CHANNEL_RANK)) fail(`candidate channel is unsupported: ${candidateChannel}`);
  return CHANNEL_RANK[candidateChannel] < CHANNEL_RANK[installedChannel];
}

function buildPlan(options, installedInfo, candidateInfo) {
  const installed = installedInfo.manifest;
  const candidate = candidateInfo.manifest;
  const rollbackFile = path.join(
    path.resolve(options.appHome),
    'updates',
    `rollback-${new Date().toISOString().replace(/[:.]/g, '-')}.json`,
  );
  return {
    action: options.install ? 'install' : 'plan-only',
    dryRun: options.dryRun,
    install: options.install,
    recordRollback: options.recordRollback,
    allowAdHoc: options.allowAdHoc,
    allowLocalDev: options.allowLocalDev,
    allowProduction: options.allowProduction,
    forceChannel: options.forceChannel,
    installed: {
      app: installedInfo.app,
      manifest: installedInfo.manifestPath,
      manifestSha256: installedInfo.manifestSha256,
      channel: installed.release && installed.release.channel,
      spinVersion: installed.runtime && installed.runtime.version,
      cmuxCommit: installed.cmux && installed.cmux.source && installed.cmux.source.commit,
      ompPackage: installed.omp && installed.omp.packageSpec,
      migrationDigest: installed.runtime && installed.runtime.migrationLevel && installed.runtime.migrationLevel.digest,
    },
    candidate: {
      artifact: candidateInfo.artifact,
      app: candidateInfo.app,
      manifest: candidateInfo.manifestPath,
      manifestSha256: candidateInfo.manifestSha256,
      channel: candidate.release && candidate.release.channel,
      spinVersion: candidate.runtime && candidate.runtime.version,
      cmuxCommit: candidate.cmux && candidate.cmux.source && candidate.cmux.source.commit,
      ompPackage: candidate.omp && candidate.omp.packageSpec,
      migrationDigest: candidate.runtime && candidate.runtime.migrationLevel && candidate.runtime.migrationLevel.digest,
    },
    changes: {
      channel: compareValues(installed.release && installed.release.channel, candidate.release && candidate.release.channel),
      spinVersion: compareValues(installed.runtime && installed.runtime.version, candidate.runtime && candidate.runtime.version),
      cmuxCommit: compareValues(
        installed.cmux && installed.cmux.source && installed.cmux.source.commit,
        candidate.cmux && candidate.cmux.source && candidate.cmux.source.commit,
      ),
      cmuxCliSha256: compareValues(installed.cmux && installed.cmux.cliSha256, candidate.cmux && candidate.cmux.cliSha256),
      ompPackage: compareValues(installed.omp && installed.omp.packageSpec, candidate.omp && candidate.omp.packageSpec),
      ompBinarySha256: compareValues(installed.omp && installed.omp.binarySha256, candidate.omp && candidate.omp.binarySha256),
      migrationDigest: compareValues(
        installed.runtime && installed.runtime.migrationLevel && installed.runtime.migrationLevel.digest,
        candidate.runtime && candidate.runtime.migrationLevel && candidate.runtime.migrationLevel.digest,
      ),
    },
    replaceableCode: REPLACEABLE_CODE,
    preservedState: PRESERVED_STATE,
    rollback: {
      metadataPath: rollbackFile,
      willWrite: options.recordRollback || options.install,
      appHome: path.resolve(options.appHome),
      // Keep every nested app bundle inside an archive so LaunchServices cannot
      // register the launcher or bundled cmux UI as another installed SPIN app.
      backupPath: path.join(path.resolve(options.appHome), 'updates', 'backups', `SPIN-${new Date().toISOString().replace(/[:.]/g, '-')}.spin-backup.zip`),
    },
    nextStep: options.install
      ? 'Installed app code replaced; rerun check-app-release or launch SPIN.app to validate runtime behavior.'
      : 'Use --install with the required channel allow flag to replace app-owned code.',
  };
}

function writeRollback(plan) {
  fs.mkdirSync(path.dirname(plan.rollback.metadataPath), { recursive: true });
  fs.writeFileSync(plan.rollback.metadataPath, `${JSON.stringify({
    createdAt: new Date().toISOString(),
    reason: 'SPIN.app update rollback metadata',
    installed: plan.installed,
    candidate: plan.candidate,
    backupPath: plan.rollback.backupPath,
    preservedState: plan.preservedState,
    replaceableCode: plan.replaceableCode,
  }, null, 2)}\n`);
}

function enforceInstallGates(options, candidateManifest) {
  const channel = candidateManifest.release && candidateManifest.release.channel;
  if (channel === 'production') {
    if (!options.allowProduction) {
      fail('candidate channel is production; pass --allow-production after Developer ID/notary verification is configured');
    }
    return;
  }
  if (channel === 'ad-hoc' && !options.allowAdHoc) {
    fail('candidate channel is ad-hoc; pass --allow-ad-hoc to install test artifacts');
  }
  if (channel === 'local-dev' && !options.allowLocalDev) {
    fail('candidate channel is local-dev; pass --allow-local-dev to install developer app bundles');
  }
}

function verifyProductionTrust(candidateApp, candidateManifest) {
  const release = candidateManifest.release || {};
  const signing = release.signing || {};
  const productionTrust = release.productionTrust || {};
  if (!signing.identity || signing.identity === '-' || signing.identity === 'unsigned') {
    fail('production candidate manifest is missing a Developer ID signing identity');
  }
  if (!String(signing.identity).includes('Developer ID Application')) {
    fail(`production candidate identity is not Developer ID Application: ${signing.identity}`);
  }
  if (!signing.teamId) {
    fail('production candidate manifest is missing Apple team id');
  }
  if (signing.hardenedRuntime !== true) {
    fail('production candidate manifest does not require hardened runtime');
  }
  if (signing.notarizationRequested !== true || productionTrust.requiresNotarization !== true) {
    fail('production candidate manifest does not require notarization');
  }
  verifyCodeSignature(candidateApp, 'production candidate');
  const details = codesignDetails(candidateApp);
  if (!details.ok) {
    fail(`production candidate signing details are unreadable: ${details.output.trim()}`);
  }
  if (!details.authorities.some((authority) => authority.includes('Developer ID Application'))) {
    fail('production candidate is not signed with a Developer ID Application certificate');
  }
  if (details.teamIdentifier !== signing.teamId) {
    fail(`production candidate team id mismatch: manifest=${signing.teamId} signature=${details.teamIdentifier || 'missing'}`);
  }
  if (!details.runtime) {
    fail('production candidate is not signed with hardened runtime');
  }
  const assess = runStatus('spctl', ['--assess', '--type', 'execute', '--verbose', candidateApp]);
  if (assess.status !== 0) {
    fail(`production candidate Gatekeeper assessment failed: ${(assess.stderr || assess.stdout || '').trim()}`);
  }
}

function installCandidate(plan, candidateApp) {
  const installedApp = plan.installed.app;
  const parent = path.dirname(installedApp);
  const stage = path.join(parent, `.SPIN.app.update-${process.pid}-${Date.now()}`);
  if (path.resolve(candidateApp) === path.resolve(installedApp)) {
    fail('candidate app and installed app are the same path');
  }
  fs.mkdirSync(path.dirname(plan.rollback.backupPath), { recursive: true });
  archiveApp(installedApp, plan.rollback.backupPath);
  writeRollback(plan);
  let replacementStarted = false;
  try {
    copyApp(candidateApp, stage);
    replacementStarted = true;
    fs.rmSync(installedApp, { recursive: true, force: true });
    fs.renameSync(stage, installedApp);
    run(process.execPath, [path.join(ROOT, 'scripts', 'app-compatibility.js'), 'verify', installedApp]);
    verifyCodeSignature(installedApp, 'installed app');
  } catch (error) {
    fs.rmSync(stage, { recursive: true, force: true });
    if (replacementStarted && fs.existsSync(plan.rollback.backupPath)) {
      fs.rmSync(installedApp, { recursive: true, force: true });
      restoreAppArchive(plan.rollback.backupPath, installedApp);
    }
    throw error;
  }
}

function printPlan(plan) {
  console.log('SPIN app update plan');
  console.log(`  installed app: ${plan.installed.app}`);
  console.log(`  candidate:     ${plan.candidate.artifact}`);
  console.log(`  channel:       ${plan.changes.channel}`);
  console.log(`  SPIN version:  ${plan.changes.spinVersion}`);
  console.log(`  cmux commit:   ${plan.changes.cmuxCommit}`);
  console.log(`  OMP package:   ${plan.changes.ompPackage}`);
  console.log(`  migration:     ${plan.changes.migrationDigest}`);
  console.log('');
  console.log('Replaceable app-owned code:');
  for (const item of plan.replaceableCode) console.log(`  - ${item}`);
  console.log('');
  console.log('Preserved user state:');
  for (const item of plan.preservedState) console.log(`  - ${item}`);
  console.log('');
  if (plan.rollback.willWrite) {
    console.log(`Rollback metadata written: ${plan.rollback.metadataPath}`);
    console.log(`Installed app backup: ${plan.rollback.backupPath}`);
  } else {
    console.log(`Rollback metadata: ${plan.rollback.metadataPath} (not written in dry run)`);
  }
  if (plan.install) console.log('Mode: install complete, app-owned code replaced');
  else console.log(`Mode: ${plan.dryRun ? 'dry run, no app code changed' : 'metadata only, no app code changed'}`);
}

const options = parseArgs(process.argv.slice(2));
const candidate = extractCandidate(options.candidate);
try {
  const installedAppInput = options.installedApp || defaultInstalledApp();
  if (!installedAppInput) fail('installed app not found; pass --installed-app or run from a SPIN.app/checkouted dist/SPIN.app context');
  const installedApp = path.resolve(installedAppInput);
  const installedInfo = requireManifest(installedApp, 'installed');
  const candidateInfo = requireManifest(candidate.app, 'candidate');
  run(process.execPath, [path.join(ROOT, 'scripts', 'app-compatibility.js'), 'verify', candidate.app]);
  verifyCodeSignature(candidate.app, 'candidate');
  if (channelDowngrade(installedInfo.manifest, candidateInfo.manifest) && !options.forceChannel) {
    fail(`candidate channel ${candidateInfo.manifest.release.channel} would downgrade installed channel ${installedInfo.manifest.release.channel}; pass --force-channel to acknowledge`);
  }
  if (options.install) {
    if (!options.installedApp && !resolveAppFromResources(process.env.SPIN_APP_RESOURCES || '')) {
      fail('--install requires --installed-app unless running from a SPIN.app bundle context');
    }
    enforceInstallGates(options, candidateInfo.manifest);
    if (candidateInfo.manifest.release && candidateInfo.manifest.release.channel === 'production') {
      verifyProductionTrust(candidate.app, candidateInfo.manifest);
    }
  }
  const plan = buildPlan(options, installedInfo, { ...candidateInfo, artifact: path.resolve(options.candidate) });
  if (options.install) installCandidate(plan, candidate.app);
  else if (options.recordRollback) writeRollback(plan);
  if (options.json) console.log(JSON.stringify(plan, null, 2));
  else printPlan(plan);
} finally {
  candidate.cleanup();
}
