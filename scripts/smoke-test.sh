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
      scripts/spin-web.js scripts/spin-app-health.js scripts/app-compatibility.js scripts/spin-app-update.js scripts/spin-app-updates.js \
      scripts/package-macos-app.sh scripts/package-macos-release.sh scripts/release-macos.sh scripts/prepare-open-source-release.sh scripts/check-installed-app.sh scripts/check-macos-signing-env.sh scripts/vendor-app-deps.sh scripts/check-app-release.sh scripts/build-app-icon.sh scripts/apply-cmux-spin-overlay.sh \
      scripts/ensure-xcode.sh scripts/build-cmux-spin.sh scripts/build-app-proof.sh \
      docs/MACOS_TESTER_INSTALL.md docs/PUBLIC_BETA_READINESS.md docs/assets \
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

for f in scripts/*.sh scripts/lib/*.sh scripts/spin install.sh spin-bootstrap.sh; do
  bash -n "$f"
done
node --check scripts/org >/dev/null
node --check scripts/ceo-dashboard.js >/dev/null
node --check scripts/spin-web.js >/dev/null
node --check scripts/spin-app-health.js >/dev/null
node --check scripts/app-compatibility.js >/dev/null
node --check scripts/spin-app-update.js >/dev/null
node --check scripts/spin-app-updates.js >/dev/null
node --check scripts/lib/spin-runtime.js >/dev/null
node --check scripts/lib/human-queue-summary.js >/dev/null
node -e 'JSON.parse(require("fs").readFileSync("app/spin-app.json","utf8")); JSON.parse(require("fs").readFileSync("app/cmux/config/cmux.json","utf8")); JSON.parse(require("fs").readFileSync("app/cmux/config/dock.json","utf8"));'
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
grep -q 'open-source-tester-notes.md' .github/workflows/macos-app.yml
grep -q 'SPIN_RELEASE_FORMAT=dmg scripts/release-macos.sh' .github/workflows/macos-app.yml
grep -q 'dist/release/\*.dmg' .github/workflows/macos-app.yml
grep -q 'actions/workflows/macos-app.yml/badge.svg' README.md
grep -q 'A local app for running a small AI software org' README.md
grep -q 'SPIN.app is the main product' README.md
grep -q 'Download SPIN.app for Mac' README.md
grep -q 'Source / CLI Setup' README.md
grep -q 'v4.1.0-beta.1' README.md
grep -q 'PUBLIC_BETA_READINESS.md' README.md
grep -q 'docs/MACOS_TESTER_INSTALL.md' README.md
grep -q 'docs/assets/spin-public-beta-demo.gif' README.md
test -s docs/assets/spin-public-beta-demo.gif
test -s docs/assets/spin-public-beta-demo.mp4
grep -q 'id="app"' docs/index.html
grep -q 'SPIN.app for Mac' docs/index.html
grep -q 'main Mac experience' docs/index.html
grep -q 'Source / CLI install' docs/index.html
grep -q 'v4.1.0-beta.1' docs/index.html
grep -q 'MACOS_TESTER_INSTALL.md' docs/index.html
grep -q 'PUBLIC_BETA_READINESS.md' docs/index.html
grep -q 'Run a small AI software org from one local app' docs/index.html
grep -q 'assets/spin-public-beta-demo.gif' docs/index.html
grep -q 'SPIN.app macOS Beta Install Guide' docs/MACOS_TESTER_INSTALL.md
grep -q 'DMG opens and shows `SPIN.app`, `Applications`, and `README.txt`' docs/MACOS_TESTER_INSTALL.md
test -f docs/PUBLIC_BETA_READINESS.md
grep -q 'Five-Minute Demo Script' docs/PUBLIC_BETA_READINESS.md
grep -q 'What Is Still Beta' docs/PUBLIC_BETA_READINESS.md
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

scripts/org queue-job example-app scout "inspect smoke path; quoted ' value" --id smoke-scout >/dev/null
scripts/org update-job smoke-scout --description "inspect updated smoke path" --max-runtime 90 >/dev/null
if scripts/org queue-job example-app scout "bad id path" --id '../bad' >/dev/null 2>&1; then
  echo "bad job id accepted"
  exit 1
fi
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  if (!q.jobs.some(j => j.id === "smoke-scout" && j.status === "queued" && j.description === "inspect updated smoke path" && j.max_runtime_seconds === 90)) process.exit(1);
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
scripts/omp-supervisor-once.sh >/dev/null
grep -q "description=inspect updated smoke path" "$TMP/project-agent.env"
node -e '
  const q = JSON.parse(require("fs").readFileSync("org/AGENT_QUEUE.json", "utf8"));
  const j = q.jobs.find(j => j.id === "smoke-scout");
  if (!j || j.status !== "completed") process.exit(1);
'

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

PATH="$FAKEBIN:$PATH" SPIN_ROOT="$KIT" \
  scripts/spin-new-project.sh smoke-floor "Smoke-test two-pane floor" > "$TMP/new-project.out"
grep -q 'Smoke-test two-pane floor' org/projects/smoke-floor/FLOOR.md
grep -q 'new-workspace --name smoke-floor' "$TMP/cmux.calls"
grep -q 'markdown open .*/org/projects/smoke-floor/FLOOR.md --workspace workspace:7 --surface surface:7 --direction right --focus false' "$TMP/cmux.calls"

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

