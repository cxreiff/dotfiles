#!/usr/bin/env bash
# stacks/scripts/startup.sh
# Bring up all Colima VMs and every stack. Invoked at system boot by the
# com.cxreiff.dotfiles.startup LaunchDaemon (RunAtLoad, runs as the user);
# also runnable by hand. Idempotent — `colima start` and stack `up` are
# no-ops when the target is already running.
#
# Routes everything through the stacks justfile recipes (vm-*-up, up-all)
# rather than calling colima / docker directly, so boot bring-up uses the
# exact same context, ports, and DNS-failover ordering as an interactive one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
justfile="${repo_root}/justfile"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(ts)] startup: $*"; }
stacks() { just -f "$justfile" stacks "$@"; }

log "starting Colima VMs (shared, bridged, agents)"
for vm in vm-shared-up vm-bridged-up vm-agents-up; do
    if ! stacks "$vm"; then
        log "ERROR: ${vm} failed — aborting (stacks have no VM to land in)"
        exit 1
    fi
done

log "bringing up stacks (up-all)"
if stacks up-all; then
    log "done — all VMs and stacks up"
else
    rc=$?
    log "WARNING: up-all exited ${rc}; some stacks may be down (e.g. adguard's" \
        "tailnet-DNS hookup can race Tailscale coming up at boot)." \
        "Re-run 'dotfiles stacks up-all' or check 'dotfiles stacks doctor'."
fi
