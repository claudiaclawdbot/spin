#!/usr/bin/env node
/* Build and verify the SPIN.app release compatibility manifest. */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const command = process.argv[2];
const appArg = process.argv[3];

function fail(message) {
  console.error(`app compatibility ${command || 'check'} failed: ${message}`);
  process.exit(1);
}

function usage() {
  console.error('Usage: scripts/app-compatibility.js write|verify SPIN.app');
  process.exit(2);
}

if (!['write', 'verify'].includes(command) || !appArg) usage();

const appPath = path.resolve(appArg);
const contentsDir = path.join(appPath, 'Contents');
const resourcesDir = path.join(contentsDir, 'Resources');
const runtimeDir = path.join(resourcesDir, 'runtime');
const manifestPath = path.join(resourcesDir, 'app', 'release-compat.json');
const repoRoot = process.env.SPIN_COMPAT_ROOT
  ? path.resolve(process.env.SPIN_COMPAT_ROOT)
  : path.resolve(__dirname, '..');

function exists(file) {
  return fs.existsSync(file);
}

function readText(file) {
  return fs.readFileSync(file, 'utf8');
}

function readTrim(file, fallback = null) {
  if (!exists(file)) return fallback;
  const value = readText(file).trim();
  return value || fallback;
}

function readJson(file, fallback = null) {
  if (!exists(file)) return fallback;
  return JSON.parse(readText(file));
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function sha256String(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function relFromResources(file) {
  return path.relative(resourcesDir, file).split(path.sep).join('/');
}

function plistString(plist, key) {
  if (!exists(plist)) return null;
  const xml = readText(plist);
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(`<key>${escaped}</key>\\s*<string>([\\s\\S]*?)</string>`));
  if (!match) return null;
  return match[1]
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function gitCommit(dir) {
  if (!exists(dir)) return null;
  const result = spawnSync('git', ['-C', dir, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (result.status !== 0) return null;
  return result.stdout.trim() || null;
}

function detectArchs(file) {
  if (!exists(file)) return [];
  const result = spawnSync('lipo', ['-archs', file], { encoding: 'utf8' });
  if (result.status === 0 && result.stdout.trim()) {
    return result.stdout.trim().split(/\s+/).filter(Boolean).sort();
  }
  const arch = process.arch === 'x64' ? 'x86_64' : process.arch;
  return [arch];
}

function executableVersion(file, args) {
  if (!exists(file)) return null;
  const result = spawnSync(file, args, {
    encoding: 'utf8',
    env: { HOME: process.env.HOME || '/tmp', PATH: '/usr/bin:/bin:/usr/sbin:/sbin' },
  });
  if (result.status !== 0) return null;
  return result.stdout.trim().split(/\r?\n/)[0] || null;
}

function boolFromEnv(name, fallback = false) {
  if (!Object.prototype.hasOwnProperty.call(process.env, name)) return fallback;
  return process.env[name] === '1' || process.env[name] === 'true';
}

function inferTeamId(identity) {
  if (!identity) return null;
  const match = String(identity).match(/\(([A-Z0-9]{5,})\)\s*$/);
  return match ? match[1] : null;
}

function migrationLevel() {
  const migrationsDir = path.join(runtimeDir, 'scripts', 'migrations');
  const scripts = exists(migrationsDir)
    ? fs.readdirSync(migrationsDir)
      .filter((name) => name.endsWith('.sh'))
      .sort()
      .map((name) => {
        const file = path.join(migrationsDir, name);
        return {
          id: name,
          path: relFromResources(file),
          sha256: sha256(file),
        };
      })
    : [];
  return {
    directory: 'Resources/runtime/scripts/migrations',
    stateDirectory: 'Resources/runtime/org/.spin-migrations',
    count: scripts.length,
    latest: scripts.length ? scripts[scripts.length - 1].id : null,
    digest: sha256String(JSON.stringify(scripts)),
    scripts,
  };
}

function firstNativeAddonFromMetadata(metadata) {
  const outputs = Array.isArray(metadata && metadata.outputs) ? metadata.outputs : [];
  return outputs.find((item) => item.kind === 'native-addon' && /\/pi_natives\..+\.node$/.test(item.path)) || null;
}

function buildManifest(previous = {}) {
  if (!exists(appPath)) fail(`missing app bundle: ${appPath}`);
  const appInfo = path.join(contentsDir, 'Info.plist');
  const cmuxInfo = path.join(resourcesDir, 'SPIN.app', 'Contents', 'Info.plist');
  const appManifestPath = path.join(resourcesDir, 'app', 'spin-app.json');
  const ompVendorPath = path.join(resourcesDir, 'app', 'omp-vendor.json');
  const ompLockPath = path.join(resourcesDir, 'app', 'omp-bun.lock');
  const cmuxBin = path.join(resourcesDir, 'bin', 'cmux');
  const ompBin = path.join(resourcesDir, 'bin', 'omp');
  const spinAgentBin = path.join(resourcesDir, 'bin', 'spin-agent');
  const runtimeVersionPath = path.join(runtimeDir, 'VERSION');
  const appManifest = readJson(appManifestPath, {});
  const ompVendor = readJson(ompVendorPath, null);
  const nativeFromVendor = firstNativeAddonFromMetadata(ompVendor);
  const nativeName = nativeFromVendor ? path.basename(nativeFromVendor.path) : null;
  const nativePath = nativeName ? path.join(resourcesDir, 'bin', nativeName) : null;
  const previousRelease = previous.release || {};
  const previousSigning = previousRelease.signing || {};
  const previousBuild = previous.build || {};
  const previousBuildMode = previousBuild.mode && previousBuild.mode !== 'unknown' ? previousBuild.mode : 'prebuilt';
  const previousCmux = previous.cmux || {};
  const cmuxSource = previousCmux.source || {};
  const runtimeVersion = readTrim(runtimeVersionPath, 'unknown');
  const cmuxSourceCommit = process.env.SPIN_CMUX_SOURCE_COMMIT
    || gitCommit(path.join(repoRoot, 'app', 'upstream', 'cmux'))
    || cmuxSource.commit
    || null;
  const ompSourceCommit = ompVendor && Object.prototype.hasOwnProperty.call(ompVendor, 'upstreamCommit')
    ? ompVendor.upstreamCommit
    : null;
  const cmuxVersion = executableVersion(cmuxBin, ['version']);
  const ompVersion = executableVersion(ompBin, ['--version']);
  const channel = process.env.SPIN_RELEASE_CHANNEL || previousRelease.channel || 'local-dev';
  const signingIdentity = Object.prototype.hasOwnProperty.call(process.env, 'SPIN_CODESIGN_IDENTITY')
    ? process.env.SPIN_CODESIGN_IDENTITY
    : previousSigning.identity || (channel === 'local-dev' ? 'unsigned' : '-');
  const teamId = process.env.SPIN_APPLE_TEAM_ID || inferTeamId(signingIdentity) || previousSigning.teamId || null;
  const hardenedRuntime = Object.prototype.hasOwnProperty.call(process.env, 'SPIN_CODESIGN_HARDENED')
    ? boolFromEnv('SPIN_CODESIGN_HARDENED')
    : typeof previousSigning.hardenedRuntime === 'boolean'
      ? previousSigning.hardenedRuntime
      : Boolean(signingIdentity && signingIdentity !== '-' && signingIdentity !== 'unsigned');
  const notarizationRequested = Object.prototype.hasOwnProperty.call(process.env, 'SPIN_NOTARIZE')
    ? boolFromEnv('SPIN_NOTARIZE')
    : Boolean(previousSigning.notarizationRequested);

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    product: {
      name: 'SPIN',
      bundleIdentifier: plistString(appInfo, 'CFBundleIdentifier'),
      version: plistString(appInfo, 'CFBundleShortVersionString'),
      build: plistString(appInfo, 'CFBundleVersion'),
      minimumMacOS: plistString(appInfo, 'LSMinimumSystemVersion'),
      appManifestPath: 'Resources/app/spin-app.json',
      appManifestSha256: exists(appManifestPath) ? sha256(appManifestPath) : null,
      entrypoint: appManifest.firstLaunch && appManifest.firstLaunch.entrypoint ? appManifest.firstLaunch.entrypoint : null,
    },
    release: {
      channel,
      signing: {
        identity: signingIdentity,
        teamId,
        hardenedRuntime,
        notarizationRequested,
        notaryProfileConfigured: Boolean(process.env.SPIN_NOTARY_PROFILE || previousSigning.notaryProfileConfigured),
      },
      productionTrust: {
        requiresDeveloperId: channel === 'production',
        requiresNotarization: channel === 'production',
        requiresGatekeeperAssessment: channel === 'production',
      },
    },
    build: {
      mode: process.env.SPIN_APP_BUILD_MODE || previousBuildMode,
      hostPlatform: process.platform,
      hostArch: process.arch === 'x64' ? 'x86_64' : process.arch,
      appArchs: detectArchs(cmuxBin),
    },
    runtime: {
      path: 'Resources/runtime',
      version: runtimeVersion,
      versionFileSha256: exists(runtimeVersionPath) ? sha256(runtimeVersionPath) : null,
      migrationLevel: migrationLevel(),
      stateModel: 'plain-file-org-v1',
      refreshPolicy: {
        replaceable: ['Resources/runtime except org/', 'Resources/runtime except logs/'],
        preserved: ['Writable runtime org/ except org/.spin-version', 'Writable runtime logs/'],
        refreshedMetadata: ['Writable runtime org/.spin-version'],
      },
    },
    cmux: {
      role: 'ui-engine',
      bundlePath: 'Resources/SPIN.app',
      bundleIdentifier: plistString(cmuxInfo, 'CFBundleIdentifier'),
      appVersion: plistString(cmuxInfo, 'CFBundleShortVersionString'),
      appBuild: plistString(cmuxInfo, 'CFBundleVersion'),
      minimumMacOS: plistString(cmuxInfo, 'LSMinimumSystemVersion'),
      cliPath: 'Resources/bin/cmux',
      cliSha256: exists(cmuxBin) ? sha256(cmuxBin) : null,
      cliArchs: detectArchs(cmuxBin),
      version: cmuxVersion,
      source: {
        upstream: 'https://github.com/manaflow-ai/cmux.git',
        path: 'app/upstream/cmux',
        commit: cmuxSourceCommit,
      },
    },
    omp: {
      role: 'agent-engine',
      binaryPath: 'Resources/bin/omp',
      binarySha256: exists(ompBin) ? sha256(ompBin) : null,
      versionOutput: ompVersion,
      agentAliasPath: 'Resources/bin/spin-agent',
      agentAliasSha256: exists(spinAgentBin) ? sha256(spinAgentBin) : null,
      vendorMetadataPath: exists(ompVendorPath) ? 'Resources/app/omp-vendor.json' : null,
      vendorMetadataSha256: exists(ompVendorPath) ? sha256(ompVendorPath) : null,
      package: ompVendor ? ompVendor.package : null,
      packageVersion: ompVendor ? ompVendor.version : null,
      packageSpec: ompVendor ? ompVendor.packageSpec : null,
      upstreamCommit: ompSourceCommit,
      platformTag: ompVendor && ompVendor.build ? ompVendor.build.platformTag || null : null,
      lockfile: exists(ompLockPath)
        ? {
            path: 'Resources/app/omp-bun.lock',
            sha256: sha256(ompLockPath),
          }
        : null,
      nativeAddon: nativePath && exists(nativePath)
        ? {
            path: `Resources/bin/${nativeName}`,
            sha256: sha256(nativePath),
          }
        : null,
      vendorOutputs: ompVendor && Array.isArray(ompVendor.outputs) ? ompVendor.outputs : [],
    },
    compatibility: {
      updateStateModel: 'plain-file-org-v1',
      updateChannels: ['local-dev', 'ad-hoc', 'production'],
      rollbackBoundary: 'Runtime code and the SPIN-owned org/.spin-version marker may refresh; all other org/ state and logs/ are preserved.',
    },
  };
}

function snapshot(manifest) {
  return {
    schemaVersion: manifest.schemaVersion,
    product: manifest.product,
    build: {
      appArchs: manifest.build && manifest.build.appArchs,
    },
    runtime: manifest.runtime,
    cmux: {
      role: manifest.cmux && manifest.cmux.role,
      bundlePath: manifest.cmux && manifest.cmux.bundlePath,
      bundleIdentifier: manifest.cmux && manifest.cmux.bundleIdentifier,
      appVersion: manifest.cmux && manifest.cmux.appVersion,
      appBuild: manifest.cmux && manifest.cmux.appBuild,
      minimumMacOS: manifest.cmux && manifest.cmux.minimumMacOS,
      cliPath: manifest.cmux && manifest.cmux.cliPath,
      cliSha256: manifest.cmux && manifest.cmux.cliSha256,
      cliArchs: manifest.cmux && manifest.cmux.cliArchs,
      version: manifest.cmux && manifest.cmux.version,
    },
    omp: manifest.omp,
    compatibility: manifest.compatibility,
  };
}

function diff(a, b, prefix = '') {
  const problems = [];
  if (JSON.stringify(a) === JSON.stringify(b)) return problems;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) || Array.isArray(b)) {
    problems.push(`${prefix || 'value'} expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
    return problems;
  }
  const keys = Array.from(new Set([...Object.keys(a), ...Object.keys(b)])).sort();
  for (const key of keys) {
    problems.push(...diff(a[key], b[key], prefix ? `${prefix}.${key}` : key));
    if (problems.length >= 12) break;
  }
  return problems;
}

if (command === 'write') {
  const previous = readJson(manifestPath, {});
  const manifest = buildManifest(previous);
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`wrote ${manifestPath}`);
  process.exit(0);
}

const recorded = readJson(manifestPath, null);
if (!recorded) fail(`missing compatibility manifest: ${manifestPath}`);
const expected = buildManifest(recorded);
const problems = diff(snapshot(recorded), snapshot(expected));
if (problems.length) {
  fail(`manifest does not match bundled app:\n  - ${problems.join('\n  - ')}`);
}
if (!recorded.release || !['local-dev', 'ad-hoc', 'production'].includes(recorded.release.channel)) {
  fail(`unsupported release channel: ${recorded.release && recorded.release.channel}`);
}
if (!recorded.build || typeof recorded.build.mode !== 'string' || !recorded.build.mode) {
  fail('missing build mode');
}
console.log(`compatibility manifest ok: ${manifestPath}`);
