#!/usr/bin/env bash
# stacks/scripts/backup-install.sh
# Install the nightly (4 AM) backup LaunchDaemon.
#
# This host is headless (administered over SSH) with FileVault on, so no
# Aqua GUI login session ever exists — a LaunchAgent (gui/$(id -u)) would
# never load, which is exactly why earlier backups silently stopped after a
# reboot. A LaunchDaemon in the `system` domain fires regardless of GUI
# login and is managed over SSH with `sudo launchctl`. It runs as the
# invoking user (UserName) so it reads the user's ~/.volumes and docker
# contexts, not root's.
#
# Run as your normal user; the script elevates with sudo only for the
# /Library/LaunchDaemons write and the launchctl bootstrap.
#
# Exit codes:
#   0 — daemon installed and scheduled, status printed to stdout
#   2 — required tool/file not found (just, justfile, template)
#   other — sed, plutil, sudo, launchctl failed (set -euo pipefail)
set -euo pipefail

just_bin="$(command -v just)"
[ -n "$just_bin" ] || { echo "just not found on PATH" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
justfile="${repo_root}/justfile"
[ -f "$justfile" ] || { echo "justfile not found at ${justfile}" >&2; exit 2; }

template="${SCRIPT_DIR}/com.cxreiff.dotfiles.backup.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

user="$(id -un)"
backups="${HOME}/.volume-backups"
label="com.cxreiff.dotfiles.backup"
plist="/Library/LaunchDaemons/${label}.plist"

# Log dir is user-owned; the user-context daemon writes stdout/stderr here.
mkdir -p "${backups}/.log"

# Remove any stale LaunchAgent install (the old, never-loading mechanism).
old_agent="${HOME}/Library/LaunchAgents/${label}.plist"
if [ -f "$old_agent" ]; then
    launchctl bootout "gui/$(id -u)" "$old_agent" 2>/dev/null || true
    rm -f "$old_agent"
    echo "Removed stale LaunchAgent: $old_agent"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed \
    -e "s|__JUST__|${just_bin}|g" \
    -e "s|__JUSTFILE__|${justfile}|g" \
    -e "s|__USER__|${user}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__BACKUPS__|${backups}|g" \
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
echo
sudo launchctl print "system/${label}" | grep -E '(state|path|next start) =' || true
