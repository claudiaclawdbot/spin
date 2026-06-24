# SPIN App Roadmap

This track is for the production macOS app wrapper. It is related to, but
separate from, the core SPIN runtime roadmap.

## Boundary

Core SPIN owns:

- plain-file org state, approvals, jobs, receipts, and project folders;
- `spin` and `org` CLI behavior;
- the Navigator loop, dispatcher, supervisors, and model fallback policy;
- headless operation when no app window is available.

SPIN.app owns:

- the visible macOS product identity, icon, launcher, first-run flow, and
  release packaging;
- the bundled cmux-derived native UI engine;
- the bundled OMP/Pi-derived agent engine;
- app-managed health checks, dependency detection, runtime seeding, updates,
  signing, and notarization.

The app can ship the core runtime, but core changes should stay usable from a
checkout and from the CLI. The app track should not turn every runtime issue
into an app issue.

## Completed Checkpoints

1. **Developer app bundle proof**

   `scripts/package-macos-app.sh` stages `dist/SPIN.app` with the runtime,
   launcher, cmux config, branding assets, license notices, bundled `cmux`,
   bundled `omp`, and `spin-agent`.

2. **Release checker**

   `scripts/check-app-release.sh` verifies app identity, nested cmux app
   identity, bundled binaries, notices, launcher syntax, runtime seeding, and
   cmux app resolution.

3. **Source cmux overlay**

   `scripts/apply-cmux-spin-overlay.sh` fetches or reuses cmux source, hydrates
   required source-build inputs, applies SPIN identity/config/sidebar assets,
   and patches current SwiftPM target-name collisions.

4. **Xcode source-build proof**

   `scripts/build-app-proof.sh --source-cmux` builds a SPIN-branded cmux app
   with Xcode, bundles it into the outer `SPIN.app`, and runs branded release
   checks.

5. **Source-built cmux-compatible CLI discovery**

   Source mode records the Xcode-built `SPIN` executable as the cmux-compatible
   CLI source and packages it internally as `Resources/bin/cmux`.

6. **No-global-dependency app proof**

   `scripts/check-app-release.sh` now runs bundled executable and runtime
   resolver probes with `PATH` reduced to system tools only, proving shell and
   Node entrypoints resolve `Resources/bin/cmux`, `Resources/bin/omp`, and
   `Resources/bin/spin-agent` instead of global installs.

7. **SPIN app icon packaging**

   The GitHub Pages header spinner mark in `assets/branding/spin-icon.svg` now
   builds into `assets/branding/SPIN.icns`. Packaging installs it as the outer
   `SPIN.app` icon and stamps the same icon into the bundled cmux-derived
   native UI app. The source cmux build product is also stamped after Xcode
   builds it, so development artifacts do not keep the upstream cmux icon.

8. **Repeatable OMP/Pi bundling**

   `scripts/vendor-app-deps.sh --omp-only` vendors the pinned
   `@oh-my-pi/pi-coding-agent@16.1.16` npm package, writes a Bun lockfile,
   compiles `vendor/bin/omp` with `bun build --compile`, copies the matching
   `pi_natives.<platform>.node` addon, and records npm integrity, lockfile,
   compiled binary, and native addon hashes in `agent/vendor/omp/metadata.json`.
   `scripts/build-app-proof.sh` now uses `vendor/bin/omp` by default and refuses
   global `omp` input unless `SPIN_ALLOW_GLOBAL_OMP_INPUT=1` is set.

9. **App health and OMP onboarding handoff**

   `scripts/spin-app-health.js` provides JSON and text health reports for the
   app/runtime boundary: bundled `cmux`, bundled `omp`, bundled `spin-agent`,
   writable runtime seeding, local `git`/shell/toolchain availability, and OMP
   setup readiness without reading or printing secrets. `spin doctor` now uses
   the same health report, first-run onboarding shows it, and `spin omp-setup`
   hands provider/account setup to OMP's own setup wizard. The cmux dock exposes
   Health and OMP Setup controls.

10. **App restart and session restore proof**

   `scripts/check-app-release.sh` now launches the packaged app into a fresh
   `SPIN_APP_HOME`, verifies first launch routes to onboarding, writes onboarding
   status plus SPIN-owned plain-file state, relaunches, and verifies the app
   routes to normal `spin up`. It also simulates a stale seeded runtime version
   and proves the launcher refreshes replaceable runtime code without overwriting
   `org/`, remembered cmux workspace refs, approvals, human queue state,
   receipts, or logs.

