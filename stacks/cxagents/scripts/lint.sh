#!/bin/bash
# stacks/cxagents/scripts/lint.sh — static lockdown invariants for the cxagents
# node: the tailnet policy (grants/ACLs/SSH), the forwarder's compose hardening,
# the routes file, and the key NAMES every stack's .env and compose environment
# carries. Reads tracked files and the KEY NAMES of .env files only; never a
# .env value. Run by `dotfiles stacks doctor` (--- cxagents ---, via doctor.sh);
# every input is overridable.
#
# Usage: lint.sh [--policy F] [--compose F] [--routes F] [--stacks-dir D]
#   --policy / --compose ending in .json are read as already rendered (JSON).
#   --stacks-dir holds one directory per stack (default: stacks/).
# Exit: 0 all pass; 1 any FAIL; 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${stack_dir}/../.." && pwd)"
# shellcheck source=../../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

policy="${repo_root}/tailscale/policy.hujson"
compose="${stack_dir}/compose.yaml"
routes="${stack_dir}/routes"
stacks_dir="${repo_root}/stacks"
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "lint: $1 needs a value" >&2; exit 2; }
    case "$1" in
        --policy) policy="$2" ;;
        --compose) compose="$2" ;;
        --routes) routes="$2" ;;
        --stacks-dir) stacks_dir="$2" ;;
        *) echo "lint: unknown argument $1" >&2; exit 2 ;;
    esac
    shift 2
done

# Rendered compose JSON. A .json path is already rendered. Empty output = unreadable.
render() {
    case "$1" in
        *.json) cat "$1" 2>/dev/null ;;
        *) docker compose -f "$1" config --no-interpolate --format json 2>/dev/null ;;
    esac
}

# Policy as JSON (HuJSON converted by the tailscale filter). Empty = unreadable.
pol="$(perl "${repo_root}/tailscale/scripts/lib/hujson2json.pl" < "$policy" 2>/dev/null | jq -c . 2>/dev/null)"
fwd="$(render "$compose")"

# Every stack's rendered compose: environment key names and container names.
# KEY NAMES only (never values). A stack that cannot be rendered is recorded.
svc_env_keys=""; container_names=""; stack_render_bad=""
for f in "$stacks_dir"/*/compose*.yaml; do
    [ -f "$f" ] || continue
    rj="$(render "$f")"
    if [ -z "$rj" ]; then stack_render_bad="${stack_render_bad} ${f}"; continue; fi
    svc_env_keys="${svc_env_keys}$(jq -r '.services[]?.environment // {} | keys[]' <<<"$rj" 2>/dev/null)"$'\n'
    container_names="${container_names}$(jq -r '.services[]? | .container_name // empty' <<<"$rj" 2>/dev/null)"$'\n'
done

# Every stack's .env KEY NAMES (never values).
env_keys=""
for f in "$stacks_dir"/*/.env; do
    [ -f "$f" ] || continue
    # compose env_file loads "KEY=v", "export KEY=v" and indented lines alike.
    env_keys="${env_keys}$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$f")"$'\n'
done

