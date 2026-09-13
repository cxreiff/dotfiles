#!/usr/bin/env bash
# stacks/adguard/scripts/tailnet-dns.sh
# Toggle Tailscale tailnet Global Nameservers between AGH and a public
# fallback. Idempotent — compares against current state before writing.
#
# Usage: tailnet-dns.sh on|off|status
#
# Exit codes:
#   0 — success (or no-op when state already matches target)
#   2 — preflight failure (.env / VM / args)
#   3 — Tailscale API failure
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
    on|off|status) ;;
    *) echo "usage: tailnet-dns.sh on|off|status" >&2; exit 2 ;;
esac

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# Source .env from the same dir as this script's parent (stacks/adguard/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
if [ ! -f "$env_file" ]; then
    echo "tailnet-dns: ${env_file} missing — copy .env.example, fill in TAILSCALE_PAT" >&2
    exit 2
fi
set -a; source "$env_file"; set +a

if [ -z "${TAILSCALE_PAT:-}" ] || [ "$TAILSCALE_PAT" = "tskey-api-CHANGE_ME" ]; then
    echo "tailnet-dns: TAILSCALE_PAT not set in ${env_file}" >&2
    exit 2
fi

api="https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers"
hdr=(-H "Authorization: Bearer ${TAILSCALE_PAT}" -H "Content-Type: application/json")

# GET current Global NS — also serves as connectivity preflight
current_json="$(curl -fsS "${hdr[@]}" "$api" 2>&1)" || {
    echo "tailnet-dns: API GET failed: $current_json" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}
current="$(echo "$current_json" | jq -r '.dns | @json')"

# For 'on' subcommand, resolve vm_ip (where AGH listens) and node_ip (this
# node's Tailscale IP, where the dns-forward relay exposes AGH) BEFORE the
# guards. Global NS points at node_ip — a native 100.x address every tailnet
# client always carries — NOT the bridged VM's LAN IP (which is only reachable
# behind an approved subnet route; see stacks/scripts/dns-forward.sh).
if [ "$cmd" = "on" ]; then
    # $NF dotted-quad guard: with no DHCP lease on col0, `colima list` leaves
    # ADDRESS empty and $NF is the RUNTIME column ("docker").
    vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" && $NF ~ /^([0-9]+\.){3}[0-9]+$/ {print $NF}')
    if [ -z "$vm_ip" ]; then
        echo "tailnet-dns: bridged VM not running, or Running with no LAN IP (col0 DHCP lease missing)" >&2
        echo "  recover: dotfiles stacks vm-bridged-down && dotfiles stacks vm-bridged-up" >&2
        exit 2
    fi
    node_ip=$("$TAILSCALE" ip -4 2>/dev/null | head -1)
    if [ -z "$node_ip" ]; then
        echo "tailnet-dns: could not read this node's Tailscale IP (is Tailscale up?)" >&2
        exit 2
    fi
fi

case "$cmd" in
    status)
        echo "$current_json" | jq .
        exit 0
        ;;

    on)
        # First-run-wizard guard (matches wait-healthy.sh): never flip Global
        # NS to point at AGH if AGH hasn't completed its wizard yet — AGH
        # isn't listening for DNS in that state, and pointing the tailnet at
        # it would brick all tailnet DNS resolution.
        # Defense-in-depth: validate that the parsed bind_hosts IP equals the
        # resolved bridged VM IP (rejects user error: binding to 0.0.0.0 or wrong IP).
        agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
        bind_ip=$(awk '/^[[:space:]]+bind_hosts:/{f=1; next} f && /^[[:space:]]+- /{print; exit}' \
                "$agh_yaml" 2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' || true)

        if [ -z "$bind_ip" ]; then
            echo "tailnet-dns: AGH wizard not yet complete — refusing to set Global NS"
            echo "  Complete wizard at http://${vm_ip}:3000 (see adguard/README.md), then re-run."
            exit 0
        elif [ "$bind_ip" != "$vm_ip" ]; then
            echo "tailnet-dns: AGH bind_hosts is ${bind_ip} but bridged VM IP is ${vm_ip}" >&2
            echo "  Re-run the wizard and pick \`col0\`, not All interfaces." >&2
            exit 0
        fi

        # dns-forward relay guard: Global NS will point at node_ip:53, served
        # by the dns-forward LaunchDaemon relaying to AGH. If that relay isn't
        # answering, pointing the tailnet at node_ip would brick all tailnet
        # DNS — so probe it first and refuse rather than strand devices.
        if ! dig +time=2 +tries=1 "@${node_ip}" google.com >/dev/null 2>&1; then
            echo "tailnet-dns: dns-forward relay at ${node_ip}:53 not answering — refusing to set Global NS" >&2
            echo "  Install/repair it: dotfiles stacks dns-forward-install" >&2
            echo "  (check: sudo launchctl print system/com.cxreiff.dotfiles.dns-forward)" >&2
            exit 3
        fi
        target="[\"${node_ip}\"]"
        ;;

    off)
        fallback="${TAILNET_DNS_FALLBACK:-1.1.1.1}"
        target="[\"${fallback}\"]"
        ;;
esac

if [ "$current" = "$target" ]; then
    echo "tailnet-dns: Global NS already ${target} — no change"
    exit 0
fi

echo "tailnet-dns: setting Global NS ${current} -> ${target}"
body="{\"dns\":${target}}"
resp="$(curl -fsS -X POST "${hdr[@]}" -d "$body" "$api" 2>&1)" || {
    echo "tailnet-dns: API POST failed: $resp" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}
echo "$resp" | jq -r '.dns | @json'
