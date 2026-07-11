# SPIN Self-Contained App Track

SPIN is moving toward a macOS app bundle where SPIN is the product and cmux/OMP
are internal foundations.

## Product Shape

- `SPIN.app` is the visible user-facing app.
- The cmux fork supplies the native terminal, browser, workspace, split-pane,
  sidebar, notification, and socket-control UI engine.
- The OMP/Pi fork supplies the internal coding-agent runtime.
- The current SPIN runtime supplies plain-file org state, approvals, jobs,
  receipts, project floors, and the `spin`/`org` CLI companion.

Users should not install `cmux` or `omp` separately once a release bundle ships.
They may still need normal developer tools, repositories, model/provider
accounts, and credentials.

## Repository Layout

```text
app/       SPIN app shell, cmux config/sidebar assets, macOS bundle templates
agent/     OMP/Pi-derived agent runtime home
runtime/   runtime migration notes; current runtime remains in scripts/ and org/
assets/    branding assets used by app packaging
licenses/  third-party notices for app releases
```

## Runtime Resolution

Shell and Node entrypoints now prefer bundled binaries before PATH:

1. `SPIN_CMUX_BIN` / `SPIN_OMP_BIN`
2. `SPIN_APP_RESOURCES/bin/<tool>`
3. `SPIN_INTERNAL_BIN_DIR/<tool>`
4. repo-local `vendor/bin/<tool>`
5. the user's normal PATH

That lets developer checkouts keep using installed tools while the packaged app
uses its internal copies.

`scripts/check-app-release.sh` verifies this contract with user PATH entries
removed: shell and Node runtime probes must resolve bundled `cmux`, `omp`, and
`spin-agent` from `SPIN.app/Contents/Resources/bin`.

## App Health And OMP Setup

SPIN owns app/runtime health checks, not OMP provider onboarding:

```bash
scripts/spin app-health
scripts/spin app-health --json
scripts/spin doctor
scripts/spin omp-setup
```

`spin app-health --json` reports bundled binary resolution, writable runtime
seeding, app bundle paths, local `git`/shell/toolchain availability, and OMP
setup readiness. It reports provider environment variable names only, never
values. `spin omp-setup` execs OMP's own `omp setup` wizard so provider/account
configuration remains inside OMP.

First-run `spin init` shows the app health report and offers to launch OMP setup.
The cmux dock includes Health, Updates, and OMP Setup controls that call the same
commands.

## OMP/Pi Vendoring

Release OMP input is generated from a pinned npm package, not copied from a
developer-installed `omp`:

```bash
scripts/vendor-app-deps.sh --omp-only
```

That command vendors the OMP version pinned in `agent/vendor/omp/package.json`, writes
`agent/vendor/omp/bun.lock`, compiles `vendor/bin/omp` with Bun, copies the
matching `vendor/bin/pi_natives.<platform>.node` addon, and writes
`agent/vendor/omp/metadata.json` with npm integrity plus lockfile, binary, and
native addon hashes. Bun is a build-time dependency only; the packaged app runs
the compiled `omp` binary and bundled native addon without requiring global
`bun` or global `omp`.

## Branding Assets

The app icon source is `assets/branding/spin-icon.svg`, the fidget-spinner mark
from the top of the SPIN GitHub Pages site. On macOS, generate the release icon
with:

```bash
scripts/build-app-icon.sh
```

That writes `assets/branding/SPIN.icns`. Packaging copies it to
`SPIN.app/Contents/Resources/SPIN.icns` and stamps the same icon into the
bundled cmux-derived UI app as `Resources/SPIN.app/Contents/Resources/AppIcon.icns`.
The source cmux build product under `app/upstream/cmux/build-spin/` is also
stamped after Xcode builds it; `scripts/build-app-proof.sh --source-cmux`
registers the packaged `dist/SPIN.app` and unregisters the transient Xcode build
product to reduce duplicate app entries during development.

## Packaging

Developer app bundle:

