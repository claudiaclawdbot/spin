#!/usr/bin/env bash
# Generate the macOS SPIN.icns app icon from the source fidget-spinner SVG.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${1:-$ROOT/assets/branding/spin-icon.svg}"
OUT="${2:-$ROOT/assets/branding/SPIN.icns}"
TMP=""

fail(){ echo "build app icon failed: $*" >&2; exit 1; }
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

[ -f "$SRC" ] || fail "missing source SVG: $SRC"
command -v qlmanage >/dev/null 2>&1 || fail "qlmanage not found; run this on macOS"
command -v sips >/dev/null 2>&1 || fail "sips not found; run this on macOS"
command -v iconutil >/dev/null 2>&1 || fail "iconutil not found; run this on macOS"

TMP="$(mktemp -d)"
mkdir -p "$TMP/icon.iconset" "$(dirname "$OUT")"

qlmanage -t -s 1024 -o "$TMP" "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" >/dev/null
MASTER="$(find "$TMP" -maxdepth 1 -name '*.png' -print -quit)"
[ -f "$MASTER" ] || fail "Quick Look did not render a PNG from $SRC"

make_icon() {
  local pixels="$1" name="$2"
  sips -z "$pixels" "$pixels" "$MASTER" --out "$TMP/icon.iconset/$name" >/dev/null
}

make_icon 16   icon_16x16.png
make_icon 32   icon_16x16@2x.png
make_icon 32   icon_32x32.png
make_icon 64   icon_32x32@2x.png
make_icon 128  icon_128x128.png
make_icon 256  icon_128x128@2x.png
make_icon 256  icon_256x256.png
make_icon 512  icon_256x256@2x.png
make_icon 512  icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$TMP/icon.iconset" -o "$OUT"
echo "wrote $OUT"
