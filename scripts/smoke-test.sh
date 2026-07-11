#!/usr/bin/env bash
# smoke-test.sh — no-network checks for install seeding, org/spin plumbing, and
# provider routing. It runs in a temporary copy so the working tree stays clean.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KIT="$TMP/spin"
mkdir -p "$KIT"
( cd "$ROOT" && {
    git ls-files -z
    git ls-files -z --others --exclude-standard -- \
      .github/workflows/macos-app.yml \
      app agent runtime assets licenses \
      SECURITY.md \
      scripts/lib/spin-runtime.sh scripts/lib/spin-runtime.js \
      scripts/lib/cmux-floor-layout.sh \
      scripts/lib/human-queue-summary.js \
      scripts/spin-web.js scripts/spin-app-health.js scripts/app-compatibility.js scripts/spin-app-update.js scripts/spin-app-updates.js scripts/omp-mcp-bootstrap.js scripts/codex-computer-use.sh \
      scripts/package-macos-app.sh scripts/package-macos-release.sh scripts/release-macos.sh scripts/prepare-open-source-release.sh scripts/check-installed-app.sh scripts/check-macos-signing-env.sh scripts/vendor-app-deps.sh scripts/check-app-release.sh scripts/build-app-icon.sh scripts/apply-cmux-spin-overlay.sh \
      scripts/ensure-xcode.sh scripts/build-cmux-spin.sh scripts/build-app-proof.sh \
      docs/INSTALL_MACOS.md docs/RELEASING_MACOS.md docs/releases \
      docs/MACOS_TESTER_INSTALL.md docs/PUBLIC_BETA_READINESS.md docs/OPEN_SOURCE_TESTER_RELEASE.md docs/assets \
      .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/app-beta-bug.yml .github/ISSUE_TEMPLATE/public-feedback.yml \
      'org/ceo/*.example.md'
  } | tar --null -czf - --files-from - ) | tar -xzf - -C "$KIT"

cd "$KIT"
export SPIN_ROOT="$KIT"
export SPIN_RUNTIME_ROOT="$KIT"
export CMUX_SOCKET_PATH="$TMP/cmux-isolated.sock"
export CMUX_ALLOW_SOCKET_OVERRIDE=1
unset SPIN_CMUX_BIN SPIN_APP_RESOURCES SPIN_INTERNAL_BIN_DIR CMUX_BUNDLED_CLI_PATH
SPIN_NO_DEPS=1 \
SPIN_INSTALL_SKIP_AGENT_CHECK=1 \
SPIN_BIN_DIR="$TMP/bin" \
  ./install.sh >/dev/null

test -f org/ceo/CEO_CHAT_PROMPT.md
test -f org/projects/workspace/PROJECT_CONTROLLER_PROMPT.md
test -f org/projects/workspace/STATE.json

# One scheduled CEO brain must exclude overlapping manual ticks. The fake
# holder's command line includes the exact script path expected by the lock
# validator, so this exercises the live-process branch without invoking an LLM.
CEO_AGENT_LOCK="$KIT/org/ceo/runs/.workspace-ceo-agent.lock"
bash -c 'while :; do sleep 1; done' "$KIT/scripts/workspace-ceo-agent.sh" &
ceo_agent_holder=$!
printf '%s\n' "$ceo_agent_holder" > "$CEO_AGENT_LOCK"
set +e
ceo_agent_output="$(SPIN_ROOT="$KIT" bash "$KIT/scripts/workspace-ceo-agent.sh" 2>&1)"
ceo_agent_rc=$?
set -e
kill "$ceo_agent_holder" 2>/dev/null || true
wait "$ceo_agent_holder" 2>/dev/null || true
rm -f "$CEO_AGENT_LOCK"
[[ "$ceo_agent_rc" -eq 0 ]]
grep -q "already running (PID $ceo_agent_holder); skipping duplicate tick" <<<"$ceo_agent_output"

