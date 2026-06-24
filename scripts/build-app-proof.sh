#!/usr/bin/env bash
# build-app-proof.sh — build the bounded self-contained SPIN.app checkpoint.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MODE="binary"
if [ "${1:-}" = "--source-cmux" ]; then
  MODE="source"
  shift
fi
OUT="${1:-$ROOT/dist/SPIN.app}"
BUILD_ENV="${SPIN_CMUX_BUILD_ENV:-$ROOT/dist/cmux-spin-build.env}"

source "$ROOT/scripts/lib/spin-runtime.sh"

find_installed_cmux_app() {
  local app
  for app in \
    "${SPIN_CMUX_APP_SOURCE:-}" \
    /Applications/cmux.app \
    /opt/homebrew/Caskroom/cmux/*/cmux.app \
    /usr/local/Caskroom/cmux/*/cmux.app; do
    [ -d "$app" ] && { printf '%s\n' "$app"; return 0; }
  done
  if command -v mdfind >/dev/null 2>&1; then
    mdfind 'kMDItemCFBundleIdentifier == "com.cmuxterm.app"' 2>/dev/null | head -1
  fi
}

find_vendored_omp() {
  [ -x "$ROOT/vendor/bin/omp" ] && { printf '%s\n' "$ROOT/vendor/bin/omp"; return 0; }
  return 1
}

refresh_launch_services_registration() {
  local app="$1" build_product="${2:-}"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
  [ -x "$lsregister" ] || return 0
  if [ -n "$build_product" ] && [ "$build_product" != "$app" ]; then
    "$lsregister" -u "$build_product" >/dev/null 2>&1 || true
  fi
  "$lsregister" -f -R -trusted "$app" >/dev/null 2>&1 || true
}

if [ "$MODE" = "source" ]; then
  "$ROOT/scripts/ensure-xcode.sh" --check >/dev/null || "$ROOT/scripts/ensure-xcode.sh"
  "$ROOT/scripts/build-cmux-spin.sh"
  # shellcheck disable=SC1090
  source "$BUILD_ENV"
else
  CMUX_APP="$(find_installed_cmux_app)"
fi

CMUX_APP="${SPIN_CMUX_APP_SOURCE:-}"
if [ -z "$CMUX_APP" ] && [ "$MODE" = "binary" ]; then
  CMUX_APP="$(find_installed_cmux_app)"
fi
CMUX_BIN="${SPIN_CMUX_BIN_SOURCE:-}"
if [ -z "$CMUX_BIN" ] || [ ! -x "$CMUX_BIN" ]; then
  CMUX_BIN="$(spin_resolve_binary cmux)" || {
    echo "cmux CLI not found. Install cmux or make the cmux Xcode build produce a CLI." >&2
    exit 1
  }
fi
OMP_BIN="${SPIN_OMP_BIN_SOURCE:-}"
if [ -z "$OMP_BIN" ] || [ ! -x "$OMP_BIN" ]; then
  OMP_BIN="$(find_vendored_omp || true)"
fi
if [ -z "$OMP_BIN" ] || [ ! -x "$OMP_BIN" ]; then
  if [ "${SPIN_ALLOW_GLOBAL_OMP_INPUT:-}" = "1" ]; then
    OMP_BIN="$(spin_resolve_binary omp)" || {
      echo "omp not found. Run scripts/vendor-app-deps.sh --omp-only or install OMP/Pi and set SPIN_ALLOW_GLOBAL_OMP_INPUT=1." >&2
      exit 1
    }
  else
    echo "vendored OMP/Pi binary not found at vendor/bin/omp." >&2
    echo "Run: scripts/vendor-app-deps.sh --omp-only" >&2
    echo "To use a one-off global omp input anyway, set SPIN_ALLOW_GLOBAL_OMP_INPUT=1." >&2
    exit 1
  fi
fi

[ -d "$CMUX_APP" ] || {
  echo "SPIN cmux app source not found: $CMUX_APP" >&2
  exit 1
}

CMUX_VERSION="$("$CMUX_BIN" version 2>/dev/null | head -1 || true)"
OMP_VERSION="$("$OMP_BIN" --version 2>/dev/null | head -1 || true)"
[ -n "$CMUX_VERSION" ] || { echo "bundled cmux candidate did not report a version: $CMUX_BIN" >&2; exit 1; }
[ -n "$OMP_VERSION" ] || { echo "bundled omp candidate did not report a version: $OMP_BIN" >&2; exit 1; }

SPIN_CMUX_APP_SOURCE="$CMUX_APP" \
SPIN_CMUX_BIN_SOURCE="$CMUX_BIN" \
SPIN_OMP_BIN_SOURCE="$OMP_BIN" \
SPIN_APP_BUILD_MODE="$MODE-cmux" \
  "$ROOT/scripts/package-macos-app.sh" "$OUT"

if [ "$MODE" = "source" ]; then
  SPIN_REQUIRE_BRANDED_CMUX_APP=1 SPIN_REQUIRE_VENDORED_OMP=1 "$ROOT/scripts/check-app-release.sh" "$OUT"
  refresh_launch_services_registration "$OUT" "$CMUX_APP"
else
  "$ROOT/scripts/check-app-release.sh" "$OUT"
fi

cat <<EOF

SPIN.app proof complete:
  mode: $MODE
  app: $OUT
  cmux app: $CMUX_APP
  cmux CLI: $CMUX_BIN
  cmux version: $CMUX_VERSION
  omp: $OMP_BIN
  omp version: $OMP_VERSION
EOF
