#!/usr/bin/env bash
# Prepare a public macOS beta release from a checked ad-hoc artifact.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RELEASE_DIR="${SPIN_RELEASE_DIR:-$ROOT/dist/release}"
FORMAT="${SPIN_RELEASE_FORMAT:-zip}"
APP="$ROOT/dist/SPIN.app"
MODE="source"
SKIP_VENDOR=0
SKIP_BUILD=0
SKIP_CORRESPONDING_SOURCE="${SPIN_SKIP_CORRESPONDING_SOURCE:-0}"
ARTIFACT=""

usage() {
  cat <<'EOF'
Usage: scripts/prepare-open-source-release.sh [options]

Options:
  --artifact PATH       use an existing SPIN-<version>-macos-<arch>.zip|.dmg
  --source-cmux         build the SPIN-branded cmux app from source (default)
  --binary-cmux         use existing binary cmux inputs if building
  --skip-build          use --app as an already-built SPIN.app
  --skip-vendor         do not refresh vendored OMP/Pi inputs before building
  --skip-corresponding-source
                        test-only: do not package the exact modified cmux source
  --app PATH            app bundle path when building or using --skip-build
  --release-dir PATH    output directory; default: dist/release
  -h, --help            show this help

This prepares a public beta release, not a production-notarized release. The
artifact must be ad-hoc signed, not notarized, and accompanied by .sha256 and
.manifest files.
EOF
}

fail(){ echo "open-source release failed: $*" >&2; exit 1; }
ok(){ echo "  ok: $*"; }

abs_path() {
  local input="$1" dir base
  if [ "${input#/}" != "$input" ]; then
    printf '%s\n' "$input"
    return 0
  fi
  dir="$(dirname "$input")"
  base="$(basename "$input")"
  mkdir -p "$dir"
  printf '%s/%s\n' "$(cd "$dir" >/dev/null 2>&1 && pwd)" "$base"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact)
      [ $# -ge 2 ] || fail "--artifact requires a path"
      ARTIFACT="$2"; shift 2 ;;
    --source-cmux) MODE="source"; shift ;;
    --binary-cmux) MODE="binary"; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-vendor) SKIP_VENDOR=1; shift ;;
    --skip-corresponding-source) SKIP_CORRESPONDING_SOURCE=1; shift ;;
    --app)
      [ $# -ge 2 ] || fail "--app requires a path"
      APP="$2"; shift 2 ;;
    --release-dir)
      [ $# -ge 2 ] || fail "--release-dir requires a path"
      RELEASE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

RELEASE_DIR="$(abs_path "$RELEASE_DIR")"
mkdir -p "$RELEASE_DIR"

case "$FORMAT" in
  zip|dmg) ;;
  *) fail "SPIN_RELEASE_FORMAT must be zip or dmg, got: $FORMAT" ;;
esac

if [ -z "$ARTIFACT" ]; then
  args=()
  if [ "$MODE" = "source" ]; then args+=(--source-cmux); else args+=(--binary-cmux); fi
  if [ "$SKIP_BUILD" = "1" ]; then args+=(--skip-build --app "$APP"); fi
  if [ "$SKIP_VENDOR" = "1" ]; then args+=(--skip-vendor); fi
  args+=(--release-dir "$RELEASE_DIR")
  SPIN_RELEASE_FORMAT="$FORMAT" "$ROOT/scripts/release-macos.sh" "${args[@]}"
  ARTIFACT="$(ls -t "$RELEASE_DIR"/SPIN-*-macos-*."$FORMAT" 2>/dev/null | head -1 || true)"
  [ -n "$ARTIFACT" ] || fail "release pipeline did not produce a macOS $FORMAT artifact"
fi

ARTIFACT="$(abs_path "$ARTIFACT")"
[ -f "$ARTIFACT" ] || fail "artifact not found: $ARTIFACT"
case "$(basename "$ARTIFACT")" in
  SPIN-*-macos-*.zip|SPIN-*-macos-*.dmg) ;;
  *) fail "artifact name is not a SPIN macOS artifact: $(basename "$ARTIFACT")" ;;
