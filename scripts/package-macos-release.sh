#!/usr/bin/env bash
# Create an installable macOS release artifact from a proven SPIN.app bundle.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FORMAT="${SPIN_RELEASE_FORMAT:-zip}"
OUT_DIR="${SPIN_RELEASE_DIR:-$ROOT/dist/release}"
IDENTITY="${SPIN_CODESIGN_IDENTITY:--}"
TMP=""

usage() {
  cat <<'EOF'
Usage: scripts/package-macos-release.sh [SPIN.app]

Environment:
  SPIN_RELEASE_FORMAT=zip|dmg       artifact format; default: zip
  SPIN_RELEASE_DIR=dist/release     output directory
  SPIN_CODESIGN_IDENTITY=-          codesign identity; default: ad-hoc
  SPIN_CODESIGN_HARDENED=0|1        hardened runtime; default: 0 for ad-hoc, 1 otherwise
  SPIN_RELEASE_PRODUCTION=1         require Developer ID/notarization preflight
  SPIN_OMP_ENTITLEMENTS=path        optional entitlements for bundled OMP CLI
  SPIN_CMUX_ENTITLEMENTS=path       optional entitlements for bundled cmux app
  SPIN_OUTER_ENTITLEMENTS=path      optional entitlements for outer SPIN.app
  SPIN_SKIP_RELEASE_CHECK=1         skip check-app-release preflight/extract check
  SPIN_NOTARIZE=1                   submit artifact with notarytool
  SPIN_NOTARY_PROFILE=name          keychain profile for notarytool
  SPIN_REQUIRE_GATEKEEPER=1         fail if spctl assessment fails

Developer releases use ad-hoc signing. Production releases should set a
Developer ID Application identity, production entitlements, and SPIN_NOTARIZE=1.
EOF
}

fail(){ echo "release package failed: $*" >&2; exit 1; }
ok(){ echo "  ok: $*"; }
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

APP="${1:-$ROOT/dist/SPIN.app}"
if [ "${APP#/}" = "$APP" ]; then
  APP="$(cd "$(dirname "$APP")" >/dev/null 2>&1 && pwd)/$(basename "$APP")"
fi

case "$FORMAT" in
  zip|dmg) ;;
  *) fail "SPIN_RELEASE_FORMAT must be zip or dmg, got: $FORMAT" ;;
esac

[ -d "$APP" ] || fail "missing app bundle: $APP"
command -v codesign >/dev/null 2>&1 || fail "codesign is required on macOS"
command -v ditto >/dev/null 2>&1 || fail "ditto is required on macOS"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
if [ "$FORMAT" = "dmg" ]; then
  command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required for dmg output"
fi

HARDENED="${SPIN_CODESIGN_HARDENED:-}"
if [ -z "$HARDENED" ]; then
  if [ "$IDENTITY" = "-" ]; then HARDENED=0; else HARDENED=1; fi
fi
case "$HARDENED" in
  0|1) ;;
  *) fail "SPIN_CODESIGN_HARDENED must be 0 or 1, got: $HARDENED" ;;
esac
if [ "${SPIN_NOTARIZE:-0}" = "1" ] && [ "$IDENTITY" = "-" ]; then
  fail "SPIN_NOTARIZE=1 requires a Developer ID signing identity"
fi
if [ "${SPIN_NOTARIZE:-0}" = "1" ] && [ "$HARDENED" != "1" ]; then
  fail "SPIN_NOTARIZE=1 requires SPIN_CODESIGN_HARDENED=1"
fi
if [ "${SPIN_RELEASE_PRODUCTION:-0}" = "1" ]; then
  "$ROOT/scripts/check-macos-signing-env.sh" --production
fi

if [ "${SPIN_SKIP_RELEASE_CHECK:-0}" != "1" ]; then
  "$ROOT/scripts/check-app-release.sh" "$APP"
  ok "source app release contract"
fi

version="0.0.0"
if [ -f "$APP/Contents/Resources/runtime/VERSION" ]; then
  version="$(tr -d '[:space:]' < "$APP/Contents/Resources/runtime/VERSION")"
elif [ -f "$ROOT/VERSION" ]; then
  version="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
version="$(printf '%s' "$version" | sed 's/[^A-Za-z0-9._-]/-/g')"
[ -n "$version" ] || version="0.0.0"

archs="$(lipo -archs "$APP/Contents/Resources/bin/cmux" 2>/dev/null | tr ' ' '+' || true)"
[ -n "$archs" ] || archs="$(uname -m)"

TMP="$(mktemp -d)"
STAGE="$TMP/stage"
DMG_STAGE="$TMP/dmg-stage"
VERIFY="$TMP/verify"
STAGE_APP="$STAGE/SPIN.app"
EXTRACTED_APP="$VERIFY/SPIN.app"
mkdir -p "$STAGE" "$VERIFY" "$OUT_DIR"
ditto --noqtn --noextattr "$APP" "$STAGE_APP"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGE_APP" 2>/dev/null || true
fi
ok "staged app copy"

