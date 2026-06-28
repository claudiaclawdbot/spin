#!/usr/bin/env bash
# Validate the SPIN.app bundle contract for a self-contained release.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP="${1:-$ROOT/dist/SPIN.app}"
if [ "${APP#/}" = "$APP" ]; then
  APP="$(cd "$(dirname "$APP")" >/dev/null 2>&1 && pwd)/$(basename "$APP")"
fi
RES="$APP/Contents/Resources"
RUNTIME="$RES/runtime"
CMUX_APP="$RES/SPIN.app"
TMP=""
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
NODE_BIN="${SPIN_RELEASE_CHECK_NODE:-$(command -v node || true)}"

fail(){ echo "release check failed: $*" >&2; exit 1; }
ok(){ echo "  ok: $*"; }
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

plist_string() {
  local plist="$1" key="$2" value=""
  if [ -x /usr/libexec/PlistBuddy ]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  if command -v plutil >/dev/null 2>&1; then
    value="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  if command -v node >/dev/null 2>&1; then
    node - "$plist" "$key" <<'NODE'
const fs = require('fs');
const [plist, key] = process.argv.slice(2);
const xml = fs.readFileSync(plist, 'utf8');
const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const match = xml.match(new RegExp(`<key>${escaped}</key>\\s*<string>([\\s\\S]*?)</string>`));
if (!match) process.exit(1);
const value = match[1]
  .replace(/&quot;/g, '"')
  .replace(/&apos;/g, "'")
  .replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>')
  .replace(/&amp;/g, '&');
process.stdout.write(value);
NODE
    return $?
  fi
  return 1
}

assert_icon_has_transparent_corners() {
  local icon="$1" label="$2" work png
  if ! command -v iconutil >/dev/null 2>&1; then
    echo "  warning: iconutil not found; skipping $label icon alpha check" >&2
    return 0
  fi
  work="$(mktemp -d)"
  if ! iconutil -c iconset "$icon" -o "$work/icon.iconset" >/dev/null 2>&1; then
    rm -rf "$work"
    fail "could not expand $label icon for alpha check"
  fi
  png="$work/icon.iconset/icon_512x512@2x.png"
  [ -f "$png" ] || png="$work/icon.iconset/icon_512x512.png"
  [ -f "$png" ] || {
    rm -rf "$work"
    fail "$label iconset is missing a 512px PNG for alpha check"
  }
  "$NODE_BIN" - "$png" "$label" <<'NODE'
const fs = require('fs');
const zlib = require('zlib');
const [pngPath, label] = process.argv.slice(2);

function fail(message) {
  console.error(message);
  process.exit(1);
}

const data = fs.readFileSync(pngPath);
if (data.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') fail(`${label} icon PNG is invalid`);

let offset = 8;
let width = 0;
let height = 0;
let bitDepth = 0;
let colorType = 0;
const idat = [];
while (offset < data.length) {
  const length = data.readUInt32BE(offset);
  offset += 4;
  const type = data.subarray(offset, offset + 4).toString('ascii');
  offset += 4;
  const chunk = data.subarray(offset, offset + length);
  offset += length + 4;
  if (type === 'IHDR') {
    width = chunk.readUInt32BE(0);
    height = chunk.readUInt32BE(4);
    bitDepth = chunk[8];
    colorType = chunk[9];
  } else if (type === 'IDAT') {
    idat.push(chunk);
  } else if (type === 'IEND') {
    break;
  }
}

if (bitDepth !== 8 || colorType !== 6) {
  fail(`${label} icon PNG must be 8-bit RGBA for alpha check`);
}

const raw = zlib.inflateSync(Buffer.concat(idat));
const bpp = 4;
const stride = width * bpp;
const rows = [];
let previous = Buffer.alloc(stride);
let input = 0;

function paeth(left, up, upLeft) {
  const p = left + up - upLeft;
  const pa = Math.abs(p - left);
  const pb = Math.abs(p - up);
  const pc = Math.abs(p - upLeft);
  if (pa <= pb && pa <= pc) return left;
  if (pb <= pc) return up;
  return upLeft;
}

for (let y = 0; y < height; y += 1) {
  const filter = raw[input];
  input += 1;
  const row = Buffer.from(raw.subarray(input, input + stride));
  input += stride;
  for (let x = 0; x < stride; x += 1) {
    const left = x >= bpp ? row[x - bpp] : 0;
    const up = previous[x];
    const upLeft = x >= bpp ? previous[x - bpp] : 0;
    if (filter === 1) row[x] = (row[x] + left) & 0xff;
    else if (filter === 2) row[x] = (row[x] + up) & 0xff;
    else if (filter === 3) row[x] = (row[x] + Math.floor((left + up) / 2)) & 0xff;
    else if (filter === 4) row[x] = (row[x] + paeth(left, up, upLeft)) & 0xff;
    else if (filter !== 0) fail(`${label} icon PNG uses unsupported filter ${filter}`);
  }
  rows.push(row);
  previous = row;
}

function alphaAt(x, y) {
  return rows[y][x * bpp + 3];
}

const corners = [
  alphaAt(0, 0),
  alphaAt(width - 1, 0),
  alphaAt(0, height - 1),
  alphaAt(width - 1, height - 1),
];
if (corners.some((alpha) => alpha !== 0)) {
  fail(`${label} icon corners are opaque: ${corners.join(',')}`);
}
NODE
  rm -rf "$work"
}

assert_spin_sidebar_defaults_seeded() {
  local home="$1" domain plist provider enabled
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ -x /usr/libexec/PlistBuddy ] || return 0
  for domain in dev.spin.app com.cmuxterm.app; do
    plist="$home/Library/Preferences/$domain.plist"
    [ -f "$plist" ] || fail "launcher did not seed $domain preferences for SPIN Navigator rail"
    provider="$(/usr/libexec/PlistBuddy -c "Print :cmuxExtensionSidebar.providerId" "$plist" 2>/dev/null || true)"
    [ "$provider" = "cmux.sidebar.custom.spin-navigator" ] || fail "$domain did not select SPIN Navigator rail: ${provider:-missing}"
    enabled="$(/usr/libexec/PlistBuddy -c "Print :customSidebars.beta.enabled" "$plist" 2>/dev/null || true)"
    [ "$enabled" = "1" ] || [ "$enabled" = "true" ] || fail "$domain did not enable custom sidebars: ${enabled:-missing}"
  done
}

