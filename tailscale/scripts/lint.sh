#!/bin/bash
# tailscale/scripts/lint.sh — static invariants on the tailnet policy.
# Usage: lint.sh [--file F]   (default tailscale/policy.hujson)
# Exit: 0 all pass; 1 any FAIL; 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

file="${SCRIPT_DIR}/../policy.hujson"
while [ $# -gt 0 ]; do
    case "$1" in
        --file) file="$2" ;;
        *) echo "lint: unknown argument $1" >&2; exit 2 ;;
    esac
    shift 2
done

j="$(perl "${SCRIPT_DIR}/lib/hujson2json.pl" < "$file" 2>/dev/null | jq -c . 2>/dev/null)"
if [ -z "$j" ]; then
    fail "policy invariant 0: ${file} does not parse as HuJSON"
    exit 1
fi
pass "policy invariant 0: parses"
pj() { jq -e "$1" <<<"$j" >/dev/null 2>&1; }

# 1 — no grant or ACL source is "*", a tag, or autogroup:tagged
if pj '[(.grants[]?.src[]?), (.acls[]?.src[]?)]
       | all(. != "*" and . != "autogroup:tagged" and (startswith("tag:") | not))'; then
    pass "policy invariant 1: no *, tag or autogroup:tagged grant/ACL source"
else
    fail "policy invariant 1: a grant/ACL source is *, a tag, or autogroup:tagged"
fi

# 2 — every tag referenced anywhere is declared in tagOwners
undeclared="$(jq -r '((.tagOwners // {}) | keys) as $own
    | [.. | strings | select(test("^tag:[A-Za-z0-9-]+")) | capture("^(?<t>tag:[A-Za-z0-9-]+)").t]
    | unique - $own | join(" ")' <<<"$j")"
if [ -z "$undeclared" ]; then
    pass "policy invariant 2: every used tag is in tagOwners"
else
    fail "policy invariant 2: tags not in tagOwners: ${undeclared}"
fi

# 3 — policy tests present (they guard against lockout at validate time)
if pj '(.tests | type == "array" and length > 0)'; then
    pass "policy invariant 3: tests present"
else
    fail "policy invariant 3: no policy tests"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
