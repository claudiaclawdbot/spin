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
  local source="${SPIN_OMP_NATIVE_SOURCE:-}" omp_source="${SPIN_OMP_BIN_SOURCE:-}" native copied=0 metadata_copied=0 use_root_vendor=0
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
  if [ "$use_root_vendor" != "1" ] && [ -n "$omp_source" ]; then
    local source_bin_dir source_res_dir
    source_bin_dir="$(cd "$(dirname "$omp_source")" >/dev/null 2>&1 && pwd)"
    source_res_dir="$(cd "$source_bin_dir/.." >/dev/null 2>&1 && pwd)"
    for native in "$source_bin_dir"/pi_natives.*.node; do
      [ -f "$native" ] || continue
      cp "$native" "$RES/bin/$(basename "$native")"
      copied=1
      echo "  bundled OMP native addon from $native"
    done
    if [ -f "$source_res_dir/app/omp-vendor.json" ]; then
      cp "$source_res_dir/app/omp-vendor.json" "$RES/app/omp-vendor.json"
      metadata_copied=1
      echo "  bundled OMP vendor metadata from source app"
      if [ -f "$source_res_dir/app/omp-bun.lock" ]; then
        cp "$source_res_dir/app/omp-bun.lock" "$RES/app/omp-bun.lock"
        echo "  bundled OMP vendor lockfile from source app"
      fi
    fi
  fi
  if [ "$use_root_vendor" = "1" ] && [ -f "$ROOT/agent/vendor/omp/metadata.json" ]; then
    cp "$ROOT/agent/vendor/omp/metadata.json" "$RES/app/omp-vendor.json"
    metadata_copied=1
    echo "  bundled OMP vendor metadata"
    if [ -f "$ROOT/agent/vendor/omp/bun.lock" ]; then
      cp "$ROOT/agent/vendor/omp/bun.lock" "$RES/app/omp-bun.lock"
      echo "  bundled OMP vendor lockfile"
    fi
  elif [ "$copied" = "1" ] && [ "$metadata_copied" != "1" ]; then
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

