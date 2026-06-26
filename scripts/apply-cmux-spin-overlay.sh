#!/usr/bin/env bash
# Apply SPIN branding/runtime overlays to a cmux checkout.
#
# This is the practical fork path: keep upstream cmux updateable, then apply a
# small, reviewable SPIN patch set for product identity and bundled defaults.
set -euo pipefail

ROOT="${SPIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CMUX_DIR="${1:-$ROOT/app/upstream/cmux}"
CMUX_REPO="${SPIN_CMUX_REPO:-https://github.com/manaflow-ai/cmux.git}"
CMUX_REF="${SPIN_CMUX_REF:-main}"
CMUX_ARCHIVE_URL="${SPIN_CMUX_ARCHIVE_URL:-https://github.com/manaflow-ai/cmux/archive/refs/heads/${CMUX_REF}.tar.gz}"
CMUX_FETCH_MODE="${SPIN_CMUX_FETCH_MODE:-archive}"

valid_cmux_checkout() {
  [ -f "$CMUX_DIR/cmux.xcodeproj/project.pbxproj" ] &&
  [ -f "$CMUX_DIR/Resources/Info.plist" ] &&
  [ -f "$CMUX_DIR/Sources/cmuxApp.swift" ] &&
  [ -f "$CMUX_DIR/CLI/cmux.swift" ]
}

fetch_cmux_archive() {
  local tmp
  tmp="$(mktemp -d)"
  echo "git clone failed; fetching cmux source archive -> $CMUX_DIR"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail "$CMUX_ARCHIVE_URL" | tar -xz -C "$tmp" --strip-components=1
  else
    python3 - "$CMUX_ARCHIVE_URL" "$tmp" <<'PY'
import sys, tarfile, urllib.request
url, dst = sys.argv[1], sys.argv[2]
archive, _ = urllib.request.urlretrieve(url)
with tarfile.open(archive, "r:gz") as tf:
    root = tf.getmembers()[0].name.split("/")[0] + "/"
    for member in tf.getmembers():
        if not member.name.startswith(root) or member.name == root:
            continue
        member.name = member.name[len(root):]
        tf.extract(member, dst)
PY
  fi
  rm -rf "$CMUX_DIR"
  mkdir -p "$(dirname "$CMUX_DIR")"
  mv "$tmp" "$CMUX_DIR"
}

github_submodule_sha() {
  local path="$1" tmp commit tree
  if [ -d "$CMUX_DIR/.git" ]; then
    git -C "$CMUX_DIR" ls-tree HEAD "$path" 2>/dev/null | awk '{print $3; exit}'
    return
  fi
  tmp="$(mktemp -d)"
  curl -fsSL "https://api.github.com/repos/manaflow-ai/cmux/commits/$CMUX_REF" -o "$tmp/commit.json"
  commit="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sha)' "$tmp/commit.json")"
  curl -fsSL "https://api.github.com/repos/manaflow-ai/cmux/git/trees/$commit?recursive=1" -o "$tmp/tree.json"
  node - "$tmp/tree.json" "$path" <<'NODE'
const fs = require('fs');
const [file, wanted] = process.argv.slice(2);
const tree = JSON.parse(fs.readFileSync(file, 'utf8')).tree || [];
const item = tree.find(entry => entry.path === wanted);
if (item && item.sha) console.log(item.sha);
NODE
  rm -rf "$tmp"
}

fetch_archive_into() {
  local url="$1" dst="$2" tmp
  tmp="$(mktemp -d)"
  curl -L --fail "$url" | tar -xz -C "$tmp" --strip-components=1
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  mv "$tmp" "$dst"
}

hydrate_cmux_build_inputs() {
  local bonsplit_sha ghostty_sha
  if [ ! -f "$CMUX_DIR/vendor/bonsplit/Package.swift" ]; then
    bonsplit_sha="$(github_submodule_sha vendor/bonsplit)"
    [ -n "$bonsplit_sha" ] || {
      echo "could not resolve cmux vendor/bonsplit submodule SHA" >&2
      exit 1
    }
    echo "fetching bonsplit submodule archive $bonsplit_sha"
    fetch_archive_into "https://github.com/manaflow-ai/bonsplit/archive/$bonsplit_sha.tar.gz" "$CMUX_DIR/vendor/bonsplit"
  fi

  if [ ! -d "$CMUX_DIR/GhosttyKit.xcframework" ]; then
    ghostty_sha="$(github_submodule_sha ghostty)"
    [ -n "$ghostty_sha" ] || {
      echo "could not resolve cmux ghostty submodule SHA" >&2
      exit 1
    }
    echo "fetching prebuilt GhosttyKit for ghostty $ghostty_sha"
    (cd "$CMUX_DIR" && GHOSTTY_SHA="$ghostty_sha" scripts/download-prebuilt-ghosttykit.sh)
  fi
}

