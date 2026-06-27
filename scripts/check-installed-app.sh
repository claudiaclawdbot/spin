#!/usr/bin/env bash
# Prove a packaged SPIN macOS artifact behaves like an installed app.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ARTIFACT="${1:-}"
TMP=""
MOUNT=""
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
  cat <<'EOF'
Usage: scripts/check-installed-app.sh dist/release/SPIN-<version>-macos-<arch>.zip|.dmg

Extracts the release artifact into a temporary Applications-like directory,
verifies the signed app contract, then runs a deterministic first-launch proof
from an isolated SPIN_APP_HOME using bundled fake cmux/OMP shims inside the
extracted app copy.
EOF
}

fail(){ echo "installed-app check failed: $*" >&2; exit 1; }
ok(){ echo "  ok: $*"; }
cleanup(){
  if [ -n "$MOUNT" ] && mount | grep -Fq " on $MOUNT "; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  fi
  [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

assert_spin_sidebar_defaults_seeded() {
  local home="$1" domain plist provider enabled
  [ "$(uname -s)" = "Darwin" ] || return 0
  [ -x /usr/libexec/PlistBuddy ] || return 0
  for domain in dev.spin.app com.cmuxterm.app; do
    plist="$home/Library/Preferences/$domain.plist"
    [ -f "$plist" ] || fail "installed first launch did not seed $domain preferences for SPIN Navigator rail"
    provider="$(/usr/libexec/PlistBuddy -c "Print :cmuxExtensionSidebar.providerId" "$plist" 2>/dev/null || true)"
    [ "$provider" = "cmux.sidebar.custom.spin-navigator" ] || fail "$domain did not select SPIN Navigator rail: ${provider:-missing}"
    enabled="$(/usr/libexec/PlistBuddy -c "Print :customSidebars.beta.enabled" "$plist" 2>/dev/null || true)"
    [ "$enabled" = "1" ] || [ "$enabled" = "true" ] || fail "$domain did not enable custom sidebars: ${enabled:-missing}"
  done
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$(ls -t "$ROOT"/dist/release/SPIN-*-macos-*.zip 2>/dev/null | head -1 || true)"
fi
[ -n "$ARTIFACT" ] || fail "missing artifact path"
if [ "${ARTIFACT#/}" = "$ARTIFACT" ]; then
  ARTIFACT="$(cd "$(dirname "$ARTIFACT")" >/dev/null 2>&1 && pwd)/$(basename "$ARTIFACT")"
fi
[ -f "$ARTIFACT" ] || fail "artifact not found: $ARTIFACT"

case "$ARTIFACT" in
  *.zip|*.dmg) ;;
  *) fail "only zip and dmg artifacts are supported for installed-app proof today: $ARTIFACT" ;;
esac

command -v ditto >/dev/null 2>&1 || fail "ditto is required on macOS"
command -v codesign >/dev/null 2>&1 || fail "codesign is required on macOS"
if [ "${ARTIFACT%.dmg}" != "$ARTIFACT" ]; then
  command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required for dmg installed-app proof"
fi

TMP="$(mktemp -d)"
INSTALL_ROOT="$TMP/Applications"
CONTROL_ROOT="$TMP/Controlled Applications"
APP_HOME="$TMP/App Support/SPIN"
HOME_DIR="$TMP/home"
GLOBAL_BIN="$TMP/global-bin"
CMUX_CALLS="$TMP/bundled-cmux.calls"
OMP_CALLS="$TMP/bundled-omp.calls"
GLOBAL_CALLS="$TMP/global.calls"
mkdir -p "$INSTALL_ROOT" "$CONTROL_ROOT" "$APP_HOME" "$HOME_DIR" "$GLOBAL_BIN"

case "$ARTIFACT" in
  *.zip)
    ditto -x -k "$ARTIFACT" "$INSTALL_ROOT"
    ;;
  *.dmg)
    MOUNT="$TMP/mount"
    mkdir -p "$MOUNT"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$ARTIFACT" >/dev/null
    [ -d "$MOUNT/SPIN.app" ] || fail "dmg missing SPIN.app"
    [ -e "$MOUNT/Applications" ] || fail "dmg missing Applications shortcut"
    [ -f "$MOUNT/README.txt" ] || fail "dmg missing README.txt"
    grep -q 'Drag SPIN.app onto Applications' "$MOUNT/README.txt" || fail "dmg README missing install instruction"
    ditto "$MOUNT/SPIN.app" "$INSTALL_ROOT/SPIN.app"
    hdiutil detach "$MOUNT" >/dev/null
    MOUNT=""
    ;;