resolve_spin_app_bundle_version() {
  spin_package_runtime_version="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  spin_package_short_version="${spin_package_runtime_version%%-*}"
  spin_package_build_number="${SPIN_BUILD_NUMBER:-}"
  if [ -z "$spin_package_build_number" ]; then
    spin_package_build_number="$(printf '%s' "$spin_package_runtime_version" | sed -n 's/.*\.\([0-9][0-9]*\)$/\1/p')"
  fi
  [ -n "$spin_package_build_number" ] || spin_package_build_number=1
  [[ "$spin_package_short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "  error: VERSION must start with a three-part numeric app version: $spin_package_runtime_version" >&2
    return 1
  }
  [[ "$spin_package_build_number" =~ ^[0-9]+$ ]] || {
    echo "  error: SPIN_BUILD_NUMBER must be numeric: $spin_package_build_number" >&2
    return 1
  }
}

set_plist_string_value() {
  local plist="$1" key="$2" value="$3"
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 ||
      /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
    return 0
  fi
  node - "$plist" "$key" "$value" <<'NODE'
const fs = require('fs');
const [plist, key, value] = process.argv.slice(2);
let xml = fs.readFileSync(plist, 'utf8');
if (!xml.includes('<plist')) throw new Error(`${plist} is not an XML plist and PlistBuddy is unavailable`);
const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const pattern = new RegExp(`(<key>${escapedKey}</key>\\s*<string>)[\\s\\S]*?(</string>)`);
if (!pattern.test(xml)) throw new Error(`missing ${key} in ${plist}`);
xml = xml.replace(pattern, `$1${value}$2`);
fs.writeFileSync(plist, xml);
NODE
}

stamp_app_bundle_version() {
  local plist="$1" label="$2"
  resolve_spin_app_bundle_version
  set_plist_string_value "$plist" CFBundleShortVersionString "$spin_package_short_version"
  set_plist_string_value "$plist" CFBundleVersion "$spin_package_build_number"
  echo "  stamped $label version $spin_package_short_version ($spin_package_build_number) from runtime $spin_package_runtime_version"
}

stamp_outer_app_version() {
  stamp_app_bundle_version "$CONTENTS/Info.plist" "outer app"
}

stamp_bundled_cmux_app_version() {
  local plist="$RES/SPIN.app/Contents/Info.plist"
  [ -f "$plist" ] || return 0
  stamp_app_bundle_version "$plist" "bundled SPIN UI"
}

cmux_source_commit_from_manifest() {
  local manifest="$1"
  [ -f "$manifest" ] || return 1
  node - "$manifest" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const commit = manifest.cmux && manifest.cmux.source && manifest.cmux.source.commit;
if (!commit) process.exit(1);
process.stdout.write(commit);
NODE
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

codesign_developer_inner_code() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local codesign_bin="/usr/bin/codesign" target
  [ -x "$codesign_bin" ] || {
    echo "  error: codesign is required to stage a runnable macOS app" >&2
    return 1
  }

  while IFS= read -r -d '' target; do
    "$codesign_bin" --force --sign - --timestamp=none "$target" >/dev/null
  done < <(find "$RES/bin" -type f \( -perm +111 -o -name '*.node' -o -name '*.dylib' \) -print0)
  "$codesign_bin" --force --sign - --timestamp=none --deep "$RES/SPIN.app" >/dev/null
}

codesign_developer_outer_app() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local codesign_bin="/usr/bin/codesign"
  "$codesign_bin" --force --sign - --timestamp=none "$OUT" >/dev/null
  "$codesign_bin" --verify --deep --strict --verbose=2 "$OUT" >/dev/null
  "$codesign_bin" --verify --strict --verbose=2 "$RES/SPIN.app" >/dev/null
  echo "  ad-hoc codesigned developer app"
}

stage_cmux_source_commit="${SPIN_CMUX_SOURCE_COMMIT:-}"
if [ -z "$stage_cmux_source_commit" ] && [ -n "${SPIN_CMUX_APP_SOURCE:-}" ]; then
  stage_cmux_source_commit="$(cmux_source_commit_from_manifest "$(dirname "$SPIN_CMUX_APP_SOURCE")/app/release-compat.json" 2>/dev/null || true)"
fi
if [ -z "$stage_cmux_source_commit" ] && [ -f "$OUT/Contents/Resources/app/release-compat.json" ]; then
  stage_cmux_source_commit="$(cmux_source_commit_from_manifest "$OUT/Contents/Resources/app/release-compat.json" 2>/dev/null || true)"
fi

rm -rf "$OUT"
mkdir -p "$MACOS" "$RES/bin" "$RES/app/cmux" "$RES/assets" "$RES/licenses"

cp "$ROOT/app/macos/Info.plist" "$CONTENTS/Info.plist"
stamp_outer_app_version
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
stamp_bundled_cmux_app_version
stage_codesign_identity="unsigned"
if [ "$(uname -s)" = "Darwin" ]; then
  stage_codesign_identity="-"
fi
codesign_developer_inner_code
SPIN_COMPAT_ROOT="$ROOT" \
SPIN_RELEASE_CHANNEL=local-dev \
SPIN_CODESIGN_IDENTITY="$stage_codesign_identity" \
SPIN_APPLE_TEAM_ID= \
SPIN_CODESIGN_HARDENED=0 \
SPIN_NOTARIZE=0 \
SPIN_NOTARY_PROFILE= \
SPIN_CMUX_SOURCE_COMMIT="$stage_cmux_source_commit" \
  node "$ROOT/scripts/app-compatibility.js" write "$OUT" >/dev/null
echo "  wrote release compatibility manifest"
codesign_developer_outer_app

echo "SPIN.app staged at: $OUT"
echo "Run release checks with: scripts/check-app-release.sh '$OUT'"