clone_cmux() {
  if [ -d "$CMUX_DIR" ] && ! valid_cmux_checkout; then
    echo "removing incomplete cmux checkout: $CMUX_DIR"
    rm -rf "$CMUX_DIR"
  fi

  if [ -d "$CMUX_DIR" ] && valid_cmux_checkout && [ ! -d "$CMUX_DIR/.git" ]; then
    echo "using existing cmux source archive: $CMUX_DIR"
    return
  fi

  if [ -d "$CMUX_DIR/.git" ] && valid_cmux_checkout; then
    echo "using existing cmux checkout: $CMUX_DIR"
    if [ "${SPIN_CMUX_OVERLAY_NO_FETCH:-}" = "1" ]; then
      echo "skipping fetch because SPIN_CMUX_OVERLAY_NO_FETCH=1"
      return
    fi
    git -C "$CMUX_DIR" fetch --depth=1 origin "$CMUX_REF"
    git -C "$CMUX_DIR" checkout FETCH_HEAD
    return
  fi
  rm -rf "$CMUX_DIR"
  mkdir -p "$(dirname "$CMUX_DIR")"
  if [ "$CMUX_FETCH_MODE" = "archive" ]; then
    fetch_cmux_archive
    return
  fi
  echo "shallow-cloning cmux $CMUX_REF -> $CMUX_DIR"
  if ! git -c http.version=HTTP/1.1 clone \
      --depth=1 --filter=blob:none --single-branch --branch "$CMUX_REF" \
      "$CMUX_REPO" "$CMUX_DIR"; then
    fetch_cmux_archive
  fi
}

require_file() {
  [ -f "$CMUX_DIR/$1" ] || {
    echo "cmux checkout missing expected file: $1" >&2
    exit 1
  }
}

replace_text() {
  local file="$1" from="$2" to="$3"
  FROM="$from" TO="$to" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$CMUX_DIR/$file"
}

clone_cmux
hydrate_cmux_build_inputs

require_file cmux.xcodeproj/project.pbxproj
require_file Resources/Info.plist
require_file Sources/cmuxApp.swift
require_file CLI/cmux.swift
require_file Packages/macOS/CmuxTerminal/Package.swift
require_file Packages/iOS/CmuxMobileTerminal/Package.swift

echo "patching cmux Xcode identity"
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app;' 'PRODUCT_BUNDLE_IDENTIFIER = dev.spin.app;'
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.debug;' 'PRODUCT_BUNDLE_IDENTIFIER = dev.spin.app.debug;'
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.docktileplugin;' 'PRODUCT_BUNDLE_IDENTIFIER = dev.spin.app.docktileplugin;'
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_BUNDLE_IDENTIFIER = com.cmuxterm.app.docktileplugin.debug;' 'PRODUCT_BUNDLE_IDENTIFIER = dev.spin.app.docktileplugin.debug;'
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_NAME = cmux;' 'PRODUCT_NAME = SPIN;'
replace_text cmux.xcodeproj/project.pbxproj 'PRODUCT_NAME = "cmux DEV";' 'PRODUCT_NAME = "SPIN DEV";'
replace_text cmux.xcodeproj/project.pbxproj 'CMUX_AUTH_CALLBACK_SCHEME = cmux;' 'CMUX_AUTH_CALLBACK_SCHEME = spin;'
replace_text cmux.xcodeproj/project.pbxproj 'CMUX_AUTH_CALLBACK_SCHEME = "cmux-dev";' 'CMUX_AUTH_CALLBACK_SCHEME = "spin-dev";'
replace_text cmux.xcodeproj/project.pbxproj 'CMUX_SIDEBAR_EXTENSION_POINT_ID = com.cmuxterm.app.cmux.sidebar;' 'CMUX_SIDEBAR_EXTENSION_POINT_ID = dev.spin.app.cmux.sidebar;'
replace_text cmux.xcodeproj/project.pbxproj 'path = cmux.app;' 'path = SPIN.app;'

echo "patching Info.plist user-facing strings"
replace_text Resources/Info.plist 'A program running within cmux would like to use your microphone.' 'A program running within SPIN would like to use your microphone.'
replace_text Resources/Info.plist 'A program running within cmux would like to use your camera.' 'A program running within SPIN would like to use your camera.'
replace_text Resources/Info.plist 'A program running within cmux would like to use Bluetooth to discover passkeys and security keys.' 'A program running within SPIN would like to use Bluetooth to discover passkeys and security keys.'
replace_text Resources/Info.plist 'A program running within cmux would like to use AppleScript.' 'A program running within SPIN would like to use AppleScript.'
replace_text Resources/Info.plist 'cmux Sidebar Tab Reorder' 'SPIN Sidebar Tab Reorder'
replace_text Resources/Info.plist 'cmux File Preview Transfer' 'SPIN File Preview Transfer'
replace_text Resources/Info.plist 'https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml' 'https://github.com/claudiaclawdbot/spin/releases/latest/download/appcast.xml'
replace_text Resources/Info.plist 'com.cmux.sidebar-tab-reorder' 'dev.spin.sidebar-tab-reorder'
replace_text Resources/Info.plist 'com.cmux.filepreview.transfer' 'dev.spin.filepreview.transfer'