esac
INSTALLED_APP="$INSTALL_ROOT/SPIN.app"
[ -x "$INSTALLED_APP/Contents/MacOS/SPIN" ] || fail "artifact did not extract SPIN.app launcher"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null 2>&1 \
  || codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
SPIN_SKIP_OMP_VENDOR_HASH=1 "$ROOT/scripts/check-app-release.sh" "$INSTALLED_APP" >/dev/null
ok "installed artifact verifies"

CONTROL_APP="$CONTROL_ROOT/SPIN.app"
ditto "$INSTALLED_APP" "$CONTROL_APP"

cat > "$CONTROL_APP/Contents/Resources/bin/cmux" <<EOF
#!/usr/bin/env bash
printf 'cmux|%s|%s\n' "\$0" "\$*" >> "$CMUX_CALLS"
printf 'socket=%s\n' "\${CMUX_SOCKET_PATH:-}" >> "$CMUX_CALLS"
case "\${1:-}" in
  ping) exit 0 ;;
  version) echo "installed-proof cmux"; exit 0 ;;
  new-workspace) echo "workspace:512"; exit 0 ;;
  list-workspaces) echo "workspace:512 SPIN Onboarding"; exit 0 ;;
  tree) echo "surface:512 [terminal] tty=ttys512"; exit 0 ;;
  read-screen) echo "installed proof screen"; exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$CONTROL_APP/Contents/Resources/bin/cmux"

cat > "$CONTROL_APP/Contents/Resources/bin/omp" <<EOF
#!/usr/bin/env bash
printf 'omp|%s|%s\n' "\$0" "\$*" >> "$OMP_CALLS"
if [[ "\${1:-}" == "--help" ]]; then echo "installed-proof omp"; exit 0; fi
if [[ "\${1:-}" == "--version" ]]; then echo "omp/installed-proof"; exit 0; fi
if [[ "\${1:-}" == "setup" && "\${2:-}" == "--help" ]]; then echo "omp setup installed proof"; exit 0; fi
if [[ "\${1:-}" == "auth-broker" && "\${2:-}" == "status" && "\${3:-}" == "--json" ]]; then echo '{"ok":false,"reason":"not_configured"}'; exit 0; fi
exit 0
EOF
chmod +x "$CONTROL_APP/Contents/Resources/bin/omp"

for bin in cmux omp; do
  cat > "$GLOBAL_BIN/$bin" <<EOF
#!/usr/bin/env bash
printf 'global-$bin|%s|%s\n' "\$0" "\$*" >> "$GLOBAL_CALLS"
exit 93
EOF
  chmod +x "$GLOBAL_BIN/$bin"
done

mkdir -p "$HOME_DIR/.config/cmux"
cat > "$HOME_DIR/.config/cmux/cmux.json" <<'EOF'
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

first_out="$TMP/first-launch.out"
env -i \
  HOME="$HOME_DIR" \
  PATH="$GLOBAL_BIN:$SYSTEM_PATH" \
  SPIN_APP_HOME="$APP_HOME" \
  SPIN_APP_NO_LOG_REDIRECT=1 \
  "$CONTROL_APP/Contents/MacOS/SPIN" > "$first_out"

grep -q 'SPIN onboarding opened in cmux (workspace:512)' "$first_out" \
  || fail "installed first launch did not open onboarding workspace"
[ -x "$APP_HOME/runtime/scripts/spin" ] || fail "installed first launch did not seed writable runtime"
[ -x "$APP_HOME/runtime/scripts/org" ] || fail "installed first launch did not seed writable org CLI"
[ -d "$APP_HOME/runtime/org" ] || fail "installed first launch did not seed org state"
[ -f "$HOME_DIR/.config/cmux/cmux.json" ] || fail "installed first launch did not seed SPIN cmux config"
grep -q '"darkModeTintColor": "#FF7ADF"' "$HOME_DIR/.config/cmux/cmux.json" || fail "installed first launch seeded stale cmux config"
grep -q '"tintOpacity": 0.24' "$HOME_DIR/.config/cmux/cmux.json" || fail "installed first launch seeded stale cmux tint opacity"
ls "$HOME_DIR/.config/cmux"/cmux.json.spin-backup-* >/dev/null 2>&1 || fail "installed first launch did not back up generated cmux template"
[ -f "$HOME_DIR/.config/cmux/sidebars/spin-navigator.swift" ] || fail "installed first launch did not seed SPIN Navigator sidebar"
assert_spin_sidebar_defaults_seeded "$HOME_DIR"
grep -Fq "$CONTROL_APP/Contents/Resources/bin/cmux|ping" "$CMUX_CALLS" \
  || fail "installed first launch did not call bundled cmux ping"
