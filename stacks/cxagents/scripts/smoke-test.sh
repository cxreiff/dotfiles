#!/usr/bin/env bash
# stacks/cxagents/scripts/smoke-test.sh — fixture runner for the AC5.3 packet-filter
# verdict that smoke.sh applies to the live netmap. Each case is a netmap JSON
# with the real field names (PacketFilter[].Srcs, PacketFilterRules[].SrcIPs),
# read through the same extraction smoke.sh uses. No tailscale, no docker, no
# network. Exit: 0 all cases pass; 1 any case failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ac5_3.sh
source "${SCRIPT_DIR}/lib/ac5_3.sh"

failures=0
pass_case() { echo "PASS smoke-fixture $1"; }
fail_case() { echo "FAIL smoke-fixture $1: $2" >&2; failures=$((failures + 1)); }

# The cxagents node's addresses (smoke.sh reads them from tailscale status).
ips='100.90.12.34
fd7a:115c:a1e0::5'

# case_src LABEL FIELD JSON_LIST WANT NEEDLE
#   FIELD: srcs (PacketFilter[].Srcs) or ips (PacketFilterRules[].SrcIPs).
#   WANT: fail (a verdict naming NEEDLE) or ok (no verdict).
case_src() {
    local label="$1" field="$2" list="$3" want="$4" needle="$5" nm srcs bad
    if [ "$field" = srcs ]; then
        nm="$(jq -nc --argjson l "$list" '{PacketFilter: [{IPProto: [6], Dst: ["100.70.208.32:22"], Srcs: $l}]}')"
    else
        nm="$(jq -nc --argjson l "$list" '{PacketFilterRules: [{SrcIPs: $l, DstPorts: [{IP: "100.70.208.32", Ports: {First: 22, Last: 22}}]}]}')"
    fi
    srcs="$(printf '%s' "$nm" | ac5_3_sources)"
    bad="$(ac5_3_verdict "$ips" "$srcs")"
    case "$want" in
        fail)
            if [ -n "$bad" ] && grep -qF -- "$needle" <<<"$bad"; then pass_case "$label"
            else fail_case "$label" "want a verdict naming '${needle}', got '${bad}'"; fi ;;
        ok)
            if [ -z "$bad" ]; then pass_case "$label"
            else fail_case "$label" "want no verdict, got '${bad}'"; fi ;;
    esac
}

case_src "cxagents bare address in PacketFilterRules SrcIPs -> FAIL" ips '["100.90.12.34"]' fail "100.90.12.34"
case_src "cxagents bare address in PacketFilter Srcs -> FAIL" srcs '["100.90.12.34"]' fail "100.90.12.34"
case_src "cxagents address as /32 -> FAIL" srcs '["100.90.12.34/32"]' fail "100.90.12.34/32"
case_src "cxagents IPv6 as /128 -> FAIL" srcs '["fd7a:115c:a1e0::5/128"]' fail "fd7a:115c:a1e0::5/128"
case_src "0.0.0.0/0 -> FAIL" srcs '["0.0.0.0/0"]' fail "0.0.0.0/0"
case_src "::/0 -> FAIL" srcs '["::/0"]' fail "::/0"
case_src "100.64.0.0/10 (CGNAT range holding the node) -> FAIL" srcs '["100.64.0.0/10"]' fail "100.64.0.0/10"
case_src "* -> FAIL" ips '["*"]' fail "*"
case_src "clean list (peers, other addresses) -> OK" srcs '["100.70.208.32/32", "100.64.1.2/32", "fd7a:115c:a1e0::9/128"]' ok ""
case_src "clean list in PacketFilterRules SrcIPs -> OK" ips '["100.70.208.32", "100.64.1.2"]' ok ""

if [ "$failures" -gt 0 ]; then
    echo "FAIL: ${failures} smoke fixture(s) failed" >&2
    exit 1
fi
echo "All smoke fixtures passed"
exit 0