for f in scripts/*.sh scripts/lib/*.sh scripts/spin install.sh spin-bootstrap.sh; do
  bash -n "$f"
done
DOCTOR_ROOT="$TMP/doctor-root"
mkdir -p "$DOCTOR_ROOT/scripts/lib" "$DOCTOR_ROOT/org/ceo/runs"
cp scripts/spin "$DOCTOR_ROOT/scripts/spin"
cp scripts/lib/spin-runtime.sh "$DOCTOR_ROOT/scripts/lib/spin-runtime.sh"
cat > "$DOCTOR_ROOT/scripts/spin-app-health.js" <<'EOF'
process.exit(7);
EOF
cat > "$DOCTOR_ROOT/scripts/workstation.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DOCTOR_ROOT/scripts/workstation.sh"
set +e
SPIN_ROOT="$DOCTOR_ROOT" bash "$DOCTOR_ROOT/scripts/spin" doctor >/dev/null 2>&1
doctor_rc=$?
set -e
[[ "$doctor_rc" -ne 0 ]]
mkdir -p \
  "$TMP/service-home/.codex/tmp/session/bin" \
  "$TMP/service-home/.cache/codex-runtimes/runtime/bin" \
  "$TMP/service-home/.local/bin" \
  "$TMP/stable-service-bin" \
  "$TMP/cmux-cli-shims/session/bin"
SERVICE_PATH="$(
  HOME="$TMP/service-home" \
  PATH="$TMP/cmux-cli-shims/session/bin:$TMP/service-home/.codex/tmp/session/bin:$TMP/service-home/.cache/codex-runtimes/runtime/bin:$TMP/stable-service-bin:/usr/bin:/bin" \
    scripts/spin-service.sh path
)"
if [[ "$SERVICE_PATH" == *"$TMP/stable-service-bin"* ]]; then
  echo "service PATH retained an arbitrary temporary directory" >&2
  exit 1
fi
if [[ "$SERVICE_PATH" != *"$TMP/service-home/.local/bin"* ]]; then
  echo "service PATH dropped the allowlisted user bin directory" >&2
  exit 1
fi
for transient_path in "cmux-cli-shims" "/.codex/tmp/" "/.cache/codex-runtimes/"; do
  if [[ "$SERVICE_PATH" == *"$transient_path"* ]]; then
    echo "service PATH retained transient path marker: $transient_path" >&2
    exit 1
  fi
done

# A durable service installation owns every process required to keep the visible
# control plane truthful after login/reboot, not only the driver loop.
SERVICE_RENDER_HOME="$TMP/service-render-home"
HOME="$SERVICE_RENDER_HOME" SPIN_ROOT="$PWD" SPIN_SERVICE_DRY_RUN=1 SPIN_SERVICE_OS=Darwin \
  scripts/spin-service.sh install >/dev/null
for label in com.spin.driver com.spin.status-watch com.spin.wiki-watch; do
  plist="$SERVICE_RENDER_HOME/Library/LaunchAgents/$label.plist"
  test -f "$plist"
  grep -q '<key>RunAtLoad</key><true/>' "$plist"
done
grep -q 'workspace-ceo-tick.sh' "$SERVICE_RENDER_HOME/Library/LaunchAgents/com.spin.driver.plist"
grep -q 'workspace-status-watch.sh' "$SERVICE_RENDER_HOME/Library/LaunchAgents/com.spin.status-watch.plist"
grep -q 'wiki-watch.sh' "$SERVICE_RENDER_HOME/Library/LaunchAgents/com.spin.wiki-watch.plist"

SERVICE_SYSTEMD_HOME="$TMP/service-systemd-home"
XDG_CONFIG_HOME="$SERVICE_SYSTEMD_HOME" HOME="$SERVICE_RENDER_HOME" SPIN_ROOT="$PWD" \
  SPIN_SERVICE_DRY_RUN=1 SPIN_SERVICE_OS=Linux scripts/spin-service.sh install >/dev/null
for name in driver status-watch wiki-watch; do
  unit="$SERVICE_SYSTEMD_HOME/systemd/user/spin-$name.service"
  test -f "$unit"
  grep -q '^Restart=always$' "$unit"
done

# Status must reject an unrelated live process in a stale lock and expose the
# liveness of all three control-plane components.
STATUS_ROOT="$TMP/status-root"
mkdir -p "$STATUS_ROOT/scripts/lib" "$STATUS_ROOT/org/ceo/runs" \
  "$STATUS_ROOT/org/projects/example" "$STATUS_ROOT/logs"
cp scripts/workspace-status.sh "$STATUS_ROOT/scripts/workspace-status.sh"
cp scripts/lib/spin-runtime.sh "$STATUS_ROOT/scripts/lib/spin-runtime.sh"
cat > "$STATUS_ROOT/org/projects/example/FLOOR.md" <<'EOF'
# Example floor
## In progress
- Smoke test
## Next
- Verify
## Waiting
- Nothing
EOF
for script in workspace-ceo-tick.sh workspace-status-watch.sh wiki-watch.sh; do
  cat > "$STATUS_ROOT/scripts/$script" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
  chmod +x "$STATUS_ROOT/scripts/$script"
done
(
  set -e
  unrelated_pid=""
  bash "$STATUS_ROOT/scripts/workspace-ceo-tick.sh" & driver_pid=$!
  bash "$STATUS_ROOT/scripts/workspace-status-watch.sh" & status_pid=$!
  bash "$STATUS_ROOT/scripts/wiki-watch.sh" & wiki_pid=$!
  trap 'kill "$driver_pid" "$status_pid" "$wiki_pid" "$unrelated_pid" 2>/dev/null || true' EXIT
  echo "$driver_pid" > "$STATUS_ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
  echo "$status_pid" > "$STATUS_ROOT/org/ceo/runs/.status-watch.lock"
  echo "$wiki_pid" > "$STATUS_ROOT/org/ceo/runs/.wiki-watch.lock"
  SPIN_ROOT="$STATUS_ROOT" bash "$STATUS_ROOT/scripts/workspace-status.sh"
  grep -q '\*\*Driver:\*\*.*running' "$STATUS_ROOT/org/ceo/WORKSPACE_STATUS.md"
  grep -q '\*\*Live status:\*\*.*running' "$STATUS_ROOT/org/ceo/WORKSPACE_STATUS.md"
  grep -q '\*\*Project index:\*\*.*running' "$STATUS_ROOT/org/ceo/WORKSPACE_STATUS.md"

  sleep 30 & unrelated_pid=$!
  echo "$unrelated_pid" > "$STATUS_ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
  SPIN_ROOT="$STATUS_ROOT" bash "$STATUS_ROOT/scripts/workspace-status.sh"
  grep -q '\*\*Driver:\*\*.*DOWN' "$STATUS_ROOT/org/ceo/WORKSPACE_STATUS.md"
)
node --check scripts/org >/dev/null
node --check scripts/ceo-dashboard.js >/dev/null
node --check scripts/spin-web.js >/dev/null
node --check scripts/spin-app-health.js >/dev/null
node --check scripts/app-compatibility.js >/dev/null
node --check scripts/spin-app-update.js >/dev/null
node --check scripts/spin-app-updates.js >/dev/null
node --check scripts/omp-mcp-bootstrap.js >/dev/null
node --check scripts/lib/spin-runtime.js >/dev/null
node --check scripts/lib/human-queue-summary.js >/dev/null
mkdir -p "$TMP/installed-runtime-home/Applications/SPIN.app/Contents/Resources/bin"
HOME="$TMP/installed-runtime-home" node - "$TMP/installed-runtime-home" <<'NODE'
const path = require('path');
const runtime = require('./scripts/lib/spin-runtime.js');
const home = process.argv[2];
const root = path.join(home, 'Library', 'Application Support', 'SPIN', 'runtime');
const expected = path.join(home, 'Applications', 'SPIN.app', 'Contents', 'Resources', 'bin');
const candidates = runtime.candidateBinDirs(root);
if (!candidates.includes(expected)) process.exit(1);
NODE
node -e 'const app=JSON.parse(require("fs").readFileSync("app/spin-app.json","utf8")); if(!/^[0-9a-f]{40}$/.test(app.components?.uiEngine?.upstreamCommit||"")) process.exit(1); JSON.parse(require("fs").readFileSync("app/cmux/config/cmux.json","utf8")); JSON.parse(require("fs").readFileSync("app/cmux/config/dock.json","utf8"));'
CMUX_PIN_REPO="$TMP/cmux-pin-source"
CMUX_PIN_ROOT="$TMP/cmux-pin-spin"
mkdir -p "$CMUX_PIN_REPO" "$CMUX_PIN_ROOT/scripts" "$CMUX_PIN_ROOT/app"
git -C "$CMUX_PIN_REPO" init -q
printf 'one\n' > "$CMUX_PIN_REPO/source.txt"
git -C "$CMUX_PIN_REPO" add source.txt
git -C "$CMUX_PIN_REPO" -c user.name=spin-test -c user.email=spin-test@example.invalid commit -qm one
CMUX_PIN_COMMIT="$(git -C "$CMUX_PIN_REPO" rev-parse HEAD)"
printf 'two\n' >> "$CMUX_PIN_REPO/source.txt"
git -C "$CMUX_PIN_REPO" add source.txt
git -C "$CMUX_PIN_REPO" -c user.name=spin-test -c user.email=spin-test@example.invalid commit -qm two
cp scripts/vendor-app-deps.sh "$CMUX_PIN_ROOT/scripts/vendor-app-deps.sh"
cp app/spin-app.json "$CMUX_PIN_ROOT/app/spin-app.json"
SPIN_ROOT="$CMUX_PIN_ROOT" SPIN_CMUX_REPO="$CMUX_PIN_REPO" SPIN_CMUX_COMMIT="$CMUX_PIN_COMMIT" \
  bash "$CMUX_PIN_ROOT/scripts/vendor-app-deps.sh" --cmux-only >/dev/null
test "$(git -C "$CMUX_PIN_ROOT/app/upstream/cmux" rev-parse HEAD)" = "$CMUX_PIN_COMMIT"
node - <<'NODE'
const cfg = JSON.parse(require('fs').readFileSync('app/cmux/config/cmux.json', 'utf8'));
if (cfg.sidebar.hideAllDetails !== true) process.exit(1);
if (cfg.sidebar.showWorkspaceDescription !== false) process.exit(1);
if (cfg.sidebar.showNotificationMessage !== false) process.exit(1);
if (cfg.sidebar.showBranchDirectory !== false) process.exit(1);
if (cfg.sidebar.showPorts !== false) process.exit(1);
if (cfg.sidebar.showPullRequests !== false) process.exit(1);
if (cfg.sidebar.showLog !== false) process.exit(1);
if (cfg.sidebar.showProgress !== false) process.exit(1);
if (cfg.sidebar.showCustomMetadata !== false) process.exit(1);
if (cfg.sidebar.showSSH !== false) process.exit(1);
if (cfg.sidebarAppearance.tintColor !== '#FF7ADF') process.exit(1);
if (cfg.sidebarAppearance.darkModeTintColor !== '#FF7ADF') process.exit(1);
if (cfg.sidebarAppearance.tintOpacity !== 0.24) process.exit(1);
NODE
node -e 'const dock=JSON.parse(require("fs").readFileSync("app/cmux/config/dock.json","utf8")); if(!dock.controls.some(c=>c.id==="spin-updates"&&/app-updates/.test(c.command))) process.exit(1);'
grep -q 'prepare-open-source-release.sh --artifact' .github/workflows/macos-app.yml
grep -q '\*-release-notes.md' .github/workflows/macos-app.yml
grep -q 'matching cmux corresponding-source archive' docs/RELEASING_MACOS.md
grep -q 'SPIN_RELEASE_FORMAT=dmg scripts/release-macos.sh' .github/workflows/macos-app.yml
grep -q 'dist/release/\*.dmg' .github/workflows/macos-app.yml
grep -q 'actions/workflows/macos-app.yml/badge.svg' README.md
grep -q 'AI agent command center for Mac' README.md
grep -q 'SPIN for Mac packages' README.md
grep -q 'Download SPIN For Mac' README.md
grep -q 'Source And CLI Setup' README.md
grep -q 'v4.1.0-beta.3' README.md
grep -q 'signed Codex CLI' README.md
grep -q 'spin computer-use probe' README.md
grep -q 'docs/INSTALL_MACOS.md' README.md
grep -q 'docs/assets/spin-public-beta-demo.gif' README.md
! grep -qi 'small AI software org\|talk to it like a person\|public beta readiness' README.md
test -s docs/assets/spin-public-beta-demo.gif
test -s docs/assets/spin-public-beta-demo.mp4
test -s docs/assets/spin-public-beta-demo-poster.png
test -s docs/assets/spin-icon.svg
grep -q 'id="app"' docs/index.html
grep -q 'SPIN for Mac' docs/index.html
grep -q 'visual command center' docs/index.html
grep -q 'Source and CLI' docs/index.html
grep -q 'v4.1.0-beta.3' docs/index.html
grep -q 'INSTALL_MACOS.md' docs/index.html
grep -q 'Project isolation comes first' docs/index.html
grep -q 'class="spinner"' docs/index.html
grep -q '@keyframes spin' docs/index.html
grep -q 'assets/spin-public-beta-demo.gif' docs/index.html
grep -q 'assets/spin-public-beta-demo-poster.png' docs/index.html
grep -q 'assets/spin-icon.svg' docs/index.html
! grep -qi 'small AI software org\|talk to it like a person\|beta readiness' docs/index.html
grep -q 'Install SPIN for Mac' docs/INSTALL_MACOS.md
grep -q 'Control-click `SPIN.app`' docs/INSTALL_MACOS.md
grep -q 'DMG opens and includes `SPIN.app`, `Applications`, and `README.txt`' docs/RELEASING_MACOS.md
grep -q 'SPIN for Mac 4.1.0 Beta 3' docs/releases/SPIN-4.1.0-beta.3.md
! grep -qi 'attach these files\|maintainer checks\|open-source tester' docs/releases/SPIN-4.1.0-beta.3.md
test -f SECURITY.md
grep -q 'Security Policy' SECURITY.md
test -f .github/ISSUE_TEMPLATE/config.yml
test -f .github/ISSUE_TEMPLATE/app-beta-bug.yml
test -f .github/ISSUE_TEMPLATE/public-feedback.yml
test -f app/cmux/sidebars/spin-navigator.swift
grep -q 'workspace.close' app/cmux/sidebars/spin-navigator.swift
grep -q 'Close project tab' app/cmux/sidebars/spin-navigator.swift
grep -q 'onTapGesture { cmux("workspace.select"' app/cmux/sidebars/spin-navigator.swift
grep -q 'frame(width: 82, alignment: .leading)' app/cmux/sidebars/spin-navigator.swift
grep -q 'Text("Project floors")' app/cmux/sidebars/spin-navigator.swift
grep -q 'frame(height: 24)' app/cmux/sidebars/spin-navigator.swift
grep -q 'cmux("workspace.create", title: "New SPIN Project")' app/cmux/sidebars/spin-navigator.swift
grep -q 'frame(height: 22)' app/cmux/sidebars/spin-navigator.swift
! grep -q 'clock.time' app/cmux/sidebars/spin-navigator.swift
grep -q 'offset(y: 2)' app/cmux/sidebars/spin-navigator.swift
grep -q 'maxHeight: .infinity, alignment: .topLeading' app/cmux/sidebars/spin-navigator.swift
grep -q 'offset(y: -58)' app/cmux/sidebars/spin-navigator.swift
test -f assets/branding/spin-icon.svg
test -f assets/branding/SPIN.icns
node - <<'NODE'
const { summarizeHumanQueueText } = require('./scripts/lib/human-queue-summary.js');
const now = new Date(Date.UTC(2026, 5, 24, 0, 0, 0));
const summary = summarizeHumanQueueText([
  '- [ ] 2026-06-20 00:00 - old approval',
  '- [x] 2026-06-19 00:00 - already handled',
  '- plain legacy waiting item',
].join('\n'), now);
if (summary.count !== 2) process.exit(1);
if (summary.oldestAgeLabel !== '4d 0h') process.exit(1);
NODE

FAKE_CMUX="$TMP/fake-cmux"
mkdir -p \
  "$FAKE_CMUX/.git" \
  "$FAKE_CMUX/cmux.xcodeproj" \
  "$FAKE_CMUX/Resources/bin" \
  "$FAKE_CMUX/Sources" \
  "$FAKE_CMUX/CLI" \
  "$FAKE_CMUX/Assets.xcassets/AppIcon.appiconset" \
  "$FAKE_CMUX/Assets.xcassets/AppIcon-Debug.appiconset" \
  "$FAKE_CMUX/Assets.xcassets/AppIcon-Nightly.appiconset" \
  "$FAKE_CMUX/Assets.xcassets/AppIconLight.imageset" \
  "$FAKE_CMUX/Assets.xcassets/AppIconDark.imageset" \
  "$FAKE_CMUX/Packages/macOS/CmuxTerminal" \
  "$FAKE_CMUX/Packages/iOS/CmuxMobileTerminal" \
  "$FAKE_CMUX/vendor/bonsplit" \
  "$FAKE_CMUX/GhosttyKit.xcframework"
cat > "$FAKE_CMUX/cmux.xcodeproj/project.pbxproj" <<'EOF'
PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app;
PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.debug;
PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.docktileplugin;
PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.docktileplugin.debug;
PRODUCT_NAME = cmux;
PRODUCT_NAME = "cmux DEV";
CMUX_AUTH_CALLBACK_SCHEME = cmux;
CMUX_AUTH_CALLBACK_SCHEME = "cmux-dev";
CMUX_SIDEBAR_EXTENSION_POINT_ID = com.cmuxterm.app.cmux.sidebar;
path = cmux.app;
EOF
cat > "$FAKE_CMUX/Resources/Info.plist" <<'EOF'
A program running within cmux would like to use your microphone.
A program running within cmux would like to use your camera.
A program running within cmux would like to use Bluetooth to discover passkeys and security keys.
A program running within cmux would like to use AppleScript.
cmux Sidebar Tab Reorder
cmux File Preview Transfer
EOF
cat > "$FAKE_CMUX/Sources/cmuxApp.swift" <<'EOF'
Button(String(localized: "menu.app.openCmuxSettingsFile", defaultValue: "Open cmux.json")) {}
Button(String(localized: "menu.app.ghosttySettings", defaultValue: "Ghostty Settings…")) {}
Button(String(localized: "menu.app.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal")) {}
Button(String(localized: "menu.app.about", defaultValue: "About cmux")) {}
splitCommandButton(title: String(localized: "menu.quitCmux", defaultValue: "Quit cmux")) {}
Text(String(localized: "about.appName", defaultValue: "cmux"))
Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
private let docsURL = URL(string: "https://cmux.com/docs")
let commitURL = commit.flatMap { hash in
  URL(string: "https://github.com/manaflow-ai/cmux/commit/\(hash)")
}
imageForMode: { mode in
                    guard let imageName = mode.imageName else { return nil }
                    return NSImage(named: imageName)
                },
imageForName: { imageName in
                    NSImage(named: imageName)
                },
EOF
cat > "$FAKE_CMUX/Sources/AppIconDockTilePlugin.swift" <<'EOF'
    private var appBundle: Bundle? {
        guard let appBundleURL else { return nil }
        return Bundle(url: appBundleURL)
    }

    private var shouldPersistBundleIcon: Bool {
        false
    }

    private func updateDockTile(_ dockTile: NSDockTile) {
        Self.assertMainQueue()

        let mode = DockTileAppIconMode(defaultsValue: appDefaults?.string(forKey: cmuxAppIconModeKey))
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let appBundleURL else {
EOF
cat > "$FAKE_CMUX/Sources/ContentView.swift" <<'EOF'
title: constant(String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json"))
subtitle: constant(String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"))
keywords: ["open", "cmux", "json", "config", "configuration", "settings", "file", "editor", "dotfile"]
defaultValue: "Open Ghostty Settings in TextEdit"
defaultValue: "Ghostty Config Files"
keywords: ["open", "ghostty", "settings", "config", "configuration", "file", "textedit", "terminal"]
defaultValue: "Make cmux the Default Terminal"
.padding(.vertical, 8)
EOF
cat > "$FAKE_CMUX/Resources/Localizable.xcstrings" <<'EOF'
{
  "strings": {
    "about.appName": { "localizations": { "en": { "stringUnit": { "value": "cmux" } } } },
    "about.description": { "localizations": { "en": { "stringUnit": { "value": "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS." } } } },
    "menu.app.about": { "localizations": { "en": { "stringUnit": { "value": "About cmux" } } } },
    "menu.app.ghosttySettings": { "localizations": { "en": { "stringUnit": { "value": "Ghostty Settings…" } } } },
    "menu.app.openCmuxSettingsFile": { "localizations": { "en": { "stringUnit": { "value": "Open cmux.json" } } } },
    "menu.app.makeDefaultTerminal": { "localizations": { "en": { "stringUnit": { "value": "Make cmux the Default Terminal" } } } },
    "menu.quitCmux": { "localizations": { "en": { "stringUnit": { "value": "Quit cmux" } } } },
    "command.openGhosttySettings.title": { "localizations": { "en": { "stringUnit": { "value": "Open Ghostty Settings in TextEdit" } } } },
    "command.openGhosttySettings.subtitle": { "localizations": { "en": { "stringUnit": { "value": "Ghostty Config Files" } } } }
  }
}
EOF
: > "$FAKE_CMUX/CLI/cmux.swift"
cat > "$FAKE_CMUX/Packages/macOS/CmuxTerminal/Package.swift" <<'EOF'
"GhosttyRuntimeTestStubs"
EOF
cat > "$FAKE_CMUX/Packages/iOS/CmuxMobileTerminal/Package.swift" <<'EOF'
"GhosttyKit"
EOF
cat > "$FAKE_CMUX/vendor/bonsplit/Package.swift" <<'EOF'
// fake bonsplit package marker
EOF
SPIN_CMUX_OVERLAY_NO_FETCH=1 scripts/apply-cmux-spin-overlay.sh "$FAKE_CMUX" >/dev/null
grep -q 'PRODUCT_NAME = SPIN;' "$FAKE_CMUX/cmux.xcodeproj/project.pbxproj"
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = dev.spin.app;' "$FAKE_CMUX/cmux.xcodeproj/project.pbxproj"
grep -q 'CMUX_AUTH_CALLBACK_SCHEME = spin;' "$FAKE_CMUX/cmux.xcodeproj/project.pbxproj"
grep -q 'CMUX_SIDEBAR_EXTENSION_POINT_ID = dev.spin.app.cmux.sidebar;' "$FAKE_CMUX/cmux.xcodeproj/project.pbxproj"
grep -q 'SPIN Sidebar Tab Reorder' "$FAKE_CMUX/Resources/Info.plist"
grep -q 'About SPIN' "$FAKE_CMUX/Sources/cmuxApp.swift"
grep -q 'Terminal Engine Settings' "$FAKE_CMUX/Sources/cmuxApp.swift"
grep -q 'Bundle.main.bundleURL.lastPathComponent == "SPIN.app"' "$FAKE_CMUX/Sources/cmuxApp.swift"
grep -q 'bundledSpinAppIcon' "$FAKE_CMUX/Sources/AppIconDockTilePlugin.swift"
grep -q 'Open SPIN Workspace Config' "$FAKE_CMUX/Sources/ContentView.swift"
grep -q 'settings.hidesAllDetails ? 3 : 8' "$FAKE_CMUX/Sources/ContentView.swift"
grep -q '"value": "About SPIN"' "$FAKE_CMUX/Resources/Localizable.xcstrings"
grep -q '"value": "Terminal Engine Settings…"' "$FAKE_CMUX/Resources/Localizable.xcstrings"
grep -q 'CmuxTerminalGhosttyRuntimeTestStubs' "$FAKE_CMUX/Packages/macOS/CmuxTerminal/Package.swift"
grep -q 'CmuxMobileGhosttyKit' "$FAKE_CMUX/Packages/iOS/CmuxMobileTerminal/Package.swift"
if command -v qlmanage >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  test -s "$FAKE_CMUX/Assets.xcassets/AppIcon.appiconset/512@2x.png"
  test -s "$FAKE_CMUX/Assets.xcassets/AppIconLight.imageset/AppIconLight.png"
  test -s "$FAKE_CMUX/Assets.xcassets/AppIconDark.imageset/AppIconDark.png"
fi
test -f "$FAKE_CMUX/Resources/spin/spin-navigator.swift"
grep -q 'workspace.close' "$FAKE_CMUX/Resources/spin/spin-navigator.swift"
test -x "$FAKE_CMUX/Resources/bin/spin-open"

scripts/org escalate "smoke approval needed" >/dev/null
org_json="$(scripts/org show --json)"
node -e '
  const digest = JSON.parse(process.argv[1]);
  if (digest.state.human_queue.length !== 1) process.exit(1);
  if (!digest.state.human_queue[0].includes("smoke approval needed")) process.exit(1);
' "$org_json"
status_out="$(SPIN_ROOT="$KIT" scripts/spin)"
grep -q "smoke approval needed" <<<"$status_out"
grep -q "1 waiting" <<<"$status_out"
dashboard_out="$(node scripts/ceo-dashboard.js "$KIT")"
grep -q "WAITING ON YOU" <<<"$dashboard_out"
grep -q "1 waiting" <<<"$dashboard_out"

SPIN_ROOT="$KIT" node scripts/spin-web.js --port 0 > "$TMP/spin-web.out" 2>&1 &
WEB_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'SPIN web:' "$TMP/spin-web.out" 2>/dev/null && break
  sleep 0.2
done
WEB_URL="$(awk '/SPIN web:/{print $3; exit}' "$TMP/spin-web.out")"
node - "$WEB_URL" <<'NODE'
const http = require('http');
const url = process.argv[2];
http.get(url, res => {
  let body = '';
  res.on('data', chunk => body += chunk);
  res.on('end', () => {
    if (!body.includes('SPIN Control') || !body.includes('smoke approval needed')) process.exit(1);
  });
}).on('error', () => process.exit(1));
NODE
node - "$WEB_URL" <<'NODE'
const http = require('http');
const url = new URL('/decision', process.argv[2]);
const body = new URLSearchParams({ action: 'APPROVE', item: 'smoke approval needed' }).toString();
const req = http.request(url, {
  method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded', 'content-length': Buffer.byteLength(body) },
}, res => process.exit(res.statusCode === 303 ? 0 : 1));
req.on('error', () => process.exit(1));
req.end(body);
NODE
kill "$WEB_PID" 2>/dev/null || true
wait "$WEB_PID" 2>/dev/null || true
grep -q 'APPROVE: smoke approval needed' org/ceo/APPROVALS.md
node - <<'NODE'
const fs = require('fs');
const file = 'org/ceo/APPROVALS.md';
const text = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, text.replace('## Pending\n', '## Pending\n\n- owner-only smoke decision\n'));
NODE
if scripts/org process-approval owner-only approve --note "agent must not self-approve" >/dev/null 2>&1; then
  echo "owner-only approval accepted without owner confirmation"
  exit 1
fi
SPIN_OWNER_CONFIRMED=1 scripts/org process-approval owner-only approve --note "smoke owner confirmation" >/dev/null
grep -q 'owner-only smoke decision.*APPROVE.*smoke owner confirmation' org/ceo/APPROVALS.md

QUEUE_LOCK_READY="$TMP/queue-lock-ready"
node - "$QUEUE_LOCK_READY" "$KIT/org/ceo/runs/.org-queue.lock" <<'NODE' &
const fs = require('fs');
const [ready, lock] = process.argv.slice(2);
fs.writeFileSync(lock, String(process.pid), { flag: 'wx' });
fs.writeFileSync(ready, 'ready\n');
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 450);
fs.unlinkSync(lock);
NODE
QUEUE_LOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$QUEUE_LOCK_READY" ]] && break
  sleep 0.05
done
node - "$KIT" <<'NODE'
const path = require('path');
const { spawnSync } = require('child_process');
const root = process.argv[2];
const started = Date.now();
const result = spawnSync(path.join(root, 'scripts', 'omp-supervisor-once.sh'), [], {
  cwd: root,
  env: { ...process.env, SPIN_ROOT: root },
  encoding: 'utf8',
});
if (result.status !== 0) {
  process.stderr.write(result.stderr || result.stdout || 'supervisor lock smoke failed\n');
  process.exit(1);
}
if (Date.now() - started < 250) {
  process.stderr.write('supervisor did not wait for the shared queue lock\n');
  process.exit(1);
}
NODE
wait "$QUEUE_LOCK_PID"

scripts/org queue-job example-app scout "inspect smoke path; quoted ' value" --id smoke-scout >/dev/null
scripts/org update-job smoke-scout --description "inspect updated smoke path" --max-runtime 90 >/dev/null
scripts/org queue-job example-app scout "inspect dependent smoke path" --id smoke-dependent --after smoke-scout >/dev/null
if scripts/org queue-job example-app scout "bad id path" --id '../bad' >/dev/null 2>&1; then
  echo "bad job id accepted"
  exit 1
fi
if scripts/org update-job smoke-scout --after smoke-dependent >/dev/null 2>&1; then
  echo "dependency cycle accepted"
  exit 1
fi
if scripts/org queue-job example-app scout "missing dependency" --id smoke-missing --after does-not-exist >/dev/null 2>&1; then
  echo "missing dependency accepted"
  exit 1
fi
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  if (!q.jobs.some(j => j.id === "smoke-scout" && j.status === "queued" && j.description === "inspect updated smoke path" && j.max_runtime_seconds === 90)) process.exit(1);
  if (!q.jobs.some(j => j.id === "smoke-dependent" && j.status === "queued" && JSON.stringify(j.depends_on) === JSON.stringify(["smoke-scout"]))) process.exit(1);
'

# Concurrent state mutations must serialize instead of racing lock release.
lock_pids=()
for project in example-app workspace example-app workspace; do
  scripts/org set-state "$project" --status "smoke-lock-contention" >/dev/null &
  lock_pids+=("$!")
done
for pid in "${lock_pids[@]}"; do
  wait "$pid"
done

cat > scripts/project-ceo-agent.sh <<EOF
#!/usr/bin/env bash
{
  printf 'id=%s\n' "\${OMP_JOB_ID:-}"
  printf 'type=%s\n' "\${OMP_JOB_TYPE:-}"
  printf 'description=%s\n' "\${OMP_JOB_DESCRIPTION:-}"
  printf 'project=%s\n' "\${1:-}"
} > "$TMP/project-agent.env"
EOF
chmod +x scripts/project-ceo-agent.sh
scripts/omp-supervisor-once.sh >/dev/null
for _ in 1 2 3 4 5; do
  [[ -f "$TMP/project-agent.env" ]] && break
  sleep 0.2
done
for _ in 1 2 3 4 5; do
  [[ -s "org/jobs/smoke-scout.heartbeat" ]] && break
  sleep 0.2
done
grep -Eq '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' org/jobs/smoke-scout.heartbeat
grep -q "description=inspect updated smoke path" "$TMP/project-agent.env"
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  const j = q.jobs.find(j => j.id === "smoke-dependent");
  if (!j || j.status !== "queued") process.exit(1);
  const first = q.jobs.find(j => j.id === "smoke-scout");
  if (!first || first.heartbeat !== "org/jobs/smoke-scout.heartbeat") process.exit(1);
'
scripts/omp-supervisor-once.sh >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  scripts/omp-supervisor-once.sh >/dev/null
  if node - <<'NODE'
const q = JSON.parse(require('fs').readFileSync('org/AGENT_QUEUE.json', 'utf8'));
for (const id of ['smoke-scout', 'smoke-dependent']) {
  if (q.jobs.find(job => job.id === id)?.status !== 'completed') process.exit(1);
}
if (!q.jobs.find(job => job.id === 'smoke-scout')?.heartbeat_at) process.exit(1);
NODE
  then
    break
  fi
  sleep 0.2
done
grep -q "description=inspect dependent smoke path" "$TMP/project-agent.env"
node - <<'NODE'
const q = JSON.parse(require('fs').readFileSync('org/AGENT_QUEUE.json', 'utf8'));
for (const id of ['smoke-scout', 'smoke-dependent']) {
  if (q.jobs.find(job => job.id === id)?.status !== 'completed') process.exit(1);
}
NODE

scripts/org queue-job example-app scout "failed dependency fixture" --id smoke-failed-prereq >/dev/null
node - <<'NODE'
const fs = require('fs');
const file = 'org/AGENT_QUEUE.json';
const q = JSON.parse(fs.readFileSync(file, 'utf8'));
const job = q.jobs.find(entry => entry.id === 'smoke-failed-prereq');
job.status = 'failed';
job.failed_at = new Date().toISOString();
job.result = 'intentional smoke fixture failure';
fs.writeFileSync(file, JSON.stringify(q, null, 2) + '\n');
NODE
scripts/org queue-job example-app scout "recover blocked dependency" --id smoke-requeue --after smoke-failed-prereq >/dev/null
scripts/omp-supervisor-once.sh >/dev/null
node - <<'NODE'
const q = JSON.parse(require('fs').readFileSync('org/AGENT_QUEUE.json', 'utf8'));
const job = q.jobs.find(entry => entry.id === 'smoke-requeue');
if (job?.status !== 'blocked' || !/smoke-failed-prereq is failed/.test(job.result || '')) process.exit(1);
NODE
node - <<'NODE'
const fs = require('fs');
const file = 'org/AGENT_QUEUE.json';
const q = JSON.parse(fs.readFileSync(file, 'utf8'));
const job = q.jobs.find(entry => entry.id === 'smoke-failed-prereq');
job.status = 'completed';
job.completed_at = new Date().toISOString();
delete job.failed_at;
delete job.result;
fs.writeFileSync(file, JSON.stringify(q, null, 2) + '\n');
NODE
scripts/org update-job smoke-requeue --requeue >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  scripts/omp-supervisor-once.sh >/dev/null
  if node -e '
    const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
    if (q.jobs.find(job => job.id === "smoke-requeue")?.status !== "completed") process.exit(1);
  '; then
    break
  fi
  sleep 0.2
done
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  if (q.jobs.find(job => job.id === "smoke-requeue")?.status !== "completed") process.exit(1);
'

# A runaway agent/test process tree must be killed inside its detached process
# group and leave a durable resource-limit result for the next reconciliation.
cat > scripts/project-ceo-agent.sh <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do sleep 1; done
EOF
chmod +x scripts/project-ceo-agent.sh
scripts/org queue-job example-app scout "resource governor fixture" --id smoke-resource-limit >/dev/null
OMP_JOB_MAX_RSS_MB=1 OMP_RESOURCE_CHECK_INTERVAL=1 scripts/omp-supervisor-once.sh >/dev/null
resource_job_pid="$(cat org/jobs/smoke-resource-limit.pid)"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s org/jobs/smoke-resource-limit.resource ]] && ! kill -0 "$resource_job_pid" 2>/dev/null && break
  sleep 0.5
done
if kill -0 "$resource_job_pid" 2>/dev/null; then
  kill -KILL -- "-$resource_job_pid" 2>/dev/null || kill -KILL "$resource_job_pid" 2>/dev/null || true
  echo "resource governor did not stop the over-limit process group" >&2
  exit 1
fi
grep -q 'Resource limit exceeded: RSS' org/jobs/smoke-resource-limit.resource
for _ in 1 2 3 4 5; do
  scripts/omp-supervisor-once.sh >/dev/null
  if node - <<'NODE'
const q = JSON.parse(require('fs').readFileSync('org/AGENT_QUEUE.json', 'utf8'));
const job = q.jobs.find(entry => entry.id === 'smoke-resource-limit');
if (job?.status !== 'failed' || !/Resource limit exceeded/.test(job.result || '')) process.exit(1);
if (job.resource_limits?.max_rss_mb !== 1 || job.resource_limits?.max_processes !== 32) process.exit(1);
NODE
  then
    break
  fi
  sleep 0.2
done
node - <<'NODE'
const q = JSON.parse(require('fs').readFileSync('org/AGENT_QUEUE.json', 'utf8'));
const job = q.jobs.find(entry => entry.id === 'smoke-resource-limit');
if (job?.status !== 'failed' || !/Resource limit exceeded/.test(job.result || '')) process.exit(1);
NODE

cat > scripts/project-ceo-agent.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
PROJECT_ID="${1:?usage: project-ceo-agent.sh <project-id>}"
PROJECT_DIR="$ROOT/org/projects/$PROJECT_ID"
STATE_FILE="$PROJECT_DIR/STATE.json"
RECEIPTS_FILE="$PROJECT_DIR/RECEIPTS.md"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
JOB_ID="${OMP_JOB_ID:-unknown}"
JOB_TYPE="${OMP_JOB_TYPE:-unknown}"
JOB_DESCRIPTION="${OMP_JOB_DESCRIPTION:-}"

node - "$STATE_FILE" "$PROJECT_ID" "$JOB_ID" "$JOB_TYPE" "$JOB_DESCRIPTION" "$TS" <<'NODE'
const fs = require('fs');
const [file, project, jobId, jobType, description, ts] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
state.project_id = state.project_id || state.project || project;
state.project = state.project || state.project_id || project;
state.status = 'completed';
state.next_action = `smoke proof complete: ${jobId}`;
state.updated_at = ts;
state.last_smoke_job = { id: jobId, type: jobType, description, completed_at: ts };
fs.writeFileSync(file, JSON.stringify(state, null, 2) + '\n');
NODE

{
  printf '\n## Smoke Project Proof — %s\n' "$TS"
  printf -- '- Project: %s\n' "$PROJECT_ID"
  printf -- '- Job: %s (%s)\n' "$JOB_ID" "$JOB_TYPE"
  printf -- '- Description: %s\n' "$JOB_DESCRIPTION"
  printf -- '- Result: completed through deterministic smoke project agent\n'
} >> "$RECEIPTS_FILE"

"$ROOT/scripts/org" set-state "$PROJECT_ID" \
  --status "completed" \
  --next "smoke proof complete: $JOB_ID" >/dev/null
"$ROOT/scripts/org" inbox "$PROJECT_ID" \
  "job $JOB_ID complete: $JOB_DESCRIPTION" >/dev/null
EOF
chmod +x scripts/project-ceo-agent.sh
scripts/org queue-job example-app scout "multi-project proof: example lane" --id smoke-example-project >/dev/null
scripts/org queue-job workspace scout "multi-project proof: workspace lane" --id smoke-workspace-project >/dev/null
scripts/omp-supervisor-once.sh >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "Smoke Project Proof" org/projects/example-app/RECEIPTS.md &&
     grep -q "Smoke Project Proof" org/projects/workspace/RECEIPTS.md &&
     grep -q "smoke-example-project complete" org/ceo/INBOX.md &&
     grep -q "smoke-workspace-project complete" org/ceo/INBOX.md; then
    break
  fi
  sleep 0.2
done
for _ in 1 2 3 4 5 6 7 8 9 10; do
  scripts/omp-supervisor-once.sh >/dev/null
  if node - <<'NODE'
const fs = require('fs');
const queue = JSON.parse(fs.readFileSync('org/AGENT_QUEUE.json', 'utf8'));
for (const id of ['smoke-example-project', 'smoke-workspace-project']) {
  const job = queue.jobs.find(j => j.id === id);
  if (!job || job.status !== 'completed') process.exit(1);
}
NODE
  then
    break
  fi
  sleep 0.2
done
grep -q "smoke-example-project complete" org/ceo/INBOX.md
grep -q "smoke-workspace-project complete" org/ceo/INBOX.md
grep -q "smoke-example-project" org/projects/example-app/STATE.json
grep -q "smoke-workspace-project" org/projects/workspace/STATE.json
node - <<'NODE'
const fs = require('fs');
const queue = JSON.parse(fs.readFileSync('org/AGENT_QUEUE.json', 'utf8'));
for (const id of ['smoke-example-project', 'smoke-workspace-project']) {
  const job = queue.jobs.find(j => j.id === id);
  if (!job || job.status !== 'completed') process.exit(1);
}
const orgState = JSON.parse(fs.readFileSync('org/state.json', 'utf8'));
for (const id of ['example-app', 'workspace']) {
  const project = (orgState.project_orchestrators || []).find(p => p.id === id || p.project === id);
  if (!project || project.status !== 'completed' || !/smoke proof complete/.test(project.next_action || '')) {
    process.exit(1);
  }
}
NODE

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
SMOKE_HOME="$TMP/home"
mkdir -p "$SMOKE_HOME"
cat > "$FAKEBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/cmux.calls"
case "\${1:-}" in
  ping) exit 0 ;;
  version) echo "cmux fake 1.0"; exit 0 ;;
  tree) echo "surface:7 [terminal]"; exit 0 ;;
  new-workspace) echo "workspace:7"; exit 0 ;;
  read-screen) echo "model: sonnet-4-6"; exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/cmux"

cat > "$TMP/slow-cmux" <<'EOF'
#!/usr/bin/env bash
/bin/sleep 10
EOF
chmod +x "$TMP/slow-cmux"
timeout_started="$(date +%s)"
set +e
SPIN_CMUX_BIN="$TMP/slow-cmux" SPIN_CMUX_COMMAND_TIMEOUT_SECONDS=1 SPIN_ROOT="$KIT" \
  bash -c 'source scripts/lib/spin-runtime.sh; spin_cmd cmux ping' >/dev/null 2>&1
timeout_rc=$?
set -e
[[ "$timeout_rc" -eq 124 ]]
(( $(date +%s) - timeout_started < 4 ))

mkdir -p "$TMP/wiki-symlink-project/src"
printf '# Symlinked project\n' > "$TMP/wiki-symlink-project/README.md"
printf 'export const linked = true;\n' > "$TMP/wiki-symlink-project/src/index.ts"
mkdir -p "$KIT/projects"
ln -s "$TMP/wiki-symlink-project" "$KIT/projects/wiki-symlink"
SPIN_ROOT="$KIT" scripts/wiki-build.sh wiki-symlink >/dev/null
grep -q 'src/index.ts' "$KIT/org/wiki/projects/wiki-symlink.md"
rm -f "$KIT/projects/wiki-symlink" "$KIT/org/wiki/projects/wiki-symlink.md"

PATH="$FAKEBIN:$PATH" SPIN_ROOT="$KIT" \
  scripts/spin-new-project.sh smoke-floor "Smoke-test two-pane floor" > "$TMP/new-project.out"
grep -q 'Smoke-test two-pane floor' org/projects/smoke-floor/FLOOR.md
grep -q 'new-workspace --name smoke-floor' "$TMP/cmux.calls"
grep -q 'markdown open .*/org/projects/smoke-floor/FLOOR.md --workspace workspace:7 --surface surface:7 --direction right --focus false' "$TMP/cmux.calls"