# parse_routes FILE: prints "target lo hi deny" per route (deny "-" = none).
# A malformed line prints "ERR: <line>" and returns 1 (fail closed).
parse_routes() {
    local file="$1" line t range deny lo hi
    [ -f "$file" ] || { echo "ERR: cannot read ${file}"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        set -f; set -- $line; set +f
        [ $# -eq 0 ] && continue
        case "$1" in \#*) continue ;; esac
        if [ $# -ne 3 ]; then echo "ERR: ${line}"; return 1; fi
        t="$1" range="$2" deny="$3"
        if ! [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then echo "ERR: ${line}"; return 1; fi
        lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
        if [ "$deny" != - ] && ! [[ "$deny" =~ ^[0-9]+(,[0-9]+)*$ ]]; then echo "ERR: ${line}"; return 1; fi
        echo "$t $lo $hi $deny"
    done < "$file"
}
route_lines="$(parse_routes "$routes")"; route_rc=$?
route_errs=""; [ "$route_rc" -eq 0 ] || route_errs="$(grep '^ERR:' <<<"$route_lines")"

# Allowlists, shared by invariants 1 and 2. A value is "provably not cxagents" only if
# it matches one of these forms: identities that can never denote a tagged node.
# Anything else (tag:cxagents, *, other autogroups, tagged autogroups, danger-all, host
# aliases, ipsets, IPs and CIDRs) may denote cxagents. Fail closed: a non-string never
# matches.
#   src_ok: autogroup:member|admin|owner|it-admin|network-admin|billing-admin|auditor,
#           group:<name>, or a user login (e.g. cxreiff@github).
#   dst_ok: autogroup:member|self|internet, group:<name>, a user login, or tag:<name>
#           with name not cxagents in any letter case (tag:CXAGENTS reaches cxagents too).
src_ok_def='def src_ok: type == "string" and (
    test("^autogroup:(member|admin|owner|it-admin|network-admin|billing-admin|auditor)$")
    or test("^group:[^[:space:]]+$")
    or test("^[^@[:space:]]+@[^@[:space:]]+$"));'
dst_ok_def='def dst_ok: type == "string" and (
    test("^autogroup:(member|self|internet)$")
    or test("^group:[^[:space:]]+$")
    or test("^[^@[:space:]]+@[^@[:space:]]+$")
    or test("^tag:(?!(?i:cxagents)$)[^[:space:]:]+$"));'

# 1 — every source of a grant, ACL or SSH rule is on the source allowlist. Each
#     offending source is named in the FAIL.
if [ -z "$pol" ]; then
    fail "cxagents invariant 1: policy unreadable (${policy})"
else
    src_bad="$(jq -r "${src_ok_def}"' [(.grants[]?.src[]?), (.acls[]?.src[]?), (.ssh[]?.src[]?)]
        | map(select(src_ok | not)) | .[]' <<<"$pol" 2>/dev/null)"; src_rc=$?
    if [ "$src_rc" -ne 0 ]; then
        fail "cxagents invariant 1: policy sources could not be evaluated (rc=${src_rc})"
    elif [ -z "$src_bad" ]; then
        pass "cxagents invariant 1: every grant, ACL and SSH rule source is an allowlisted identity (autogroup:member, admin, owner, it-admin, network-admin, billing-admin, auditor; group:<name>; a user login)"
    else
        fail "cxagents invariant 1: source(s) outside the allowlist (could be cxagents): $(tr '\n' ' ' <<<"$src_bad")"
    fi
fi

# 2 — every grant whose destination may be cxagents is a tcp ip list whose ranges each
#     sit inside one route and contain none of that route's deny ports. A grant may
#     reach cxagents unless every destination is on dst_ok, so any destination outside
#     that allowlist (tag:cxagents, autogroup:tagged, *, danger-all, IPs, CIDRs, host
#     aliases) selects the grant. ACL destinations: the host part (before the last
#     colon) must be on dst_ok, or the ACL is refused.
inv2_bad=""
if [ -z "$pol" ]; then
    inv2_bad="policy unreadable;"
elif [ "$route_rc" -ne 0 ]; then
    inv2_bad="routes unreadable (${route_errs});"
else
    # A grant with no array dst is not provably safe, so it is selected too (fail closed).
    cx_grants="$(jq -c "${dst_ok_def}"' [.grants[]? | select(((.dst | type) != "array") or ((.dst | length) == 0) or any(.dst[]; dst_ok | not))]' <<<"$pol" 2>/dev/null)"; cx_rc=$?
    [ "$cx_rc" -eq 0 ] || inv2_bad="${inv2_bad} grants could not be evaluated (rc=${cx_rc});"
    acl_bad="$(jq -r "${dst_ok_def}"' [.acls[]?.dst[]? | (if type == "string" then sub(":[^:]*$"; "") else . end) | select(dst_ok | not)] | .[]' <<<"$pol" 2>/dev/null)"; acl_rc=$?
    [ "$acl_rc" -eq 0 ] || inv2_bad="${inv2_bad} ACL destinations could not be evaluated (rc=${acl_rc});"
    [ -z "$acl_bad" ] || inv2_bad="${inv2_bad} ACL destination host(s) outside the allowlist (use a grant): $(tr '\n' ' ' <<<"$acl_bad");"
    # A grant with no ip list, or a non-array one, cannot be checked: refuse it.
    no_ip="$(jq '[.[] | select(((.ip | type) != "array") or ((.ip | length) == 0))] | length' <<<"$cx_grants" 2>/dev/null)"
    [ "${no_ip:-1}" = 0 ] || inv2_bad="${inv2_bad} a grant that may reach tag:cxagents has no ip list;"
    cx_ips="$(jq -r '.[] | .ip[]?' <<<"$cx_grants" 2>/dev/null)"
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if ! [[ "$ip" =~ ^tcp:([0-9]+)(-([0-9]+))?$ ]]; then
            inv2_bad="${inv2_bad} '${ip}' is not tcp:N or tcp:N-M;"; continue
        fi
        a=$((10#${BASH_REMATCH[1]})); b=$a
        [ -n "${BASH_REMATCH[3]:-}" ] && b=$((10#${BASH_REMATCH[3]}))
        [ "$a" -le "$b" ] || { inv2_bad="${inv2_bad} '${ip}' is reversed;"; continue; }
        covered=0
        while read -r t lo hi deny; do
            [ -n "${lo:-}" ] || continue
            if [ "$a" -ge "$lo" ] && [ "$b" -le "$hi" ]; then
                covered=1
                if [ "$deny" != - ]; then
                    for p in $(tr ',' ' ' <<<"$deny"); do
                        if [ "$p" -ge "$a" ] && [ "$p" -le "$b" ]; then
                            inv2_bad="${inv2_bad} '${ip}' includes ${t} deny port ${p};"
                        fi
                    done
                fi
            fi
        done <<<"$route_lines"
        [ "$covered" -eq 1 ] || inv2_bad="${inv2_bad} '${ip}' is not inside one route;"
    done <<<"$cx_ips"
fi
if [ -z "$inv2_bad" ]; then
    pass "cxagents invariant 2: grants that may reach tag:cxagents (any destination outside the allowlist) are tcp ranges inside routes, avoiding deny ports; every ACL destination host is allowlisted"
else
    fail "cxagents invariant 2:${inv2_bad}"
fi

# 3 — forwarder hardening (rendered stacks/cxagents/compose.yaml)
if [ -z "$fwd" ]; then
    fail "cxagents invariant 3: cannot render ${compose}"
elif jq -e '
    (.services.forwarder) as $s
    | ($s != null)
    and ($s.container_name == "cxagents-forwarder")
    and (($s.networks // {}) | keys == ["cxagents"])
    and (.networks.cxagents.name == "cxagents")
    and (($s.ports // []) | length == 0)
    and ($s.network_mode == null)
    and (($s.cap_drop // []) | index("ALL") != null)
    and (($s.security_opt // []) | index("no-new-privileges:true") != null)
    and ($s.read_only == true)
    and ($s.user == "65532:65532")
    and ($s.logging.driver == "json-file")
    and ($s.logging.options."max-size" != null)
    and ($s.logging.options."max-file" != null)
    and (($s.volumes // []) | length == 2)
    and ([$s.volumes[] | select(.type == "volume" and .source == "state" and .target == "/state")] | length == 1)
    and ([$s.volumes[] | select(.type == "bind" and .target == "/etc/forwarder/routes" and .read_only == true
        and ((.source // "") | endswith("/stacks/cxagents/routes")))] | length == 1)
    and (($s.privileged // false) == false)
    and (($s.cap_add // []) | length == 0)
    and (($s.devices // []) | length == 0)
    and ($s.pid == null) and ($s.ipc == null) and ($s.userns_mode == null) and ($s.cgroup == null)
    and (($s.volumes_from // []) | length == 0)
    and (($s.sysctls // {}) | length == 0)
    and (([($s.security_opt // [])[] | select(test("unconfined|disable"))]) | length == 0)
    ' <<<"$fwd" >/dev/null 2>&1; then
    pass "cxagents invariant 3: forwarder is non-root, cap_drop ALL, no privileged/cap_add/host namespaces/devices, no-new-privileges, read-only, unpublished, bounded logs, no volumes_from or sysctls, cxagents network only"
else
    fail "cxagents invariant 3: forwarder hardening differs from the lockdown (${compose})"
fi

# 4 — no auth-key/OAuth key name in any stack .env or compose environment
#     (--no-pat: a leftover PAT line is doctor's WARN, not a lockdown failure)
inv4_bad=""
[ -z "$stack_render_bad" ] || inv4_bad="cannot render${stack_render_bad};"
hits="$(printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | "${repo_root}/tailscale/scripts/keyscan.sh" --names --no-pat)"
krc=$?
case "$krc" in
    0) ;;
    1) inv4_bad="${inv4_bad} credential key name(s) in stack env/compose: $(tr '\n' ' ' <<<"$hits")" ;;
    *) inv4_bad="${inv4_bad} keyscan failed (rc=${krc});" ;;
esac
if [ -z "$inv4_bad" ]; then
    pass "cxagents invariant 4: no auth-key or OAuth key name in any stack .env or compose environment"
else
    fail "cxagents invariant 4:${inv4_bad}"
fi

# 5 — every route target is a container_name in a rendered stack compose
if [ "$route_rc" -ne 0 ]; then
    fail "cxagents invariant 5: routes unreadable (${route_errs})"
else
    unknown=""
    while read -r t lo hi deny; do
        [ -n "${t:-}" ] || continue
        printf '%s\n' "$container_names" | grep -qxF -- "$t" || unknown="${unknown} ${t}"
    done <<<"$route_lines"
    if [ -n "$unknown" ] || [ -n "$stack_render_bad" ]; then
        fail "cxagents invariant 5: route target(s) not a container_name:${unknown}${stack_render_bad:+ (unrendered:${stack_render_bad})}"
    else
        pass "cxagents invariant 5: every route target is a container_name in a stack compose"
    fi
fi

# 6 — routes parse, start at >=1024, stay within 65535, do not overlap, and keep
#     deny ports inside their range
inv6_bad=""
if [ "$route_rc" -ne 0 ]; then
    inv6_bad="unparseable (${route_errs});"
elif [ -z "$route_lines" ]; then
    inv6_bad="no routes;"
else
    while read -r t lo hi deny; do
        [ -n "${t:-}" ] || continue
        if [ "$lo" -lt 1024 ] || [ "$hi" -gt 65535 ] || [ "$lo" -gt "$hi" ]; then
            inv6_bad="${inv6_bad} ${t} ${lo}-${hi} outside 1024-65535;"
        fi
        if [ "$deny" != - ]; then
            for p in $(tr ',' ' ' <<<"$deny"); do
                if [ "$p" -lt "$lo" ] || [ "$p" -gt "$hi" ]; then
                    inv6_bad="${inv6_bad} ${t} deny ${p} outside ${lo}-${hi};"
                fi
            done
        fi
    done <<<"$route_lines"
    overlaps="$(awk '{ t[NR]=$1; lo[NR]=$2; hi[NR]=$3 }
        END { for (i=1;i<=NR;i++) for (j=i+1;j<=NR;j++)
              if (lo[i] <= hi[j] && lo[j] <= hi[i]) print t[i] " overlaps " t[j] }' <<<"$route_lines")"
    [ -z "$overlaps" ] || inv6_bad="${inv6_bad} $(tr '\n' ';' <<<"$overlaps")"
fi
if [ -z "$inv6_bad" ]; then
    pass "cxagents invariant 6: routes parse, start at 1024 or above, do not overlap, deny ports inside their range"
else
    fail "cxagents invariant 6:${inv6_bad}"
fi

# 7 — identity: FORWARDER_HOSTNAME and FORWARDER_TAG, and the tag is declared in tagOwners
if jq -e --argjson p "${pol:-null}" '
    .services.forwarder.environment.FORWARDER_HOSTNAME == "cxagents"
    and .services.forwarder.environment.FORWARDER_TAG == "tag:cxagents"
    and (($p.tagOwners // {}) | has("tag:cxagents"))' <<<"$fwd" >/dev/null 2>&1; then
    pass "cxagents invariant 7: forwarder identity is cxagents / tag:cxagents, declared in tagOwners"
else
    fail "cxagents invariant 7: forwarder FORWARDER_HOSTNAME/FORWARDER_TAG is not cxagents/tag:cxagents, or the tag is not in tagOwners"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
