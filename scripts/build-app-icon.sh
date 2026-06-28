#!/usr/bin/env bash
# Generate the macOS SPIN.icns app icon.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SRC="${1:-$ROOT/assets/branding/spin-icon.svg}"
OUT="${2:-$ROOT/assets/branding/SPIN.icns}"
TMP=""

fail(){ echo "build app icon failed: $*" >&2; exit 1; }
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

[ -f "$SRC" ] || fail "missing source SVG: $SRC"
command -v sips >/dev/null 2>&1 || fail "sips not found; run this on macOS"
command -v iconutil >/dev/null 2>&1 || fail "iconutil not found; run this on macOS"

TMP="$(mktemp -d)"
mkdir -p "$TMP/icon.iconset" "$(dirname "$OUT")"

render_spin_master_with_swift() {
  local out="$1"
  [ "$(basename "$SRC")" = "spin-icon.svg" ] || return 1
  command -v swift >/dev/null 2>&1 || return 1
  cat > "$TMP/render-spin-icon.swift" <<'SWIFT'
import AppKit
import CoreGraphics

let out = CommandLine.arguments[1]
let size = 1024
let side = CGFloat(size)

func color(_ hex: String, alpha: CGFloat = 1.0) -> CGColor {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = Int(trimmed, radix: 16) ?? 0
    return CGColor(
        red: CGFloat((value >> 16) & 0xff) / 255.0,
        green: CGFloat((value >> 8) & 0xff) / 255.0,
        blue: CGFloat(value & 0xff) / 255.0,
        alpha: alpha
    )
}

func gradient(_ start: String, _ end: String) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(start), color(end)] as CFArray,
        locations: [0.0, 1.0]
    )!
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [.alphaFirst],
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

guard let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
    fatalError("could not create bitmap context")
}

context.clear(CGRect(x: 0, y: 0, width: side, height: side))
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.translateBy(x: 0, y: side)
context.scaleBy(x: 1, y: -1)

let neon = gradient("#ff2bd6", "#00e5ff")
let surface = gradient("#2a0035", "#07000d")
let rounded = CGPath(
    roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
    cornerWidth: 236,
    cornerHeight: 236,
    transform: nil
)

context.saveGState()
context.addPath(rounded)
context.clip()
context.drawLinearGradient(surface, start: CGPoint(x: 128, y: 96), end: CGPoint(x: 896, y: 928), options: [])
context.restoreGState()

context.saveGState()
context.addPath(rounded)
context.setLineWidth(22)
context.replacePathWithStrokedPath()
context.clip()
context.drawLinearGradient(neon, start: CGPoint(x: 152, y: 132), end: CGPoint(x: 872, y: 896), options: [])
context.restoreGState()

func fillEllipse(centerX: CGFloat, centerY: CGFloat, radius: CGFloat, fill: CGColor) {
    context.addEllipse(in: CGRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
    context.setFillColor(fill)
    context.fillPath()
}

func strokeEllipse(centerX: CGFloat, centerY: CGFloat, radius: CGFloat, width: CGFloat) {
    context.saveGState()
    context.addEllipse(in: CGRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
    context.setLineWidth(width)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(neon, start: CGPoint(x: 185, y: 140), end: CGPoint(x: 840, y: 884), options: [])
    context.restoreGState()
}

for circle in [(512.0, 320.0, 112.0), (672.0, 656.0, 112.0), (352.0, 656.0, 112.0)] {
    fillEllipse(centerX: CGFloat(circle.0), centerY: CGFloat(circle.1), radius: CGFloat(circle.2), fill: color("#18102b"))
    strokeEllipse(centerX: CGFloat(circle.0), centerY: CGFloat(circle.1), radius: CGFloat(circle.2), width: 44)
}
fillEllipse(centerX: 512, centerY: 512, radius: 70, fill: color("#18102b"))
strokeEllipse(centerX: 512, centerY: 512, radius: 70, width: 48)

context.saveGState()
context.addEllipse(in: CGRect(x: 482, y: 482, width: 60, height: 60))
context.clip()
context.drawLinearGradient(neon, start: CGPoint(x: 152, y: 132), end: CGPoint(x: 872, y: 896), options: [])
context.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: out), options: .atomic)
SWIFT
  swift "$TMP/render-spin-icon.swift" "$out" >/dev/null
}

render_master_with_quicklook() {
  local out="$1" rendered
  command -v qlmanage >/dev/null 2>&1 || return 1
  qlmanage -t -s 1024 -o "$TMP" "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" >/dev/null
  rendered="$(find "$TMP" -maxdepth 1 -name '*.png' -print -quit)"
  [ -f "$rendered" ] || return 1
  cp "$rendered" "$out"
}

MASTER="$TMP/master.png"
if ! render_spin_master_with_swift "$MASTER"; then
  render_master_with_quicklook "$MASTER" || fail "could not render a PNG from $SRC"
fi
[ -f "$MASTER" ] || fail "renderer did not produce $MASTER"

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
