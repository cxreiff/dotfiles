#!/usr/bin/env bash
# stacks/scripts/backup-install.sh
set -euo pipefail

just_bin="$(command -v just)"
[ -n "$just_bin" ] || { echo "just not found on PATH" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
justfile="${repo_root}/justfile"
[ -f "$justfile" ] || { echo "justfile not found at ${justfile}" >&2; exit 2; }

backups="${HOME}/.volume-backups"
agents="${HOME}/Library/LaunchAgents"
plist="${agents}/com.cxreiff.dotfiles.backup.plist"
template="${SCRIPT_DIR}/com.cxreiff.dotfiles.backup.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

mkdir -p "${backups}/.log" "${agents}"

sed \
    -e "s|__JUST__|${just_bin}|g" \
    -e "s|__JUSTFILE__|${justfile}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__BACKUPS__|${backups}|g" \
    "$template" > "$plist"

plutil -lint "$plist" >/dev/null

uid="$(id -u)"
if launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}" "$plist"
fi
launchctl bootstrap "gui/${uid}" "$plist"

echo
echo "Installed: $plist"
echo
launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" | grep -E '(state|path|next start) ='