ROLLUP_ROOT="$TMP/semantic-rollup"
mkdir -p "$ROLLUP_ROOT/scripts/lib" "$ROLLUP_ROOT/org/ceo/runs" \
  "$ROLLUP_ROOT/org/projects/active-app" "$ROLLUP_ROOT/org/projects/old-app" \
  "$ROLLUP_ROOT/org/wiki"
cp scripts/workspace-status.sh scripts/wiki-update.sh "$ROLLUP_ROOT/scripts/"
cp scripts/lib/spin-runtime.sh scripts/lib/human-queue-summary.js "$ROLLUP_ROOT/scripts/lib/"
cat > "$ROLLUP_ROOT/org/state.json" <<'EOF'
{
  "project_orchestrators": [
    { "project": "active-app", "status": "active-company-project" },
    { "project": "old-app", "status": "completed" }
  ]
}
EOF
cat > "$ROLLUP_ROOT/org/OMP_HARNESS.json" <<'EOF'
{
  "projects": {
    "active-app": { "cmux_workspace": "workspace:1" },
    "old-app": { "cmux_workspace": "workspace:2" }
  }
}
EOF
printf '%s\n' '{ "jobs": [] }' > "$ROLLUP_ROOT/org/AGENT_QUEUE.json"
printf '%s\n' '# Human Queue' > "$ROLLUP_ROOT/org/HUMAN_QUEUE.md"
for id in active-app old-app; do
  cat > "$ROLLUP_ROOT/org/projects/$id/FLOOR.md" <<EOF
