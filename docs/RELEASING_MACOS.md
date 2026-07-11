# Releasing SPIN For Mac

This document is the maintainer runbook for building and publishing the public
Mac distribution. Customer install instructions live in
[INSTALL_MACOS.md](INSTALL_MACOS.md).

## Release Standard

Every public release must provide:

- a DMG built from the tagged source;
- a SHA-256 checksum and compatibility manifest;
- customer-facing release notes;
- the exact corresponding source for the bundled cmux-derived component;
- passing source, bundle, extraction, installation, and first-launch checks;
- signing and notarization language that matches the artifact exactly.

The current beta lane is ad-hoc signed and not notarized. Do not describe it as
Developer ID signed or notarized until the pipeline verifies both properties.

## Build And Prepare

```bash
SPIN_RELEASE_FORMAT=dmg scripts/release-macos.sh --source-cmux
scripts/prepare-open-source-release.sh \
  --artifact dist/release/SPIN-*-macos-*.dmg
```

The release pipeline builds the SPIN-branded app, bundles OMP/Pi, signs the
bundle, creates the DMG and metadata, verifies extraction, and tests an
installed-app first launch. The preparation step verifies those artifacts and
creates customer-facing release notes.

An existing artifact can be prepared through the CLI alias:

```bash
scripts/spin app-release-notes \
  --artifact dist/release/SPIN-*-macos-*.dmg
```

## Required Assets

```text
SPIN-<version>-macos-<arch>.dmg
SPIN-<version>-macos-<arch>.dmg.sha256
SPIN-<version>-macos-<arch>.manifest
SPIN-<version>-macos-<arch>-release-notes.md
SPIN-<version>-cmux-corresponding-source-<commit>.tar.gz
SPIN-<version>-cmux-corresponding-source-<commit>.tar.gz.sha256
```

The cmux source archive must match the upstream commit recorded in the bundled
compatibility manifest. It contains tracked upstream source and the SPIN overlay
used by the build, without generated build caches.

## Product Copy Requirements

Release titles use this format:

```text
SPIN for Mac <version>
```

Release notes should explain the product, changes, requirements, installation,
known limitations, checksum, and open-source components. Keep build commands,
asset-upload instructions, and maintainer checklists in this runbook rather
than in the customer-facing release body.

## Verification

Run the strongest available checks before publishing:

```bash
scripts/smoke-test.sh
scripts/check-app-release.sh dist/SPIN.app
scripts/check-app-release.sh /Applications/SPIN.app
scripts/check-installed-app.sh dist/release/SPIN-*-macos-*.dmg
spin app-health
```

Confirm manually that:

- the DMG opens and includes `SPIN.app`, `Applications`, and `README.txt`;
- a clean macOS account can copy and launch the app;
- first launch opens onboarding and later launches restore the workspace;
- the Navigator rail and project workspaces are visible;
- provider setup, project creation, delegation, and receipts are coherent;
- the release page lists the DMG, checksum, manifest, release notes, and
  matching cmux corresponding-source archive;
- public copy contains no local paths, credentials, private identifiers, or
  internal operator instructions.

## Distribution And Licensing

SPIN runtime source is MIT. OMP/Pi-derived components retain their MIT notices.
The bundled cmux-derived UI is GPL-3.0-or-later unless a commercial cmux license
applies. Public binaries must remain GPL-compatible and include the exact
corresponding source plus `THIRD_PARTY_NOTICES.md`.

The current distribution channel is GitHub Releases. Developer ID signing,
Apple notarization, and a verified remote update feed remain separate release
gates.