timestamp_arg=(--timestamp)
if [ "$IDENTITY" = "-" ]; then
  timestamp_arg=(--timestamp=none)
fi
OMP_ENTITLEMENTS="${SPIN_OMP_ENTITLEMENTS:-}"
if [ "$HARDENED" = "1" ] && [ -z "$OMP_ENTITLEMENTS" ]; then
  OMP_ENTITLEMENTS="$TMP/omp.entitlements"
  cat > "$OMP_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
EOF
fi

sign_args() {
  local entitlements="${1:-}"
  printf '%s\0' --force --sign "$IDENTITY" "${timestamp_arg[@]}"
  if [ "$HARDENED" = "1" ]; then
    printf '%s\0' --options runtime
  fi
  if [ -n "$entitlements" ]; then
    [ -f "$entitlements" ] || fail "entitlements file not found: $entitlements"
    printf '%s\0' --entitlements "$entitlements"
  fi
}

codesign_target() {
  local target="$1" entitlements="${2:-}" deep="${3:-0}" args=() output=""
  [ -e "$target" ] || return 0
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(sign_args "$entitlements")
  if [ "$deep" = "1" ]; then
    args+=(--deep)
  fi
  if ! output="$(codesign "${args[@]}" "$target" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

verify_codesign() {
  codesign --verify "$@" >/dev/null 2>&1 || codesign --verify "$@"
}

codesign_inner_code() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' file; do
    if [ "$(basename "$file")" = "omp" ]; then
      codesign_target "$file" "$OMP_ENTITLEMENTS"
    else
      codesign_target "$file"
    fi
  done < <(find "$dir" -type f \( -perm +111 -o -name '*.node' -o -name '*.dylib' \) -print0)
}

codesign_inner_code "$STAGE_APP/Contents/Resources/bin"
codesign_target "$STAGE_APP/Contents/Resources/SPIN.app" "${SPIN_CMUX_ENTITLEMENTS:-}" 1
compat_channel="${SPIN_RELEASE_CHANNEL:-}"
if [ -z "$compat_channel" ]; then
  if [ "${SPIN_RELEASE_PRODUCTION:-0}" = "1" ]; then compat_channel="production"; else compat_channel="ad-hoc"; fi
fi
SPIN_COMPAT_ROOT="$ROOT" SPIN_RELEASE_CHANNEL="$compat_channel" \
  node "$ROOT/scripts/app-compatibility.js" write "$STAGE_APP" >/dev/null
ok "release compatibility manifest"
codesign_target "$STAGE_APP" "${SPIN_OUTER_ENTITLEMENTS:-}" 1
ok "codesigned app using identity '$IDENTITY' (hardened=$HARDENED)"

verify_codesign --deep --strict --verbose=2 "$STAGE_APP"
verify_codesign --strict --verbose=2 "$STAGE_APP/Contents/Resources/SPIN.app"
for bin in cmux omp spin-agent; do
  verify_codesign --verbose=2 "$STAGE_APP/Contents/Resources/bin/$bin"