# $id
## In progress
- Stable status
## Next
- Stable next action
## Waiting on human
- Nothing
EOF
done

SPIN_ROOT="$ROLLUP_ROOT" "$ROLLUP_ROOT/scripts/workspace-status.sh"
grep -q '^## active-app' "$ROLLUP_ROOT/org/ceo/WORKSPACE_STATUS.md"
if grep -q '^## old-app' "$ROLLUP_ROOT/org/ceo/WORKSPACE_STATUS.md"; then
  echo "Coordinator status retained an inactive project floor" >&2
  exit 1
fi
status_hash_before="$(shasum -a 256 "$ROLLUP_ROOT/org/ceo/WORKSPACE_STATUS.md" | awk '{print $1}')"
sleep 1
SPIN_ROOT="$ROLLUP_ROOT" "$ROLLUP_ROOT/scripts/workspace-status.sh"
status_hash_after="$(shasum -a 256 "$ROLLUP_ROOT/org/ceo/WORKSPACE_STATUS.md" | awk '{print $1}')"
[[ "$status_hash_before" == "$status_hash_after" ]] || { echo "semantic status rewrote timestamp-only output" >&2; exit 1; }
grep -q 'status-watch.heartbeat' scripts/workspace-status-watch.sh
grep -q 'heartbeat .*s ago' scripts/workstation.sh

SPIN_ROOT="$ROLLUP_ROOT" "$ROLLUP_ROOT/scripts/wiki-update.sh" > "$TMP/wiki-update-first.out"
grep -q '^### active-app -' "$ROLLUP_ROOT/org/wiki/workspace.md"
if grep -q '^### old-app -' "$ROLLUP_ROOT/org/wiki/workspace.md"; then
  echo "workspace wiki retained an inactive project" >&2
  exit 1
fi
wiki_hash_before="$(shasum -a 256 "$ROLLUP_ROOT/org/wiki/workspace.md" | awk '{print $1}')"
sleep 1
SPIN_ROOT="$ROLLUP_ROOT" "$ROLLUP_ROOT/scripts/wiki-update.sh" > "$TMP/wiki-update-second.out"
wiki_hash_after="$(shasum -a 256 "$ROLLUP_ROOT/org/wiki/workspace.md" | awk '{print $1}')"
[[ "$wiki_hash_before" == "$wiki_hash_after" ]] || { echo "semantic wiki rewrote timestamp-only output" >&2; exit 1; }
test ! -s "$TMP/wiki-update-second.out"

# Project floors keep OMP itself in SPIN-owned metadata even when the product
# path resolves elsewhere. The real code path remains explicit and exported.
FLOORBIN="$TMP/floorbin"
FLOOR_CAPTURE="$TMP/floor-omp.capture"
mkdir -p "$FLOORBIN" "$TMP/protected-project" \
  "$KIT/org/projects/protected-floor"
ln -s "$TMP/protected-project" "$KIT/projects/protected-floor"
cat > "$FLOORBIN/omp" <<'EOF'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'project=%s\n' "${SPIN_PROJECT_ROOT:-}"
  printf 'args=%s\n' "$*"
} > "$FLOOR_CAPTURE"
EOF
chmod +x "$FLOORBIN/omp"
TERM=xterm FLOOR_CAPTURE="$FLOOR_CAPTURE" SPIN_OMP_BIN="$FLOORBIN/omp" \
  SPIN_OMP_MCP_BOOTSTRAP=0 SPIN_ROOT="$KIT" \
  scripts/cmux-floor.sh protected-floor > "$TMP/protected-floor.out"
grep -Fx "cwd=$KIT/org/projects/protected-floor" "$FLOOR_CAPTURE"
grep -Fx "project=$KIT/projects/protected-floor" "$FLOOR_CAPTURE"
grep -F 'Use absolute project paths' "$FLOOR_CAPTURE"
grep -F "floor:  $KIT/org/projects/protected-floor" "$TMP/protected-floor.out"
grep -F "code:   $KIT/projects/protected-floor" "$TMP/protected-floor.out"
rm -f "$KIT/projects/protected-floor" \
  "$KIT/org/ceo/runs/floors/protected-floor.pid"
rm -rf "$KIT/org/projects/protected-floor"

: > "$TMP/cmux.calls"
PATH="$FAKEBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  bash scripts/workspace-status.sh
  spin_cmux_reconcile_managed_floors
'
grep -q 'new-workspace --name SPIN Coordinator' "$TMP/cmux.calls"
grep -q 'new-workspace --name smoke-floor' "$TMP/cmux.calls"
grep -q 'markdown open .*/org/ceo/WORKSPACE_STATUS.md' "$TMP/cmux.calls"

ASYNCBIN="$TMP/asyncbin"
mkdir -p "$ASYNCBIN" "$KIT/projects/async-app" "$KIT/org/projects/async-app"
node - "$KIT/org/OMP_HARNESS.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const harness = JSON.parse(fs.readFileSync(file, 'utf8'));
harness.projects['async-app'] = { cmux_workspace: null };
fs.writeFileSync(file, `${JSON.stringify(harness, null, 2)}\n`);
NODE
cat > "$ASYNCBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/async-cmux.calls"
if [[ "\${1:-}" == "--json" && "\${2:-}" == "list-workspaces" ]]; then
  if [[ -f "$TMP/async-workspace-created" ]]; then
    printf '%s\n' '{"workspaces":[{"ref":"workspace:77","title":"async-app","current_directory":"$KIT/org/projects/async-app"}]}'
  else
    printf '%s\n' '{"workspaces":[]}'
  fi
  exit 0
fi
case "\${1:-}" in
  new-workspace) touch "$TMP/async-workspace-created"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$ASYNCBIN/cmux"
PATH="$ASYNCBIN:$PATH" SPIN_ROOT="$KIT" SPIN_CMUX_ASYNC_CREATE_RETRIES=2 \
  SPIN_CMUX_ASYNC_CREATE_DELAY=0 bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_ensure_project_floor async-app false
