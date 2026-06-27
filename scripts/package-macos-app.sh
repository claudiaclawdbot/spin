#!/usr/bin/env bash
# Build a developer SPIN.app bundle from this checkout.
#
# This packages the current SPIN runtime and release assets. It does not compile
# the long-term Swift cmux fork; pass SPIN_CMUX_APP_SOURCE and SPIN_CMUX_BIN_SOURCE
# when producing a source-built release. OMP defaults to vendor/bin/omp from
# scripts/vendor-app-deps.sh --omp-only unless SPIN_OMP_BIN_SOURCE is intentional.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${1:-$ROOT/dist/SPIN.app}"
CONTENTS="$OUT/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
RUNTIME="$RES/runtime"

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude 'dist' \
      --exclude 'app/upstream' \
      --exclude 'agent/upstream' \
      --exclude 'agent/vendor/npm' \
      --exclude 'agent/vendor/omp/node_modules' \
      --exclude 'agent/vendor/omp/build' \
      --exclude 'vendor/sources' \
      --exclude 'vendor/bin' \
      --exclude 'node_modules' \
      "$src"/ "$dst"/
  else
    (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -)
  fi
}

copy_cmux_app_if_present() {
  local source="${SPIN_CMUX_APP_SOURCE:-}"
  if [ -z "$source" ]; then
    echo "  warning: source-built cmux app not bundled; set SPIN_CMUX_APP_SOURCE" >&2
    return 1
  fi
  [ -d "$source" ] || {
    echo "  warning: SPIN_CMUX_APP_SOURCE is not an app bundle: $source" >&2
    return 1
  }
  rm -rf "$RES/SPIN.app"
  if command -v rsync >/dev/null 2>&1; then
    mkdir -p "$RES/SPIN.app"
    rsync -a --delete "$source"/ "$RES/SPIN.app"/
  else
    cp -R "$source" "$RES/SPIN.app"
  fi
  echo "  bundled cmux app from $source"
}

copy_binary_if_present() {
  local name="$1" source_var="$2" source=""
  eval "source=\${$source_var:-}"
  if [ -n "$source" ] && [ -x "$source" ]; then
    cp "$source" "$RES/bin/$name"
    chmod +x "$RES/bin/$name"
    echo "  bundled $name from $source"
    return 0
  fi
  if [ -x "$ROOT/vendor/bin/$name" ]; then
    cp "$ROOT/vendor/bin/$name" "$RES/bin/$name"
    chmod +x "$RES/bin/$name"
    echo "  bundled $name from vendor/bin/$name"
    return 0
  fi
  echo "  warning: $name not bundled; set $source_var or provide vendor/bin/$name" >&2
  return 1
}

copy_agent_alias_if_present() {
  if [ -x "$RES/bin/omp" ]; then
    cat > "$RES/bin/spin-agent" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
exec "$DIR/omp" "$@"
EOF
    chmod +x "$RES/bin/spin-agent"
    echo "  added spin-agent alias for bundled omp"
  fi
}

copy_omp_companions_if_present() {
  local source="${SPIN_OMP_NATIVE_SOURCE:-}" omp_source="${SPIN_OMP_BIN_SOURCE:-}" native copied=0 use_root_vendor=0
  if { [ -z "$omp_source" ] || [ "$omp_source" = "$ROOT/vendor/bin/omp" ]; } && [ -x "$ROOT/vendor/bin/omp" ]; then
    use_root_vendor=1
  fi
  if [ -n "$source" ] && [ -f "$source" ]; then
    cp "$source" "$RES/bin/$(basename "$source")"
    copied=1
    echo "  bundled OMP native addon from $source"
  fi
  if [ "$use_root_vendor" = "1" ]; then
    for native in "$ROOT"/vendor/bin/pi_natives.*.node; do
      [ -f "$native" ] || continue
      cp "$native" "$RES/bin/$(basename "$native")"
      copied=1
      echo "  bundled OMP native addon from $native"
    done
  fi
  if [ "$use_root_vendor" = "1" ] && [ -f "$ROOT/agent/vendor/omp/metadata.json" ]; then
    cp "$ROOT/agent/vendor/omp/metadata.json" "$RES/app/omp-vendor.json"
    echo "  bundled OMP vendor metadata"
    if [ -f "$ROOT/agent/vendor/omp/bun.lock" ]; then
      cp "$ROOT/agent/vendor/omp/bun.lock" "$RES/app/omp-bun.lock"
      echo "  bundled OMP vendor lockfile"
    fi
  elif [ "$copied" = "1" ]; then
    echo "  warning: OMP native addon bundled without agent/vendor/omp/metadata.json" >&2
  fi
}

