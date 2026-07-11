# SPIN.app macOS Beta Install Guide

This guide is for the open-source SPIN.app macOS beta. It is a self-contained
app bundle: SPIN includes its cmux workspace UI and OMP/Pi agent runtime inside
the app. You do not install `cmux` or `omp` separately.

The current beta release is:

- Release: https://github.com/claudiaclawdbot/spin/releases/tag/v4.1.0-beta.3
- Artifact: `SPIN-4.1.0-beta.3-macos-arm64.dmg`
- Apple support: Apple Silicon / arm64
- Signing: ad-hoc
- Notarized: no

Because this beta is not Apple-notarized, macOS may show an extra first-launch
warning. That is expected for this beta lane.

## Install

1. Download the `.dmg` from the release page.
2. Open the DMG.
3. Drag `SPIN.app` onto `Applications`.
4. Eject the SPIN disk image.
5. Open `SPIN.app` from Applications.

Equivalent terminal install:

```bash
hdiutil attach SPIN-4.1.0-beta.3-macos-arm64.dmg
cp -R /Volumes/SPIN/SPIN.app /Applications/
hdiutil detach /Volumes/SPIN
open /Applications/SPIN.app
```

## Optional Checksum Verification

The release also includes a separate `.sha256` file. It is not another app
component; it is an optional beta-tester check for confirming the DMG bytes
before opening it. It is separate because a checksum stored inside the DMG would
not prove anything if the DMG itself had been changed.

```bash
shasum -a 256 -c SPIN-4.1.0-beta.3-macos-arm64.dmg.sha256
```

## First Launch

On first launch, SPIN creates its writable app runtime under:

```text
~/Library/Application Support/SPIN/runtime
```

The first screen should route to SPIN onboarding. The expected flow is:

1. Open the SPIN onboarding workspace.
2. Run the bundled app health check.
3. Hand provider/account setup to OMP's own setup flow.
4. Create or choose your SPIN workspace.
5. Create the first project.
6. Start the Coordinator floor.

SPIN bundles cmux and OMP/Pi, but it does not bundle provider accounts, API
keys, GitHub auth, or normal developer tools. You still connect those during
onboarding.

## Gatekeeper Warning

If macOS says it cannot verify the developer:

1. In Finder, Control-click `/Applications/SPIN.app`.
2. Choose Open.

If a trusted local beta is still blocked:

```bash
xattr -dr com.apple.quarantine /Applications/SPIN.app
open /Applications/SPIN.app
```

Do not use the quarantine command for random downloads. Use it only after
confirming the artifact came from this project. For extra assurance, use the
optional checksum step above before removing quarantine.

## Health And Updates

Inside SPIN, the app health command is:

```bash
spin app-health
```

It should report bundled `cmux`, bundled `omp`, bundled `spin-agent`, writable
runtime state, and OMP setup readiness.

To check a downloaded future app artifact before installing it:

```bash
spin app-updates --check --candidate ~/Downloads/SPIN-4.1.0-beta.3-macos-arm64.dmg
```

Tester builds require an explicit opt-in before app code replacement:

```bash
spin app-updates --install --yes --allow-test-builds \
  --candidate ~/Downloads/SPIN-4.1.0-beta.3-macos-arm64.dmg
```

## Clean Tester Checklist

Use this checklist on a fresh macOS user account or a Mac without global
`cmux`/`omp` installed:

- DMG opens and shows `SPIN.app`, `Applications`, and `README.txt`.
- Dragging `SPIN.app` to Applications succeeds.
- First launch opens onboarding.
- `spin app-health` resolves bundled cmux and OMP from inside the app.
- OMP setup opens from `spin omp-setup`.
- A first project can be created.
- The Coordinator floor starts.
- A background job can be dispatched.
- Relaunch after onboarding routes to normal `spin up`.
- `spin app-updates --check` can inspect a downloaded beta DMG.

## Uninstall

To remove the app:

```bash
rm -rf /Applications/SPIN.app
rm -rf "$HOME/Library/Application Support/SPIN"
```

Remove the Application Support folder only if you also want to delete local SPIN
runtime state, project metadata, logs, approvals, and receipts.