grep -Fq "$CONTROL_APP/Contents/Resources/bin/cmux|new-workspace --name SPIN Onboarding" "$CMUX_CALLS" \
  || fail "installed first launch did not call bundled cmux onboarding workspace"
grep -Fq "socket=$HOME_DIR/.local/state/cmux/spin.sock" "$CMUX_CALLS" \
  || fail "installed first launch did not pass the SPIN-owned cmux socket"
[ ! -s "$GLOBAL_CALLS" ] || fail "installed launch called a global cmux/omp shim: $(cat "$GLOBAL_CALLS")"
ok "installed first launch uses bundled cmux and seeds runtime"

route_before="$TMP/route-before.out"
env -i \
  HOME="$HOME_DIR" \
  PATH="$GLOBAL_BIN:$SYSTEM_PATH" \
  SPIN_APP_HOME="$APP_HOME" \
  SPIN_APP_LAUNCH_DRY_RUN=1 \
  "$CONTROL_APP/Contents/MacOS/SPIN" > "$route_before"
grep -q 'app-launch: onboarding' "$route_before" || fail "pre-onboarding relaunch route was not onboarding"

route_omp_ready="$TMP/route-omp-ready.out"
env -i \
  HOME="$HOME_DIR" \
  PATH="$GLOBAL_BIN:$SYSTEM_PATH" \
  SPIN_APP_HOME="$APP_HOME" \
  SPIN_APP_ASSUME_OMP_CONFIGURED=1 \
  SPIN_APP_LAUNCH_DRY_RUN=1 \
  "$CONTROL_APP/Contents/MacOS/SPIN" > "$route_omp_ready"
grep -q 'app-launch: spin up' "$route_omp_ready" || fail "existing OMP setup route was not spin up"

touch "$APP_HOME/runtime/org/.spin-onboarded"
route_after="$TMP/route-after.out"
env -i \
  HOME="$HOME_DIR" \
  PATH="$GLOBAL_BIN:$SYSTEM_PATH" \
  SPIN_APP_HOME="$APP_HOME" \
  SPIN_APP_LAUNCH_DRY_RUN=1 \
  "$CONTROL_APP/Contents/MacOS/SPIN" > "$route_after"
grep -q 'app-launch: spin up' "$route_after" || fail "post-onboarding relaunch route was not spin up"
ok "installed relaunch routes to spin up after onboarding"

NODE_BIN="$(command -v node || true)"
if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ]; then
  health_json="$TMP/app-health.json"
  env -i \
    HOME="$HOME_DIR" \
    PATH="$SYSTEM_PATH" \
    SPIN_APP_RESOURCES="$CONTROL_APP/Contents/Resources" \
    SPIN_INTERNAL_BIN_DIR="$CONTROL_APP/Contents/Resources/bin" \
    SPIN_BUNDLED_RUNTIME="$CONTROL_APP/Contents/Resources/runtime" \
    SPIN_ROOT="$APP_HOME/runtime" \
    "$NODE_BIN" "$APP_HOME/runtime/scripts/spin-app-health.js" --json > "$health_json"
  "$NODE_BIN" - "$health_json" "$CONTROL_APP/Contents/Resources/bin" <<'NODE'
const fs = require('fs');
const path = require('path');
const [healthPath, binDir] = process.argv.slice(2);
const health = JSON.parse(fs.readFileSync(healthPath, 'utf8'));
function fail(message) {
  console.error(message);
  process.exit(1);
}
if (!health.app || health.app.inBundle !== true) fail('health did not detect installed app bundle context');
if (!health.app.runtimeWritable || health.app.runtimeWritable.status !== 'ok') fail('health did not validate installed writable runtime');
for (const [name, key] of [['cmux', 'cmux'], ['omp', 'omp'], ['spin-agent', 'spinAgent']]) {
  const item = health.binaries && health.binaries[key];
  if (!item || item.status !== 'ok') fail(`health did not validate bundled ${name}`);
  if (item.path !== path.join(binDir, name)) fail(`health resolved ${name} outside installed bundle`);
  if (item.source !== 'app-bundled') fail(`health did not classify ${name} as app-bundled`);
}
NODE
  ok "installed app health resolves bundled binaries"
fi

echo "SPIN installed-app check passed: $ARTIFACT"
