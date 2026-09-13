#!/bin/bash
# stacks/scripts/dns-forward.sh
# DNS relay: expose AdGuard (running in the bridged VM at TARGET:53) on this
# Mac's *Tailscale* address so tailnet clients resolve via a native 100.x
# node IP — which every Tailscale client always carries — instead of the
# bridged VM's LAN IP, which is only reachable behind an approved subnet
# route (fragile: breaks if the client doesn't accept routes, or if the
# remote network reuses the same 192.168.x.x subnet).
#
# Run as root (binding :53 is privileged) under the dns-forward LaunchDaemon.
# Two socat forwarders (UDP for normal queries, TCP for large/DNSSEC
# responses) bound to BIND:53, fanning out to TARGET:53. If either exits we
# tear both down and exit non-zero so launchd's KeepAlive restarts the whole
# daemon cleanly rather than limping along on a single protocol.
#
# Usage: dns-forward.sh <bind-ip> <target-ip>
#   bind-ip   — this node's Tailscale IP (e.g. 100.108.229.113)
#   target-ip — the bridged VM IP where AdGuard listens (e.g. 192.168.1.78)
#
# Exit codes:
#   1 — a forwarder exited (or BIND not yet assigned — e.g. Tailscale not up
#       at boot); launchd restarts after ThrottleInterval
#   2 — socat not found / args missing
set -u

bind="${1:?usage: dns-forward.sh <bind-ip> <target-ip>}"
target="${2:?usage: dns-forward.sh <bind-ip> <target-ip>}"

socat="$(command -v socat)" || { echo "dns-forward: socat not on PATH (brew install socat)" >&2; exit 2; }

# Sweep socat stragglers from a previous generation before binding. The
# per-client children that `fork` spawns are not tracked by this script and
# survive a kill of the two listener parents; under live tailnet traffic a
# surviving child still holds ${bind}:53 and our own bind fails EADDRINUSE,
# turning KeepAlive into a crash-loop (observed 2026-07-26). We run as root,
# so this reaches orphans from any prior generation. The pattern can't match
# this script itself (its argv has no "socat").
if pkill -f "socat.*bind=${bind}" 2>/dev/null; then
    sleep 1  # let the killed sockets close before we bind
fi

# UDP leg uses RECVFROM/SENDTO, not LISTEN: UDP4-LISTEN connects the bound
# socket to the first peer, so any ICMP port-unreachable (a client that went
# away) surfaces as a fatal ECONNREFUSED read in the listener and kills the
# relay — observed 2026-07-26 as a restart storm under live tailnet traffic.
# RECVFROM keeps the socket unconnected (immune to that) and forks one child
# per datagram, which is the correct multi-client shape for DNS anyway.
# -T30: reap stuck children after 30s. reuseaddr: survive fast restarts.
"$socat" -T30 "UDP4-RECVFROM:53,bind=${bind},fork,reuseaddr" "UDP4-SENDTO:${target}:53" &
udp=$!
"$socat"     "TCP4-LISTEN:53,bind=${bind},fork,reuseaddr" "TCP4:${target}:53" &
tcp=$!

# On exit, kill the listener parents AND sweep their forked children — the
# same straggler class the startup sweep guards against.
trap 'kill "$udp" "$tcp" 2>/dev/null; pkill -f "socat.*bind=${bind}" 2>/dev/null' TERM INT EXIT

# Supervise: exit (non-zero) the moment either forwarder dies so KeepAlive
# restarts both. bash 3.2 has no `wait -n`, so poll liveness.
while kill -0 "$udp" 2>/dev/null && kill -0 "$tcp" 2>/dev/null; do
    sleep 5
done

echo "dns-forward: a socat forwarder exited (bind=${bind} target=${target}); restarting" >&2
exit 1
