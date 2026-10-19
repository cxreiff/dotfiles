#!/usr/bin/env bash
# stacks/adguard/scripts/tailnet-dns.sh
# Toggle Tailscale tailnet Global Nameservers between AGH and a public
# fallback. Idempotent — compares against current state before writing.
#
# Usage: tailnet-dns.sh on|off|status
#
# Exit codes:
#   0 — success (or no-op when state already matches target)
#   2 — preflight failure (args / VM / node IP / tailscale/.env credentials)
#   3 — Tailscale API failure, or the dns-forward relay not answering
#
# Auth: tailscale/scripts/api.sh --client admin (OAuth, tailscale/.env).
# stacks/adguard/.env is optional and only supplies TAILNET_DNS_FALLBACK.
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
    on|off|status) ;;
    *) echo "usage: tailnet-dns.sh on|off|status" >&2; exit 2 ;;
esac

TAILSCALE="/opt/homebrew/bin/tailscale"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ts_scripts="${repo_root}/tailscale/scripts"
# shellcheck source=../../../tailscale/scripts/lib/conf.sh
source "${ts_scripts}/lib/conf.sh"          # TAILNET
# shellcheck source=lib/fallback.sh
source "${SCRIPT_DIR}/lib/fallback.sh"      # tailnet_dns_fallback

[ -n "$TAILNET" ] || { echo "tailnet-dns: TAILNET missing in tailscale/tailnet.conf" >&2; exit 2; }

ns_path="/tailnet/${TAILNET}/dns/nameservers"
api_fail() {   # $1 = api.sh exit code, $2 = verb
    if [ "$1" -eq 2 ]; then
        echo "tailnet-dns: Tailscale API credentials unavailable — restore tailscale/.env (see tailscale/README.md, Credentials)" >&2
        exit 2
    fi
    echo "tailnet-dns: API $2 failed (see api.sh message above)" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}

# GET current Global NS — also serves as connectivity preflight
current_json="$("${ts_scripts}/api.sh" --client admin GET "$ns_path")" || api_fail $? GET
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
        # Fallback NS: the only value read from stacks/adguard/.env (not sourced).
        # Read and validated only here, so an invalid entry cannot block `on`,
        # `status`, or doctor's read-only probe. Garbage exits 2 before the POST.
        env_file="${SCRIPT_DIR}/../.env"
        fallback="1.1.1.1"
        if [ -f "$env_file" ]; then
            v="$(tailnet_dns_fallback "$env_file")" || exit 2
            [ -n "$v" ] && fallback="$v"
        fi
        target="[\"${fallback}\"]"
        ;;
esac

if [ "$current" = "$target" ]; then
    echo "tailnet-dns: Global NS already ${target} — no change"
    exit 0
fi

echo "tailnet-dns: setting Global NS ${current} -> ${target}"
body="{\"dns\":${target}}"
resp="$("${ts_scripts}/api.sh" --client admin POST "$ns_path" \
    -H 'Content-Type: application/json' -d "$body")" || api_fail $? POST
echo "$resp" | jq -r '.dns | @json'
