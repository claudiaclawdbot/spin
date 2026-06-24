#!/usr/bin/env bash
# ensure-xcode.sh — make full Xcode available for source-building the SPIN cmux app.
set -euo pipefail

MODE="${1:-setup}"
XCODE_APP="${SPIN_XCODE_APP:-/Applications/Xcode.app}"
DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
APP_STORE_URL="macappstore://itunes.apple.com/app/id497799835"

have_full_xcode() {
  [ -d "$DEVELOPER_DIR" ] || return 1
  DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -version >/dev/null 2>&1
}

selected_developer_dir() {
  xcode-select -p 2>/dev/null || true
}

selected_full_xcode() {
  [ "$(selected_developer_dir)" = "$DEVELOPER_DIR" ]
}

status() {
  echo "Xcode app: $XCODE_APP"
  echo "selected developer dir: $(selected_developer_dir || true)"
  if have_full_xcode; then
    echo "full Xcode: ready"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -version
  else
    echo "full Xcode: missing or not runnable"
  fi
}

install_xcode() {
  if have_full_xcode; then
    return 0
  fi

  echo "Full Xcode is not installed at $XCODE_APP."
  if ! command -v mas >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
    echo "Installing mas so Xcode can be requested from the Mac App Store..."
    brew install mas
  fi

  if command -v mas >/dev/null 2>&1; then
    echo "Requesting Xcode from the Mac App Store..."
    if mas install 497799835; then
      return 0
    fi
    echo "mas could not install Xcode. The App Store may need sign-in or approval."
  fi

  if command -v open >/dev/null 2>&1; then
    echo "Opening the Xcode App Store page. Install Xcode, then rerun this script."
    open "$APP_STORE_URL" >/dev/null 2>&1 || true
  fi
  return 2
}

select_xcode() {
  have_full_xcode || return 1
  if ! selected_full_xcode; then
    echo "Selecting $DEVELOPER_DIR..."
    sudo xcode-select -s "$DEVELOPER_DIR"
  fi
}

finish_first_launch() {
  echo "Accepting Xcode license and running first-launch setup if needed..."
  sudo xcodebuild -license accept >/dev/null 2>&1 || true
  sudo xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
}

case "$MODE" in
  --check|check)
    status
    have_full_xcode && selected_full_xcode
    ;;
  setup|"")
    install_xcode
    select_xcode
    finish_first_launch
    status
    have_full_xcode && selected_full_xcode
    ;;
  *)
    echo "usage: scripts/ensure-xcode.sh [--check]" >&2
    exit 2
    ;;
esac
