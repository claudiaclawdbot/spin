const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), 'utf8');
}

const version = read('VERSION').trim();
const releaseNotesPath = `docs/releases/SPIN-${version}.md`;
const publicDocs = {
  readme: read('README.md'),
  site: read('docs/index.html'),
  install: read('docs/INSTALL_MACOS.md'),
  readiness: read('docs/PUBLIC_BETA_READINESS.md'),
  roadmap: read('docs/APP_ROADMAP.md'),
  release: read(releaseNotesPath),
};

test('public download surfaces match the source release version', () => {
  assert.match(publicDocs.readme, new RegExp(`releases/tag/v${version.replaceAll('.', '\\.')}`));
  assert.match(publicDocs.site, new RegExp(`releases/tag/v${version.replaceAll('.', '\\.')}`));
  assert.match(publicDocs.install, new RegExp(`releases/tag/v${version.replaceAll('.', '\\.')}`));

  for (const [name, contents] of Object.entries(publicDocs)) {
    const releaseTags = [...contents.matchAll(/releases\/tag\/v([^)"\s]+)/g)]
      .map((match) => match[1]);
    assert.ok(
      releaseTags.every((tag) => tag === version),
      `${name} contains a release tag that does not match ${version}`,
    );
  }
});

test('current release notes and download filenames match the source version', () => {
  assert.ok(fs.existsSync(path.join(root, releaseNotesPath)), `${releaseNotesPath} is missing`);
  assert.equal(read(releaseNotesPath).split(/\r?\n/, 1)[0], `# SPIN for Mac ${version}`);

  assert.match(publicDocs.site, new RegExp(`docs/releases/SPIN-${version.replaceAll('.', '\\.')}\\.md`));
  assert.match(publicDocs.readiness, new RegExp(`releases/SPIN-${version.replaceAll('.', '\\.')}\\.md`));
  assert.ok(
    publicDocs.install.includes(`SPIN-${version}-macos-arm64.dmg`),
    'install guide does not name the current DMG',
  );
  assert.ok(
    publicDocs.install.includes(`SPIN-${version}-macos-arm64.dmg.sha256`),
    'install guide does not name the current checksum file',
  );
  assert.ok(
    publicDocs.roadmap.includes(`\`${version}\` versioning`),
    'app roadmap does not name the current beta version',
  );
});

test('public Mac requirements match the outer app minimum system version', () => {
  const appInfo = read('app/macos/Info.plist');
  const minimumMatch = appInfo.match(
    /<key>LSMinimumSystemVersion<\/key>\s*<string>([^<]+)<\/string>/,
  );
  assert.ok(minimumMatch, 'outer app Info.plist omits LSMinimumSystemVersion');
  const requirement = `macOS ${minimumMatch[1]} or later`;
  for (const [name, contents] of Object.entries({
    readme: publicDocs.readme,
    site: publicDocs.site,
    install: publicDocs.install,
    release: publicDocs.release,
  })) {
    assert.ok(contents.includes(requirement), `${name} must state "${requirement}"`);
  }
});

test('public Mac surfaces preserve the ad-hoc signing disclosure', () => {
  for (const [name, contents] of Object.entries({
    readme: publicDocs.readme,
    site: publicDocs.site,
    install: publicDocs.install,
  })) {
    assert.match(contents, /ad-hoc signed/i, `${name} omits ad-hoc signing`);
    assert.match(contents, /not Apple-notarized/i, `${name} omits notarization status`);
  }
});

test('README and product site do not use em dashes', () => {
  assert.doesNotMatch(publicDocs.readme, /—/u);
  assert.doesNotMatch(publicDocs.site, /—/u);
});
