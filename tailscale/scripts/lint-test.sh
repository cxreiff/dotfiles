#!/bin/bash
# tailscale/scripts/lint-test.sh — proves each policy lint invariant fails on a
# fixture that violates exactly that invariant. Fixtures are generated in a
# trap-cleaned temp dir from the real tailscale/policy.hujson.
# Exit: 0 all fixtures pass; 1 any fixture failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lint="${SCRIPT_DIR}/lint.sh"
policy="${SCRIPT_DIR}/../policy.hujson"
hujson2json="${SCRIPT_DIR}/lib/hujson2json.pl"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0

pass_fixture() { echo "PASS lint-fixture $1"; }
fail_fixture() { echo "FAIL lint-fixture $1: $2" >&2; failures=$((failures + 1)); }

# mk NAME JQ_FILTER -> $tmp/NAME.json = base policy with the filter applied
mk() {
    if ! jq "$2" "$tmp/base.json" > "$tmp/$1.json" 2>/dev/null; then
        fail_fixture "$1" "jq fixture filter failed"; return 1
    fi
}

# expect_only LABEL PREFIX FILE [lint args...]: exactly one FAIL, whose text starts with PREFIX
expect_only() {
    local label="$1" prefix="$2" file="$3" out nfail
    out="$("$lint" --file "$file" 2>&1 || true)"
    nfail="$(grep -c '^\[FAIL\]' <<<"$out" || true)"
    if [ "$nfail" -eq 1 ] && grep -q "^\[FAIL\] ${prefix}" <<<"$out"; then
        pass_fixture "$label"
    else
        fail_fixture "$label" "expected only '${prefix}' to FAIL"; echo "$out" >&2
    fi
}

# expect_none LABEL FILE: lint passes with no FAIL
expect_none() {
    local label="$1" file="$2" out rc
    out="$("$lint" --file "$file" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q '^\[FAIL\]' <<<"$out"; then
        pass_fixture "$label"
    else
        fail_fixture "$label" "expected no FAIL (rc=${rc})"; echo "$out" >&2
    fi
}

if [ ! -f "$policy" ]; then
    echo "FAIL lint-fixture baseline: ${policy} missing (dotfiles tailscale policy-pull)" >&2
    exit 1
fi
perl "$hujson2json" < "$policy" > "$tmp/base.json" || { echo "FAIL lint-fixture baseline: cannot convert policy" >&2; exit 1; }

# Baseline: the real policy passes every invariant
expect_none baseline "$policy"

# Invariant 0: unparseable
printf '{ "grants": [ ' > "$tmp/inv0-unparseable.hujson"
expect_only inv0-unparseable 'policy invariant 0:' "$tmp/inv0-unparseable.hujson"

# Invariant 1: * / tag / autogroup:tagged grant or ACL sources
mk inv1-star-src '.grants += [{"src":["*"],"dst":["*"],"ip":["*"]}]' && \
    expect_only inv1-star-src 'policy invariant 1:' "$tmp/inv1-star-src.json"
mk inv1-tag-src '.tagOwners["tag:x"] = ["autogroup:admin"] | .grants += [{"src":["tag:x"],"dst":["autogroup:member"],"ip":["*"]}]' && \
    expect_only inv1-tag-src 'policy invariant 1:' "$tmp/inv1-tag-src.json"
mk inv1-tagged-src '.grants += [{"src":["autogroup:tagged"],"dst":["autogroup:member"],"ip":["*"]}]' && \
    expect_only inv1-tagged-src 'policy invariant 1:' "$tmp/inv1-tagged-src.json"
mk inv1-acl-star '.acls = [{"action":"accept","src":["*"],"dst":["*:*"]}]' && \
    expect_only inv1-acl-star 'policy invariant 1:' "$tmp/inv1-acl-star.json"

# Invariant 2: used tag not declared in tagOwners
mk inv2-undeclared '.grants += [{"src":["autogroup:member"],"dst":["tag:nope"],"ip":["*"]}]' && \
    expect_only inv2-undeclared 'policy invariant 2:' "$tmp/inv2-undeclared.json"

# Invariant 3: no policy tests
mk inv3-no-tests 'del(.tests)' && \
    expect_only inv3-no-tests 'policy invariant 3:' "$tmp/inv3-no-tests.json"

# HuJSON features: comments (line and block, with quotes/commas inside) must not change the verdict
perl -0pe 's/\{/{\n\t\/\/ a "quoted", comment,\n\t\/* block *\/\n/' "$policy" > "$tmp/hujson-features.hujson"
expect_none hujson-features "$tmp/hujson-features.hujson"

# HuJSON strings: the filter keeps string contents verbatim and drops trailing commas
if printf '{"a": ["http://x",],}' | perl "$hujson2json" | jq -e '.a == ["http://x"]' >/dev/null 2>&1; then
    pass_fixture hujson-strings
else
    fail_fixture hujson-strings "filter mangled a string or kept a trailing comma"
fi

# Policy equality (policy.sh same-policy, the reformat-adoption predicate in push).
# expect_same LABEL yes|no FILE_A FILE_B: same-policy exits 0 for yes, 1 for no.
expect_same() {
    local label="$1" want="$2" rc=0
    "$policy_sh" --file "$3" same-policy "$4" >/dev/null 2>&1 || rc=$?
    if { [ "$want" = yes ] && [ "$rc" -eq 0 ]; } || { [ "$want" = no ] && [ "$rc" -eq 1 ]; }; then
        pass_fixture "$label"
    else
        fail_fixture "$label" "expected same-policy ${want} (rc=${rc})"
    fi
}
policy_sh="${SCRIPT_DIR}/policy.sh"

expect_same same-policy-identical yes "$policy" "$policy"

# (a) reformatted copy: tab-indented, layout changed, plus a leading comment -> equal
{ printf '%s\n' '// reformatted copy'; jq --tab . "$tmp/base.json"; } > "$tmp/reformatted.hujson"
expect_same same-policy-reformatted yes "$policy" "$tmp/reformatted.hujson"

# (b) one grant changed -> unequal
mk grant-changed '.grants[0].ip = ["203.0.113.7:9"]' && \
    expect_same same-policy-grant-changed no "$policy" "$tmp/grant-changed.json"

# (c) unparseable -> unequal, fail closed (also when both sides are unparseable)
printf '{ "grants": [ ' > "$tmp/unparseable.hujson"
expect_same same-policy-unparseable no "$policy" "$tmp/unparseable.hujson"
expect_same same-policy-unparseable-both no "$tmp/unparseable.hujson" "$tmp/unparseable.hujson"

# Empty files never compare equal (an empty conversion is not a policy)
: > "$tmp/empty.hujson"
expect_same same-policy-empty-both no "$tmp/empty.hujson" "$tmp/empty.hujson"

# Scripts that hold OAuth tokens or minted auth keys must not use here-strings:
# bash 3.2 writes them to a temp file under /var/tmp.
if grep -n '<<<' "${SCRIPT_DIR}/api.sh" "${SCRIPT_DIR}/authkey.sh"; then
    echo "FAIL lint-fixture no-here-strings (api.sh/authkey.sh)"; failures=$((failures + 1))
else
    echo "PASS lint-fixture no-here-strings"
fi

# Key-name scan (keyscan.sh --repo) fixtures: every name form is flagged.
"${SCRIPT_DIR}/keyscan-test.sh" || failures=$((failures + 1))

if [ "$failures" -eq 0 ]; then
    echo "All fixtures passed"
    exit 0
fi
echo "${failures} fixture(s) failed" >&2
exit 1
