# Open-Source Tester Release

SPIN ships open-source macOS beta builds as the current public Mac distribution
path. These builds are public, inspectable, and ad-hoc signed, but they are not
Apple-notarized. Gatekeeper may warn on first launch. The preferred beta
artifact is a DMG.

User-facing install instructions live in
[`docs/MACOS_TESTER_INSTALL.md`](MACOS_TESTER_INSTALL.md). This file is the
maintainer checklist for preparing the GitHub release assets.

## Build And Prepare

The normal checked tester release path is:

```bash
SPIN_RELEASE_FORMAT=dmg scripts/release-macos.sh --source-cmux
scripts/prepare-open-source-release.sh --artifact dist/release/SPIN-*-macos-*.dmg
```

The first command builds the source-branded cmux app, bundles OMP/Pi, signs the
bundle ad-hoc, writes the DMG/checksum/manifest, verifies extraction, and proves
installed-app first launch. The second command verifies the release files and
writes GitHub-ready tester release notes next to them.

If the artifact already exists, use the shorter CLI alias:

```bash
scripts/spin app-release-notes --artifact dist/release/SPIN-*-macos-*.dmg
```

The script refuses artifacts that are not zip/DMG files, are not ad-hoc signed,
are marked notarized, fail checksum verification, or lack bundled third-party
notices and compatibility metadata.

## Release Assets

Attach these files to a GitHub release:

```text
SPIN-<version>-macos-<arch>.dmg
SPIN-<version>-macos-<arch>.dmg.sha256
SPIN-<version>-macos-<arch>.manifest
SPIN-<version>-macos-<arch>-open-source-tester-notes.md
```

GitHub automatically provides source archives for the tag. The release notes
should state that the binary is a tester build, not a notarized production
release.

## Tester Install

Users should verify the checksum before opening the app:

```bash
shasum -a 256 -c SPIN-<version>-macos-<arch>.dmg.sha256
hdiutil attach SPIN-<version>-macos-<arch>.dmg
cp -R /Volumes/SPIN/SPIN.app /Applications/
hdiutil detach /Volumes/SPIN
open /Applications/SPIN.app
```

If macOS blocks the app because it is not notarized, users can try Finder
right-click or Control-click, then Open. If they trust the local artifact and
have verified the checksum, they can remove quarantine:

```bash
xattr -dr com.apple.quarantine /Applications/SPIN.app
open /Applications/SPIN.app
```

Do not present the quarantine command as a casual install step. It is a fallback
for testers who intentionally trust the exact checked artifact.

## License Posture

Open source does not remove the macOS signing distinction. It only means the
source and license posture are public.

- SPIN runtime code is MIT.
- OMP/Pi-derived components preserve MIT notices.
- The bundled cmux-derived UI engine is GPL-3.0-or-later unless a commercial
  cmux license is negotiated.

Public SPIN.app binaries derived from cmux must therefore be distributed in a
GPL-compatible way. Keep `licenses/THIRD_PARTY_NOTICES.md` in source and binary
releases. The checked public workflow also packages the exact modified cmux
checkout as `SPIN-<version>-cmux-corresponding-source-<commit>.tar.gz`; do not
publish the app artifact without that source asset unless a commercial cmux
license has replaced the GPL distribution path.

## Distribution Posture

The current public Mac distribution path is the open-source DMG on GitHub, not
the Mac App Store. Developer ID notarization can reduce Gatekeeper friction in a
future release, but SPIN.app is not blocked on it. The beta release path is for
users who are comfortable verifying checksums and accepting the documented
first-launch Gatekeeper warning.