esac

SOURCE_DIR="$(cd "$(dirname "$ARTIFACT")" >/dev/null 2>&1 && pwd)"
case "$ARTIFACT" in
  *.zip) BASE="$(basename "$ARTIFACT" .zip)" ;;
  *.dmg) BASE="$(basename "$ARTIFACT" .dmg)" ;;
esac
SOURCE_SHA="$ARTIFACT.sha256"
SOURCE_MANIFEST="$SOURCE_DIR/$BASE.manifest"
[ -f "$SOURCE_SHA" ] || fail "missing checksum file: $SOURCE_SHA"
[ -f "$SOURCE_MANIFEST" ] || fail "missing manifest file: $SOURCE_MANIFEST"

if [ "$SOURCE_DIR" != "$RELEASE_DIR" ]; then
  cp "$ARTIFACT" "$RELEASE_DIR/$(basename "$ARTIFACT")"
  cp "$SOURCE_SHA" "$RELEASE_DIR/$(basename "$SOURCE_SHA")"
  cp "$SOURCE_MANIFEST" "$RELEASE_DIR/$(basename "$SOURCE_MANIFEST")"
  ARTIFACT="$RELEASE_DIR/$(basename "$ARTIFACT")"
  SOURCE_SHA="$ARTIFACT.sha256"
  SOURCE_MANIFEST="$RELEASE_DIR/$BASE.manifest"
  ok "copied artifact, checksum, and manifest into release directory"
fi

sha_expected="$(awk '{print $1}' "$SOURCE_SHA")"
sha_actual="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
[ "$sha_actual" = "$sha_expected" ] || fail "checksum mismatch for $(basename "$ARTIFACT")"
ok "artifact checksum"

manifest_get() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' "$SOURCE_MANIFEST"
}

manifest_artifact="$(manifest_get artifact)"
version="$(manifest_get version)"
archs="$(manifest_get archs)"
format="$(manifest_get format)"
codesign_identity="$(manifest_get codesign_identity)"
notarized="$(manifest_get notarized)"
compat_sha="$(manifest_get compatibility_manifest_sha256)"

[ "$manifest_artifact" = "$(basename "$ARTIFACT")" ] || fail "manifest artifact does not match artifact name"
case "$format" in
  zip|dmg) ;;
  *) fail "public beta release must be a zip or dmg artifact, got: ${format:-missing}" ;;
esac
[ "$format" = "${ARTIFACT##*.}" ] || fail "manifest format does not match artifact extension: manifest=$format artifact=${ARTIFACT##*.}"
[ "$codesign_identity" = "-" ] || fail "public beta release must be ad-hoc signed, got identity: ${codesign_identity:-missing}"
[ "$notarized" = "false" ] || fail "public beta release must not be marked notarized"
[ -n "$version" ] || fail "manifest missing version"
[ -n "$archs" ] || fail "manifest missing archs"
[ -n "$compat_sha" ] || fail "manifest missing compatibility manifest hash"
VERSIONED_NOTES="$ROOT/docs/releases/SPIN-$version.md"
[ -f "$VERSIONED_NOTES" ] || fail "missing versioned release notes: $VERSIONED_NOTES"
[ "$(sed -n '1p' "$VERSIONED_NOTES")" = "# SPIN for Mac $version" ] || \
  fail "versioned release notes heading does not match artifact version $version"
ok "public beta manifest policy"

TMP="$(mktemp -d)"
MOUNT=""
cleanup(){
  if [ -n "$MOUNT" ] && mount | grep -Fq " on $MOUNT "; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
command -v ditto >/dev/null 2>&1 || fail "ditto is required to inspect release artifact"
case "$format" in
  zip)
    ditto -x -k "$ARTIFACT" "$TMP"
    ;;
  dmg)
    command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required to inspect dmg release artifact"
    MOUNT="$TMP/mount"
    mkdir -p "$MOUNT" "$TMP/extract"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$ARTIFACT" >/dev/null
    ditto "$MOUNT/SPIN.app" "$TMP/extract/SPIN.app"
    hdiutil detach "$MOUNT" >/dev/null
    MOUNT=""
    mv "$TMP/extract/SPIN.app" "$TMP/SPIN.app"
    ;;