' > "$TMP/async-floor.out"
grep -q '^workspace:77$' "$TMP/async-floor.out"
test "$(grep -c 'new-workspace --name async-app' "$TMP/async-cmux.calls")" -eq 1
grep -q "new-workspace --name async-app --cwd $KIT/org/projects/async-app" "$TMP/async-cmux.calls"
grep -q '"cmux_workspace": "workspace:77"' "$KIT/org/OMP_HARNESS.json"

FAILEDUPBIN="$TMP/failed-up-bin"
mkdir -p "$FAILEDUPBIN"
cat > "$FAILEDUPBIN/cmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ping" ]]; then exit 0; fi
if [[ "${1:-}" == "--json" && "${2:-}" == "list-workspaces" ]]; then
  printf '%s\n' '{"workspaces":[]}'
  exit 0
fi
exit 0
EOF
chmod +x "$FAILEDUPBIN/cmux"
if PATH="$FAILEDUPBIN:$PATH" HOME="$SMOKE_HOME" SPIN_ROOT="$KIT" \
  SPIN_DISABLE_BACKGROUND_DAEMONS=1 SPIN_OMP_MCP_BOOTSTRAP=0 \
  SPIN_CMUX_ASYNC_CREATE_RETRIES=1 SPIN_CMUX_ASYNC_CREATE_DELAY=0 \
  scripts/spin-up.sh > "$TMP/failed-spin-up.out" 2>&1; then
  echo "spin up reported success with every required workspace unavailable" >&2
  exit 1
fi
grep -q 'SPIN startup incomplete:' "$TMP/failed-spin-up.out"
if grep -q 'SPIN is up' "$TMP/failed-spin-up.out"; then
  echo "spin up printed a false success banner" >&2
  exit 1
fi

DRIFTBIN="$TMP/driftbin"
mkdir -p "$DRIFTBIN"
node - "$KIT/org/OMP_HARNESS.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const harness = JSON.parse(fs.readFileSync(file, 'utf8'));
harness.projects['example-app'].cmux_workspace = 'workspace:3';
fs.writeFileSync(file, `${JSON.stringify(harness, null, 2)}\n`);
NODE
cat > "$DRIFTBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/drift-cmux.calls"
if [[ "\${1:-}" == "--json" && "\${2:-}" == "list-workspaces" ]]; then
  cat <<JSON
{"workspaces":[{"ref":"workspace:3","title":"example-app","custom_title":"example-app","current_directory":"$KIT/projects/example-app"}]}
JSON
  exit 0
fi
case "\${1:-}" in
  tree)
    echo 'surface:3 [terminal] "π: public-demo" [selected] tty=ttys003'
    exit 0
    ;;
  read-screen) echo "omp v16.1.16 public-demo"; exit 0 ;;
  new-workspace) echo "workspace:9"; exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$DRIFTBIN/cmux"
PATH="$DRIFTBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_ensure_project_floor example-app false
' > "$TMP/drift-floor.out"
grep -q 'workspace:9' "$TMP/drift-floor.out"
grep -q 'new-workspace --name example-app' "$TMP/drift-cmux.calls"
if grep -q 'send --workspace workspace:3' "$TMP/drift-cmux.calls"; then
  echo "stale example-app floor accepted a different project's OMP tab"
  exit 1
fi
grep -q '"cmux_workspace": "workspace:9"' org/OMP_HARNESS.json

# A matching terminal title and stale OMP scrollback are not proof of a live
# floor when cmux exposes a TTY and the recorded process is dead.
STALEBIN="$TMP/stalebin"
mkdir -p "$STALEBIN" "$KIT/org/ceo/runs/floors"
node - "$KIT/org/OMP_HARNESS.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const harness = JSON.parse(fs.readFileSync(file, 'utf8'));
harness.projects['example-app'].cmux_workspace = 'workspace:15';
fs.writeFileSync(file, `${JSON.stringify(harness, null, 2)}\n`);
NODE
cat > "$KIT/org/ceo/runs/floors/example-app.pid" <<'EOF'
pid=999999
target=example-app
tty=/dev/ttys015
EOF
cat > "$STALEBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/stale-cmux.calls"
if [[ "\${1:-}" == "--json" && "\${2:-}" == "list-workspaces" ]]; then
  cat <<JSON
{"workspaces":[{"ref":"workspace:15","title":"example-app","current_directory":"$KIT/org/projects/example-app"}]}
JSON
  exit 0
fi
case "\${1:-}" in
  tree) echo "surface:15 [terminal] \"\${STALE_TITLE:-π: example-app}\" [selected] tty=ttys015"; exit 0 ;;
  read-screen) echo 'OMP agent IDLE until you type'; exit 0 ;;
  send|send-key) exit 0 ;;
  new-workspace) echo 'workspace:99'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STALEBIN/cmux"
PATH="$STALEBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_ensure_project_floor example-app false
' > "$TMP/stale-floor.out"
if ! grep -q 'workspace:15' "$TMP/stale-floor.out"; then
  echo "stale matching floor was not restarted in place" >&2
  sed -n '1,80p' "$TMP/stale-floor.out" >&2
  sed -n '1,160p' "$TMP/stale-cmux.calls" >&2
  exit 1
fi
grep -q 'send --workspace workspace:15 --surface surface:15' "$TMP/stale-cmux.calls"
grep -q 'send-key --workspace workspace:15 --surface surface:15 enter' "$TMP/stale-cmux.calls"
if grep -q 'new-workspace' "$TMP/stale-cmux.calls"; then
  echo "stale matching floor was duplicated instead of restarted in place" >&2
  exit 1
fi

# A different live floor on the restored TTY must not make a dead target marker
# look healthy, and SPIN must never type a launch command into that agent.
: > "$TMP/stale-cmux.calls"
PATH="$STALEBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_floor_process_running_on_tty() { return 0; }
  if spin_cmux_floor_active_in_workspace workspace:15 example-app; then
    echo "wrong live floor on shared TTY was accepted as example-app" >&2
    exit 1
  fi
  spin_cmux_ensure_project_floor example-app false
' > "$TMP/shared-tty-floor.out"
grep -q 'workspace:99' "$TMP/shared-tty-floor.out"
grep -q 'new-workspace --name example-app' "$TMP/stale-cmux.calls"
if grep -q 'send --workspace workspace:15' "$TMP/stale-cmux.calls"; then
  echo "SPIN typed a floor launch into another live agent on the shared TTY" >&2
  exit 1
fi

SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_project_floor_ids() { printf "%s\n" example-app; }
  spin_cmux_saved_workspace_ref() {
    [[ "$1" == ceo ]] && printf "%s\n" workspace:1 || printf "%s\n" workspace:2
  }
  spin_cmux_terminal_surface() { printf "%s\n" surface:1; }
  spin_cmux_surface_tty() { printf "%s\n" ttys001; }
  collision="$(spin_cmux_duplicate_managed_floor_ttys)"
  [[ "$collision" == $'"'"'ttys001\tceo\texample-app'"'"' ]]
'

# A live target marker on the exact TTY remains authoritative even when cmux
# renders a display-name alias instead of the registry id in the terminal title.
PATH="$STALEBIN:$PATH" SPIN_ROOT="$KIT" STALE_TITLE='π: Example Product' bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_floor_marker_running() { return 0; }
  spin_cmux_floor_marker_value() {
    [[ "$2" == tty ]] && printf "%s\n" /dev/ttys015
  }
  if spin_cmux_terminal_title_matches_target workspace:15 example-app; then
    echo "display-name alias unexpectedly matched the registry id" >&2
    exit 1
  fi
  spin_cmux_floor_active_in_workspace workspace:15 example-app
'

PATH="$STALEBIN:$PATH" SPIN_ROOT="$KIT" STALE_TITLE='Terminal' bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_floor_marker_running() { return 0; }
  spin_cmux_floor_marker_value() {
    [[ "$2" == tty ]] && printf "%s\n" /dev/ttys015
  }
  if spin_cmux_floor_active_in_workspace workspace:15 example-app; then
    echo "floor without a live OMP terminal title was accepted" >&2
    exit 1
  fi
'

RECONCILEBIN="$TMP/reconcilebin"
mkdir -p "$RECONCILEBIN"
node - "$KIT/org/OMP_HARNESS.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const harness = JSON.parse(fs.readFileSync(file, 'utf8'));
harness.workspace_ceo = harness.workspace_ceo || {};
harness.workspace_ceo.cmux_workspace = 'workspace:7';
harness.projects['example-app'].cmux_workspace = 'workspace:9';
fs.writeFileSync(file, `${JSON.stringify(harness, null, 2)}\n`);
NODE
cat > "$RECONCILEBIN/cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/reconcile-cmux.calls"
if [[ "\${1:-}" == "--json" && "\${2:-}" == "list-workspaces" ]]; then
  cat <<JSON
{"workspaces":[
  {"ref":"workspace:9","title":"example-app","current_directory":"$KIT/org/projects/example-app"},
  {"ref":"workspace:3","title":"example-app","current_directory":"$KIT/projects/example-app"},
  {"ref":"workspace:7","title":"SPIN Coordinator","current_directory":"$SMOKE_HOME"},
  {"ref":"workspace:8","title":"SPIN Coordinator","current_directory":"$SMOKE_HOME"}
]}
JSON
  exit 0
fi
case "\${1:-}" in
  tree)
    if [[ -f "$TMP/reconcile-board-visible" ]]; then
      cat <<TREE
surface:50 [terminal] "π: .omp-ceo" [selected] tty=ttys050
surface:51 [markdown] "FLOOR.md" [selected]
surface:52 [markdown] "WORKSPACE_STATUS.md" [selected]
TREE
    else
      cat <<TREE
surface:50 [terminal] "π: .omp-ceo" [selected] tty=ttys050
surface:51 [markdown] "FLOOR.md" [selected]
TREE
    fi
    ;;
  close-workspace|close-surface|markdown) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$RECONCILEBIN/cmux"
PATH="$RECONCILEBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  expected_refs="$(printf "workspace:3\nworkspace:8\n")"
  test "$(spin_cmux_stale_managed_workspace_refs)" = "$expected_refs"
  test "$(spin_cmux_prune_stale_managed_workspaces)" = "$expected_refs"
  bash scripts/workspace-status.sh
  spin_cmux_open_coordinator_board workspace:50 surface:50
'
grep -q 'close-workspace --workspace workspace:3' "$TMP/reconcile-cmux.calls"
grep -q 'close-workspace --workspace workspace:8' "$TMP/reconcile-cmux.calls"
if grep -Eq 'close-workspace --workspace workspace:(7|9)$' "$TMP/reconcile-cmux.calls"; then
  echo "canonical Coordinator or project workspace was pruned" >&2
  exit 1
fi
grep -q 'close-surface --workspace workspace:50 --surface surface:51' "$TMP/reconcile-cmux.calls"
grep -q 'markdown open .*/org/ceo/WORKSPACE_STATUS.md --workspace workspace:50 --surface surface:50 --direction right --focus false' "$TMP/reconcile-cmux.calls"
touch "$TMP/reconcile-board-visible"
: > "$TMP/reconcile-cmux.calls"
PATH="$RECONCILEBIN:$PATH" SPIN_ROOT="$KIT" bash -c '
  ROOT="$SPIN_ROOT"
  source scripts/lib/spin-runtime.sh
  source scripts/lib/cmux-floor-layout.sh
  spin_cmux_open_coordinator_board workspace:50 surface:50
'
grep -q 'close-surface --workspace workspace:50 --surface surface:51' "$TMP/reconcile-cmux.calls"
if grep -q 'markdown open' "$TMP/reconcile-cmux.calls"; then
  echo "Coordinator opened a duplicate status board when one was already visible"
  exit 1
fi

PATH="$FAKEBIN:$PATH" SPIN_ROOT="$KIT" \
  scripts/delegate.sh --id smoke-delegate example-app "make ascii art" > "$TMP/delegate.out"
grep -q 'delegated smoke-delegate to example-app' "$TMP/delegate.out"
grep -q 'delegate smoke-delegate complete:' "$TMP/cmux.calls"
grep -q 'SPIN live delegation: smoke-delegate' org/projects/example-app/WORKSPACE_HANDOFF.md
grep -q 'cd "$SPIN_ROOT" && scripts/org inbox example-app "delegate smoke-delegate complete:' org/projects/example-app/WORKSPACE_HANDOFF.md
grep -q 'ceo -> example-app: delegate smoke-delegate: make ascii art' org/ceo/runs/delegations.log

cat > "$TMP/internal-cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/internal-cmux.calls"
printf 'socket=%s\n' "\${CMUX_SOCKET_PATH:-}" >> "$TMP/internal-cmux.calls"
case "\${1:-}" in
  ping) exit 0 ;;
  version) echo "cmux internal fake 1.0"; exit 0 ;;
  tree) echo "surface:9 [terminal]"; exit 0 ;;
  new-workspace) echo "workspace:9"; exit 0 ;;
  read-screen) echo "model: sonnet-4-6"; exit 0 ;;
  send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/internal-cmux"
SPIN_CMUX_BIN="$TMP/internal-cmux" SPIN_ROOT="$KIT" \
  scripts/delegate.sh --id internal-cmux-delegate example-app "use bundled cmux" > "$TMP/internal-delegate.out"
grep -q 'delegated internal-cmux-delegate to example-app' "$TMP/internal-delegate.out"
grep -q 'delegate internal-cmux-delegate complete:' "$TMP/internal-cmux.calls"
grep -q 'SPIN live delegation: internal-cmux-delegate' org/projects/example-app/WORKSPACE_HANDOFF.md
grep -q 'cd "$SPIN_ROOT" && scripts/org inbox example-app "delegate internal-cmux-delegate complete:' org/projects/example-app/WORKSPACE_HANDOFF.md

cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "codex fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/codex.args"
cat >/dev/null
EOF
chmod +x "$FAKEBIN/codex"