11. **Installable macOS artifact and signing preflight**

   `scripts/package-macos-release.sh` stages a copy of `dist/SPIN.app`, ad-hoc
   signs it by default, verifies the outer and bundled cmux app signatures,
   signs bundled `cmux`, `omp`, `spin-agent`, and OMP native addons, removes
   quarantine xattrs, creates a distributable zip or DMG, writes a SHA-256
   checksum and manifest, extracts the artifact, and reruns the app release
   contract against the extracted app. Developer ID signing, hardened runtime,
   OMP entitlements, Gatekeeper assessment, and notarytool submission are wired
   through environment variables so production credentials can be added without
   changing the release script.

12. **Installed-app first-run UX proof**

   `scripts/check-installed-app.sh` extracts the release zip into a temporary
   Applications-like directory, verifies the signed app contract, then runs
   `SPIN.app/Contents/MacOS/SPIN` with a clean `SPIN_APP_HOME` from a controlled
   installed copy. The proof uses bundled cmux/OMP shims inside that installed
   copy so first launch is deterministic: it seeds the writable runtime, opens
   the `SPIN Onboarding` workspace through the bundled cmux-compatible CLI,
   avoids global cmux/OMP shims, verifies relaunch routing changes to `spin up`
   after `.spin-onboarded`, and confirms app health resolves installed bundled
   binaries.

13. **Production signing and notarization readiness**

   `scripts/check-macos-signing-env.sh` reports Developer ID identities,
   hardened-runtime mode, Apple team id, cmux/OMP/outer entitlements, notarytool
   profile configuration, and required macOS signing tools without printing
   secrets. Local mode exits successfully with warnings, while `--production` or
   `SPIN_RELEASE_PRODUCTION=1` turns missing signing/notary inputs into failures.
   `scripts/package-macos-release.sh` now runs that production preflight before
   app packaging when production mode is requested, so incomplete credential
   setup fails immediately. Hardened-runtime signing keeps OMP native addon
   loading by generating the minimal OMP disable-library-validation entitlement
   when no custom `SPIN_OMP_ENTITLEMENTS` file is provided.

14. **Release command and CI artifact workflow**

   `scripts/release-macos.sh` now runs the bounded app release pipeline in one
   command: optional OMP/Pi vendoring, source or binary app proof, strict branded
   cmux and vendored OMP release checks, signed artifact packaging, installed-app
   launch proof, signing environment reporting, and final artifact/checksum/
   manifest output. `.github/workflows/macos-app.yml` adds a manual macOS
   Actions workflow that vendors app dependencies, builds the source cmux fork,
   runs the same checked ad-hoc release command, and uploads the artifact,
   checksum, manifest, and tester release notes together.

15. **Update-channel and release compatibility policy**

   `scripts/app-compatibility.js` writes and verifies
   `SPIN.app/Contents/Resources/app/release-compat.json`. The manifest records
   SPIN runtime version, migration level, cmux bundle identity/source commit,
   cmux CLI hash/arch, OMP package/version/vendor metadata hash, OMP binary and
   native addon hashes, release channel, build mode, and the org/log preservation
   boundary. `scripts/package-macos-app.sh` writes it during app staging;
   `scripts/package-macos-release.sh` regenerates it after signing inner binaries
   so the signed artifact verifies its signed bytes; `scripts/check-app-release.sh`
   fails when the manifest does not match the bundled runtime and binaries.
   `docs/APP_BUNDLE.md` defines the `local-dev`, `ad-hoc`, and `production`
   update channels plus the rollback/session-preservation boundary.

16. **App update and rollback dry-run mechanics**

   `scripts/spin-app-update.js` adds `spin app-update` as the app-specific update
   planner. It extracts a candidate `.zip`, `.dmg`, or `.app` artifact, verifies its
   `release-compat.json` against bundled files, reads the installed/current app
   manifest, compares channel, SPIN version, cmux source commit, OMP package, and
   migration digest, prints the replaceable app-owned code and preserved user
   state, refuses channel downgrades such as `production` to `ad-hoc` unless
   `--force-channel` is passed, and writes rollback metadata under
   `<app-home>/updates/` only when `--record-rollback` is requested. It still does
   not replace installed app code; replacement is reserved for the next bounded
   checkpoint.

