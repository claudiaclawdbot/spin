#!/usr/bin/env bash
# Run the full bounded macOS app release pipeline.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="$ROOT/dist/SPIN.app"
RELEASE_DIR="${SPIN_RELEASE_DIR:-$ROOT/dist/release}"
MODE="binary"
SKIP_VENDOR=0
SKIP_BUILD=0
PRODUCTION=0
FORMAT="${SPIN_RELEASE_FORMAT:-zip}"

usage() {
  cat <<'EOF'
Usage: scripts/release-macos.sh [options]

Options:
  --source-cmux          build the SPIN-branded cmux app from source
  --binary-cmux          use an existing cmux app/CLI input (default)
  --skip-vendor          do not run vendor-app-deps when OMP release input exists
  --skip-build           use --app as an already-built SPIN.app
  --app PATH             app bundle path; default: dist/SPIN.app
  --release-dir PATH     output directory; default: dist/release
  --production           require Developer ID/notarization preflight
  -h, --help             show this help

Default local releases are ad-hoc signed and do not require Apple credentials.
Production releases require SPIN_CODESIGN_IDENTITY, SPIN_APPLE_TEAM_ID or an
inferable team id, SPIN_CMUX_ENTITLEMENTS, SPIN_NOTARIZE=1, and
SPIN_NOTARY_PROFILE.
Set SPIN_RELEASE_FORMAT=dmg to produce a public beta DMG instead of a zip.
EOF
}

fail(){ echo "macOS release failed: $*" >&2; exit 1; }
step(){ echo; echo "==> $*"; }
ok(){ echo "  ok: $*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-cmux) MODE="source"; shift ;;
    --binary-cmux) MODE="binary"; shift ;;
    --skip-vendor) SKIP_VENDOR=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --production) PRODUCTION=1; shift ;;
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

case "$FORMAT" in
  zip|dmg) ;;
  *) fail "SPIN_RELEASE_FORMAT must be zip or dmg, got: $FORMAT" ;;
esac

if [ "${APP#/}" = "$APP" ]; then
  APP="$(cd "$(dirname "$APP")" >/dev/null 2>&1 && pwd)/$(basename "$APP")"
fi
if [ "${RELEASE_DIR#/}" = "$RELEASE_DIR" ]; then
  mkdir -p "$(dirname "$RELEASE_DIR")"
  RELEASE_DIR="$(cd "$(dirname "$RELEASE_DIR")" >/dev/null 2>&1 && pwd)/$(basename "$RELEASE_DIR")"
fi

if [ "$PRODUCTION" = "1" ]; then
  export SPIN_RELEASE_PRODUCTION=1
  step "Production signing preflight"
  "$ROOT/scripts/check-macos-signing-env.sh" --production
fi

if [ "$SKIP_VENDOR" != "1" ]; then
  if [ -x "$ROOT/vendor/bin/omp" ] && [ -f "$ROOT/agent/vendor/omp/metadata.json" ]; then
    ok "vendored OMP input already present"
  else
    step "Vendoring OMP/Pi release input"
    "$ROOT/scripts/vendor-app-deps.sh" --omp-only
  fi
fi

if [ "$SKIP_BUILD" = "1" ]; then
  [ -d "$APP" ] || fail "--skip-build app not found: $APP"
  step "Refreshing compatibility manifest"
  SPIN_COMPAT_ROOT="$ROOT" node "$ROOT/scripts/app-compatibility.js" write "$APP" >/dev/null
  ok "compatibility manifest refreshed"
  step "Checking existing app bundle"
  SPIN_REQUIRE_BRANDED_CMUX_APP=1 SPIN_REQUIRE_VENDORED_OMP=1 \
    "$ROOT/scripts/check-app-release.sh" "$APP"
else
  step "Building app proof"
  build_args=()
  if [ "$MODE" = "source" ]; then
    build_args+=(--source-cmux)
  fi
  build_args+=("$APP")
  "$ROOT/scripts/build-app-proof.sh" "${build_args[@]}"

  step "Checking app bundle"
  SPIN_REQUIRE_BRANDED_CMUX_APP=1 SPIN_REQUIRE_VENDORED_OMP=1 \
    "$ROOT/scripts/check-app-release.sh" "$APP"
fi

step "Packaging macOS release artifact"
release_channel="${SPIN_RELEASE_CHANNEL:-}"
if [ -z "$release_channel" ]; then
  if [ "$PRODUCTION" = "1" ]; then release_channel="production"; else release_channel="ad-hoc"; fi
fi
SPIN_RELEASE_DIR="$RELEASE_DIR" \
SPIN_RELEASE_CHANNEL="$release_channel" \
SPIN_REQUIRE_BRANDED_CMUX_APP=1 \
SPIN_REQUIRE_VENDORED_OMP=1 \
  "$ROOT/scripts/package-macos-release.sh" "$APP"

artifact="$(ls -t "$RELEASE_DIR"/SPIN-*-macos-*."$FORMAT" 2>/dev/null | head -1 || true)"
[ -n "$artifact" ] || fail "release artifact was not created in $RELEASE_DIR"

step "Checking installed app artifact"
"$ROOT/scripts/check-installed-app.sh" "$artifact"

step "Signing environment report"
if [ "$PRODUCTION" = "1" ]; then
  "$ROOT/scripts/check-macos-signing-env.sh" --production
else
  "$ROOT/scripts/check-macos-signing-env.sh"
fi

checksum_file="$artifact.sha256"
manifest_file="${artifact%.$FORMAT}.manifest"
[ -f "$checksum_file" ] || fail "missing checksum: $checksum_file"
[ -f "$manifest_file" ] || fail "missing manifest: $manifest_file"

echo
echo "SPIN macOS release complete:"
echo "  app:      $APP"
echo "  artifact: $artifact"
echo "  sha256:   $(awk '{print $1}' "$checksum_file")"
echo "  manifest: $manifest_file"