```bash
SPIN_CMUX_APP_SOURCE=/path/to/source-built/SPIN.app \
SPIN_CMUX_BIN_SOURCE=/path/to/cmux-or-SPIN \
SPIN_OMP_BIN_SOURCE=/path/to/omp \
  scripts/package-macos-app.sh

scripts/check-app-release.sh dist/SPIN.app
```

For app-track status and bounded next steps, see
[APP_ROADMAP](APP_ROADMAP.md).

Bounded proof app with real bundled cmux/OMP:

```bash
scripts/build-app-proof.sh
```

That command:

- stages the installed cmux app at `SPIN.app/Contents/Resources/SPIN.app`;
- bundles real `cmux` and the vendored `vendor/bin/omp` under `Resources/bin/`;
- runs `scripts/check-app-release.sh dist/SPIN.app`.

Completion for the binary-input proof means `scripts/build-app-proof.sh` exits 0.
If `vendor/bin/omp` is missing, run `scripts/vendor-app-deps.sh --omp-only`.
A one-off global `omp` input is allowed only when
`SPIN_ALLOW_GLOBAL_OMP_INPUT=1` is set.

Full Xcode is only needed for the source-built/rebranded cmux fork proof:

```bash
scripts/build-app-proof.sh --source-cmux
```

That command:

- builds the SPIN-branded cmux fork from source;
- stages the source-built cmux app at `SPIN.app/Contents/Resources/SPIN.app`;
- records the source-built cmux-compatible CLI output, currently named `SPIN`,
  and packages it internally as `Resources/bin/cmux`;
- bundles OMP/Pi from `vendor/bin/omp` by default, plus the matching native addon
  and vendor metadata;
- runs release checks with `SPIN_REQUIRE_BRANDED_CMUX_APP=1` and
  `SPIN_REQUIRE_VENDORED_OMP=1`, including bundled binary resolution with user
  PATH entries removed.

If the Mac App Store requires Apple ID or admin interaction to install Xcode,
complete that prompt and rerun the source-cmux command.

Upstream source/package fetch for fork work:

```bash
scripts/vendor-app-deps.sh
```

Use `scripts/vendor-app-deps.sh --cmux-only` to refresh only the cmux source
checkout, or `scripts/vendor-app-deps.sh --omp-only` to rebuild only the OMP/Pi
release input.

Apply the SPIN overlay to a cmux checkout:

```bash
scripts/apply-cmux-spin-overlay.sh

cd app/upstream/cmux
xcodebuild -workspace cmux.xcworkspace -scheme cmux -configuration Release -derivedDataPath build
```

The overlay keeps the fork small and repeatable: it patches app identity,
bundle IDs, auth callback schemes, permission strings, and installs SPIN's
default cmux config/sidebar/dock assets into `Resources/spin/`.

Unsigned universal build command:

