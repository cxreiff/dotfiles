#!/usr/bin/env bash
# tailscale/scripts/lib/conf.sh — source-only. Sets TAILNET, TAILNET_DNS_SUFFIX,
# NODE_HOSTNAME from tailscale/tailnet.conf (KEY=VALUE, `#` comments).
# TAILSCALE_TAILNET_CONF overrides the file (tests).
ts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ts_conf="${TAILSCALE_TAILNET_CONF:-${ts_root}/tailnet.conf}"
conf_get() { sed -n "s/^$1=\([^[:space:]#]*\).*/\1/p" "$ts_conf" | tail -1; }
TAILNET="$(conf_get TAILNET)"
TAILNET_DNS_SUFFIX="$(conf_get TAILNET_DNS_SUFFIX)"
NODE_HOSTNAME="$(conf_get NODE_HOSTNAME)"