17. **App update execution mechanics**

   `spin app-update --install` now provides an opt-in app-code replacement path
   for `local-dev` and `ad-hoc` candidates. The command verifies the candidate
   compatibility manifest, enforces channel gates, requires `--allow-ad-hoc` or
   `--allow-local-dev` for non-production artifacts, requires
   `--allow-production` plus trust verification for production artifacts, backs
   up the installed app under
   `<app-home>/updates/backups/`, writes rollback metadata under
   `<app-home>/updates/`, stages the candidate app, replaces the installed app
   path, and verifies the installed compatibility manifest after replacement.
   Smoke coverage proves the ad-hoc allow gate, backup, rollback metadata,
   stale-app replacement, post-install release check, production-candidate refusal,
   and preserved-state plan.

18. **Production trust verification for app updates**

   `release-compat.json` now records signing/trust intent: signing identity,
   Apple team id, hardened runtime intent, notarization intent, and whether the
   channel requires Developer ID, notarization, and Gatekeeper assessment.
   `spin app-update --install --allow-production` now fails closed unless a
   production candidate has Developer ID signing metadata, matching actual code
   signature team id, hardened runtime, notarization intent, valid deep
   `codesign --verify`, and passing `spctl --assess --type execute`.
   Smoke coverage proves production installs are refused without
   `--allow-production` and still refused with `--allow-production` when the
   candidate is only production-marked but not actually trusted.

20. **User-facing app update surface**

   `spin app-updates` now wraps the checked `spin app-update` mechanics with a
   safer user-facing command. It reports installed and candidate app
   versions/channels, discovers local artifacts from `--candidate`,
   `SPIN_APP_UPDATE_CANDIDATE`, `SPIN_UPDATE_ARTIFACT`, or the newest
   `SPIN-*-macos-*` zip/DMG artifact in the release directory, and delegates plan/install
   work to the lower-level updater. Installs require `--yes` plus
   channel-specific allow flags: `--allow-test-builds`, `--allow-local-dev`, or
   `--allow-production`. The cmux dock now exposes an Updates control that runs
   the same safe no-candidate status path. Smoke coverage proves no-candidate
   status, checked plan output, ad-hoc install refusal without
   `--allow-test-builds`, opt-in ad-hoc install through the wrapper, and
   post-install release verification.

21. **Open-source tester release packaging**

   `scripts/prepare-open-source-release.sh` prepares a public tester release
   from the checked ad-hoc macOS artifact without requiring Apple Developer ID.
   It can run the normal source-cmux release pipeline or consume an existing
   zip/DMG, verifies the `.sha256` and `.manifest`, refuses non-zip/DMG,
   non-ad-hoc-signed, or notarized artifacts, extracts the app to verify bundled
   third-party notices and compatibility metadata, and writes
   `SPIN-<version>-macos-<arch>-open-source-tester-notes.md` beside the
   artifact. `spin app-release-notes` exposes the same path for maintainers, and
   the manual macOS Actions workflow uploads the notes with the DMG, checksum,
   and manifest. The tester notes explain checksum verification, install steps,
   Gatekeeper warnings, quarantine fallback, bundled cmux/OMP scope, and the
   GPL-compatible license posture for public binaries.

22. **Public app lane on GitHub and Pages**

   The repository now presents the app work as a separate visible lane from the
   stable CLI/runtime install path. `README.md` includes a macOS app artifact
   workflow badge and explains the CLI/runtime lane versus the macOS app tester
   lane. `docs/index.html` adds a dedicated SPIN.app tester section with the
   checked build/release-notes commands, links to the macOS app workflow, app
   bundle docs, app roadmap, and open-source tester release instructions. This
   makes the app track discoverable without implying the Apple-notarized
   production channel is complete.

23. **Clean beta install polish**

   The app release lane now uses `4.1.0-beta.1` versioning for tester builds,
   stages DMGs with `SPIN.app`, an Applications shortcut, and `README.txt`, and
   verifies that layout during installed-app checks. `docs/MACOS_TESTER_INSTALL.md`
   is the single user-facing install guide for download, checksum verification,
   first launch, provider setup expectations, update checks, Gatekeeper fallback,
   and uninstall. README and the GitHub Pages app lane link directly to the
   beta release and install guide.

## Current App Proof

The current bounded release proof is:

```bash
scripts/release-macos.sh --source-cmux
```

Expected result:

- outer app: `dist/SPIN.app`;
- nested native UI app: `dist/SPIN.app/Contents/Resources/SPIN.app`;
- nested native UI bundle id: `dev.spin.app`;
- outer app icon: `dist/SPIN.app/Contents/Resources/SPIN.icns`;
- nested UI app icon:
  `dist/SPIN.app/Contents/Resources/SPIN.app/Contents/Resources/AppIcon.icns`;