done
for native in "$STAGE_APP"/Contents/Resources/bin/*.node; do
  [ -e "$native" ] || continue
  verify_codesign --verbose=2 "$native"
done
ok "code signatures verify"

outer_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE_APP/Contents/Info.plist" 2>/dev/null || true)"
inner_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE_APP/Contents/Resources/SPIN.app/Contents/Info.plist" 2>/dev/null || true)"
[ "$outer_id" = "dev.spin.app" ] || fail "outer bundle id is not dev.spin.app: ${outer_id:-missing}"
[ "$inner_id" = "dev.spin.app" ] || fail "inner bundle id is not dev.spin.app: ${inner_id:-missing}"
ok "bundle identifiers"

if command -v xattr >/dev/null 2>&1; then
  quarantine="$(xattr -pr com.apple.quarantine "$STAGE_APP" 2>/dev/null || true)"
  [ -z "$quarantine" ] || fail "staged app still has quarantine xattrs"
  ok "no quarantine xattrs in staged app"
fi

artifact_base="SPIN-${version}-macos-${archs}"
artifact="$OUT_DIR/$artifact_base.$FORMAT"
rm -f "$artifact" "$artifact.sha256" "$OUT_DIR/$artifact_base.manifest"

if [ "$FORMAT" = "zip" ]; then
  (cd "$STAGE" && ditto -c -k --keepParent --sequesterRsrc --rsrc --noqtn --noextattr SPIN.app "$artifact")
  ditto --noqtn --noextattr -x -k "$artifact" "$VERIFY"
else
  mkdir -p "$DMG_STAGE"
  ditto --noqtn --noextattr "$STAGE_APP" "$DMG_STAGE/SPIN.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  if [ -f "$ROOT/assets/branding/SPIN.icns" ]; then
    cp "$ROOT/assets/branding/SPIN.icns" "$DMG_STAGE/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
      SetFile -a C "$DMG_STAGE" >/dev/null 2>&1 || true
    fi
  fi
  cat > "$DMG_STAGE/README.txt" <<EOF
SPIN.app $version macOS beta

Install:
1. Drag SPIN.app onto Applications.
2. Eject the SPIN disk image.
3. Open SPIN.app from Applications.

If macOS says it cannot verify the developer, Control-click SPIN.app and choose
Open after you have verified the downloaded SHA-256 checksum from GitHub.

SPIN bundles its cmux workspace UI and OMP/Pi agent runtime. You still connect
your own model/provider accounts during onboarding.
EOF
  hdiutil create -volname "SPIN" -srcfolder "$DMG_STAGE" -ov -format UDZO "$artifact" >/dev/null
  MOUNT="$(hdiutil attach -nobrowse -readonly "$artifact" | awk '/\/Volumes\//{print $3; exit}')"
  [ -n "$MOUNT" ] || fail "could not mount dmg for verification"
  trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; cleanup' EXIT
  [ -d "$MOUNT/SPIN.app" ] || fail "dmg missing SPIN.app"
  [ -e "$MOUNT/Applications" ] || fail "dmg missing Applications shortcut"
  [ -f "$MOUNT/README.txt" ] || fail "dmg missing README.txt"
  grep -q 'Drag SPIN.app onto Applications' "$MOUNT/README.txt" || fail "dmg README missing install instruction"
  ditto --noqtn --noextattr "$MOUNT/SPIN.app" "$EXTRACTED_APP"
  hdiutil detach "$MOUNT" >/dev/null
  trap cleanup EXIT
fi
ok "created $FORMAT artifact"

[ -d "$EXTRACTED_APP" ] || fail "artifact did not contain SPIN.app"
verify_codesign --deep --strict --verbose=2 "$EXTRACTED_APP"
if command -v xattr >/dev/null 2>&1; then
  quarantine="$(xattr -pr com.apple.quarantine "$EXTRACTED_APP" 2>/dev/null || true)"
  [ -z "$quarantine" ] || fail "extracted app has quarantine xattrs"
fi
if [ "${SPIN_SKIP_RELEASE_CHECK:-0}" != "1" ]; then
  SPIN_SKIP_OMP_VENDOR_HASH=1 "$ROOT/scripts/check-app-release.sh" "$EXTRACTED_APP"
fi
ok "artifact extraction verifies"

if [ "$IDENTITY" != "-" ] && command -v spctl >/dev/null 2>&1; then
  if spctl --assess --type execute --verbose "$EXTRACTED_APP" >/dev/null 2>&1; then
    ok "Gatekeeper assessment"
  elif [ "${SPIN_REQUIRE_GATEKEEPER:-0}" = "1" ]; then
    spctl --assess --type execute --verbose "$EXTRACTED_APP"
  else
    echo "  note: Gatekeeper assessment did not pass; notarization may still be required"
  fi
else
  echo "  note: Gatekeeper assessment skipped for ad-hoc signing"
fi

notarized=false
if [ "${SPIN_NOTARIZE:-0}" = "1" ]; then
  command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for notarization"
  [ -n "${SPIN_NOTARY_PROFILE:-}" ] || fail "SPIN_NOTARY_PROFILE is required when SPIN_NOTARIZE=1"
  xcrun notarytool submit "$artifact" --keychain-profile "$SPIN_NOTARY_PROFILE" --wait
  notarized=true
  if [ "$FORMAT" = "dmg" ]; then
    xcrun stapler staple "$artifact"
    ok "notarized and stapled dmg"
  else
    ok "notarized zip submission"
  fi
else
  echo "  note: notarization skipped; set SPIN_NOTARIZE=1 and SPIN_NOTARY_PROFILE for production"
fi

sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"
compat_sha="$(shasum -a 256 "$STAGE_APP/Contents/Resources/app/release-compat.json" | awk '{print $1}')"
printf '%s  %s\n' "$sha256" "$(basename "$artifact")" > "$artifact.sha256"
cat > "$OUT_DIR/$artifact_base.manifest" <<EOF
artifact=$(basename "$artifact")
version=$version
archs=$archs
format=$FORMAT
codesign_identity=$IDENTITY
notarized=$notarized
sha256=$sha256
compatibility_manifest=SPIN.app/Contents/Resources/app/release-compat.json
compatibility_manifest_sha256=$compat_sha
EOF
ok "release checksum and manifest"

echo
echo "SPIN macOS release artifact:"
echo "  $artifact"
echo "  $artifact.sha256"
echo "  $OUT_DIR/$artifact_base.manifest"