assert_asset_car_spin_icon_assets() {
  local car="$1"
  [ -f "$car" ] || return 0
  command -v xcrun >/dev/null 2>&1 || {
    echo "  warning: xcrun not found; skipping bundled cmux Assets.car icon check" >&2
    return 0
  }
  "$NODE_BIN" - "$car" <<'NODE'
const { spawnSync } = require('child_process');
const car = process.argv[2];
const result = spawnSync('xcrun', ['assetutil', '--info', car], { encoding: 'utf8' });
if (result.status !== 0) {
  console.error(result.stderr || `assetutil failed for ${car}`);
  process.exit(1);
}
let entries;
try {
  entries = JSON.parse(result.stdout);
} catch (error) {
  console.error(`could not parse assetutil output for ${car}: ${error.message}`);
  process.exit(1);
}
for (const name of ['AppIconLight', 'AppIconDark']) {
  const image = entries.find((entry) => entry.Name === name && entry.AssetType === 'Image');
  if (!image) {
    console.error(`bundled cmux Assets.car is missing ${name}`);
    process.exit(1);
  }
  if (image.Opaque !== false) {
    console.error(`bundled cmux ${name} is opaque in Assets.car; Dock icon will show square corners`);
    process.exit(1);
  }
}
NODE
}

[ -d "$APP" ] || fail "missing app bundle: $APP"
[ -f "$APP/Contents/Info.plist" ] || fail "missing Info.plist"
[ -x "$APP/Contents/MacOS/SPIN" ] || fail "missing executable launcher"
[ -f "$RES/app/spin-app.json" ] || fail "missing app manifest"
[ -f "$RES/app/cmux/config/cmux.json" ] || fail "missing bundled cmux config"
grep -q '"hideAllDetails": true' "$RES/app/cmux/config/cmux.json" || fail "bundled cmux config does not hide sidebar details"
grep -q '"showWorkspaceDescription": false' "$RES/app/cmux/config/cmux.json" || fail "bundled cmux config still shows workspace descriptions"
grep -q '"showPorts": false' "$RES/app/cmux/config/cmux.json" || fail "bundled cmux config still shows port rows"
grep -q '"showPullRequests": false' "$RES/app/cmux/config/cmux.json" || fail "bundled cmux config still shows pull request rows"
[ -f "$RES/app/cmux/sidebars/spin-navigator.swift" ] || fail "missing SPIN sidebar"
[ -f "$RUNTIME/scripts/spin" ] || fail "missing runtime spin CLI"
[ -f "$RUNTIME/scripts/org" ] || fail "missing runtime org CLI"

grep -q '<string>SPIN</string>' "$APP/Contents/Info.plist" || fail "app identity is not SPIN"
outer_bundle_id="$(plist_string "$APP/Contents/Info.plist" CFBundleIdentifier || true)"
[ "$outer_bundle_id" = "dev.spin.launcher" ] || fail "outer launcher bundle id is not dev.spin.launcher: ${outer_bundle_id:-missing}"
ok "app identity"

[ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || fail "node not found for release check; set SPIN_RELEASE_CHECK_NODE"

app_icon_file="$(plist_string "$APP/Contents/Info.plist" CFBundleIconFile || true)"
[ "$app_icon_file" = "SPIN" ] || fail "app icon plist key is not SPIN: ${app_icon_file:-missing}"
[ -s "$RES/SPIN.icns" ] || fail "missing app icon at Resources/SPIN.icns"
assert_icon_has_transparent_corners "$RES/SPIN.icns" "SPIN"
ok "app icon"

[ -d "$CMUX_APP" ] || fail "missing bundled cmux app at Resources/SPIN.app"
[ -f "$CMUX_APP/Contents/Info.plist" ] || fail "bundled cmux app missing Info.plist"
cmux_bundle_id="$(plist_string "$CMUX_APP/Contents/Info.plist" CFBundleIdentifier || true)"
if [ "${SPIN_REQUIRE_BRANDED_CMUX_APP:-}" = "1" ]; then
  [ "$cmux_bundle_id" = "dev.spin.app" ] || fail "bundled cmux app bundle id is not dev.spin.app: ${cmux_bundle_id:-missing}"
  cmux_feed_url="$(plist_string "$CMUX_APP/Contents/Info.plist" SUFeedURL || true)"
  if grep -q 'manaflow-ai/cmux' <<<"$cmux_feed_url"; then
    fail "bundled cmux app still uses the upstream cmux update feed"
  fi
else
  case "$cmux_bundle_id" in
    dev.spin.app|com.cmuxterm.app) ;;
    *) fail "bundled cmux app bundle id is not recognized: ${cmux_bundle_id:-missing}" ;;
  esac
fi
ok "bundled cmux app identity ($cmux_bundle_id)"

cmux_icon_file="$(plist_string "$CMUX_APP/Contents/Info.plist" CFBundleIconFile || true)"
[ "$cmux_icon_file" = "AppIcon" ] || fail "bundled cmux app icon plist key is not AppIcon: ${cmux_icon_file:-missing}"
cmux_icon_name="$(plist_string "$CMUX_APP/Contents/Info.plist" CFBundleIconName || true)"
[ -z "$cmux_icon_name" ] || fail "bundled cmux app still uses asset-catalog icon name: $cmux_icon_name"
[ -s "$CMUX_APP/Contents/Resources/AppIcon.icns" ] || fail "missing bundled cmux app icon at Resources/SPIN.app/Contents/Resources/AppIcon.icns"
cmp -s "$RES/SPIN.icns" "$CMUX_APP/Contents/Resources/AppIcon.icns" || fail "bundled cmux app icon does not match SPIN icon"
assert_asset_car_spin_icon_assets "$CMUX_APP/Contents/Resources/Assets.car"
ok "bundled cmux app icon"

