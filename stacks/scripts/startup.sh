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

# Single-instance lock: two concurrent runs race `colima start -p bridged`
# and can restart the bridged socket_vmnet daemon underneath a qemu that
# just attached to it, leaving col0 with no DHCP lease (observed 2026-07-26,
# when a stale LaunchAgent copy of the startup plist double-fired this
# script). noclobber redirect is the atomic acquire; a lockfile whose PID is
# dead is stale and stolen (macOS flock(1) doesn't exist and shlock(1) never
# reaps dead-PID locks). /tmp is wiped at boot, so the boot-time contention
# this guards against always starts lock-free.
lockfile="/tmp/com.cxreiff.dotfiles.startup.lock"
acquire() { (set -C; echo $$ > "$lockfile") 2>/dev/null; }
if ! acquire; then
    holder=$(cat "$lockfile" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        log "another startup.sh instance (PID ${holder}) is already running — exiting"
        exit 0
    fi
    rm -f "$lockfile"
    if ! acquire; then
        log "another startup.sh instance grabbed the lock — exiting"
        exit 0
    fi
fi
trap 'rm -f "$lockfile"' EXIT

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