BROKEN_CODEX_BIN="$TMP/broken-codex-bin"
mkdir -p "$BROKEN_CODEX_BIN"
cat > "$BROKEN_CODEX_BIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "broken codex shim" >&2
exit 127
EOF
chmod +x "$BROKEN_CODEX_BIN/codex"

PATH="$BROKEN_CODEX_BIN:$PATH" CODEX_CLI_PATH="$FAKEBIN/codex" HOME="$SMOKE_HOME" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  test \"\$(spin_resolve_codex_cli)\" = '$FAKEBIN/codex'
  probe_codex
  run_agent codex 'hello' '$TMP/codex.log'
"
grep -q '^exec --cd ' "$TMP/codex.args"
grep -q -- '--full-auto' "$TMP/codex.args"
if grep -q 'gpt-4.5-preview' "$TMP/codex.args"; then
  echo "direct Codex fallback pinned the retired gpt-4.5-preview model"
  exit 1
fi

cat > "$FAKEBIN/omp" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then echo "omp fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/omp.args"
exit 0
EOF
chmod +x "$FAKEBIN/omp"

MCP_NODE_REPL="$TMP/computer-use-fixture/node_repl"
MCP_PLUGIN_ROOT="$TMP/computer-use-fixture/plugin"
MCP_CODEX="$TMP/computer-use-fixture/codex"
MCP_FIXTURE_CONFIG="$TMP/omp-agent/mcp.json"
mkdir -p "$MCP_PLUGIN_ROOT/scripts" "$MCP_PLUGIN_ROOT/skills/computer-use" \
  "$(dirname "$MCP_FIXTURE_CONFIG")"
cat > "$MCP_NODE_REPL" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MCP_NODE_REPL"
cat > "$MCP_CODEX" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "codex fake signed lane"; exit 0; fi
printf '%s\n' "\$@" > "$TMP/computer-use-codex.args"
env | sort > "$TMP/computer-use-codex.env"
if command -v lsof >/dev/null 2>&1; then
  lsof -a -p \$\$ -d 0 -Fn > "$TMP/computer-use-codex.stdin" 2>/dev/null || true
fi
out=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--output-last-message" && \$# -ge 2 ]]; then out="\$2"; shift 2; continue; fi
  shift
done
[[ -n "\$out" ]] && printf '%s\n' 'VISIBLE_CODEX_CUA_OK SPIN - SPIN Coordinator' > "\$out"
exit 0
EOF
chmod +x "$MCP_CODEX"
: > "$MCP_PLUGIN_ROOT/scripts/computer-use-client.mjs"
: > "$MCP_PLUGIN_ROOT/skills/computer-use/SKILL.md"
cat > "$MCP_FIXTURE_CONFIG" <<'EOF'
{
  "mcpServers": {
    "keep-me": { "type": "stdio", "command": "/usr/bin/true" },
    "computer-use": { "type": "stdio", "command": "./broken-relative-client" }
  }
}
EOF
SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$MCP_FIXTURE_CONFIG" \
  node scripts/omp-mcp-bootstrap.js repair --json > "$TMP/omp-mcp-repair.json"