esac
[ -d "$TMP/SPIN.app" ] || fail "artifact did not provide SPIN.app"
[ -f "$TMP/SPIN.app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md" ] || fail "artifact missing third-party notices"
grep -q 'GPL-3.0-or-later' "$TMP/SPIN.app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md" || fail "artifact notices missing cmux GPL posture"
grep -q 'oh-my-pi' "$TMP/SPIN.app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md" || fail "artifact notices missing OMP/Pi notice"
node "$ROOT/scripts/app-compatibility.js" verify "$TMP/SPIN.app" >/dev/null
ok "artifact notices and compatibility manifest"

SOURCE_ARCHIVE=""
SOURCE_ARCHIVE_SHA=""
SOURCE_ASSET_LINES=""
SOURCE_RELEASE_SECTION=""
if [ "$SKIP_CORRESPONDING_SOURCE" != "1" ]; then
  CMUX_SOURCE_DIR="${SPIN_CMUX_SOURCE_DIR:-$ROOT/app/upstream/cmux}"
  [ -e "$CMUX_SOURCE_DIR/.git" ] || fail "matching cmux source checkout missing: $CMUX_SOURCE_DIR"
  cmux_source_commit="$(node - "$TMP/SPIN.app/Contents/Resources/app/release-compat.json" <<'NODE'
const manifest = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const commit = manifest.cmux && manifest.cmux.source && manifest.cmux.source.commit;
if (!commit) process.exit(1);
process.stdout.write(commit);
NODE
)" || fail "artifact compatibility manifest is missing the cmux source commit"
  tracked_cmux_commit="${SPIN_CMUX_COMMIT:-$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.components?.uiEngine?.upstreamCommit || "")' "$ROOT/app/spin-app.json" 2>/dev/null || true)}"
  [ -n "$tracked_cmux_commit" ] || fail "tracked cmux source commit is missing from app/spin-app.json"
  [ "$cmux_source_commit" = "$tracked_cmux_commit" ] || fail "artifact cmux commit $cmux_source_commit does not match tracked pin $tracked_cmux_commit"
  checkout_commit="$(git -C "$CMUX_SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
  [ "$checkout_commit" = "$cmux_source_commit" ] || fail "cmux source checkout $checkout_commit does not match artifact $cmux_source_commit"

  source_short="$(printf '%s' "$cmux_source_commit" | cut -c1-12)"
  source_name="SPIN-$version-cmux-corresponding-source-$source_short"
  source_parent="$TMP/corresponding-source"
  source_stage="$source_parent/$source_name"
  mkdir -p "$source_stage"
  (
    cd "$CMUX_SOURCE_DIR"
    {
      git ls-files -z
      git ls-files -z --others --exclude-standard \
        --exclude='build-spin/' \
        --exclude='.spm-cache/' \
        --exclude='DerivedData/' \
        --exclude='.build/'
    } | tar --null -cf - --files-from -
  ) | (cd "$source_stage" && tar -xf -)
  cat > "$source_stage/SPIN-CORRESPONDING-SOURCE.txt" <<EOF
SPIN cmux corresponding source

Upstream: https://github.com/manaflow-ai/cmux.git
Upstream commit: $cmux_source_commit
SPIN version: $version

This archive captures tracked source plus SPIN's modified and added overlay files
from the exact checkout used by the release pipeline. Build instructions live in
the SPIN repository under scripts/build-cmux-spin.sh and docs/APP_BUNDLE.md.
EOF
  SOURCE_ARCHIVE="$RELEASE_DIR/$source_name.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$SOURCE_ARCHIVE" -C "$source_parent" "$source_name"
  SOURCE_ARCHIVE_SHA="$SOURCE_ARCHIVE.sha256"
  (
    cd "$RELEASE_DIR"
    shasum -a 256 "$(basename "$SOURCE_ARCHIVE")" > "$(basename "$SOURCE_ARCHIVE_SHA")"
  )
  SOURCE_ASSET_LINES="- \`$(basename "$SOURCE_ARCHIVE")\`
