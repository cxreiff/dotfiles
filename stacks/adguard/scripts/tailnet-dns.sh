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

# Source .env from the same dir as this script's parent (stacks/adguard/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
if [ ! -f "$env_file" ]; then
    echo "tailnet-dns: ${env_file} missing — copy .env.example, fill in TAILSCALE_PAT" >&2
    exit 2
fi
# shellcheck disable=SC1090
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

# For 'on' subcommand, resolve vm_ip BEFORE the wizard guard
if [ "$cmd" = "on" ]; then
    vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
    if [ -z "$vm_ip" ]; then
        echo "tailnet-dns: bridged VM not running (run: dotfiles stacks vm-bridged)" >&2
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
        target="[\"${vm_ip}\"]"
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
