#!/usr/bin/env bash
# stacks/scripts/bridged-ip-changed.sh
# Re-run all the automatable refreshes after the bridged VM IP changes.
# Prints a checklist of remaining human-must-do steps at the end.
#
# Exit codes:
#   0 — all automatable steps complete, checklist printed to stdout
#   1 — bridged VM not running or col0 MAC not readable or AGH config missing
#   other — sed, diff, just, or tailscale failed (set -euo pipefail)
set -euo pipefail

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# repo root is two levels up from stacks/scripts/ (matches Phase 4 backup-install.sh).
# Repo root's justfile has `mod stacks`, so `just -f <repo>/justfile stacks <recipe>`
# is the canonical invocation. Using `${SCRIPT_DIR}/..` here would resolve to
# stacks/, whose justfile has `mod adguard` etc. — the `stacks` target wouldn't
# resolve.
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "bridged-ip-changed: bridged VM not running (run: dotfiles stacks vm-bridged)" >&2
    exit 1
fi

vm_mac=$(colima ssh -p bridged -- ip link show col0 2>/dev/null \
    | awk '/link\/ether/ {print $2}')
if [ -z "$vm_mac" ]; then
    echo "bridged-ip-changed: could not read col0 MAC via colima ssh" >&2
    exit 1
fi

echo "bridged-ip-changed: bridged VM is at IP=${vm_ip} MAC=${vm_mac}"
echo

# 1. Patch AGH bind_hosts
agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
if [ ! -f "$agh_yaml" ]; then
    echo "bridged-ip-changed: ${agh_yaml} not found — has AGH ever started?" >&2
    exit 1
fi
echo "Patching ${agh_yaml} bind_hosts -> ${vm_ip} ..."
sed -i .bak -E '/^[[:space:]]+bind_hosts:/{n;s/^([[:space:]]+- )[0-9.]+$/\1'"$vm_ip"'/;}' \
    "$agh_yaml"
# Show diff against the .bak backup so the user sees what changed
diff -u "$agh_yaml.bak" "$agh_yaml" || true

# 2. Restart AGH so it re-binds
echo
echo "Restarting adguard ..."
just -f "${repo_root}/justfile" stacks adguard restart

# 3. Refresh both serve mappings (drop + re-add)
echo
echo "Refreshing Tailscale serve mappings ..."
for port in 8689 8767; do
    "$TAILSCALE" serve --https="$port" off || true
done
just -f "${repo_root}/justfile" stacks adguard serve
just -f "${repo_root}/justfile" stacks homebridge serve

# 4. Re-advertise subnet route
echo
echo "Re-advertising /32 subnet route ..."
just -f "${repo_root}/justfile" stacks adguard advertise

# 5. Refresh Global NS
echo
echo "Refreshing Tailscale Global Nameservers ..."
just -f "${repo_root}/justfile" stacks adguard tailnet-dns-on

# 6. Closing checklist
cat <<EOF

==========================================================
bridged-ip-changed complete. Manual steps remaining:
==========================================================

1. Router DHCP reservation: ensure the bridged VM gets the same IP after
   a router reboot. Set:
     MAC: ${vm_mac}
     IP:  ${vm_ip}
   On RT-AC68U: LAN -> DHCP Server -> Manual Assignment.

2. Tailscale subnet route approval: re-approval is required after any
   IP change. Visit:
     https://login.tailscale.com/admin/machines
   Find this host -> Edit route settings -> enable ${vm_ip}/32.

3. Confirm doctor is all-green:
     dotfiles stacks doctor
EOF