PATH="$FAKEBIN:$PATH" HOME="$SMOKE_HOME" bash -c "
  set -euo pipefail
  source '$KIT/scripts/lib/ceo-waterfall.sh'
  run_agent codex 'hello' '$TMP/codex.log'
"
grep -q '^exec --cd ' "$TMP/codex.args"

cat > "$FAKEBIN/omp" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then echo "omp fake"; exit 0; fi
printf '%s\n' "\$*" > "$TMP/omp.args"
exit 0
EOF
chmod +x "$FAKEBIN/omp"

PATH="$FAKEBIN:$PATH" HOME="$SMOKE_HOME" SPIN_OMP_CONFIG="$TMP/spin-omp.yml" SPIN_OMP_DEFAULT_FALLBACKS= CEO_OMP_MODEL=openrouter/test-model bash -c "
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

scripts/ensure-xcode.sh --check >/dev/null 2>&1 || true

SPIN_CMUX_APP_SOURCE="$FAKE_CMUX_APP" \
SPIN_CMUX_BIN_SOURCE="$TMP/internal-cmux" \
SPIN_OMP_BIN_SOURCE="$TMP/internal-omp" \
  scripts/package-macos-app.sh "$TMP/SPIN.app" >/dev/null
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
  TESTER_RELEASE_DIR="$TMP/open-source-tester-release"
  scripts/prepare-open-source-release.sh --artifact "$RELEASE_COMMAND_ZIP" --release-dir "$TESTER_RELEASE_DIR" > "$TMP/open-source-release.out"
  TESTER_NOTES="$(ls "$TESTER_RELEASE_DIR"/*-open-source-tester-notes.md | head -1)"
  test -f "$TESTER_RELEASE_DIR/$(basename "$RELEASE_COMMAND_ZIP")"
  test -f "$TESTER_RELEASE_DIR/$(basename "$RELEASE_COMMAND_ZIP").sha256"
  test -f "$TESTER_RELEASE_DIR/$(basename "${RELEASE_COMMAND_ZIP%.zip}.manifest")"
  test -f "$TESTER_NOTES"
  grep -q 'Open-Source Tester Release' "$TESTER_NOTES"
  grep -q 'ad-hoc signed' "$TESTER_NOTES"
  grep -q 'not notarized' "$TESTER_NOTES"
  grep -q 'xattr -dr com.apple.quarantine /Applications/SPIN.app' "$TESTER_NOTES"
  grep -q 'GPL-compatible' "$TESTER_NOTES"
  grep -q 'cmux-derived UI engine is GPL-3.0-or-later' "$TESTER_NOTES"
  grep -q "$(basename "$RELEASE_COMMAND_ZIP")" "$TESTER_NOTES"
  grep -q "$(awk '{print $1}' "$RELEASE_COMMAND_ZIP.sha256")" "$TESTER_NOTES"
  scripts/spin app-release-notes --artifact "$RELEASE_COMMAND_ZIP" --release-dir "$TMP/open-source-tester-release-cli" > "$TMP/app-release-notes.out"
  ls "$TMP/open-source-tester-release-cli"/*-open-source-tester-notes.md >/dev/null
  DMG_TESTER_RELEASE_DIR="$TMP/open-source-tester-release-dmg"
  scripts/prepare-open-source-release.sh --artifact "$RELEASE_DMG" --release-dir "$DMG_TESTER_RELEASE_DIR" > "$TMP/open-source-release-dmg.out"
  DMG_TESTER_NOTES="$(ls "$DMG_TESTER_RELEASE_DIR"/*-open-source-tester-notes.md | head -1)"
  test -f "$DMG_TESTER_RELEASE_DIR/$(basename "$RELEASE_DMG")"
  test -f "$DMG_TESTER_RELEASE_DIR/$(basename "$RELEASE_DMG").sha256"
  test -f "$DMG_TESTER_RELEASE_DIR/$(basename "${RELEASE_DMG%.dmg}.manifest")"
  grep -q 'Format: `dmg`' "$DMG_TESTER_NOTES"
  grep -q 'hdiutil attach' "$DMG_TESTER_NOTES"
  grep -q 'Applications shortcut and README.txt' "$DMG_TESTER_NOTES"
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
  INSTALL_ROLLBACK_FILE="$(find "$TMP/install-home/updates" -type f -name 'rollback-*.json' | head -1)"
  INSTALL_BACKUP_APP="$(find "$TMP/install-home/updates/backups" -maxdepth 1 -type d -name 'SPIN-*.app' | head -1)"
  test -f "$INSTALL_ROLLBACK_FILE"
  test -d "$INSTALL_BACKUP_APP"
  test -f "$INSTALL_BACKUP_APP/Contents/Resources/app/stale-update-marker"
  grep -q '"backupPath"' "$INSTALL_ROLLBACK_FILE"
  node - "$INSTALL_APP/Contents/Resources/app/release-compat.json" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!manifest.release || manifest.release.channel !== 'ad-hoc') process.exit(1);
NODE
  scripts/check-app-release.sh "$INSTALL_APP" >/dev/null
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
env -i HOME="$TMP/spin-up-launch-home" PATH="$PATH" SPIN_ROOT="$KIT" SPIN_APP_ASSUME_OMP_CONFIGURED=1 SPIN_CMUX_BIN="$TMP/spin-up-launch-cmux" \
  scripts/spin app-launch > "$TMP/spin-up-launch.out"
grep -q 'SPIN orchestrator floor open' "$TMP/spin-up-launch.out"
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
