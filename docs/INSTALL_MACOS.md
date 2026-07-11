# Install SPIN for Mac

SPIN for Mac is distributed as a self-contained DMG. The app includes its
workspace UI, OMP/Pi agent runtime, and SPIN orchestration tools; `cmux` and
`omp` do not need to be installed separately.

## Requirements

- Apple silicon Mac
- macOS 13 or later
- At least one model/provider account supported by OMP
- Git and any development tools required by the projects being managed

The current release is
[SPIN for Mac 4.1.0 Beta 3](https://github.com/claudiaclawdbot/spin/releases/tag/v4.1.0-beta.3).

## Download And Install

1. Download `SPIN-4.1.0-beta.3-macos-arm64.dmg` from the release page.
2. Open the DMG.
3. Drag `SPIN.app` into the Applications folder.
4. Eject the SPIN disk image.
5. Open SPIN from Applications.

SPIN creates its writable runtime on first launch at:

```text
~/Library/Application Support/SPIN/runtime
```

Application updates replace app-owned code while preserving this runtime.

## First Launch On macOS

The current public beta is ad-hoc signed and not Apple-notarized. macOS may say
that it cannot verify the developer on first launch.

To open the verified GitHub release:

1. Open the Applications folder in Finder.
2. Control-click `SPIN.app`.
3. Select **Open**.
4. Confirm **Open** in the macOS dialog.

This exception applies only to the selected app. Do not disable Gatekeeper
system-wide.

If macOS still blocks a DMG downloaded from this repository, verify the
checksum first. As a final fallback, remove quarantine only from that verified
copy:

```bash
xattr -dr com.apple.quarantine /Applications/SPIN.app
open /Applications/SPIN.app
```

## Verify The Download

The release includes a SHA-256 checksum beside the DMG. Download both files to
the same folder, then run:

```bash
cd ~/Downloads
shasum -a 256 -c SPIN-4.1.0-beta.3-macos-arm64.dmg.sha256
```

The expected SHA-256 for Beta 3 is:

```text
6b99c32db54365f3aa0025bf201a44cb91b409ef4c705c191e42f76c2ee2b7bf
```

## Complete Onboarding

The first launch opens SPIN Onboarding. The setup flow covers:

1. App and bundled-runtime health checks.
2. OMP provider authentication.
3. Workspace creation or selection.
4. Adding the first software project.
5. Starting the Navigator and project workspace.

SPIN does not include provider subscriptions, API credentials, GitHub access,
source repositories, or project-specific developer tools. Those remain in the
normal account and CLI configuration on the Mac.

## Check App Health

Run this command in a SPIN terminal:

```bash
spin app-health
```

The report verifies the bundled workspace engine, `omp`, `spin-agent`, writable
runtime state, and provider-setup status.

For a broader system check:

```bash
spin doctor
```

## Install A Downloaded Update

SPIN can verify a downloaded DMG before replacing the installed app:

```bash
spin app-updates --check --candidate ~/Downloads/SPIN-<version>-macos-arm64.dmg
spin app-updates --install --yes --allow-test-builds \
  --candidate ~/Downloads/SPIN-<version>-macos-arm64.dmg
```

The update process validates compatibility metadata, preserves runtime state,
creates a backup of the installed app, and records rollback information.

## Uninstall

Remove only the application:

```bash
rm -rf /Applications/SPIN.app
```

Remove application data as well:

```bash
rm -rf "$HOME/Library/Application Support/SPIN"
```

The second command permanently removes local project metadata, runtime state,
logs, approvals, and receipts. It does not delete the source repositories that
SPIN manages.