```bash
cd app/upstream/cmux
CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Release -derivedDataPath build-universal \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath .spm-cache \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

The package script stages:

- `SPIN.app/Contents/MacOS/SPIN`
- `SPIN.app/Contents/Resources/runtime`
- `SPIN.app/Contents/Resources/SPIN.app` as the bundled cmux UI app
- `SPIN.app/Contents/Resources/SPIN.icns` as the visible app icon
- `SPIN.app/Contents/Resources/bin/cmux`
- `SPIN.app/Contents/Resources/bin/omp`
- `SPIN.app/Contents/Resources/bin/pi_natives.<platform>.node`
- `SPIN.app/Contents/Resources/bin/spin-agent` as a SPIN-branded alias to OMP
- `SPIN.app/Contents/Resources/app/omp-vendor.json`
- `SPIN.app/Contents/Resources/app/omp-bun.lock`
- SPIN-branded cmux config, sidebar, dock controls, branding assets, and notices.

At runtime, the launcher copies the bundled seed runtime into
`~/Library/Application Support/SPIN/runtime` and runs from that writable copy.
On first launch, `spin app-launch` opens a `SPIN Onboarding` cmux workspace that
runs `spin init`; after onboarding it starts the normal Coordinator floor.

The writable runtime is split between replaceable app code and user state:

- replaceable code comes from `SPIN.app/Contents/Resources/runtime`;
- persistent user state lives under the seeded runtime's `org/` tree;
- runtime logs live under the seeded runtime's `logs/` tree;
- `.spin-onboarded` in `org/` controls whether app launch routes to onboarding
  or normal `spin up`;
- remembered cmux workspace refs live in `org/OMP_HARNESS.json` and are treated
  as user state, not bundle-owned defaults.

On every launch, the wrapper refreshes app-owned runtime code while preserving
`org/` and `logs/`. This matters for same-version hotfixes: a corrected app
bundle must not keep running stale seeded scripts from
`~/Library/Application Support/SPIN/runtime`. `scripts/check-app-release.sh`
proves this with a fresh `SPIN_APP_HOME`: first launch routes to onboarding,
relaunch routes to `spin up`, and onboarding state, workspace refs, approvals,
queue entries, receipts, and logs survive runtime refresh.

## Compatibility Manifest

Each app bundle carries an app/runtime compatibility manifest:

```text
SPIN.app/Contents/Resources/app/release-compat.json
```

`scripts/app-compatibility.js write SPIN.app` records:

- SPIN runtime `VERSION`;
- runtime migration level from `Resources/runtime/scripts/migrations/*.sh`;
- release channel: `local-dev`, `ad-hoc`, or `production`;
- build mode, such as `source-cmux`, `binary-cmux`, or `prebuilt`;
- bundled cmux app bundle id, cmux-compatible CLI version, arch, and SHA-256;
- cmux upstream source path and commit when available at build time;
- bundled OMP package, package version, vendor metadata hash, lockfile hash,
  binary hash, native addon hash, and upstream commit;
- the state boundary: runtime code is replaceable, while `org/` and `logs/`
  are preserved user state.

`scripts/package-macos-app.sh` writes the manifest during app staging.
`scripts/package-macos-release.sh` regenerates it after signing bundled binaries
so release artifacts verify the signed bytes. `scripts/check-app-release.sh`
fails if the manifest does not match the bundled runtime, cmux CLI, OMP binary,
OMP native addon, lockfile, app manifest, or migration level.

Update channels are intentionally narrow:

- `local-dev`: mutable developer builds from this checkout. These are not
  user-distribution artifacts.
- `ad-hoc`: checked unsigned/ad-hoc artifacts from `scripts/release-macos.sh` or
  the manual macOS artifact workflow. These are the current open-source beta
  distribution artifacts.
- `production`: optional higher-trust artifacts if Developer ID/notarization is
  added later. Production builds must not be replaced by `ad-hoc` or `local-dev`
  builds without an explicit force path in a future updater.

Rollback policy follows the same boundary as launcher refresh: app-managed code
can be replaced, but provider credentials, model account state, `org/`, logs,
approvals, receipts, and remembered cmux workspace refs remain user state. A
future app updater should read the installed and candidate compatibility
manifests first, write rollback metadata, then replace only app-owned code.

## App Update Planning

Checkpoint 16 added the planning surface for app-managed updates:

```bash
scripts/spin app-update --dry-run dist/release/SPIN-*-macos-*.zip
```

The command extracts the candidate artifact, reads its
`Resources/app/release-compat.json`, compares it to the installed/current app
manifest, verifies the candidate manifest against bundled files, and prints:

- installed app path and candidate artifact path;
- channel, SPIN runtime version, cmux source commit, OMP package, and migration
  digest changes;
- app-owned code that a future updater may replace;
- user state that must be preserved;
- rollback metadata path.

By default, `spin app-update` refuses to move from a higher-trust channel to a
lower-trust channel, such as `production` to `ad-hoc`. Use `--force-channel` only
when intentionally testing a downgrade. `--record-rollback` writes rollback
metadata under `<app-home>/updates/` without replacing app code.

Checkpoint 17 adds the first opt-in app-code replacement path for non-production
artifacts:

```bash
scripts/spin app-update --install --allow-ad-hoc \
  --installed-app /path/to/SPIN.app \
  dist/release/SPIN-*-macos-*.zip
```

The install path:

- requires `--install`;
- requires `--installed-app` unless running from inside a packaged SPIN.app
  context;
- requires `--allow-ad-hoc` for ad-hoc artifacts and `--allow-local-dev` for
  local-dev app bundles;
- requires `--allow-production` for production candidates and then verifies
  Developer ID identity, Apple team id, hardened runtime intent, notarization
  intent, code signature, and Gatekeeper assessment;
- backs up the replaced app as a non-launchable `.spin-backup` directory under
  `<app-home>/updates/backups/`, avoiding duplicate LaunchServices app entries;
- writes rollback metadata under `<app-home>/updates/`;
- stages the candidate app before replacing the installed app path;
- verifies the installed app compatibility manifest after replacement.

Production update installs fail closed unless the candidate is a real Developer
ID signed/notarized artifact. Local/ad-hoc installs remain explicitly separate
through `--allow-ad-hoc` and `--allow-local-dev`.

Source builds also fail closed on dependency identity. The cmux commit is pinned
in `app/spin-app.json`; `scripts/vendor-app-deps.sh` fetches and detaches to that
exact commit before applying the SPIN overlay. `SPIN_CMUX_COMMIT` is an explicit
release-engineering override, not a floating default.

Checkpoint 20 adds the user-facing wrapper around that checked mechanical path:

```bash
scripts/spin app-updates
scripts/spin app-updates --check --candidate dist/release/SPIN-*-macos-*.zip
scripts/spin app-updates --install --yes --allow-test-builds \
  --candidate dist/release/SPIN-*-macos-*.zip \
  --installed-app /path/to/SPIN.app
```

`spin app-updates` discovers a local candidate from `--candidate`,
`SPIN_APP_UPDATE_CANDIDATE`, `SPIN_UPDATE_ARTIFACT`, or the newest
`SPIN-*-macos-*` zip/DMG in `SPIN_RELEASE_DIR`/`dist/release`. It prints the
installed and candidate app versions/channels, then delegates the actual check or
install to `spin app-update`. Installs require `--yes` plus the channel-specific
allow flag: `--allow-test-builds` for ad-hoc artifacts, `--allow-local-dev` for
developer bundles, and `--allow-production` for production artifacts after
trust verification.

The cmux dock Updates control runs `scripts/spin app-updates`, which is safe when
no candidate is available: it reports current app state and exits without
changing app code. This still does not fetch a remote update feed or run a
background auto-updater; it is the user-facing surface over the checked local
artifact updater.

## Release Artifact

Run the full bounded macOS release proof with:

```bash
scripts/release-macos.sh --source-cmux
```

That command vendors OMP/Pi if needed, builds the SPIN-branded cmux fork, stages
`dist/SPIN.app`, enforces the branded cmux and vendored OMP contract, signs and
packages the app, checks installed-app first launch/relaunch behavior, reports
signing readiness, and prints the artifact path, checksum, and manifest path.

For an already-built local bundle, rerun packaging and installed-app checks with:

```bash
scripts/release-macos.sh --skip-build --skip-vendor --app dist/SPIN.app
```

The manual GitHub Actions workflow `.github/workflows/macos-app.yml` runs the
same source-cmux release path on `macos-26` and uploads the checked ad-hoc zip,
DMG, `.sha256`, and `.manifest` files as one artifact.

The lower-level release packaging command is still available when you only need
to package a checked bundle:

```bash
scripts/package-macos-release.sh dist/SPIN.app
```

The release script:

- reruns `scripts/check-app-release.sh` on the source app;
- stages a copy so `dist/SPIN.app` is not mutated;
- ad-hoc signs by default;
- signs the outer app, bundled cmux app, bundled `cmux`, bundled `omp`,
  `spin-agent`, and OMP native addons;
- regenerates `Resources/app/release-compat.json` after signing inner binaries;
- creates `dist/release/SPIN-<version>-macos-<arch>.zip` or `.dmg`;
- writes matching `.sha256` and `.manifest` files, including the compatibility
  manifest hash;
- extracts the artifact and reruns the app release contract against the extracted
  signed app.

## Open-Source Tester Release

SPIN can publish checked open-source beta builds without Apple Developer ID.
These are ad-hoc signed, not notarized, and may show Gatekeeper warnings, but
they are the current public Mac distribution path when paired with source,
checksums, and license notices.

Prepare the GitHub release assets and release notes with:

```bash
SPIN_RELEASE_FORMAT=dmg scripts/release-macos.sh --source-cmux
scripts/prepare-open-source-release.sh --artifact dist/release/SPIN-*-macos-*.dmg
```

or, for an already-created artifact:

```bash
scripts/spin app-release-notes --artifact dist/release/SPIN-*-macos-*.zip
scripts/spin app-release-notes --artifact dist/release/SPIN-*-macos-*.dmg
```

That writes:

```text
dist/release/SPIN-<version>-macos-<arch>.dmg
dist/release/SPIN-<version>-macos-<arch>.dmg.sha256
dist/release/SPIN-<version>-macos-<arch>.manifest
dist/release/SPIN-<version>-macos-<arch>-open-source-tester-notes.md
dist/release/SPIN-<version>-cmux-corresponding-source-<commit>.tar.gz
dist/release/SPIN-<version>-cmux-corresponding-source-<commit>.tar.gz.sha256
```

The tester release notes include checksum verification, install steps, the
Gatekeeper/quarantine fallback, bundled cmux/OMP explanation, and GPL-compatible
license posture. The matching cmux source asset contains the exact source and
SPIN overlay used by the bundled GPL component, without generated build caches.
See [OPEN_SOURCE_TESTER_RELEASE](OPEN_SOURCE_TESTER_RELEASE.md).

After creating the artifact, prove installed-app launch behavior with:

```bash
scripts/check-installed-app.sh dist/release/SPIN-*-macos-*.zip
scripts/check-installed-app.sh dist/release/SPIN-*-macos-*.dmg
```

That script extracts the artifact into a temporary Applications-like directory,
verifies the signed app contract, then runs `SPIN.app/Contents/MacOS/SPIN` from
a clean `SPIN_APP_HOME`. For deterministic automation it uses a controlled copy
with bundled test cmux/OMP shims, proving first launch seeds the writable
runtime, opens the `SPIN Onboarding` workspace through the bundled cmux-compatible
CLI, avoids global cmux/OMP shims, and routes relaunch to `spin up` after
`.spin-onboarded`.

Optional Developer ID/notarization signing is environment-driven:

```bash
SPIN_CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
SPIN_CODESIGN_HARDENED=1 \
SPIN_CMUX_ENTITLEMENTS=/path/to/cmux.entitlements \
SPIN_NOTARIZE=1 \
SPIN_NOTARY_PROFILE=spin-notary \
scripts/release-macos.sh --production --source-cmux
```

OMP loads a bundled native addon, so hardened-runtime production signing must
give the OMP executable library-validation permission. The release script
generates the minimal OMP entitlement automatically when hardened signing is
enabled, or accepts `SPIN_OMP_ENTITLEMENTS=/path/to/omp.entitlements`.

Check production signing readiness without printing credentials:

```bash
scripts/check-macos-signing-env.sh
scripts/check-macos-signing-env.sh --production
```

Local mode reports warnings and exits successfully so beta DMG packaging
continues to work. The optional production mode fails on missing Developer ID
identities, team id, cmux entitlements, notarization enablement, or notarytool
profile. `SPIN_RELEASE_PRODUCTION=1 scripts/package-macos-release.sh
dist/SPIN.app` runs the same trust-hardening preflight before packaging.

## Licensing

cmux is GPL-3.0-or-later unless a commercial license is negotiated. A public
SPIN app derived from cmux should therefore be released in a GPL-compatible way.
OMP/Pi is MIT; preserve its notices. The current SPIN repo is MIT; preserve its
notice too.
