#!/usr/bin/env bash
# stacks/adguard/scripts/lib/fallback.sh — source-only.
#
# tailnet_dns_fallback FILE: print the TAILNET_DNS_FALLBACK value from a
# hand-written KEY=VALUE file (stacks/adguard/.env). Prints nothing when the key
# is absent or blank (the caller then keeps its default).
#
# Normalizes: CR bytes, surrounding whitespace, a trailing ` # comment`, and one
# pair of surrounding single or double quotes. The result must be an IPv4 or
# IPv6 address; anything else returns 2 with a message that names the KEY and
# never the value. The value is never substituted silently.
#
# IPv6 is checked structurally (bash 3.2-safe, no external tools): groups of
# 1-4 hex digits, at most one `::`, exactly 8 groups without `::` and at most 7
# with it, at least one group. IPv4-mapped forms such as ::ffff:1.2.3.4 are
# deliberately rejected (dotted-quad tails are not accepted in the IPv6 branch).
#
# Reads only the one key (no sourcing); never echoes the value on failure.

# _tailnet_dns_ipv6_ok ADDR: returns 0 when ADDR is a plain IPv6 address per the
# rules above, 1 otherwise.
_tailnet_dns_ipv6_ok() {
    local a="$1" rest head="" tail="" c hn=0 tn=0 grp='^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*$'
    [[ "$a" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$a" in
        *:::*) return 1 ;;
        *::*) ;;
        *)
            [[ "$a" =~ ^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}$ ]]
            return $?
            ;;
    esac
    rest="${a#*::}"
    case "$rest" in *::*) return 1 ;; esac
    head="${a%%::*}"
    tail="$rest"
    if [ -n "$head" ]; then
        [[ "$head" =~ $grp ]] || return 1
        c="${head//[!:]/}"; hn=$(( ${#c} + 1 ))
    fi
    if [ -n "$tail" ]; then
        [[ "$tail" =~ $grp ]] || return 1
        c="${tail//[!:]/}"; tn=$(( ${#c} + 1 ))
    fi
    [ $(( hn + tn )) -le 7 ] && [ $(( hn + tn )) -ge 1 ]
}

tailnet_dns_fallback() {
    local file="$1" raw v o valid=0
    raw="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?TAILNET_DNS_FALLBACK=//p' "$file" | tail -1)"
    v="$(printf '%s' "$raw" | tr -d '\r' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//')"
    if [ "${#v}" -ge 2 ]; then
        case "$v" in
            \"*\") v="${v#\"}"; v="${v%\"}" ;;
            \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
    fi
    v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$v" ]; then
        return 0
    fi

    if [[ "$v" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        valid=1
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            [ "$o" -le 255 ] || valid=0
        done
    elif [[ "$v" == *:* ]] && _tailnet_dns_ipv6_ok "$v"; then
        valid=1
    fi

    if [ "$valid" -ne 1 ]; then
        echo "tailnet-dns: TAILNET_DNS_FALLBACK in stacks/adguard/.env is not an IP address (value not printed; fix the entry)" >&2
        return 2
    fi
    printf '%s\n' "$v"
}
