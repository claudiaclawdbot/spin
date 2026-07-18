#!/usr/bin/env bash
# spin-service.sh — install/remove the supervised SPIN control-plane services.
#
#   spin service install     # install + start driver, status roll-up, and wiki watch
#   spin service repair      # reconcile an older/partial service installation
#   spin service uninstall   # stop + remove every SPIN service
#   spin service status      # verify every required service is running
#   spin service path        # show the stable PATH saved by the services
#
# The driver pauses cleanly while org/ceo/runs/STOP exists. The lightweight
# status and wiki services remain alive so the visible control plane keeps
# reporting the pause instead of leaving a stale green board behind.
set -uo pipefail

ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
ACTION="${1:-status}"
OS="${SPIN_SERVICE_OS:-$(uname -s)}"
DRY_RUN="${SPIN_SERVICE_DRY_RUN:-0}"
RUN_DIR="$ROOT/org/ceo/runs"
STOPFILE="$RUN_DIR/STOP"

DRIVER_LABEL="com.spin.driver"
STATUS_LABEL="com.spin.status-watch"
WIKI_LABEL="com.spin.wiki-watch"

DRIVER_SCRIPT="$ROOT/scripts/workspace-ceo-tick.sh"
STATUS_SCRIPT="$ROOT/scripts/workspace-status-watch.sh"
WIKI_SCRIPT="$ROOT/scripts/wiki-watch.sh"

DRIVER_LOG="$RUN_DIR/workspace-ceo-driver.log"
STATUS_LOG="$ROOT/logs/status-watch.log"
WIKI_LOG="$ROOT/logs/wiki-watch.log"

source "$ROOT/scripts/lib/spin-runtime.sh"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_d=$'\e[2m'; c_o=$'\e[0m'

