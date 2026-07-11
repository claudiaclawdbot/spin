#!/usr/bin/env bash
# build-cmux-spin.sh — source-build the SPIN-branded cmux app with the overlay.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CMUX_DIR="${SPIN_CMUX_DIR:-$ROOT/app/upstream/cmux}"
DERIVED_DATA="${SPIN_CMUX_DERIVED_DATA:-$CMUX_DIR/build-spin}"
OUT_ENV="${SPIN_CMUX_BUILD_ENV:-$ROOT/dist/cmux-spin-build.env}"
CONFIGURATION="${SPIN_CMUX_CONFIGURATION:-Release}"
ARCHS="${SPIN_CMUX_ARCHS:-$(uname -m)}"
ONLY_ACTIVE_ARCH="${SPIN_CMUX_ONLY_ACTIVE_ARCH:-YES}"
CMUX_COMMIT="${SPIN_CMUX_COMMIT:-}"
if [ -z "$CMUX_COMMIT" ] && command -v node >/dev/null 2>&1 && [ -f "$ROOT/app/spin-app.json" ]; then
  CMUX_COMMIT="$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.components?.uiEngine?.upstreamCommit || "")' \
    "$ROOT/app/spin-app.json" 2>/dev/null || true)"
fi

if [[ ! "$CMUX_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "cmux source build requires a pinned 40-character commit" >&2
  exit 1
fi

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

"$ROOT/scripts/ensure-xcode.sh" --check >/dev/null || {
  echo "Full Xcode is required to build the SPIN cmux app. Run: scripts/ensure-xcode.sh" >&2
  exit 2
}

if [ ! -d "$CMUX_DIR/.git" ] || [ "$(git -C "$CMUX_DIR" rev-parse HEAD 2>/dev/null || true)" != "$CMUX_COMMIT" ]; then
  SPIN_CMUX_COMMIT="$CMUX_COMMIT" "$ROOT/scripts/vendor-app-deps.sh" --cmux-only
fi

actual_cmux_commit="$(git -C "$CMUX_DIR" rev-parse HEAD 2>/dev/null || true)"
[ "$actual_cmux_commit" = "$CMUX_COMMIT" ] || {
  echo "cmux source checkout mismatch before overlay: expected $CMUX_COMMIT, got ${actual_cmux_commit:-missing}" >&2
  exit 1
}

SPIN_CMUX_COMMIT="$CMUX_COMMIT" SPIN_CMUX_REF="$CMUX_COMMIT" SPIN_CMUX_OVERLAY_NO_FETCH=1 \
  "$ROOT/scripts/apply-cmux-spin-overlay.sh" "$CMUX_DIR"

actual_cmux_commit="$(git -C "$CMUX_DIR" rev-parse HEAD 2>/dev/null || true)"
[ "$actual_cmux_commit" = "$CMUX_COMMIT" ] || {
  echo "cmux source checkout drifted during overlay: expected $CMUX_COMMIT, got ${actual_cmux_commit:-missing}" >&2
  exit 1
}

cd "$CMUX_DIR"
echo "Building SPIN cmux app with Xcode..."
CMUX_SKIP_ZIG_BUILD="${CMUX_SKIP_ZIG_BUILD:-1}" \
xcodebuild \
  -workspace cmux.xcworkspace \
  -scheme cmux \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$CMUX_DIR/.spm-cache" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
  CODE_SIGNING_ALLOWED=NO \
  build

PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
CMUX_APP="$(find "$PRODUCTS" -maxdepth 3 -type d -name 'SPIN.app' | head -1)"
CMUX_BIN="$(find "$PRODUCTS" -maxdepth 4 -type f -perm -111 \( -name 'cmux' -o -name 'SPIN' \) | head -1)"

[ -n "$CMUX_APP" ] || {
  echo "Xcode build completed but no SPIN.app was found under $PRODUCTS" >&2
  exit 1
}

ICON="$ROOT/assets/branding/SPIN.icns"
if [ ! -f "$ICON" ] && [ -x "$ROOT/scripts/build-app-icon.sh" ]; then
  "$ROOT/scripts/build-app-icon.sh" "$ROOT/assets/branding/spin-icon.svg" "$ICON" >/dev/null 2>&1 || true
fi
if [ -f "$ICON" ]; then
  mkdir -p "$CMUX_APP/Contents/Resources"
  cp "$ICON" "$CMUX_APP/Contents/Resources/AppIcon.icns"
  touch "$CMUX_APP"
  if [ -x /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -f -R -trusted "$CMUX_APP" >/dev/null 2>&1 || true
  fi
  echo "Stamped SPIN icon into cmux build product"
else
  echo "warning: SPIN app icon not found; build product may keep the upstream cmux icon" >&2
fi

mkdir -p "$(dirname "$OUT_ENV")"
{
  printf 'SPIN_CMUX_APP_SOURCE='; quote_sh "$CMUX_APP"; printf '\n'
  printf 'SPIN_CMUX_BIN_SOURCE='; quote_sh "$CMUX_BIN"; printf '\n'
} > "$OUT_ENV"

echo "SPIN cmux app: $CMUX_APP"
if [ -n "$CMUX_BIN" ]; then
  echo "SPIN cmux CLI: $CMUX_BIN"
else
  echo "SPIN cmux CLI: not found in Xcode products; build-app-proof will use an installed real cmux CLI."
fi
echo "Build env: $OUT_ENV"
