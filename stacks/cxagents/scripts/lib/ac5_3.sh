#!/usr/bin/env bash
# stacks/cxagents/scripts/lib/ac5_3.sh — source-only. The AC5.3 packet-filter
# verdict, shared by smoke.sh (live netmap) and smoke-test.sh (fixtures).

# ac5_3_sources: a netmap JSON on stdin -> its packet-filter source prefixes, one
#   per line, sorted and unique: PacketFilter[].Srcs (classic) and
#   PacketFilterRules[].SrcIPs (newer). Prints nothing for unreadable JSON.
ac5_3_sources() {
    jq -r '((.PacketFilter // [])[]?.Srcs[]?), ((.PacketFilterRules // [])[]?.SrcIPs[]?)' 2>/dev/null | sort -u
}

# ac5_3_verdict IPS SRCS: IPS are the cxagents node's addresses and SRCS the
#   source prefixes (both newline lists). Prints the entries that admit the node,
#   joined by ", ", and nothing when no source admits it. Entries are a bare
#   address (SrcIPs) or addr/32|128 (Srcs). Wildcards, universal prefixes, other
#   prefix lengths and anything not shaped like one address are reported as
#   offenders to inspect by hand, never passed silently.
ac5_3_verdict() {
    local ips="$1" srcs="$2" line addr bad=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            '*'|'0.0.0.0/0'|'::/0') bad="${bad:+$bad, }$line (universal)"; continue ;;
        esac
        addr="${line%/*}"
        if [ "$addr" != "$line" ]; then
            case "${line#*/}" in
                32|128) ;;
                *) bad="${bad:+$bad, }$line (prefix length not checked by hand)"; continue ;;
            esac
        fi
        case "$addr" in
            *[!0-9a-fA-F.:]*|'') bad="${bad:+$bad, }$line (not a single address; inspect by hand)"; continue ;;
        esac
        if grep -qxF "$addr" <<<"$ips"; then bad="${bad:+$bad, }$line"; fi
    done <<<"$srcs"
    printf '%s' "$bad"
}
