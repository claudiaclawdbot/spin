#!/usr/bin/env bash
# Prepare an open-source macOS tester release from a checked ad-hoc artifact.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RELEASE_DIR="${SPIN_RELEASE_DIR:-$ROOT/dist/release}"
FORMAT="${SPIN_RELEASE_FORMAT:-zip}"
APP="$ROOT/dist/SPIN.app"
MODE="source"
SKIP_VENDOR=0
SKIP_BUILD=0
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
  --app PATH            app bundle path when building or using --skip-build
  --release-dir PATH    output directory; default: dist/release
  -h, --help            show this help

This prepares a public tester release, not a production notarized release. The
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
  *) fail "tester release must be a zip or dmg artifact, got: ${format:-missing}" ;;
esac
[ "$format" = "${ARTIFACT##*.}" ] || fail "manifest format does not match artifact extension: manifest=$format artifact=${ARTIFACT##*.}"
[ "$codesign_identity" = "-" ] || fail "tester release must be ad-hoc signed, got identity: ${codesign_identity:-missing}"
[ "$notarized" = "false" ] || fail "tester release must not be marked notarized"
[ -n "$version" ] || fail "manifest missing version"
[ -n "$archs" ] || fail "manifest missing archs"
[ -n "$compat_sha" ] || fail "manifest missing compatibility manifest hash"
ok "tester manifest policy"

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

NOTES="$RELEASE_DIR/$BASE-open-source-tester-notes.md"
if [ "$format" = "dmg" ]; then
  install_steps="shasum -a 256 -c $(basename "$SOURCE_SHA")
hdiutil attach $(basename "$ARTIFACT")
cp -R /Volumes/SPIN/SPIN.app /Applications/
hdiutil detach /Volumes/SPIN
open /Applications/SPIN.app"
else
  install_steps="shasum -a 256 -c $(basename "$SOURCE_SHA")
ditto -x -k $(basename "$ARTIFACT") .
mv SPIN.app /Applications/
open /Applications/SPIN.app"
fi
cat > "$NOTES" <<EOF
# SPIN $version macOS Open-Source Tester Release

This is an open-source tester build of SPIN.app for macOS. It is ad-hoc signed
and not notarized. That means the source and release artifacts are public and
inspectable, but macOS Gatekeeper may show extra warnings compared with a future
Developer ID notarized production build.

## Assets

Attach these files to the GitHub release:

- \`$(basename "$ARTIFACT")\`
- \`$(basename "$SOURCE_SHA")\`
- \`$(basename "$SOURCE_MANIFEST")\`
- \`$(basename "$NOTES")\`

Release metadata:

- Version: \`$version\`
- Format: \`$format\`
- macOS archs: \`$archs\`
- Signing: ad-hoc (\`-\`)
- Notarized: \`false\`
- SHA-256: \`$sha_actual\`
- Compatibility manifest SHA-256: \`$compat_sha\`

## Install

Download the app artifact and checksum into the same directory, then verify:

\`\`\`bash
$install_steps
\`\`\`

On first launch, SPIN seeds its writable runtime under
\`~/Library/Application Support/SPIN/runtime\` and opens the onboarding
workspace. SPIN bundles its cmux UI engine and OMP/Pi agent engine; users still
need their own model/provider accounts and normal developer tools.

## macOS Warning

Because this tester build is not Apple-notarized, macOS may block the first
launch or say it cannot verify the developer. After verifying the checksum, try
Finder right-click or Control-click on \`SPIN.app\`, then choose Open.

If macOS still blocks a trusted local tester build, remove quarantine explicitly:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/SPIN.app
open /Applications/SPIN.app
\`\`\`

Do not use the quarantine command for random downloads. Use it only after
checking the SHA-256 above and confirming the artifact came from this project.

## Source And License

This tester release is intended to be distributed with matching source code from
the same GitHub tag or commit. The app bundle includes
\`SPIN.app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md\`.

- SPIN runtime code is MIT.
- OMP/Pi-derived components preserve MIT notices.
- The cmux-derived UI engine is GPL-3.0-or-later unless a commercial cmux
  license is negotiated, so public SPIN.app binaries must be distributed in a
  GPL-compatible way.

## Maintainer Checks

This release was prepared by the checked ad-hoc app pipeline:

\`\`\`bash
scripts/release-macos.sh --source-cmux
scripts/prepare-open-source-release.sh --artifact $ARTIFACT
\`\`\`

The release pipeline verifies bundled cmux/OMP resolution without global
dependencies, app identity, license notices, runtime seeding, restart/session
restore, compatibility metadata, ad-hoc code signatures, artifact extraction,
and installed-app first launch.
EOF

ok "wrote tester release notes"
echo
echo "SPIN open-source tester release prepared:"
echo "  artifact: $ARTIFACT"
echo "  checksum: $SOURCE_SHA"
echo "  manifest: $SOURCE_MANIFEST"
echo "  notes:    $NOTES"
