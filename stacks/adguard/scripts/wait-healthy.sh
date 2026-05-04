#!/usr/bin/env bash
# stacks/adguard/scripts/wait-healthy.sh
# Poll AGH at the bridged-VM IP until it answers a DNS query or the deadline
# expires.
#
# Exit codes:
#   0 — AGH is responding to DNS, OR AGH is in first-run-wizard state (no
#       bind_hosts populated yet — the wizard hasn't been completed). The
#       latter case is a benign no-op for the up hook; the caller (`adguard
#       up`) interprets exit 0 as "safe to proceed", and the chained
#       `tailnet-dns.sh on` then either flips Global NS (wizard done) or
#       quietly no-ops (wizard pending — user hasn't yet pointed AGH at
#       col0; flipping Global NS at AGH would brick DNS).
#   1 — bridged VM not running, OR AGH is wizard-complete + bind_hosts
#       populated but DNS isn't responding within 60s (real failure).
set -euo pipefail

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "wait-healthy: bridged VM not running" >&2
    exit 1
fi

# First-run-wizard guard: if AGH yaml is missing, or has no bind_hosts entry
# yet, AGH is in wizard mode (only the :3000 web UI is listening; no DNS
# bind on col0). Exit 0 with a clear message — no DNS to wait for.
# Defense-in-depth: validate that the parsed bind_hosts IP equals the
# resolved bridged VM IP (rejects user error: binding to 0.0.0.0 or wrong IP).
agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
bind_ip=$(awk '/^[[:space:]]+bind_hosts:/{f=1; next} f && /^[[:space:]]+- /{print; exit}' \
        "$agh_yaml" 2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' || true)

if [ -z "$bind_ip" ]; then
    echo "wait-healthy: AGH wizard not yet complete (no bind_hosts in ${agh_yaml})"
    echo "  Complete the wizard at http://${vm_ip}:3000 (bind to col0 — see adguard/README.md)."
    echo "  Then re-run: dotfiles stacks adguard restart"
    exit 0
elif [ "$bind_ip" != "$vm_ip" ]; then
    echo "wait-healthy: AGH bind_hosts is ${bind_ip} but bridged VM IP is ${vm_ip}" >&2
    echo "  Re-run the wizard at http://${vm_ip}:3000 and pick \`col0\`, not All interfaces." >&2
    exit 1
fi

deadline=$(($(date +%s) + 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if dig "@${vm_ip}" example.com +tries=1 +time=2 +short >/dev/null 2>&1; then
        # Exit 0 from dig means we got a response — AGH is up.
        echo "wait-healthy: AGH at ${vm_ip} responding"
        exit 0
    fi
    sleep 1
done

echo "wait-healthy: AGH at ${vm_ip} did not respond within 60s" >&2
exit 1
