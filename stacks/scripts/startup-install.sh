#!/usr/bin/env bash
# stacks/scripts/startup-install.sh
# Install the boot-time autostart LaunchDaemon. At system boot it runs
# scripts/startup.sh (start all three Colima VMs, then up-all).
#
# This host is headless (administered over SSH) with FileVault on, so no
# Aqua GUI login session ever exists — a LaunchAgent (gui/$(id -u)) would
# never load. A LaunchDaemon in the `system` domain loads at boot without a
# GUI session, and is installed/managed entirely over SSH with `sudo
# launchctl`. It runs as the invoking user (UserName) so Colima uses
# ~/.colima and the user's docker contexts, not root's.
#
# Run as your normal user; the script elevates with sudo only for the
# /Library/LaunchDaemons write and the launchctl bootstrap.
#
# Exit codes:
#   0 — daemon installed and loaded, status printed
#   2 — required tool/file not found (startup.sh, template)
#   other — sed/plutil/sudo/launchctl failed (set -euo pipefail)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
startup_sh="${SCRIPT_DIR}/startup.sh"
[ -x "$startup_sh" ] || { echo "startup.sh not found/executable at ${startup_sh}" >&2; exit 2; }

template="${SCRIPT_DIR}/com.cxreiff.dotfiles.startup.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

user="$(id -un)"
logdir="${HOME}/Library/Logs"
label="com.cxreiff.dotfiles.startup"
plist="/Library/LaunchDaemons/${label}.plist"

# Pre-create user-owned log files so the user-context daemon can write them.
mkdir -p "$logdir"
touch "${logdir}/${label}.out.log" "${logdir}/${label}.err.log"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed \
    -e "s|__STARTUP_SH__|${startup_sh}|g" \
    -e "s|__USER__|${user}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__LOGDIR__|${logdir}|g" \
    "$template" > "$tmp"
plutil -lint "$tmp" >/dev/null

echo "Installing ${plist} (sudo required)…"
sudo cp "$tmp" "$plist"
sudo chown root:wheel "$plist"
sudo chmod 644 "$plist"

if sudo launchctl print "system/${label}" >/dev/null 2>&1; then
    sudo launchctl bootout "system/${label}" 2>/dev/null || true
fi
sudo launchctl bootstrap system "$plist"
sudo launchctl enable "system/${label}"

echo
echo "Installed daemon: $plist"
echo "Runs at boot:     ${startup_sh}"
echo "Logs:             ${logdir}/${label}.{out,err}.log"
echo
sudo launchctl print "system/${label}" | grep -E '(state|path|program) =' || true