- \`$(basename "$SOURCE_ARCHIVE_SHA")\`"
  SOURCE_RELEASE_SECTION="The release also includes the exact modified cmux source tree used to build
the bundled GPL component, identified by upstream commit \`$cmux_source_commit\`."
  ok "matching cmux corresponding source ($source_short)"
fi

NOTES="$RELEASE_DIR/$BASE-release-notes.md"
if [ "$format" = "dmg" ]; then
  install_steps="shasum -a 256 -c $(basename "$SOURCE_SHA")
hdiutil attach $(basename "$ARTIFACT")
cp -R /Volumes/SPIN/SPIN.app /Applications/
hdiutil detach /Volumes/SPIN
open /Applications/SPIN.app"
  finder_install="The DMG also includes an Applications shortcut and README.txt. In Finder, open the DMG and drag SPIN.app onto Applications."
else
  install_steps="shasum -a 256 -c $(basename "$SOURCE_SHA")
ditto -x -k $(basename "$ARTIFACT") .
mv SPIN.app /Applications/
open /Applications/SPIN.app"
  finder_install="The zip contains SPIN.app directly. Extract it, then move SPIN.app into Applications."
fi
cat > "$NOTES" <<EOF
# SPIN for Mac $version

SPIN is a visual command center for coordinating AI coding agents across
multiple software projects. Each project keeps its own repository context,
while the Navigator manages portfolio priorities, delegation, approvals, and
progress from one Mac workspace.
EOF

tail -n +2 "$VERSIONED_NOTES" >> "$NOTES"

cat >> "$NOTES" <<EOF

## Requirements

- macOS architecture: \`$archs\`
- At least one model/provider account supported by OMP
- Git and the normal development tools used by managed projects

## Install

$finder_install

Optional checksum verification and terminal installation:

\`\`\`bash
$install_steps
\`\`\`

On first launch, SPIN creates its writable runtime under
\`~/Library/Application Support/SPIN/runtime\` and opens onboarding. Provider
accounts, GitHub authentication, source repositories, and project-specific
tools remain under the operator's control.

## macOS First Launch

This public beta is ad-hoc signed and not Apple-notarized. macOS may require a
Control-click on \`SPIN.app\` followed by **Open** on first launch.

If macOS still blocks a DMG downloaded from this repository, verify the
checksum before removing quarantine from that app only:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/SPIN.app
open /Applications/SPIN.app
\`\`\`

## Download Integrity

- Version: \`$version\`
- Format: \`$format\`
- Signing: ad-hoc
- Notarized: no
- App SHA-256: \`$sha_actual\`
- Compatibility manifest SHA-256: \`$compat_sha\`

Release files:

- \`$(basename "$ARTIFACT")\`
- \`$(basename "$SOURCE_SHA")\`
- \`$(basename "$SOURCE_MANIFEST")\`
- \`$(basename "$NOTES")\`
$SOURCE_ASSET_LINES

## Open-Source Components

The app includes \`SPIN.app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md\`.
SPIN runtime source is MIT, OMP/Pi-derived components preserve their MIT
notices, and the bundled cmux-derived UI is distributed under its applicable
GPL-3.0-or-later terms unless a commercial cmux license applies.

$SOURCE_RELEASE_SECTION

## Release Verification

The checked release pipeline verifies bundled runtime resolution, app identity,
license notices, runtime seeding, restart and session restore, compatibility
metadata, code signatures, artifact extraction, and installed-app first launch.
EOF

ok "wrote customer release notes"
echo
echo "SPIN release package prepared:"
echo "  artifact: $ARTIFACT"
echo "  checksum: $SOURCE_SHA"
echo "  manifest: $SOURCE_MANIFEST"
echo "  notes:    $NOTES"
if [ -n "$SOURCE_ARCHIVE" ]; then
  echo "  cmux source: $SOURCE_ARCHIVE"
fi