echo "patching bundled CLI welcome copy"
replace_text CLI/cmux.swift '\(c1)c\(c2)m\(c3)u\(c7)x\(reset)' '\(c1)S\(c2)P\(c3)I\(c7)N\(reset)'
replace_text CLI/cmux.swift 'the open source terminal' 'the SPIN workspace'
replace_text CLI/cmux.swift 'built for coding agents' 'for OMP project agents'
replace_text CLI/cmux.swift 'https://cmux.com/docs' 'https://github.com/claudiaclawdbot/spin#readme'
replace_text CLI/cmux.swift 'https://github.com/manaflow-ai/cmux (please leave a star ⭐)' 'https://github.com/claudiaclawdbot/spin'
replace_text CLI/cmux.swift 'founders@manaflow.com' 'SPIN owns orchestration; cmux powers the workspace'
replace_text CLI/cmux.swift 'Run \(reset)\(bold)cmux --help\(reset)\(subdued) for all commands.' 'Run \(reset)\(bold)spin help\(reset)\(subdued) for SPIN commands.'
replace_text CLI/cmux.swift 'Run \(reset)\(bold)cmux shortcuts\(reset)\(subdued) to edit shortcuts.' 'Run \(reset)\(bold)spin app-health\(reset)\(subdued) to verify the bundled runtime.'
replace_text CLI/cmux.swift 'Run \(reset)\(bold)cmux feedback\(reset)\(subdued) to report a bug.' 'Run \(reset)\(bold)spin up\(reset)\(subdued) to open the Coordinator.'

echo "patching app-build SwiftPM target collisions"
replace_text Packages/macOS/CmuxTerminal/Package.swift '"GhosttyRuntimeTestStubs"' '"CmuxTerminalGhosttyRuntimeTestStubs"'
replace_text Packages/iOS/CmuxMobileTerminal/Package.swift '"GhosttyKit"' '"CmuxMobileGhosttyKit"'

echo "installing SPIN default cmux config assets"
mkdir -p "$CMUX_DIR/Resources/spin"
cp "$ROOT/app/cmux/config/cmux.json" "$CMUX_DIR/Resources/spin/cmux.json"
cp "$ROOT/app/cmux/config/dock.json" "$CMUX_DIR/Resources/spin/dock.json"
cp "$ROOT/app/cmux/sidebars/spin-navigator.swift" "$CMUX_DIR/Resources/spin/spin-navigator.swift"
cp "$ROOT/assets/branding/spin-icon.svg" "$CMUX_DIR/Resources/spin/spin-icon.svg"
cp "$ROOT/licenses/THIRD_PARTY_NOTICES.md" "$CMUX_DIR/Resources/spin/THIRD_PARTY_NOTICES.md"

SPIN_TEAM_ID="${SPIN_APPLE_TEAM_ID:-TEAMID}"
cat > "$CMUX_DIR/Resources/spin.release.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>${SPIN_TEAM_ID}.dev.spin.app</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${SPIN_TEAM_ID}</string>
	<key>com.apple.developer.web-browser.public-key-credential</key>
	<true/>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
EOF

cat > "$CMUX_DIR/Resources/bin/spin-open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${SPIN_ROOT:-$HOME/spin}"
if [ -x "$ROOT/scripts/spin" ]; then
  exec "$ROOT/scripts/spin" up
fi
echo "SPIN runtime not found. Set SPIN_ROOT or install SPIN first." >&2
exit 1
EOF
chmod +x "$CMUX_DIR/Resources/bin/spin-open"

cat > "$CMUX_DIR/SPIN_FORK_NOTES.md" <<'EOF'
# SPIN cmux Fork Notes

This checkout has had the SPIN overlay applied.

Patched identity:

- App product name: SPIN
- Release bundle id: dev.spin.app
- Debug bundle id: dev.spin.app.debug
- Auth callback scheme: spin
- Sidebar extension point: dev.spin.app.cmux.sidebar

Bundled SPIN assets:

- Resources/spin/cmux.json
- Resources/spin/dock.json
- Resources/spin/spin-navigator.swift
- Resources/spin/spin-icon.svg
- Resources/spin/THIRD_PARTY_NOTICES.md
- Resources/spin.release.entitlements

Build:

```bash
xcodebuild -workspace cmux.xcworkspace -scheme cmux -configuration Release -derivedDataPath build
```

The CLI target still produces a cmux-compatible socket client. SPIN bundles that
binary at `SPIN.app/Contents/Resources/bin/cmux` so existing automation and the
SPIN runtime keep working.

For signed releases, replace TEAMID in `Resources/spin.release.entitlements` or
run the overlay with `SPIN_APPLE_TEAM_ID=<team-id>`.
EOF

echo "SPIN overlay applied to $CMUX_DIR"
echo "Next: cd '$CMUX_DIR' && xcodebuild -workspace cmux.xcworkspace -scheme cmux -configuration Release -derivedDataPath build"