copy_app_icon_if_present() {
  local icon="$ROOT/assets/branding/SPIN.icns"
  if [ ! -f "$icon" ] && [ -x "$ROOT/scripts/build-app-icon.sh" ]; then
    "$ROOT/scripts/build-app-icon.sh" "$ROOT/assets/branding/spin-icon.svg" "$icon" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$icon" ]; then
    echo "  warning: SPIN.icns not bundled; run scripts/build-app-icon.sh on macOS" >&2
    return 1
  fi
  cp "$icon" "$RES/SPIN.icns"
  echo "  bundled app icon from $icon"
}

normalize_bundled_cmux_app_icon_plist() {
  local plist="$1"
  [ -f "$plist" ] || return 0
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$plist" >/dev/null 2>&1 ||
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    node - "$plist" <<'NODE'
const fs = require('fs');
const plist = process.argv[2];
let xml = fs.readFileSync(plist, 'utf8');
if (!xml.includes('<plist')) {
  console.error(`  warning: ${plist} is not an XML plist; cannot normalize icon keys without PlistBuddy`);
  process.exit(0);
}
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const stringKeyPattern = (key) =>
  new RegExp(`\\n?\\s*<key>${escapeRegExp(key)}</key>\\s*\\n?\\s*<string>[\\s\\S]*?</string>`, 'g');
xml = xml.replace(stringKeyPattern('CFBundleIconName'), '');
const iconFileEntry = '  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>';
if (stringKeyPattern('CFBundleIconFile').test(xml)) {
  xml = xml.replace(stringKeyPattern('CFBundleIconFile'), `\n${iconFileEntry}`);
} else {
  xml = xml.replace(/(\s*<\/dict>\s*<\/plist>\s*)$/, `\n${iconFileEntry}$1`);
}
fs.writeFileSync(plist, xml);
NODE
    return 0
  fi
  echo "  warning: node not found; bundled cmux app may retain asset-catalog icon name" >&2
}

apply_icon_to_bundled_cmux_app() {
  [ -f "$RES/SPIN.icns" ] || return 0
  [ -d "$RES/SPIN.app/Contents" ] || return 0
  local plist="$RES/SPIN.app/Contents/Info.plist"
  mkdir -p "$RES/SPIN.app/Contents/Resources"
  cp "$RES/SPIN.icns" "$RES/SPIN.app/Contents/Resources/AppIcon.icns"
  normalize_bundled_cmux_app_icon_plist "$plist"
  echo "  applied SPIN icon to bundled cmux app"
}

rm -rf "$OUT"
mkdir -p "$MACOS" "$RES/bin" "$RES/app/cmux" "$RES/assets" "$RES/licenses"

cp "$ROOT/app/macos/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/app/macos/SPIN" "$MACOS/SPIN"
chmod +x "$MACOS/SPIN"

copy_tree "$ROOT" "$RUNTIME"

cp "$ROOT/app/spin-app.json" "$RES/app/spin-app.json"
cp -R "$ROOT/app/cmux/config" "$RES/app/cmux/config"
cp -R "$ROOT/app/cmux/sidebars" "$RES/app/cmux/sidebars"
cp -R "$ROOT/assets/branding" "$RES/assets/branding"
cp "$ROOT/LICENSE" "$RES/licenses/SPIN-MIT.txt"
[ -f "$ROOT/licenses/THIRD_PARTY_NOTICES.md" ] && cp "$ROOT/licenses/THIRD_PARTY_NOTICES.md" "$RES/licenses/THIRD_PARTY_NOTICES.md"

copy_app_icon_if_present || true
copy_binary_if_present cmux SPIN_CMUX_BIN_SOURCE || true
copy_binary_if_present omp SPIN_OMP_BIN_SOURCE || true
copy_omp_companions_if_present
copy_agent_alias_if_present
copy_cmux_app_if_present || true
apply_icon_to_bundled_cmux_app
SPIN_COMPAT_ROOT="$ROOT" node "$ROOT/scripts/app-compatibility.js" write "$OUT" >/dev/null
echo "  wrote release compatibility manifest"

echo "SPIN.app staged at: $OUT"
echo "Run release checks with: scripts/check-app-release.sh '$OUT'"