if [ "${SPIN_REQUIRE_BRANDED_CMUX_APP:-}" = "1" ]; then
  cmux_brand_strings="$(mktemp)"
  while IFS= read -r -d '' file; do
    case "$file" in
      *.icns|*.png|*.jpg|*.jpeg|*.gif|*.ttf|*.otf|*.car|*.framework/*|*.xcframework/*) continue ;;
    esac
    case "$file" in
      *.strings)
        plutil -p "$file" >> "$cmux_brand_strings" 2>/dev/null || /usr/bin/strings "$file" >> "$cmux_brand_strings" 2>/dev/null || true ;;
      *)
        /usr/bin/strings "$file" >> "$cmux_brand_strings" 2>/dev/null || true ;;
    esac
  done < <(find "$CMUX_APP/Contents" -type f -print0)
  for forbidden in 'About cmux' 'Ghostty Settings' 'Open cmux.json' 'Quit cmux' 'Make cmux the Default Terminal'; do
    if grep -q "$forbidden" "$cmux_brand_strings"; then
      rm -f "$cmux_brand_strings"
      fail "bundled cmux app still exposes upstream UI branding: $forbidden"
    fi
  done
  for required in 'About SPIN' 'Terminal Engine Settings' 'Open SPIN Workspace Config' 'Quit SPIN'; do
    if ! grep -q "$required" "$cmux_brand_strings"; then
      rm -f "$cmux_brand_strings"
      fail "bundled cmux app is missing SPIN UI branding: $required"
    fi
  done
  rm -f "$cmux_brand_strings"
  ok "bundled cmux app UI branding"
fi

for bin in cmux omp; do
  [ -x "$RES/bin/$bin" ] || fail "missing bundled $bin at Resources/bin/$bin"
  ok "bundled $bin"
done
[ -x "$RES/bin/spin-agent" ] || fail "missing bundled spin-agent alias"
ok "bundled spin-agent alias"

if [ "${SPIN_SKIP_BINARY_EXEC_CHECK:-0}" != "1" ]; then
  "$RES/bin/cmux" version >/dev/null 2>&1 || fail "bundled cmux does not execute"
  env -i HOME="${HOME:-/tmp}" PATH="$SYSTEM_PATH" "$RES/bin/cmux" version >/dev/null 2>&1 || fail "bundled cmux does not execute without user PATH"
  ok "bundled cmux executes"
  if [ "${SPIN_REQUIRE_BRANDED_CMUX_APP:-}" = "1" ]; then
    cmux_welcome="$("$RES/bin/cmux" welcome 2>/dev/null || true)"
    grep -q 'SPIN' <<<"$cmux_welcome" || fail "bundled cmux welcome is not SPIN-branded"
    if grep -q 'https://cmux.com/docs' <<<"$cmux_welcome"; then
      fail "bundled cmux welcome still points users to cmux docs"
    fi
    ok "bundled cmux welcome is SPIN-branded"
  fi
  "$RES/bin/omp" --version >/dev/null 2>&1 || fail "bundled omp does not execute"
  env -i HOME="${HOME:-/tmp}" PATH="$SYSTEM_PATH" "$RES/bin/omp" --version >/dev/null 2>&1 || fail "bundled omp does not execute without user PATH"
  ok "bundled omp executes"
  env -i HOME="${HOME:-/tmp}" PATH="$SYSTEM_PATH" "$RES/bin/spin-agent" --version >/dev/null 2>&1 || fail "bundled spin-agent does not execute without user PATH"
  ok "bundled spin-agent executes"
else
  ok "bundled binary execution skipped"
fi

if [ "${SPIN_REQUIRE_VENDORED_OMP:-}" = "1" ]; then
  [ -f "$RES/app/omp-vendor.json" ] || fail "missing OMP vendor metadata at Resources/app/omp-vendor.json"
fi
skip_omp_vendor_hash="${SPIN_SKIP_OMP_VENDOR_HASH:-0}"
if [ "$skip_omp_vendor_hash" != "1" ] && [ -f "$RES/app/release-compat.json" ]; then
  compat_channel="$("$NODE_BIN" - "$RES/app/release-compat.json" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
process.stdout.write((manifest.release && manifest.release.channel) || '');
NODE
)"
  case "$compat_channel" in
    ad-hoc|production) skip_omp_vendor_hash=1 ;;
  esac
fi
if [ -f "$RES/app/omp-vendor.json" ] && [ "$skip_omp_vendor_hash" != "1" ]; then
  "$NODE_BIN" - "$RES/app/omp-vendor.json" "$RES/bin" "$RES/app/omp-bun.lock" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [metadataPath, binDir, bundledLockPath] = process.argv.slice(2);
const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
function fail(message) {
  console.error(message);
  process.exit(1);
}
if (metadata.package !== '@oh-my-pi/pi-coding-agent') fail('unexpected OMP package');
if (!metadata.version || !metadata.packageSpec) fail('missing OMP package version/spec');
if (!metadata.npm || !metadata.npm.integrity || !metadata.npm.localPackSha256) fail('missing OMP npm integrity metadata');
const outputs = Array.isArray(metadata.outputs) ? metadata.outputs : [];
const binary = outputs.find((item) => item.kind === 'compiled-cli' && item.path === 'vendor/bin/omp');
const native = outputs.find((item) => item.kind === 'native-addon' && /\/pi_natives\..+\.node$/.test(item.path));
if (!binary || !binary.sha256) fail('missing compiled OMP binary output metadata');
if (!native || !native.sha256) fail('missing OMP native addon output metadata');
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if (hash(path.join(binDir, 'omp')) !== binary.sha256) fail('bundled OMP binary sha256 does not match metadata');
const nativeName = path.basename(native.path);
const nativePath = path.join(binDir, nativeName);
if (!fs.existsSync(nativePath)) fail(`missing bundled OMP native addon ${nativeName}`);
if (hash(nativePath) !== native.sha256) fail('bundled OMP native addon sha256 does not match metadata');
const lockfile = metadata.build && metadata.build.lockfile;
if (!lockfile || !lockfile.sha256) fail('missing OMP lockfile metadata');
if (!fs.existsSync(bundledLockPath)) fail('missing bundled OMP lockfile');
if (hash(bundledLockPath) !== lockfile.sha256) fail('bundled OMP lockfile sha256 does not match metadata');
NODE
  ok "bundled OMP vendor metadata"
elif [ -f "$RES/app/omp-vendor.json" ]; then
  ok "bundled OMP vendor metadata (hash check delegated to compatibility manifest)"
elif [ "${SPIN_REQUIRE_VENDORED_OMP:-}" = "1" ]; then
  fail "missing OMP vendor metadata"
fi

"$NODE_BIN" "$ROOT/scripts/app-compatibility.js" verify "$APP" >/dev/null
ok "release compatibility manifest"

[ -f "$RES/licenses/SPIN-MIT.txt" ] || fail "missing SPIN MIT license notice"
[ -f "$RES/licenses/THIRD_PARTY_NOTICES.md" ] || fail "missing third-party notices"
grep -q 'cmux' "$RES/licenses/THIRD_PARTY_NOTICES.md" || fail "third-party notices missing cmux"
grep -q 'GPL-3.0-or-later' "$RES/licenses/THIRD_PARTY_NOTICES.md" || fail "cmux GPL posture missing"
grep -q 'oh-my-pi' "$RES/licenses/THIRD_PARTY_NOTICES.md" || fail "third-party notices missing OMP/Pi"
ok "license notices"

SPIN_APP_RESOURCES="$RES" \
SPIN_ROOT="$RUNTIME" \
SPIN_INTERNAL_BIN_DIR="$RES/bin" \
  bash -n "$APP/Contents/MacOS/SPIN"
ok "launcher syntax"

grep -q '"entrypoint": "Resources/runtime/scripts/spin app-launch"' "$RES/app/spin-app.json" || fail "app manifest does not use app-launch"
ok "app launch manifest"

TMP="$(mktemp -d)"
app_launcher_dry_run() {
  env -i HOME="$TMP/home" PATH="$SYSTEM_PATH" SPIN_APP_HOME="$TMP/home" SPIN_APP_LAUNCH_DRY_RUN=1 "$APP/Contents/MacOS/SPIN"
}

launch_out="$(app_launcher_dry_run)"
grep -q 'app-launch: onboarding' <<<"$launch_out" || fail "launcher did not route fresh app home to onboarding"
[ -x "$TMP/home/runtime/scripts/spin" ] || fail "launcher did not seed writable runtime"
[ -x "$TMP/home/runtime/scripts/org" ] || fail "launcher did not seed writable org CLI"
[ -f "$TMP/home/.config/cmux/cmux.json" ] || fail "launcher did not seed SPIN cmux config"
grep -q '"hideAllDetails": true' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config does not hide sidebar details"
grep -q '"showWorkspaceDescription": false' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config still shows workspace descriptions"
grep -q '"showPorts": false' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config still shows port rows"
grep -q '"showPullRequests": false' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config still shows pull request rows"
grep -q '"darkModeTintColor": "#FF7ADF"' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config is not soft SPIN-branded"
grep -q '"tintOpacity": 0.24' "$TMP/home/.config/cmux/cmux.json" || fail "seeded cmux config is not using the soft SPIN tint opacity"
[ -f "$TMP/home/.config/cmux/sidebars/spin-navigator.swift" ] || fail "launcher did not seed SPIN Navigator sidebar"
assert_spin_sidebar_defaults_seeded "$TMP/home"
ok "first-launch runtime seed"
SEEDED_RUNTIME="$TMP/home/runtime"

mkdir -p "$TMP/template-home/.config/cmux"
cat > "$TMP/template-home/.config/cmux/cmux.json" <<'EOF'
{
  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
  "schemaVersion": 1,
  // cmux creates this template on launch when ~/.config/cmux/cmux.json is missing.
  //   "sidebarAppearance" : {
  //     "darkModeTintColor" : null,
  //     "tintColor" : "#000000"
  //   }
}
EOF
template_out="$(env -i HOME="$TMP/template-home" PATH="$SYSTEM_PATH" SPIN_APP_HOME="$TMP/template-home" SPIN_APP_LAUNCH_DRY_RUN=1 "$APP/Contents/MacOS/SPIN")"
grep -q 'app-launch: onboarding' <<<"$template_out" || fail "launcher did not route template-home launch to onboarding"
grep -q '"darkModeTintColor": "#FF7ADF"' "$TMP/template-home/.config/cmux/cmux.json" || fail "launcher did not replace generated cmux template with soft SPIN config"
grep -q '"hideAllDetails": true' "$TMP/template-home/.config/cmux/cmux.json" || fail "launcher did not replace generated cmux template with compact sidebar config"
grep -q '"tintOpacity": 0.24' "$TMP/template-home/.config/cmux/cmux.json" || fail "launcher did not replace generated cmux template with soft SPIN tint opacity"
ls "$TMP/template-home/.config/cmux"/cmux.json.spin-backup-* >/dev/null 2>&1 || fail "launcher did not back up generated cmux template"
assert_spin_sidebar_defaults_seeded "$TMP/template-home"
ok "generated cmux template refreshes to soft SPIN config"

omp_ready_out="$(env -i HOME="$TMP/omp-ready-home" PATH="$SYSTEM_PATH" SPIN_APP_HOME="$TMP/omp-ready-home" SPIN_APP_ASSUME_OMP_CONFIGURED=1 SPIN_APP_LAUNCH_DRY_RUN=1 "$APP/Contents/MacOS/SPIN")"
grep -q 'app-launch: spin up' <<<"$omp_ready_out" || fail "launcher did not route existing OMP config to spin up"
ok "existing OMP setup routes to spin up"

socket_env_out="$(env -i HOME="$TMP/socket-home" PATH="$SYSTEM_PATH" SPIN_ROOT="$SEEDED_RUNTIME" /bin/bash -c '
  set -euo pipefail
  source "$SPIN_ROOT/scripts/lib/spin-runtime.sh"
  spin_prepare_cmux_environment
  printf "%s\n%s\n%s\n%s\n" "$CMUX_SOCKET_PATH" "$CMUX_ALLOW_SOCKET_OVERRIDE" "$CMUX_SOCKET_ENABLE" "$CMUX_SOCKET_MODE"
')"
prepared_socket="$(printf '%s\n' "$socket_env_out" | sed -n '1p')"
prepared_override="$(printf '%s\n' "$socket_env_out" | sed -n '2p')"
prepared_enable="$(printf '%s\n' "$socket_env_out" | sed -n '3p')"
prepared_mode="$(printf '%s\n' "$socket_env_out" | sed -n '4p')"
case "$prepared_socket" in
  "$TMP/socket-home/.local/state/cmux/spin.sock") ;;
  *) fail "runtime did not prepare SPIN-owned cmux socket: ${prepared_socket:-missing}" ;;
esac
[ "$prepared_override" = "1" ] || fail "runtime did not allow SPIN socket override"
[ "$prepared_enable" = "1" ] || fail "runtime did not enable cmux socket"
[ "$prepared_mode" = "allowall" ] || fail "runtime did not request controllable cmux socket mode"
ok "runtime prepares SPIN-owned cmux socket"

cat > "$TMP/fake-cmux" <<EOF
#!/usr/bin/env bash
printf 'args=%s\n' "\$*" >> "$TMP/fake-cmux.calls"
printf 'socket=%s\n' "\${CMUX_SOCKET_PATH:-}" >> "$TMP/fake-cmux.calls"
case "\${1:-}" in
  ping) exit 0 ;;
  version) echo "cmux fake release-check"; exit 0 ;;
  new-workspace) echo "workspace:42"; exit 0 ;;
  list-workspaces) echo "workspace:42 SPIN Onboarding"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/fake-cmux"
first_run_out="$(env -i HOME="$TMP/live-home" PATH="$SYSTEM_PATH" SPIN_APP_HOME="$TMP/live-home" SPIN_APP_NO_LOG_REDIRECT=1 SPIN_CMUX_BIN="$TMP/fake-cmux" "$APP/Contents/MacOS/SPIN")"
grep -q 'SPIN onboarding opened in cmux' <<<"$first_run_out" || fail "real app launcher did not report onboarding workspace creation"
grep -q 'args=new-workspace --name SPIN Onboarding' "$TMP/fake-cmux.calls" || fail "real app launcher did not create the SPIN Onboarding workspace"
grep -q "socket=$TMP/live-home/.local/state/cmux/spin.sock" "$TMP/fake-cmux.calls" || fail "real app launcher did not pass the SPIN-owned cmux socket to cmux"
ok "real first-launch path creates SPIN onboarding workspace"

SESSION_ORG="$SEEDED_RUNTIME/org"
SESSION_MARKER="spin-restart-proof-$$"
mkdir -p "$SESSION_ORG/ceo/runs" "$SESSION_ORG/projects/restart-proof" "$SEEDED_RUNTIME/logs"
cat > "$SESSION_ORG/.spin-onboarded" <<EOF
onboarded_at=1970-01-01T00:00:00Z
proof=$SESSION_MARKER
EOF
cat > "$SESSION_ORG/OMP_HARNESS.json" <<EOF
{
  "workspace_ceo": {
    "cmux_workspace": "workspace:restart-ceo"
  },
  "projects": {
    "restart-proof": {
      "cmux_workspace": "workspace:restart-project"
    }
  }
}
EOF
cat > "$SESSION_ORG/state.json" <<EOF
{
  "project_orchestrators": [
    {
      "project": "restart-proof",
      "status": "active:$SESSION_MARKER"
    }
  ]
}
EOF
printf '# Approvals\n\n- [ ] restart approval %s\n' "$SESSION_MARKER" > "$SESSION_ORG/ceo/APPROVALS.md"
printf '# Human Queue\n\n- [ ] restart queue %s\n' "$SESSION_MARKER" > "$SESSION_ORG/HUMAN_QUEUE.md"
printf 'receipt=%s\n' "$SESSION_MARKER" > "$SESSION_ORG/ceo/runs/restart-proof.receipt"
printf 'log=%s\n' "$SESSION_MARKER" > "$SEEDED_RUNTIME/logs/restart-proof.log"

relaunch_out="$(app_launcher_dry_run)"
grep -q 'app-launch: spin up' <<<"$relaunch_out" || fail "launcher did not route onboarded app home to spin up"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/.spin-onboarded" || fail "onboarding marker did not persist across relaunch"
grep -Fq 'workspace:restart-ceo' "$SESSION_ORG/OMP_HARNESS.json" || fail "Coordinator cmux workspace ref did not persist across relaunch"
grep -Fq 'workspace:restart-project' "$SESSION_ORG/OMP_HARNESS.json" || fail "project cmux workspace ref did not persist across relaunch"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/state.json" || fail "org state did not persist across relaunch"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/APPROVALS.md" || fail "approvals did not persist across relaunch"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/HUMAN_QUEUE.md" || fail "human queue did not persist across relaunch"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/runs/restart-proof.receipt" || fail "receipt did not persist across relaunch"
grep -Fq "$SESSION_MARKER" "$SEEDED_RUNTIME/logs/restart-proof.log" || fail "logs did not persist across relaunch"
ok "app relaunch preserves onboarding, workspace refs, and org state"

cat > "$SEEDED_RUNTIME/scripts/spin" <<'EOF'
#!/usr/bin/env bash
echo "stale same-version runtime"
exit 71
EOF
chmod +x "$SEEDED_RUNTIME/scripts/spin"
same_version_refresh_out="$(app_launcher_dry_run)"
grep -q 'app-launch: spin up' <<<"$same_version_refresh_out" || fail "launcher did not refresh same-version runtime code"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/.spin-onboarded" || fail "onboarding marker was overwritten during same-version runtime refresh"
grep -Fq 'workspace:restart-ceo' "$SESSION_ORG/OMP_HARNESS.json" || fail "Coordinator cmux workspace ref was overwritten during same-version runtime refresh"
grep -Fq 'workspace:restart-project' "$SESSION_ORG/OMP_HARNESS.json" || fail "project cmux workspace ref was overwritten during same-version runtime refresh"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/state.json" || fail "org state was overwritten during same-version runtime refresh"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/APPROVALS.md" || fail "approvals were overwritten during same-version runtime refresh"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/HUMAN_QUEUE.md" || fail "human queue was overwritten during same-version runtime refresh"
grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/runs/restart-proof.receipt" || fail "receipt was overwritten during same-version runtime refresh"
grep -Fq "$SESSION_MARKER" "$SEEDED_RUNTIME/logs/restart-proof.log" || fail "logs were overwritten during same-version runtime refresh"
ok "same-version runtime refresh preserves user state"

if [ -f "$RUNTIME/VERSION" ]; then
  printf 'stale-local-runtime-version\n' > "$SEEDED_RUNTIME/VERSION"
  refresh_out="$(app_launcher_dry_run)"
  grep -q 'app-launch: spin up' <<<"$refresh_out" || fail "launcher did not route refreshed runtime to spin up"
  cmp -s "$RUNTIME/VERSION" "$SEEDED_RUNTIME/VERSION" || fail "launcher did not refresh stale runtime version"
  grep -Fq "$SESSION_MARKER" "$SESSION_ORG/.spin-onboarded" || fail "onboarding marker was overwritten during runtime refresh"
  grep -Fq 'workspace:restart-ceo' "$SESSION_ORG/OMP_HARNESS.json" || fail "Coordinator cmux workspace ref was overwritten during runtime refresh"
  grep -Fq 'workspace:restart-project' "$SESSION_ORG/OMP_HARNESS.json" || fail "project cmux workspace ref was overwritten during runtime refresh"
  grep -Fq "$SESSION_MARKER" "$SESSION_ORG/state.json" || fail "org state was overwritten during runtime refresh"
  grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/APPROVALS.md" || fail "approvals were overwritten during runtime refresh"
  grep -Fq "$SESSION_MARKER" "$SESSION_ORG/HUMAN_QUEUE.md" || fail "human queue was overwritten during runtime refresh"
  grep -Fq "$SESSION_MARKER" "$SESSION_ORG/ceo/runs/restart-proof.receipt" || fail "receipt was overwritten during runtime refresh"
  grep -Fq "$SESSION_MARKER" "$SEEDED_RUNTIME/logs/restart-proof.log" || fail "logs were overwritten during runtime refresh"
  ok "runtime version refresh preserves user state"
fi

resolved_cmux_app="$(SPIN_APP_RESOURCES="$RES" SPIN_ROOT="$RUNTIME" /bin/bash -c 'source "$SPIN_ROOT/scripts/lib/spin-runtime.sh"; spin_cmux_app_path' 2>/dev/null || true)"
[ "$resolved_cmux_app" = "$CMUX_APP" ] || fail "runtime did not resolve bundled cmux app: ${resolved_cmux_app:-missing}"
ok "bundled cmux app resolution"

resolver_out="$(env -i HOME="$TMP/home" PATH="$SYSTEM_PATH" SPIN_APP_RESOURCES="$RES" SPIN_INTERNAL_BIN_DIR="$RES/bin" SPIN_ROOT="$SEEDED_RUNTIME" /bin/bash -c '
  set -euo pipefail
  source "$SPIN_ROOT/scripts/lib/spin-runtime.sh"
  spin_resolve_binary cmux
  spin_resolve_binary omp
  spin_resolve_binary spin-agent
')"
resolved_cmux="$(printf '%s\n' "$resolver_out" | sed -n '1p')"
resolved_omp="$(printf '%s\n' "$resolver_out" | sed -n '2p')"
resolved_agent="$(printf '%s\n' "$resolver_out" | sed -n '3p')"
[ "$resolved_cmux" = "$RES/bin/cmux" ] || fail "shell resolver did not choose bundled cmux: ${resolved_cmux:-missing}"
[ "$resolved_omp" = "$RES/bin/omp" ] || fail "shell resolver did not choose bundled omp: ${resolved_omp:-missing}"
[ "$resolved_agent" = "$RES/bin/spin-agent" ] || fail "shell resolver did not choose bundled spin-agent: ${resolved_agent:-missing}"
ok "shell resolver uses bundled binaries without user PATH"

node_resolver_out="$(env -i HOME="$TMP/home" PATH="$SYSTEM_PATH" SPIN_APP_RESOURCES="$RES" SPIN_INTERNAL_BIN_DIR="$RES/bin" SPIN_ROOT="$SEEDED_RUNTIME" "$NODE_BIN" - <<'NODE'
const runtime = require(`${process.env.SPIN_ROOT}/scripts/lib/spin-runtime.js`);
for (const bin of ['cmux', 'omp', 'spin-agent']) {
  console.log(runtime.resolveBinary(bin));
}
NODE
)"
node_resolved_cmux="$(printf '%s\n' "$node_resolver_out" | sed -n '1p')"
node_resolved_omp="$(printf '%s\n' "$node_resolver_out" | sed -n '2p')"
node_resolved_agent="$(printf '%s\n' "$node_resolver_out" | sed -n '3p')"
[ "$node_resolved_cmux" = "$RES/bin/cmux" ] || fail "Node resolver did not choose bundled cmux: ${node_resolved_cmux:-missing}"
[ "$node_resolved_omp" = "$RES/bin/omp" ] || fail "Node resolver did not choose bundled omp: ${node_resolved_omp:-missing}"
[ "$node_resolved_agent" = "$RES/bin/spin-agent" ] || fail "Node resolver did not choose bundled spin-agent: ${node_resolved_agent:-missing}"
ok "Node resolver uses bundled binaries without user PATH"

health_json="$(env -i HOME="$TMP/home" PATH="$SYSTEM_PATH" SPIN_APP_RESOURCES="$RES" SPIN_INTERNAL_BIN_DIR="$RES/bin" SPIN_BUNDLED_RUNTIME="$RUNTIME" SPIN_ROOT="$SEEDED_RUNTIME" "$NODE_BIN" "$SEEDED_RUNTIME/scripts/spin-app-health.js" --json)"
health_file="$TMP/app-health.json"
printf '%s\n' "$health_json" > "$health_file"
"$NODE_BIN" - "$health_file" "$RES/bin" <<'NODE'
const fs = require('fs');
const path = require('path');
const [healthFile, binDir] = process.argv.slice(2);
const health = JSON.parse(fs.readFileSync(healthFile, 'utf8'));
function fail(message) {
  console.error(message);
  process.exit(1);
}
if (!health.app || health.app.inBundle !== true) fail('app health did not detect bundle context');
if (health.app.runtimeWritable.status !== 'ok') fail('app health did not validate writable runtime');
for (const [name, key] of [['cmux', 'cmux'], ['omp', 'omp'], ['spin-agent', 'spinAgent']]) {
  const item = health.binaries && health.binaries[key];
  if (!item || item.status !== 'ok') fail(`app health did not validate bundled ${name}`);
  if (item.path !== path.join(binDir, name)) fail(`app health resolved ${name} outside bundled bin`);
  if (item.source !== 'app-bundled') fail(`app health did not classify ${name} as app-bundled`);
}
if (!health.omp || health.omp.owner !== 'OMP') fail('app health does not preserve OMP ownership');
if (health.omp.setupCommand !== 'spin omp-setup') fail('app health missing OMP setup handoff command');
if (health.summary.status === 'error') fail('app health summary reports error');
NODE
ok "app health reports bundled runtime and OMP handoff"

echo "SPIN.app release checks passed: $APP"
