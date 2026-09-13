#!/usr/bin/env bash
# stacks/scripts/dns-forward-install.sh
# Install the DNS-relay LaunchDaemon that exposes AdGuard (bridged VM :53)
# on this node's Tailscale address :53, so tailnet clients resolve via a
# native 100.x node IP rather than the bridged VM's subnet-routed LAN IP.
# See dns-forward.sh and stacks/adguard/README.md for the why.
#
# Runs as ROOT (binds :53) — unlike startup/backup which run as the user.
# The BIND (this node's Tailscale IP) and TARGET (bridged VM IP) are resolved
# now and baked into the plist; re-run this after either changes (the bridged
# VM IP is re-coordinated by bridged-ip-changed.sh, which calls back here).
#
# Run as your normal user; elevates with sudo only for the
# /Library/LaunchDaemons write and the launchctl bootstrap.
#
# Exit codes:
#   0 — daemon installed and loaded, status printed
#   2 — required tool/file not found (socat, dns-forward.sh, template, tailscale)
#   3 — could not resolve the Tailscale node IP or bridged VM IP
#   other — sed/plutil/sudo/launchctl failed (set -euo pipefail)
set -euo pipefail

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

forward_sh="${SCRIPT_DIR}/dns-forward.sh"
[ -x "$forward_sh" ] || { echo "dns-forward.sh not found/executable at ${forward_sh}" >&2; exit 2; }

template="${SCRIPT_DIR}/com.cxreiff.dotfiles.dns-forward.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

command -v socat >/dev/null 2>&1 || { echo "socat not installed (run: brew install socat)" >&2; exit 2; }
[ -x "$TAILSCALE" ] || { echo "tailscale CLI missing at ${TAILSCALE}" >&2; exit 2; }

# BIND = this node's Tailscale IPv4 (stable per node; the relay listens here).
bind_ip="$("$TAILSCALE" ip -4 2>/dev/null | head -1)"
if [ -z "$bind_ip" ]; then
    echo "dns-forward-install: could not read this node's Tailscale IP (is Tailscale up?)" >&2
    exit 3
fi

# TARGET = bridged VM IP where AdGuard listens.
target_ip="$(colima list 2>/dev/null | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')"
if [ -z "$target_ip" ]; then
    echo "dns-forward-install: bridged VM not running (run: dotfiles stacks vm-bridged-up)" >&2
    exit 3
fi

logdir="${HOME}/Library/Logs"
label="com.cxreiff.dotfiles.dns-forward"
plist="/Library/LaunchDaemons/${label}.plist"

# Pre-create log files (user-owned; the root daemon appends to them).
mkdir -p "$logdir"
touch "${logdir}/${label}.out.log" "${logdir}/${label}.err.log"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed \
    -e "s|__DNS_FORWARD_SH__|${forward_sh}|g" \
    -e "s|__BIND__|${bind_ip}|g" \
    -e "s|__TARGET__|${target_ip}|g" \
    -e "s|__LOGDIR__|${logdir}|g" \
    "$template" > "$tmp"
plutil -lint "$tmp" >/dev/null

echo "Installing ${plist} (sudo required)…"
echo "  relay: ${bind_ip}:53  ->  ${target_ip}:53"
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
echo "Relay:            ${bind_ip}:53 -> ${target_ip}:53 (UDP + TCP)"
echo "Logs:             ${logdir}/${label}.{out,err}.log"
echo
sudo launchctl print "system/${label}" | grep -E '(state|path|program) =' || true
echo
echo "Next: point Tailscale Global NS at this node IP via"
echo "  dotfiles stacks adguard tailnet-dns-on"
echo "(then on the phone/clients, Global NS becomes ${bind_ip} — no subnet route needed)."