stable_service_path(){
  local candidate result="" seen=":"
  local -a candidates=()

  IFS=':' read -r -a candidates <<< "${PATH:-}"
  candidates+=(
    "$HOME/.local/bin"
    "$HOME/bin"
    "$HOME/.bun/bin"
    "/Applications/SPIN.app/Contents/Resources/bin"
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && "$candidate" == /* && -d "$candidate" ]] || continue
    case "$candidate" in
      "$HOME/.local/bin"|"$HOME/bin"|"$HOME/.bun/bin")
        ;;
      /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/run/*|/private/var/run/*|*cmux-cli-shims*|"$HOME/.codex/tmp/"*|"$HOME/.cache/codex-runtimes/"*)
        continue
        ;;
    esac
    [[ "$seen" == *":$candidate:"* ]] && continue
    result="${result:+$result:}$candidate"
    seen="$seen$candidate:"
  done

  printf '%s' "$result"
}

xml_escape(){
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

stop_managed_process(){
  local lock="$1" expected="$2"
  spin_stop_locked_process "$lock" "$expected" || true
}

stop_all_managed_processes(){
  stop_managed_process "$RUN_DIR/.workspace-ceo-tick.lock" "$DRIVER_SCRIPT"
  stop_managed_process "$RUN_DIR/.status-watch.lock" "$STATUS_SCRIPT"
  stop_managed_process "$RUN_DIR/.wiki-watch.lock" "$WIKI_SCRIPT"
}

# ── macOS: launchd LaunchAgents ─────────────────────────────────────────────
plist_path(){ printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$1"; }

write_launchd_plist(){
  local label="$1" script="$2" log="$3" keepalive="$4"
  local p service_path keepalive_xml
  p="$(plist_path "$label")"
  service_path="$(stable_service_path)"
  mkdir -p "$(dirname "$p")" "$RUN_DIR" "$ROOT/logs"

  if [[ "$keepalive" == "driver" ]]; then
    keepalive_xml="<dict><key>PathState</key><dict><key>$(xml_escape "$STOPFILE")</key><false/></dict></dict>"
  else
    keepalive_xml="<true/>"
  fi

  cat > "$p" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$(xml_escape "$script")</string></array>
  <key>WorkingDirectory</key><string>$(xml_escape "$ROOT")</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$(xml_escape "$service_path")</string>
    <key>HOME</key><string>$(xml_escape "$HOME")</string>
    <key>SPIN_ROOT</key><string>$(xml_escape "$ROOT")</string>
    <key>WORKSPACE_ROOT</key><string>$(xml_escape "$ROOT")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>$keepalive_xml
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$log")</string>
</dict></plist>
PLIST
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$p" >/dev/null || { echo "✗ generated plist invalid: $p"; return 1; }
  elif [[ "$DRY_RUN" != "1" ]]; then
    echo "✗ plutil is required to validate launchd service files"
    return 1
  fi
}

launchd_bootout(){
  local label="$1" p domain="gui/$(id -u)"
  p="$(plist_path "$label")"
  launchctl bootout "$domain/$label" 2>/dev/null || \
    launchctl bootout "$domain" "$p" 2>/dev/null || \
    launchctl unload "$p" 2>/dev/null || \
    launchctl remove "$label" 2>/dev/null || true
}

launchd_bootstrap(){
  local label="$1" p domain="gui/$(id -u)"
  p="$(plist_path "$label")"
  launchctl bootstrap "$domain" "$p" 2>/dev/null || launchctl load -w "$p" 2>/dev/null
}

launchd_install(){
  write_launchd_plist "$DRIVER_LABEL" "$DRIVER_SCRIPT" "$DRIVER_LOG" driver || return 1
  write_launchd_plist "$STATUS_LABEL" "$STATUS_SCRIPT" "$STATUS_LOG" always || return 1
  write_launchd_plist "$WIKI_LABEL" "$WIKI_SCRIPT" "$WIKI_LOG" always || return 1

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "launchd service files rendered (dry run)."
    return 0
  fi

  launchd_bootout "$DRIVER_LABEL"
  launchd_bootout "$STATUS_LABEL"
  launchd_bootout "$WIKI_LABEL"
  stop_all_managed_processes
  rm -f "$RUN_DIR/STATUS_WATCH_STOP" "$RUN_DIR/WIKI_WATCH_STOP"

  launchd_bootstrap "$DRIVER_LABEL" || { echo "${c_r}✗ failed to load $DRIVER_LABEL${c_o}"; return 1; }
  launchd_bootstrap "$STATUS_LABEL" || { echo "${c_r}✗ failed to load $STATUS_LABEL${c_o}"; return 1; }
  launchd_bootstrap "$WIKI_LABEL" || { echo "${c_r}✗ failed to load $WIKI_LABEL${c_o}"; return 1; }
  echo "${c_g}✓ installed supervised SPIN control plane${c_o} — driver, live status, and wiki watch."
}

launchd_uninstall(){
  launchd_bootout "$DRIVER_LABEL"
  launchd_bootout "$STATUS_LABEL"
  launchd_bootout "$WIKI_LABEL"
  stop_all_managed_processes
  rm -f "$(plist_path "$DRIVER_LABEL")" "$(plist_path "$STATUS_LABEL")" "$(plist_path "$WIKI_LABEL")"
  echo "${c_y}removed supervised SPIN control plane${c_o}."
}

launchd_component_status(){
  local label="$1" output
  output="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null || true)"
  if [[ -n "$output" ]] && grep -q 'state = running' <<< "$output"; then
    echo "  ${c_g}● $label running${c_o}"
    return 0
  fi
  if [[ "$label" == "$DRIVER_LABEL" && -n "$output" && -f "$STOPFILE" ]]; then
    echo "  ${c_y}● $label loaded (intentionally paused)${c_o}"
    return 0
  fi
  echo "  ${c_r}○ $label not running${c_o}"
  return 1
}

launchd_status(){
  local failed=0
  echo "SPIN services:"
  launchd_component_status "$DRIVER_LABEL" || failed=1
  launchd_component_status "$STATUS_LABEL" || failed=1
  launchd_component_status "$WIKI_LABEL" || failed=1
  return "$failed"
}

launchd_installed(){
  local label
  for label in "$DRIVER_LABEL" "$STATUS_LABEL" "$WIKI_LABEL"; do
    [[ -f "$(plist_path "$label")" ]] && return 0
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && return 0
  done
  return 1
}

# ── Linux: systemd --user services ──────────────────────────────────────────
unit_path(){ printf '%s/systemd/user/spin-%s.service\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$1"; }

write_systemd_unit(){
  local name="$1" description="$2" script="$3" condition="${4:-}"
  local unit service_path condition_line=""
  unit="$(unit_path "$name")"
  service_path="$(stable_service_path)"
  mkdir -p "$(dirname "$unit")" "$RUN_DIR" "$ROOT/logs"
  [[ -n "$condition" ]] && condition_line="ExecCondition=/bin/sh -c 'test ! -f \"\$SPIN_ROOT/org/ceo/runs/STOP\"'"
  cat > "$unit" <<UNIT
[Unit]
Description=$description
[Service]
Type=simple
WorkingDirectory="$ROOT"
Environment="HOME=$HOME"
Environment="PATH=$service_path"
Environment="SPIN_ROOT=$ROOT"
Environment="WORKSPACE_ROOT=$ROOT"
$condition_line
ExecStart=/bin/bash "$script"
Restart=always
RestartSec=15
[Install]
WantedBy=default.target
UNIT
}

systemd_install(){
  write_systemd_unit driver "SPIN Navigator driver loop" "$DRIVER_SCRIPT" driver
  write_systemd_unit status-watch "SPIN live status roll-up" "$STATUS_SCRIPT"
  write_systemd_unit wiki-watch "SPIN project wiki watcher" "$WIKI_SCRIPT"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "systemd service files rendered (dry run)."
    return 0
  fi
  stop_all_managed_processes
  rm -f "$RUN_DIR/STATUS_WATCH_STOP" "$RUN_DIR/WIKI_WATCH_STOP"
  systemctl --user daemon-reload
  systemctl --user enable --now spin-driver.service spin-status-watch.service spin-wiki-watch.service
  echo "${c_g}✓ installed supervised SPIN control plane${c_o} — driver, live status, and wiki watch."
  echo "${c_d}  (tip: 'loginctl enable-linger $USER' keeps it running after you log out)${c_o}"
}

systemd_uninstall(){
  systemctl --user disable --now spin-driver.service spin-status-watch.service spin-wiki-watch.service 2>/dev/null || true
  rm -f "$(unit_path driver)" "$(unit_path status-watch)" "$(unit_path wiki-watch)"
  systemctl --user daemon-reload 2>/dev/null || true
  stop_all_managed_processes
  echo "${c_y}removed supervised SPIN control plane${c_o}."
}

systemd_status(){
  local name failed=0
  echo "SPIN services:"
  for name in driver status-watch wiki-watch; do
    if systemctl --user is-active "spin-$name.service" >/dev/null 2>&1; then
      echo "  ${c_g}● spin-$name.service running${c_o}"
    elif [[ "$name" == "driver" && -f "$STOPFILE" && -f "$(unit_path driver)" ]]; then
      echo "  ${c_y}● spin-driver.service installed (intentionally paused)${c_o}"
    else
      echo "  ${c_r}○ spin-$name.service not running${c_o}"
      failed=1
    fi
  done
  return "$failed"
}

systemd_installed(){
  [[ -f "$(unit_path driver)" || -f "$(unit_path status-watch)" || -f "$(unit_path wiki-watch)" ]]
}

# ── dispatch ────────────────────────────────────────────────────────────────
case "$OS:$ACTION" in
  *:path)             stable_service_path; echo ;;
  Darwin:install|Darwin:repair) launchd_install ;;
  Darwin:uninstall)             launchd_uninstall ;;
  Darwin:status)                launchd_status ;;
  Darwin:installed)             launchd_installed ;;
  Linux:install|Linux:repair)
    if [[ "$DRY_RUN" != "1" ]]; then
      command -v systemctl >/dev/null || { echo "systemd not found — run the driver with: nohup spin start, or your own supervisor"; exit 1; }
    fi
    systemd_install
    ;;
  Linux:uninstall) systemd_uninstall ;;
  Linux:status)    systemd_status ;;
  Linux:installed) systemd_installed ;;
  *) echo "unsupported: OS=$OS action=$ACTION (try: install | repair | uninstall | status)"; exit 1 ;;
esac