node - "$MCP_FIXTURE_CONFIG" "$TMP/omp-mcp-repair.json" "$MCP_CODEX" <<'NODE'
const fs = require('fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const result = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (config.mcpServers['keep-me'].command !== '/usr/bin/true') process.exit(1);
if (config.mcpServers['computer-use']) process.exit(1);
if (!config.disabledServers.includes('computer-use')) process.exit(1);
if (result.status !== 'configured' || result.route !== 'codex-delegate' || !result.changed) process.exit(1);
if (result.codexBin !== process.argv[4]) process.exit(1);
NODE
if [[ "$(uname -s)" == "Darwin" ]]; then
  mcp_config_mode="$(stat -f '%Lp' "$MCP_FIXTURE_CONFIG")"
else
  mcp_config_mode="$(stat -c '%a' "$MCP_FIXTURE_CONFIG")"
fi
test "$mcp_config_mode" = "600"
before_mcp_hash="$(shasum -a 256 "$MCP_FIXTURE_CONFIG" | awk '{print $1}')"
SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$MCP_FIXTURE_CONFIG" \
  node scripts/omp-mcp-bootstrap.js repair --quiet
after_mcp_hash="$(shasum -a 256 "$MCP_FIXTURE_CONFIG" | awk '{print $1}')"
test "$before_mcp_hash" = "$after_mcp_hash"
SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$MCP_FIXTURE_CONFIG" \
  node scripts/omp-mcp-bootstrap.js prompt > "$TMP/omp-mcp-prompt.txt"
grep -q 'Do not call OMP.*node_repl' "$TMP/omp-mcp-prompt.txt"
grep -q 'codex-computer-use.sh' "$TMP/omp-mcp-prompt.txt"
grep -q -- '--read-only' "$TMP/omp-mcp-prompt.txt"
grep -q 'action-time confirmation' "$TMP/omp-mcp-prompt.txt"
grep -q 'explicit user-authored pre-approval' "$TMP/omp-mcp-prompt.txt"
cat > "$TMP/omp-disabled-mcp.json" <<'EOF'
{ "disabledServers": ["computer-use"], "mcpServers": {} }
EOF
SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$TMP/omp-disabled-mcp.json" \
  node scripts/omp-mcp-bootstrap.js repair --json > "$TMP/omp-disabled-result.json"
node -e 'const r=require(process.argv[1]); if(r.status!=="configured"||r.route!=="codex-delegate"||r.changed) process.exit(1)' "$TMP/omp-disabled-result.json"
SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$TMP/omp-disabled-mcp.json" OPENAI_API_KEY=must-not-leak \
  CODEX_THREAD_ID=must-not-leak CMUX_SURFACE_ID=must-not-leak \
  bash scripts/codex-computer-use.sh probe > "$TMP/computer-use-probe.out"
grep -q '^VISIBLE_CODEX_CUA_OK SPIN - SPIN Coordinator$' "$TMP/computer-use-probe.out"
grep -qx 'exec' "$TMP/computer-use-codex.args"
grep -qx -- '--ephemeral' "$TMP/computer-use-codex.args"
grep -qx -- '--sandbox' "$TMP/computer-use-codex.args"
test "$(awk 'take { print; exit } $0 == "-C" { take=1 }' "$TMP/computer-use-codex.args")" = "$KIT/org/ceo"
grep -q 'Read-only scope:' "$TMP/computer-use-codex.args"
grep -q 'VISIBLE_CODEX_CUA_OK' "$TMP/computer-use-codex.args"
grep -q '^CODEX_HOME=' "$TMP/computer-use-codex.env"
if [[ "$(uname -s)" == "Darwin" ]]; then
  grep -Fx 'n/dev/null' "$TMP/computer-use-codex.stdin"
fi
if grep -Eq '^(OPENAI_API_KEY|CODEX_THREAD_ID|CMUX_SURFACE_ID)=' "$TMP/computer-use-codex.env"; then
  echo "Computer Use Codex inherited parent credentials or session context" >&2
  exit 1
fi
MCP_CUSTOM_CLIENT="$TMP/custom-computer-use"
cat > "$MCP_CUSTOM_CLIENT" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MCP_CUSTOM_CLIENT"
cat > "$TMP/omp-custom-mcp.json" <<EOF
{ "mcpServers": { "computer-use": { "command": "$MCP_CUSTOM_CLIENT", "args": ["serve"] } } }
EOF
before_custom_hash="$(shasum -a 256 "$TMP/omp-custom-mcp.json" | awk '{print $1}')"
SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$TMP/omp-custom-mcp.json" \
  node scripts/omp-mcp-bootstrap.js repair --json > "$TMP/omp-custom-result.json"
after_custom_hash="$(shasum -a 256 "$TMP/omp-custom-mcp.json" | awk '{print $1}')"
test "$before_custom_hash" = "$after_custom_hash"
node -e 'const r=require(process.argv[1]); if(r.status!=="custom"||r.changed) process.exit(1)' "$TMP/omp-custom-result.json"
cat > "$TMP/omp-custom-disabled-mcp.json" <<EOF
{ "disabledServers": ["computer-use"], "mcpServers": { "computer-use": { "command": "$MCP_CUSTOM_CLIENT", "args": ["serve"] } } }
EOF
before_custom_disabled_hash="$(shasum -a 256 "$TMP/omp-custom-disabled-mcp.json" | awk '{print $1}')"
SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$TMP/omp-custom-disabled-mcp.json" \
  node scripts/omp-mcp-bootstrap.js repair --json > "$TMP/omp-custom-disabled-result.json"
after_custom_disabled_hash="$(shasum -a 256 "$TMP/omp-custom-disabled-mcp.json" | awk '{print $1}')"
test "$before_custom_disabled_hash" = "$after_custom_disabled_hash"
node -e 'const r=require(process.argv[1]); if(r.status!=="custom-disabled"||r.changed) process.exit(1)' "$TMP/omp-custom-disabled-result.json"
HOME="$SMOKE_HOME" CODEX_HOME="$TMP/missing-codex" SPIN_NODE_REPL_BIN="$TMP/missing-node-repl" \
  SPIN_COMPUTER_USE_PLUGIN_ROOT="$TMP/missing-plugin" SPIN_OMP_MCP_CONFIG="$TMP/missing-mcp.json" \
  node scripts/omp-mcp-bootstrap.js status --json > "$TMP/omp-mcp-unavailable.json"
node -e 'const r=require(process.argv[1]); if(r.status!=="unavailable"||r.changed) process.exit(1)' "$TMP/omp-mcp-unavailable.json"
test ! -e "$TMP/missing-mcp.json"

PATH="$FAKEBIN:$PATH" HOME="$SMOKE_HOME" SPIN_OMP_CONFIG="$TMP/spin-omp.yml" \
  SPIN_CODEX_BIN="$MCP_CODEX" SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE=1 \
  SPIN_NODE_REPL_BIN="$MCP_NODE_REPL" SPIN_COMPUTER_USE_PLUGIN_ROOT="$MCP_PLUGIN_ROOT" \
  SPIN_OMP_MCP_CONFIG="$MCP_FIXTURE_CONFIG" SPIN_OMP_DEFAULT_FALLBACKS= \
  CEO_OMP_MODEL=openrouter/test-model bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent omp 'hello' '$TMP/omp.log'
"
grep -q -- '--config' "$TMP/omp.args"
grep -q -- "$TMP/spin-omp.yml" "$TMP/omp.args"
if grep -q -- '--model' "$TMP/omp.args"; then
  echo "omp run pinned --model instead of using fallback config"
  exit 1
fi
grep -q 'fallbackChains:' "$TMP/spin-omp.yml"
grep -q 'openai-codex/gpt-5-codex' "$TMP/spin-omp.yml"
grep -q 'openrouter/test-model' "$TMP/spin-omp.yml"
grep -q -- '--append-system-prompt' "$TMP/omp.args"
grep -q 'codex-computer-use.sh' "$TMP/omp.args"
if grep -q 'setupComputerUseRuntime' "$TMP/omp.args"; then
  echo "omp prompt advertised the unsupported direct node_repl Computer Use path"
  exit 1
fi

cat > "$TMP/internal-omp" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then echo "internal omp fake"; exit 0; fi
if [[ "\${1:-}" == "--version" ]]; then echo "omp/internal-fake"; exit 0; fi
if [[ "\${1:-}" == "setup" && "\${2:-}" == "--help" ]]; then echo "omp setup fake"; exit 0; fi
if [[ "\${1:-}" == "auth-broker" && "\${2:-}" == "status" && "\${3:-}" == "--json" ]]; then echo '{"ok":false,"reason":"not_configured"}'; exit 0; fi
printf '%s\n' "\$*" > "$TMP/internal-omp.args"
exit 0
EOF
chmod +x "$TMP/internal-omp"
env -u SPIN_ROOT -u OMP_ROOT CEO_ROOT="$KIT" HOME="$SMOKE_HOME" bash -c '
  set -euo pipefail
  source "$1/scripts/lib/ceo-waterfall.sh"
  test "$SPIN_ROOT" = "$1"
' _ "$KIT"
SPIN_OMP_BIN="$TMP/internal-omp" HOME="$SMOKE_HOME" SPIN_OMP_CONFIG="$TMP/internal-spin-omp.yml" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent omp 'hello' '$TMP/internal-omp.log'
"
grep -q -- '--config' "$TMP/internal-omp.args"
grep -q -- "$TMP/internal-spin-omp.yml" "$TMP/internal-omp.args"

SPIN_CMUX_BIN="$TMP/internal-cmux" SPIN_OMP_BIN="$TMP/internal-omp" SPIN_ROOT="$KIT" HOME="$SMOKE_HOME" \
  node scripts/spin-app-health.js --json > "$TMP/app-health.json" 2>"$TMP/app-health.err"
if [ ! -s "$TMP/app-health.json" ]; then
  echo "spin-app-health produced empty JSON" >&2
  sed -n '1,120p' "$TMP/app-health.err" >&2
  exit 1
fi
APP_HEALTH_JSON="$TMP/app-health.json" CMUX_EXPECTED="$TMP/internal-cmux" OMP_EXPECTED="$TMP/internal-omp" node <<'NODE'
const fs = require('fs');
const file = process.env.APP_HEALTH_JSON;
const cmux = process.env.CMUX_EXPECTED;
const omp = process.env.OMP_EXPECTED;
const raw = fs.readFileSync(file, 'utf8');
let health;
try {
  health = JSON.parse(raw);
} catch (error) {
  console.error('invalid app-health JSON:', JSON.stringify(raw.slice(0, 240)));
  throw error;
}
if (health.binaries.cmux.path !== cmux || health.binaries.cmux.status !== 'ok') process.exit(1);
if (health.binaries.omp.path !== omp || health.binaries.omp.status !== 'ok') process.exit(1);
if (health.omp.owner !== 'OMP' || health.omp.setupCommand !== 'spin omp-setup') process.exit(1);
if (health.omp.authBroker.status !== 'not_configured') process.exit(1);
if (health.summary.status === 'error') process.exit(1);
NODE
SPIN_CMUX_BIN="$TMP/internal-cmux" SPIN_OMP_BIN="$TMP/internal-omp" SPIN_ROOT="$KIT" HOME="$SMOKE_HOME" \
  scripts/spin app-health > "$TMP/app-health.out"
grep -q 'setup handoff: spin omp-setup' "$TMP/app-health.out"
SPIN_OMP_BIN="$TMP/internal-omp" SPIN_ROOT="$KIT" HOME="$SMOKE_HOME" \
  scripts/spin omp-setup --help > "$TMP/omp-setup.out"
grep -q 'omp setup fake' "$TMP/omp-setup.out"

HOME="$SMOKE_HOME" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  probe_claude(){ return 1; }
  probe_gemini(){ return 1; }
  probe_omp(){ return 0; }
  probe_ollama(){ return 0; }
  run_agent(){ echo \"\$1\" > '$TMP/provider'; return 0; }
  run_agent_resilient true '' prompt '$TMP/provider.log'
"
grep -q '^omp$' "$TMP/provider"

FAKE_CMUX_APP="$TMP/fake-cmux-app/SPIN.app"
mkdir -p "$FAKE_CMUX_APP/Contents/MacOS" "$FAKE_CMUX_APP/Contents/Resources/en.lproj"
cat > "$FAKE_CMUX_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SPIN</string>
  <key>CFBundleIdentifier</key>
  <string>dev.spin.app</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>SPIN</string>
</dict>
</plist>
EOF
cat > "$FAKE_CMUX_APP/Contents/Resources/en.lproj/Localizable.strings" <<'EOF'
"menu.app.about" = "About SPIN";
"menu.app.ghosttySettings" = "Terminal Engine Settings…";
"menu.app.openCmuxSettingsFile" = "Open SPIN Workspace Config";
"menu.quitCmux" = "Quit SPIN";
EOF
cat > "$FAKE_CMUX_APP/Contents/MacOS/SPIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_CMUX_APP/Contents/MacOS/SPIN"
FAKE_CMUX_SOURCE="$TMP/fake-cmux-source"
git init -q "$FAKE_CMUX_SOURCE"
printf '# Fake cmux source\n' > "$FAKE_CMUX_SOURCE/README.md"
git -C "$FAKE_CMUX_SOURCE" add README.md
git -C "$FAKE_CMUX_SOURCE" -c user.name=SPIN -c user.email=spin@example.invalid \
  commit -q -m "fake source fixture"
FAKE_CMUX_COMMIT="$(git -C "$FAKE_CMUX_SOURCE" rev-parse HEAD)"
printf 'modified overlay fixture\n' > "$FAKE_CMUX_SOURCE/SPIN-OVERLAY.txt"
mkdir -p "$FAKE_CMUX_SOURCE/build-spin" "$FAKE_CMUX_SOURCE/.spm-cache"
printf 'generated build output\n' > "$FAKE_CMUX_SOURCE/build-spin/generated.bin"
printf 'generated package cache\n' > "$FAKE_CMUX_SOURCE/.spm-cache/cache.bin"
mkdir -p "$TMP/fake-cmux-app/app"
cat > "$TMP/fake-cmux-app/app/release-compat.json" <<EOF
{
  "cmux": {
    "source": {
      "commit": "$FAKE_CMUX_COMMIT"
    }
  }
}
EOF

scripts/ensure-xcode.sh --check >/dev/null 2>&1 || true

SPIN_CMUX_APP_SOURCE="$FAKE_CMUX_APP" \
SPIN_CMUX_BIN_SOURCE="$TMP/internal-cmux" \
SPIN_OMP_BIN_SOURCE="$TMP/internal-omp" \
  scripts/package-macos-app.sh "$TMP/SPIN.app" >/dev/null
node - "$TMP/SPIN.app/Contents/Info.plist" <<'NODE'
const fs = require('fs');
const xml = fs.readFileSync(process.argv[2], 'utf8');
const value = key => (xml.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`)) || [])[1];
if (value('CFBundleShortVersionString') !== '4.1.0' || value('CFBundleVersion') !== '3') process.exit(1);
NODE
if [[ "$(uname -s)" == "Darwin" ]]; then
  codesign --verify --deep --strict --verbose=2 "$TMP/SPIN.app" >/dev/null
  codesign --verify --strict --verbose=2 "$TMP/SPIN.app/Contents/Resources/SPIN.app" >/dev/null
  node - "$TMP/SPIN.app/Contents/Resources/app/release-compat.json" "$FAKE_CMUX_COMMIT" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (manifest.release.channel !== 'local-dev') process.exit(1);
if (manifest.release.signing.identity !== '-') process.exit(1);
if (manifest.cmux.source.commit !== process.argv[3]) process.exit(1);
NODE
fi
printf 'smoke native addon\n' > "$TMP/SPIN.app/Contents/Resources/bin/pi_natives.smoke.node"
printf '# smoke OMP lock\n' > "$TMP/SPIN.app/Contents/Resources/app/omp-bun.lock"
node - "$TMP/SPIN.app/Contents/Resources" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [resources] = process.argv.slice(2);
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const omp = path.join(resources, 'bin', 'omp');
const native = path.join(resources, 'bin', 'pi_natives.smoke.node');
const lock = path.join(resources, 'app', 'omp-bun.lock');
const metadata = {
  package: '@oh-my-pi/pi-coding-agent',
  version: '0.0.0-smoke',
  packageSpec: '@oh-my-pi/pi-coding-agent@0.0.0-smoke',
  npm: {
    integrity: 'sha512-smoke',
    localPackSha256: hash(lock),
  },
  build: {
    lockfile: {
      path: 'agent/vendor/omp/bun.lock',
      sha256: hash(lock),
    },
  },
  outputs: [
    {
      kind: 'compiled-cli',
      path: 'vendor/bin/omp',
      sha256: hash(omp),
    },
    {
      kind: 'native-addon',
      path: 'vendor/bin/pi_natives.smoke.node',
      sha256: hash(native),
    },
  ],
};
fs.writeFileSync(path.join(resources, 'app', 'omp-vendor.json'), `${JSON.stringify(metadata, null, 2)}\n`);
NODE
node scripts/app-compatibility.js write "$TMP/SPIN.app" >/dev/null
if ! SPIN_SKIP_BINARY_EXEC_CHECK=1 SPIN_REQUIRE_BRANDED_CMUX_APP=1 SPIN_REQUIRE_VENDORED_OMP=1 \
  scripts/check-app-release.sh "$TMP/SPIN.app" > "$TMP/check-app-release.out" 2>&1; then
  sed -n '1,160p' "$TMP/check-app-release.out" >&2
  exit 1
fi
scripts/check-macos-signing-env.sh >/dev/null
if env SPIN_RELEASE_PRODUCTION=1 SPIN_CODESIGN_IDENTITY=- SPIN_APPLE_TEAM_ID= SPIN_CODESIGN_HARDENED=0 SPIN_CMUX_ENTITLEMENTS= SPIN_NOTARIZE=0 SPIN_NOTARY_PROFILE= \
  scripts/check-macos-signing-env.sh --production >/dev/null 2>&1; then
  echo "production signing preflight passed unexpectedly without credentials"
  exit 1
fi
if env SPIN_CODESIGN_IDENTITY=- SPIN_APPLE_TEAM_ID= SPIN_CODESIGN_HARDENED=0 SPIN_CMUX_ENTITLEMENTS= SPIN_NOTARIZE=0 SPIN_NOTARY_PROFILE= \
  scripts/release-macos.sh --production --skip-build --skip-vendor --app "$TMP/SPIN.app" --release-dir "$TMP/release-production" >/dev/null 2>&1; then
  echo "production release passed unexpectedly without credentials"
  exit 1
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  SPIN_SKIP_BINARY_EXEC_CHECK=1 SPIN_RELEASE_DIR="$TMP/release" scripts/package-macos-release.sh "$TMP/SPIN.app" >/dev/null
  ls "$TMP/release"/SPIN-*-macos-*.zip >/dev/null
  ls "$TMP/release"/SPIN-*-macos-*.zip.sha256 >/dev/null
  ls "$TMP/release"/SPIN-*-macos-*.manifest >/dev/null
  scripts/check-installed-app.sh "$TMP/release"/SPIN-*-macos-*.zip >/dev/null
  SPIN_SKIP_BINARY_EXEC_CHECK=1 SPIN_SKIP_RELEASE_CHECK=1 SPIN_RELEASE_FORMAT=dmg SPIN_RELEASE_DIR="$TMP/release-dmg" scripts/package-macos-release.sh "$TMP/SPIN.app" >/dev/null
  RELEASE_DMG="$(ls "$TMP/release-dmg"/SPIN-*-macos-*.dmg | head -1)"
  test -f "$RELEASE_DMG"
  test -f "$RELEASE_DMG.sha256"
  test -f "${RELEASE_DMG%.dmg}.manifest"
  scripts/check-installed-app.sh "$RELEASE_DMG" >/dev/null
  SPIN_SKIP_BINARY_EXEC_CHECK=1 scripts/release-macos.sh --skip-build --skip-vendor --app "$TMP/SPIN.app" --release-dir "$TMP/release-command" >/dev/null
  ls "$TMP/release-command"/SPIN-*-macos-*.zip >/dev/null
  ls "$TMP/release-command"/SPIN-*-macos-*.zip.sha256 >/dev/null
  ls "$TMP/release-command"/SPIN-*-macos-*.manifest >/dev/null
  RELEASE_COMMAND_ZIP="$(ls "$TMP/release-command"/SPIN-*-macos-*.zip | head -1)"
  PUBLIC_RELEASE_DIR="$TMP/public-beta-release"
  if SPIN_CMUX_SOURCE_DIR="$FAKE_CMUX_SOURCE" scripts/prepare-open-source-release.sh --artifact "$RELEASE_COMMAND_ZIP" --release-dir "$PUBLIC_RELEASE_DIR" >/dev/null 2>&1; then
    echo "open-source release accepted an artifact outside the tracked cmux pin" >&2
    exit 1
  fi
  SPIN_CMUX_COMMIT="$FAKE_CMUX_COMMIT" SPIN_CMUX_SOURCE_DIR="$FAKE_CMUX_SOURCE" \
    scripts/prepare-open-source-release.sh --artifact "$RELEASE_COMMAND_ZIP" --release-dir "$PUBLIC_RELEASE_DIR" > "$TMP/open-source-release.out"
  RELEASE_NOTES="$(ls "$PUBLIC_RELEASE_DIR"/*-release-notes.md | head -1)"
  test -f "$PUBLIC_RELEASE_DIR/$(basename "$RELEASE_COMMAND_ZIP")"
  test -f "$PUBLIC_RELEASE_DIR/$(basename "$RELEASE_COMMAND_ZIP").sha256"
  test -f "$PUBLIC_RELEASE_DIR/$(basename "${RELEASE_COMMAND_ZIP%.zip}.manifest")"
  test -f "$RELEASE_NOTES"
  RELEASE_SOURCE_ARCHIVE="$(ls "$PUBLIC_RELEASE_DIR"/*-cmux-corresponding-source-*.tar.gz | head -1)"
  test -f "$RELEASE_SOURCE_ARCHIVE.sha256"
  tar -tzf "$RELEASE_SOURCE_ARCHIVE" | grep -q '/SPIN-OVERLAY.txt$'
  tar -tzf "$RELEASE_SOURCE_ARCHIVE" | grep -q '/SPIN-CORRESPONDING-SOURCE.txt$'
  if tar -tzf "$RELEASE_SOURCE_ARCHIVE" | grep -Eq '/(build-spin|\.spm-cache)/'; then
    echo "corresponding-source archive included generated build/cache output" >&2
    exit 1
  fi
  (
    cd "$PUBLIC_RELEASE_DIR"
    shasum -a 256 -c "$(basename "$RELEASE_SOURCE_ARCHIVE").sha256"
  ) >/dev/null
  grep -q 'SPIN for Mac' "$RELEASE_NOTES"
  grep -q 'visual command center' "$RELEASE_NOTES"
  grep -q 'ad-hoc signed' "$RELEASE_NOTES"
  grep -q 'not Apple-notarized' "$RELEASE_NOTES"
  ! grep -qi 'attach these files\|maintainer checks\|open-source tester' "$RELEASE_NOTES"
  if grep -Fq "$TMP" "$RELEASE_NOTES"; then
    echo "release notes included an absolute build path" >&2
    exit 1
  fi
  grep -q 'xattr -dr com.apple.quarantine /Applications/SPIN.app' "$RELEASE_NOTES"
  grep -q 'GPL-3.0-or-later' "$RELEASE_NOTES"
  grep -q "$(basename "$RELEASE_SOURCE_ARCHIVE")" "$RELEASE_NOTES"
  grep -q "$(basename "$RELEASE_COMMAND_ZIP")" "$RELEASE_NOTES"
  grep -q "$(awk '{print $1}' "$RELEASE_COMMAND_ZIP.sha256")" "$RELEASE_NOTES"
  SPIN_SKIP_CORRESPONDING_SOURCE=1 scripts/spin app-release-notes --artifact "$RELEASE_COMMAND_ZIP" --release-dir "$TMP/public-beta-release-cli" > "$TMP/app-release-notes.out"
  ls "$TMP/public-beta-release-cli"/*-release-notes.md >/dev/null
  DMG_PUBLIC_RELEASE_DIR="$TMP/public-beta-release-dmg"
  scripts/prepare-open-source-release.sh --skip-corresponding-source --artifact "$RELEASE_DMG" --release-dir "$DMG_PUBLIC_RELEASE_DIR" > "$TMP/open-source-release-dmg.out"
  DMG_RELEASE_NOTES="$(ls "$DMG_PUBLIC_RELEASE_DIR"/*-release-notes.md | head -1)"
  test -f "$DMG_PUBLIC_RELEASE_DIR/$(basename "$RELEASE_DMG")"
  test -f "$DMG_PUBLIC_RELEASE_DIR/$(basename "$RELEASE_DMG").sha256"
  test -f "$DMG_PUBLIC_RELEASE_DIR/$(basename "${RELEASE_DMG%.dmg}.manifest")"
  grep -q 'Format: `dmg`' "$DMG_RELEASE_NOTES"
  grep -q 'hdiutil attach' "$DMG_RELEASE_NOTES"
  grep -q 'Applications shortcut and README.txt' "$DMG_RELEASE_NOTES"
  scripts/spin app-updates --check --candidate "$RELEASE_DMG" --installed-app "$TMP/SPIN.app" > "$TMP/app-updates-check-dmg.out"
  grep -q 'SPIN app updates' "$TMP/app-updates-check-dmg.out"
  grep -q 'SPIN app update plan' "$TMP/app-updates-check-dmg.out"
  SPIN_RELEASE_DIR="$TMP/no-release-artifacts" scripts/spin app-updates --installed-app "$TMP/SPIN.app" > "$TMP/app-updates-empty.out"
  grep -q 'SPIN app updates' "$TMP/app-updates-empty.out"
  grep -q 'candidate:     none' "$TMP/app-updates-empty.out"
  scripts/spin app-updates --check --candidate "$RELEASE_COMMAND_ZIP" --installed-app "$TMP/SPIN.app" > "$TMP/app-updates-check.out"
  grep -q 'SPIN app updates' "$TMP/app-updates-check.out"
  grep -q 'SPIN app update plan' "$TMP/app-updates-check.out"
  grep -q 'dry run, no app code changed' "$TMP/app-updates-check.out"
  scripts/spin app-update --dry-run --installed-app "$TMP/SPIN.app" "$RELEASE_COMMAND_ZIP" > "$TMP/app-update-plan.out"
  grep -q 'SPIN app update plan' "$TMP/app-update-plan.out"
  grep -q 'Preserved user state:' "$TMP/app-update-plan.out"
  grep -q 'org/OMP_HARNESS.json' "$TMP/app-update-plan.out"
  grep -q 'dry run, no app code changed' "$TMP/app-update-plan.out"
  scripts/spin app-update --record-rollback --installed-app "$TMP/SPIN.app" --app-home "$TMP/app-update-home" "$RELEASE_COMMAND_ZIP" > "$TMP/app-update-record.out"
  ROLLBACK_FILE="$(find "$TMP/app-update-home/updates" -type f -name 'rollback-*.json' | head -1)"
  test -f "$ROLLBACK_FILE"
  grep -q '"preservedState"' "$ROLLBACK_FILE"
  node - "$ROLLBACK_FILE" <<'NODE'
const receipt = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (!receipt.backupPath.endsWith('.spin-backup.zip') || receipt.backupPath.endsWith('.app')) process.exit(1);
NODE
  PROD_APP="$TMP/production/SPIN.app"
  mkdir -p "$TMP/production"
  if command -v ditto >/dev/null 2>&1; then ditto "$TMP/SPIN.app" "$PROD_APP"; else cp -R "$TMP/SPIN.app" "$PROD_APP"; fi
  node - "$PROD_APP/Contents/Resources/app/release-compat.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.release.channel = 'production';
fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  if scripts/spin app-update --dry-run --installed-app "$PROD_APP" "$RELEASE_COMMAND_ZIP" >/dev/null 2>&1; then
    echo "app-update allowed production channel downgrade without force"
    exit 1
  fi
  scripts/spin app-update --dry-run --force-channel --installed-app "$PROD_APP" "$RELEASE_COMMAND_ZIP" > "$TMP/app-update-force.out"
  grep -q 'production -> ad-hoc' "$TMP/app-update-force.out"
  INSTALL_APP="$TMP/install-target/SPIN.app"
  mkdir -p "$TMP/install-target"
  if command -v ditto >/dev/null 2>&1; then ditto "$TMP/SPIN.app" "$INSTALL_APP"; else cp -R "$TMP/SPIN.app" "$INSTALL_APP"; fi
  printf 'stale app marker\n' > "$INSTALL_APP/Contents/Resources/app/stale-update-marker"
  if scripts/spin app-update --install --installed-app "$INSTALL_APP" --app-home "$TMP/install-home" "$RELEASE_COMMAND_ZIP" >/dev/null 2>&1; then
    echo "app-update installed ad-hoc candidate without --allow-ad-hoc"
    exit 1
  fi
  scripts/spin app-update --install --allow-ad-hoc --installed-app "$INSTALL_APP" --app-home "$TMP/install-home" "$RELEASE_COMMAND_ZIP" > "$TMP/app-update-install.out"
  grep -q 'Mode: install complete, app-owned code replaced' "$TMP/app-update-install.out"
  test ! -e "$INSTALL_APP/Contents/Resources/app/stale-update-marker"
  codesign --verify --deep --strict --verbose=2 "$INSTALL_APP" >/dev/null
  INSTALL_ROLLBACK_FILE="$(find "$TMP/install-home/updates" -type f -name 'rollback-*.json' | head -1)"
  INSTALL_BACKUP_ARCHIVE="$(find "$TMP/install-home/updates/backups" -maxdepth 1 -type f -name 'SPIN-*.spin-backup.zip' | head -1)"
  test -f "$INSTALL_ROLLBACK_FILE"
  test -f "$INSTALL_BACKUP_ARCHIVE"
  INSTALL_BACKUP_EXTRACT="$TMP/install-backup-extract"
  mkdir -p "$INSTALL_BACKUP_EXTRACT"
  ditto -x -k "$INSTALL_BACKUP_ARCHIVE" "$INSTALL_BACKUP_EXTRACT"
  test -f "$INSTALL_BACKUP_EXTRACT/SPIN.app/Contents/Resources/app/stale-update-marker"
  grep -q '"backupPath"' "$INSTALL_ROLLBACK_FILE"
  if find "$TMP/install-home/updates/backups" -name '*.app' | grep -q .; then
    echo "app updater created a LaunchServices-indexable rollback app"
    exit 1
  fi
  node - "$INSTALL_APP/Contents/Resources/app/release-compat.json" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!manifest.release || manifest.release.channel !== 'ad-hoc') process.exit(1);
NODE
  scripts/check-app-release.sh "$INSTALL_APP" >/dev/null
  CORRUPT_CANDIDATE_APP="$TMP/corrupt-candidate/SPIN.app"
  mkdir -p "$TMP/corrupt-candidate"
  ditto "$INSTALL_APP" "$CORRUPT_CANDIDATE_APP"
  printf 'signature tamper\n' > "$CORRUPT_CANDIDATE_APP/Contents/Resources/app/signature-tamper"
  if scripts/spin app-update --install --allow-ad-hoc --installed-app "$INSTALL_APP" --app-home "$TMP/corrupt-install-home" "$CORRUPT_CANDIDATE_APP" >/dev/null 2>&1; then
    echo "app-update installed a candidate with an invalid code signature"
    exit 1
  fi
  codesign --verify --deep --strict --verbose=2 "$INSTALL_APP" >/dev/null
  UI_INSTALL_APP="$TMP/ui-install-target/SPIN.app"
  mkdir -p "$TMP/ui-install-target"
  if command -v ditto >/dev/null 2>&1; then ditto "$TMP/SPIN.app" "$UI_INSTALL_APP"; else cp -R "$TMP/SPIN.app" "$UI_INSTALL_APP"; fi
  printf 'stale app marker\n' > "$UI_INSTALL_APP/Contents/Resources/app/stale-update-marker"
  if scripts/spin app-updates --install --yes --candidate "$RELEASE_COMMAND_ZIP" --installed-app "$UI_INSTALL_APP" --app-home "$TMP/ui-install-home" >/dev/null 2>&1; then
    echo "app-updates installed ad-hoc candidate without --allow-test-builds"
    exit 1
  fi
  scripts/spin app-updates --install --yes --allow-test-builds --candidate "$RELEASE_COMMAND_ZIP" --installed-app "$UI_INSTALL_APP" --app-home "$TMP/ui-install-home" > "$TMP/app-updates-install.out"
  grep -q 'SPIN app updates' "$TMP/app-updates-install.out"
  grep -q 'Mode: install complete, app-owned code replaced' "$TMP/app-updates-install.out"
  test ! -e "$UI_INSTALL_APP/Contents/Resources/app/stale-update-marker"
  scripts/check-app-release.sh "$UI_INSTALL_APP" >/dev/null
  PROD_CANDIDATE_APP="$TMP/prod-candidate/SPIN.app"
  mkdir -p "$TMP/prod-candidate"
  if command -v ditto >/dev/null 2>&1; then ditto "$TMP/SPIN.app" "$PROD_CANDIDATE_APP"; else cp -R "$TMP/SPIN.app" "$PROD_CANDIDATE_APP"; fi
  node - "$PROD_CANDIDATE_APP/Contents/Resources/app/release-compat.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.release.channel = 'production';
manifest.release.signing = {
  identity: 'Developer ID Application: SPIN Smoke Test (SMOKE1)',
  teamId: 'SMOKE1',
  hardenedRuntime: true,
  notarizationRequested: true,
  notaryProfileConfigured: true,
};
manifest.release.productionTrust = {
  requiresDeveloperId: true,
  requiresNotarization: true,
  requiresGatekeeperAssessment: true,
};
fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  if scripts/spin app-update --install --allow-ad-hoc --installed-app "$INSTALL_APP" --app-home "$TMP/prod-install-home" "$PROD_CANDIDATE_APP" >/dev/null 2>&1; then
    echo "app-update installed production candidate without notarization support"
    exit 1
  fi
  if scripts/spin app-update --install --allow-production --installed-app "$INSTALL_APP" --app-home "$TMP/prod-trust-home" "$PROD_CANDIDATE_APP" >/dev/null 2>&1; then
    echo "app-update installed untrusted production candidate"
    exit 1
  fi
fi

env -i HOME="$SMOKE_HOME" PATH="$PATH" SPIN_APP_LAUNCH_DRY_RUN=1 scripts/spin app-launch > "$TMP/app-launch-before.out"
grep -q 'app-launch: onboarding' "$TMP/app-launch-before.out"
env -i HOME="$SMOKE_HOME" PATH="$PATH" SPIN_APP_ASSUME_OMP_CONFIGURED=1 SPIN_APP_LAUNCH_DRY_RUN=1 scripts/spin app-launch > "$TMP/app-launch-omp-ready.out"
grep -q 'app-launch: spin up' "$TMP/app-launch-omp-ready.out"

cat > "$TMP/spin-up-launch-cmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/spin-up-launch-cmux.calls"
case "\${1:-}" in
  ping) exit 0 ;;
  version) echo "cmux fake spin-up launch"; exit 0 ;;
  --json)
    if [[ "\${2:-}" == "list-workspaces" ]]; then echo '{"workspaces":[]}'; exit 0; fi
    exit 0
    ;;
  new-workspace) echo "workspace:88"; exit 0 ;;
  list-workspaces|tree|sidebar|markdown|send|send-key) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/spin-up-launch-cmux"
env -i HOME="$TMP/spin-up-launch-home" PATH="$PATH" SPIN_ROOT="$KIT" SPIN_APP_ASSUME_OMP_CONFIGURED=1 SPIN_DISABLE_BACKGROUND_DAEMONS=1 SPIN_TEST_ASSUME_FLOORS_READY=1 SPIN_CMUX_BIN="$TMP/spin-up-launch-cmux" \
  scripts/spin app-launch > "$TMP/spin-up-launch.out"
grep -q 'SPIN orchestrator floor open' "$TMP/spin-up-launch.out"
grep -q 'background driver disabled for this run' "$TMP/spin-up-launch.out"
grep -q 'new-workspace --name SPIN Coordinator' "$TMP/spin-up-launch-cmux.calls"
grep -q 'cmux-floor.sh' "$TMP/spin-up-launch-cmux.calls"
grep -q "'ceo'" "$TMP/spin-up-launch-cmux.calls"

touch org/.spin-onboarded
env -i HOME="$SMOKE_HOME" PATH="$PATH" SPIN_APP_LAUNCH_DRY_RUN=1 scripts/spin app-launch > "$TMP/app-launch-after.out"
grep -q 'app-launch: spin up' "$TMP/app-launch-after.out"
rm -f org/.spin-onboarded

env -i HOME="$TMP/app-home" PATH="$PATH" SPIN_APP_HOME="$TMP/app-home" SPIN_APP_NO_LOG_REDIRECT=1 "$TMP/SPIN.app/Contents/MacOS/SPIN" > "$TMP/app-launch.out"
test -x "$TMP/app-home/runtime/scripts/spin"
grep -q 'SPIN onboarding opened in cmux' "$TMP/app-launch.out"
grep -q 'new-workspace --name SPIN Onboarding' "$TMP/internal-cmux.calls"
grep -q "socket=$TMP/app-home/.local/state/cmux/spin.sock" "$TMP/internal-cmux.calls"

echo "smoke ok"