- internal cmux-compatible CLI: `dist/SPIN.app/Contents/Resources/bin/cmux`;
- internal OMP/Pi runtime binary: `dist/SPIN.app/Contents/Resources/bin/omp`;
- internal OMP/Pi native addon:
  `dist/SPIN.app/Contents/Resources/bin/pi_natives.<platform>.node`;
- OMP/Pi vendor metadata and lockfile:
  `dist/SPIN.app/Contents/Resources/app/omp-vendor.json` and
  `dist/SPIN.app/Contents/Resources/app/omp-bun.lock`;
- compatibility manifest:
  `dist/SPIN.app/Contents/Resources/app/release-compat.json`;
- shell and Node runtime resolvers select bundled `cmux`, `omp`, and
  `spin-agent` with user PATH entries removed;
- `spin-app-health.js --json` reports app-bundled `cmux`, `omp`, and
  `spin-agent`, validates the writable seeded runtime, and preserves OMP as the
  setup owner with `spin omp-setup`;
- a fresh app home survives relaunch and runtime refresh with onboarding state,
  remembered cmux workspace refs, approvals, queue entries, receipts, and logs
  intact;
- `scripts/package-macos-release.sh dist/SPIN.app` creates
  `dist/release/SPIN-<version>-macos-<arch>.zip` or `.dmg`, plus `.sha256` and
  `.manifest`, and verifies the extracted signed app;
- `scripts/check-installed-app.sh dist/release/SPIN-*-macos-*` proves the
  extracted installed app completes first-launch and relaunch routing from an
  isolated app home;
- `scripts/check-macos-signing-env.sh` reports local signing readiness without
  requiring credentials, and production mode fails fast when Developer ID/notary
  inputs are absent;
- `scripts/release-macos.sh --source-cmux` runs the build, strict app release
  check, release packaging, installed-app proof, and signing report in one
  bounded command;
- `scripts/spin app-update --dry-run dist/release/SPIN-*-macos-*` reads the
  installed and candidate compatibility manifests and prints a no-change update
  plan;
- `scripts/spin app-update --install --allow-ad-hoc --installed-app <temp-app>
  --app-home <temp-home> dist/release/SPIN-*-macos-*` replaces a temporary
  installed app, writes rollback metadata, and verifies the installed
  compatibility manifest;
- `scripts/spin app-update --install --allow-production ...` fails closed for
  production-marked candidates that do not pass Developer ID/Gatekeeper trust;
- `scripts/spin app-updates` is the user-facing update surface and the cmux dock
  includes an Updates control that calls it;
- `scripts/spin app-updates --check --candidate dist/release/SPIN-*-macos-*`
  prints the friendly update header and the checked low-level plan;
- `scripts/spin app-updates --install --yes --allow-test-builds --candidate
  dist/release/SPIN-*-macos-* --installed-app <temp-app>` installs an
  ad-hoc artifact through the same rollback/verification path;
- `scripts/prepare-open-source-release.sh --artifact
  dist/release/SPIN-*-macos-*.dmg` verifies a checked ad-hoc DMG and writes
  GitHub-ready open-source tester release notes;
- `scripts/spin app-release-notes --artifact dist/release/SPIN-*-macos-*.dmg`
  exposes the same tester release preparation path from the CLI;
- `README.md` and `docs/index.html` expose a separate app tester lane with clear
  ad-hoc/not-notarized boundaries and links to the app workflow/docs;
- release checks pass with `SPIN_REQUIRE_BRANDED_CMUX_APP=1` and
  `SPIN_REQUIRE_VENDORED_OMP=1`.

## Credential-Gated Checkpoint

**Checkpoint 19: notarized production release execution**

Goal: run the production signing/notarization path with real Apple Developer
credentials and prove a production artifact can pass the same install gate that
currently fails closed locally.

Bounded deliverables:

- Configure Developer ID Application identity, Apple team id, cmux entitlements,
  hardened runtime, notarytool profile, and notarization.
- Produce a `production` channel release artifact.
- Verify `codesign`, Gatekeeper, notarization, compatibility manifest, installed
  app first launch, and production app-update install gate.
- Keep ad-hoc/local update behavior unchanged.

Exit criteria:

```bash
scripts/check-macos-signing-env.sh --production
scripts/release-macos.sh --production --source-cmux
scripts/spin app-update --install --allow-production dist/release/SPIN-*-macos-*.zip
scripts/smoke-test.sh
```

Those commands pass only on a machine configured with Developer ID and notary
credentials; local smoke continues to prove production installs fail closed when
credentials are absent.

## Later Checkpoints

- Add a signed remote update feed and background update notifications around the
  checked local artifact updater.
