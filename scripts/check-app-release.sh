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

[ -d "$APP" ] || fail "missing app bundle: $APP"
[ -f "$APP/Contents/Info.plist" ] || fail "missing Info.plist"
[ -x "$APP/Contents/MacOS/SPIN" ] || fail "missing executable launcher"
[ -f "$RES/app/spin-app.json" ] || fail "missing app manifest"
[ -f "$RES/app/cmux/config/cmux.json" ] || fail "missing bundled cmux config"
[ -f "$RES/app/cmux/sidebars/spin-navigator.swift" ] || fail "missing SPIN sidebar"
[ -f "$RUNTIME/scripts/spin" ] || fail "missing runtime spin CLI"
[ -f "$RUNTIME/scripts/org" ] || fail "missing runtime org CLI"

grep -q '<string>SPIN</string>' "$APP/Contents/Info.plist" || fail "app identity is not SPIN"
ok "app identity"

app_icon_file="$(plist_string "$APP/Contents/Info.plist" CFBundleIconFile || true)"
[ "$app_icon_file" = "SPIN" ] || fail "app icon plist key is not SPIN: ${app_icon_file:-missing}"
[ -s "$RES/SPIN.icns" ] || fail "missing app icon at Resources/SPIN.icns"
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
[ -s "$CMUX_APP/Contents/Resources/AppIcon.icns" ] || fail "missing bundled cmux app icon at Resources/SPIN.app/Contents/Resources/AppIcon.icns"
cmp -s "$RES/SPIN.icns" "$CMUX_APP/Contents/Resources/AppIcon.icns" || fail "bundled cmux app icon does not match SPIN icon"
ok "bundled cmux app icon"

for bin in cmux omp; do
  [ -x "$RES/bin/$bin" ] || fail "missing bundled $bin at Resources/bin/$bin"
  ok "bundled $bin"
done
[ -x "$RES/bin/spin-agent" ] || fail "missing bundled spin-agent alias"
ok "bundled spin-agent alias"

[ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ] || fail "node not found for release check; set SPIN_RELEASE_CHECK_NODE"

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
ok "first-launch runtime seed"
SEEDED_RUNTIME="$TMP/home/runtime"

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
