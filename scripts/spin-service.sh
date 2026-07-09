#!/usr/bin/env bash
# spin-service.sh — install/remove a supervisor that keeps the SPIN driver alive.
#
#   spin service install     # set it up + start it (launchd on macOS, systemd --user on Linux)
#   spin service uninstall   # stop + remove it
#   spin service status      # is it installed / running?
#   spin service path        # show the stable executable path saved by the service
#
# The supervisor respawns the driver if it dies (crash, closed pane, machine wake)
# and PAUSES cleanly when you `spin stop` (the STOP file) — no respawn loop. This is
# what turns "runs while I watch it" into "runs unattended".
set -uo pipefail
ROOT="${SPIN_ROOT:-${OMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
ACTION="${1:-status}"
STOPFILE="$ROOT/org/ceo/runs/STOP"
LOG="$ROOT/org/ceo/runs/workspace-ceo-driver.log"
TICK="$ROOT/scripts/workspace-ceo-tick.sh"
OS="$(uname -s)"
LABEL="com.spin.driver"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_d=$'\e[2m'; c_o=$'\e[0m'

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

# ── macOS: launchd LaunchAgent ───────────────────────────────────────────────
plist_path(){ echo "$HOME/Library/LaunchAgents/$LABEL.plist"; }
launchd_install(){
  local p service_path domain; p="$(plist_path)"; service_path="$(stable_service_path)"; domain="gui/$(id -u)"; mkdir -p "$(dirname "$p")"
  cat > "$p" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$TICK</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$service_path</string>
    <key>HOME</key><string>$HOME</string>
    <key>SPIN_ROOT</key><string>$ROOT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Keep alive UNLESS the STOP file exists (so \`spin stop\` pauses cleanly). -->
  <key>KeepAlive</key><dict><key>PathState</key><dict><key>$STOPFILE</key><false/></dict></dict>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
  plutil -lint "$p" >/dev/null || { echo "✗ generated plist invalid"; return 1; }
  # Reload an existing service so launchd adopts the new program and environment.
  launchctl bootout "$domain/$LABEL" 2>/dev/null || \
    launchctl bootout "$domain" "$p" 2>/dev/null || \
    launchctl unload "$p" 2>/dev/null || true
  # Stop any hand-started driver so the supervised one owns the lock.
  local cur; cur="$(cat "$ROOT/org/ceo/runs/.workspace-ceo-tick.lock" 2>/dev/null)"
  [[ -n "${cur:-}" ]] && kill -TERM "$cur" 2>/dev/null && sleep 2
  rm -f "$ROOT/org/ceo/runs/.workspace-ceo-tick.lock"
  launchctl bootstrap "$domain" "$p" 2>/dev/null || launchctl load -w "$p" 2>/dev/null
  echo "${c_g}✓ installed launchd agent $LABEL${c_o} — driver is now supervised."
}
launchd_uninstall(){
  local p; p="$(plist_path)"
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || launchctl unload "$p" 2>/dev/null || true
  rm -f "$p"; echo "${c_y}removed launchd agent $LABEL${c_o} (driver no longer supervised)."
}
launchd_status(){ launchctl list 2>/dev/null | grep -q "$LABEL" && echo "${c_g}● launchd agent installed${c_o}" || echo "${c_d}○ launchd agent not installed${c_o}"; }

# ── Linux: systemd --user service ────────────────────────────────────────────
unit_path(){ echo "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/spin-driver.service"; }
systemd_install(){
  local u; u="$(unit_path)"; mkdir -p "$(dirname "$u")"
  cat > "$u" <<UNIT
[Unit]
Description=SPIN Navigator driver loop
[Service]
Type=simple
WorkingDirectory=$ROOT
Environment=SPIN_ROOT=$ROOT
ExecStart=/bin/bash $TICK
Restart=always
RestartSec=15
# Pause cleanly when the STOP file exists.
ExecCondition=/bin/sh -c '! test -f $STOPFILE'
[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now spin-driver.service
  echo "${c_g}✓ installed systemd --user unit spin-driver${c_o} — driver is now supervised."
  echo "${c_d}  (tip: 'loginctl enable-linger $USER' keeps it running after you log out)${c_o}"
}
systemd_uninstall(){ systemctl --user disable --now spin-driver.service 2>/dev/null; rm -f "$(unit_path)"; systemctl --user daemon-reload 2>/dev/null; echo "${c_y}removed systemd unit spin-driver${c_o}."; }
systemd_status(){ systemctl --user is-active spin-driver.service >/dev/null 2>&1 && echo "${c_g}● systemd unit active${c_o}" || echo "${c_d}○ systemd unit not active${c_o}"; }

# ── dispatch ─────────────────────────────────────────────────────────────────
case "$OS:$ACTION" in
  *:path)             stable_service_path; echo ;;
  Darwin:install)   launchd_install ;;
  Darwin:uninstall) launchd_uninstall ;;
  Darwin:status)    launchd_status ;;
  Linux:install)    command -v systemctl >/dev/null || { echo "systemd not found — run the driver with: nohup spin start, or your own supervisor"; exit 1; }; systemd_install ;;
  Linux:uninstall)  systemd_uninstall ;;
  Linux:status)     systemd_status ;;
  *) echo "unsupported: OS=$OS action=$ACTION (try: install | uninstall | status)"; exit 1 ;;
esac
