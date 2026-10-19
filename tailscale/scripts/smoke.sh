#!/usr/bin/env bash
# tailscale/scripts/smoke.sh — live checks against the tailnet. NEVER changes
# the live policy. Every push below is declined at a prompt, stopped by lint or
# validate, or sent with a stale If-Match (TS_POLICY_TEST_STALE_ETAG=1 -> 412).
# The live ETag is captured at start and asserted unchanged after every check.
# Temporary repos for push checks live under the temp dir (trap-cleaned).
# Exit: 0 all pass; 1 any FAIL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${ts_root}/.." && pwd)"
# shellcheck source=../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"
# shellcheck source=lib/conf.sh
source "${SCRIPT_DIR}/lib/conf.sh"

api="${SCRIPT_DIR}/api.sh"
policy="${SCRIPT_DIR}/policy.sh"
tmp="$(mktemp -d)"
# Id of an auth key minted by check_ac5_2 and not yet deleted. The EXIT trap deletes
# it, so a failed assertion still leaves nothing live behind. The key value itself
# is never stored in a variable that outlives its check.
minted_id=""
cleanup() {
    if [ -n "$minted_id" ]; then
        "$api" --client authkeys --tags tag:cxagents DELETE "/tailnet/${TAILNET}/keys/${minted_id}" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

# Live ETag (quotes stripped); empty if the API call fails.
live_etag() {
    if ! "$api" GET "/tailnet/${TAILNET}/acl" -H 'Accept: application/hujson' -D "$tmp/etag.hdr" >/dev/null 2>&1; then
        echo ""; return 0
    fi
    sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' "$tmp/etag.hdr" | tr -d '\r"' | tail -1 || true
}

ETAG0="$(live_etag)"
if [ -z "$ETAG0" ]; then echo "smoke: could not read the live ETag at start; aborting" >&2; exit 1; fi

# live_ok LABEL OK DETAIL: PASS only if OK=1 and the live ETag still equals ETAG0.
live_ok() {
    local now
    now="$(live_etag)"
    if [ "$now" != "$ETAG0" ]; then
        fail "$1 (live policy changed during smoke — run policy-diff)"; return 0
    fi
    if [ "$2" -eq 1 ]; then pass "$1"; else fail "$1 ($3)"; fi
}

# json_edit IN FILTER OUT: HuJSON -> JSON, then jq FILTER into OUT.
json_edit() {
    perl "${SCRIPT_DIR}/lib/hujson2json.pl" < "$1" | jq "$2" >"$3"
}

# commit_repo DIR: DIR becomes a git repo whose only commit is DIR/policy.hujson.
commit_repo() {
    git -C "$1" init -q
    git -C "$1" add policy.hujson
    git -C "$1" -c user.name=smoke -c user.email=smoke@localhost -c commit.gpgsign=false commit -q -m smoke
}

# prepend FILE LINE: put LINE before the policy body. A comment on the file's last
# line is rejected by Tailscale's validator ("parsing comment: unexpected EOF"),
# so the fixture comments go in front, where they change the bytes but not the policy.
prepend() {
    { printf '%s\n' "$2"; cat "$1"; } >"$1.new" && mv "$1.new" "$1"
}

# mkrepo DIR: DIR/policy.hujson = live bytes, committed (live is in the lineage).
# Returns 1 if the pull fails; callers report that as a FAIL line.
mkrepo() {
    mkdir -p "$1"
    "$policy" --file "$1/policy.hujson" pull >/dev/null 2>&1 || return 1
    commit_repo "$1"
}

check_ac2_1() {
    local ok=0
    if "$api" --client admin GET /tailnet/-/dns/nameservers >"$tmp/ns.json" 2>"$tmp/ns.err" \
        && jq -e '.dns|type=="array"' "$tmp/ns.json" >/dev/null 2>&1; then ok=1; fi
    live_ok "AC2.1 (admin client reads DNS nameservers)" "$ok" "$(cat "$tmp/ns.err" 2>/dev/null)"
}

check_ac2_2() {
    local ok=1 rc out secret f
    f="$tmp/missing.env"
    printf 'TS_ADMIN_CLIENT_ID=CHANGE_ME\nTS_ADMIN_CLIENT_SECRET=CHANGE_ME\n' >"$tmp/placeholder.env"
    printf 'TS_OAUTH_CLIENT_ID=x\nTS_OAUTH_CLIENT_SECRET=y\n' >"$tmp/deprecated.env"

    # (a) missing file, (b) placeholder credentials: exit 2, hint names tailscale/.env.example
    for f in "$tmp/missing.env" "$tmp/placeholder.env"; do
        rc=0; out="$(TAILSCALE_ENV_FILE="$f" "$api" GET /tailnet/-/devices 2>&1 >/dev/null)" || rc=$?
        [ "$rc" -eq 2 ] || ok=0
        grep -qF 'tailscale/.env.example' <<<"$out" || ok=0
    done
    # (c) deprecated OAuth names: exit 2, message names TS_ADMIN_CLIENT_ID
    rc=0; out="$(TAILSCALE_ENV_FILE="$tmp/deprecated.env" "$api" GET /tailnet/-/devices 2>&1 >/dev/null)" || rc=$?
    [ "$rc" -eq 2 ] || ok=0
    grep -qF 'TS_ADMIN_CLIENT_ID' <<<"$out" || ok=0

    # Real .env: a successful call and --granted-scopes must not print the secret or a tskey- value.
    # The secret is read into a variable only to prove it is absent from output; it is never printed.
    secret="$(sed -n 's/^TS_ADMIN_CLIENT_SECRET=//p' "$ts_root/.env" 2>/dev/null | tail -1)" || secret=""
    if [ -z "$secret" ]; then
        ok=0
    else
        rc=0; "$api" --client admin GET /tailnet/-/devices >"$tmp/dev.out" 2>"$tmp/dev.err" || rc=$?
        [ "$rc" -eq 0 ] || ok=0
        rc=0; "$api" --client admin --granted-scopes >"$tmp/scopes.out" 2>"$tmp/scopes.err" || rc=$?
        [ "$rc" -eq 0 ] || ok=0
        # The secret is fed to grep through a file descriptor, never on argv.
        for f in "$tmp/dev.out" "$tmp/dev.err" "$tmp/scopes.out" "$tmp/scopes.err"; do
            if grep -qF -f <(printf '%s\n' "$secret") "$f" || grep -qF 'tskey-' "$f"; then ok=0; fi
        done
    fi
    unset secret
    live_ok "AC2.2 (env fixtures refused; secret and tskey- absent from output)" "$ok" "see api.sh output checks"
}

check_ac2_3() {
    local rc=0 ok=0
    "$api" --client admin GET /tailnet/-/keys >/dev/null 2>"$tmp/keys.err" || rc=$?
    if [ "$rc" -eq 3 ] && grep -qF 'HTTP 403' "$tmp/keys.err"; then ok=1; fi
    live_ok "AC2.3 (admin client cannot list auth keys: HTTP 403)" "$ok" "rc=$rc"
}

check_ac2_5() {
    local mode ok=1 ks rc=0
    mode="$(stat -L -f %Lp "$ts_root/.env" 2>/dev/null || echo none)"
    [ "$mode" = 600 ] || ok=0
    git -C "$repo_root" check-ignore -q tailscale/.env || ok=0
    ks="$("${SCRIPT_DIR}/keyscan.sh" --repo 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || ok=0
    live_ok "AC2.5 (.env mode 600, gitignored, keyscan clean)" "$ok" "mode=$mode keyscan rc=$rc: $ks"
}

check_ac1_6() {
    local ok=1 rc=0 out d
    out="$("$policy" diff 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && [ -z "$out" ] || ok=0
    d="$tmp/d.hujson"
    cp "$ts_root/policy.hujson" "$d"
    printf '// smoke diff\n' >>"$d"
    rc=0; out="$("$policy" --file "$d" diff 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || ok=0
    case "$out" in "--- live (${TAILNET})"*) ;; *) ok=0 ;; esac
    grep -qF '+// smoke diff' <<<"$out" || ok=0
    live_ok "AC1.6 (policy diff: identical is silent; a repo edit shows as a unified diff)" "$ok" "rc=$rc"
}

check_ac1_1() {
    local d="$tmp/pull" ok=1 st=""
    mkdir -p "$d"
    "$policy" --file "$d/p.hujson" pull >/dev/null 2>&1 || ok=0
    [ -f "$d/p.hujson" ] || ok=0
    if [ "$ok" -eq 1 ]; then
        "$api" GET "/tailnet/${TAILNET}/acl" -H 'Accept: application/hujson' >"$d/fresh.hujson" 2>/dev/null || ok=0
        cmp -s "$d/p.hujson" "$d/fresh.hujson" || ok=0
        st="$("$policy" --file "$d/p.hujson" status 2>&1)" || ok=0
        [ "$st" = in-sync ] || ok=0
    fi
    live_ok "AC1.1 (pull writes live bytes; status in-sync)" "$ok" "status=$st"
}

check_ac1_2() {
    local d="$tmp/pull" ok=1 before after rc=0
    [ -f "$d/p.hujson" ] || ok=0
    before="$(shasum -a 256 "$d/p.hujson" 2>/dev/null | cut -d' ' -f1)" || before=""
    "$policy" --file "$d/p.hujson" pull >/dev/null 2>&1 || rc=$?
    after="$(shasum -a 256 "$d/p.hujson" 2>/dev/null | cut -d' ' -f1)" || after=""
    [ "$rc" -ne 0 ] || ok=0
    [ "$before" = "$after" ] || ok=0
    live_ok "AC1.2 (pull refuses to overwrite without --force)" "$ok" "rc=$rc"
}

check_ac1_3() {
    local sha st="" rc=0 ok=1
    sha="$(shasum -a 256 "$ts_root/policy.hujson" 2>/dev/null | cut -d' ' -f1)" || sha=""
    [ "$ETAG0" = "$sha" ] || ok=0
    st="$("$policy" status 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && [ "$st" = in-sync ] || ok=0
    live_ok "AC1.3 (live ETag == sha256 of repo policy; status in-sync)" "$ok" "etag=$ETAG0 sha=$sha status=$st"
}

check_ac1_5_lint() {
    local d="$tmp/lint" ok=0 rc=0 out
    mkrepo "$d" || { fail "AC1.5 (lint fixture: policy.sh pull failed)"; return 0; }
    json_edit "$d/policy.hujson" '.grants += [{"src":["*"],"dst":["autogroup:member"],"ip":["*"]}]' "$d/p.json" \
        || { fail "AC1.5 (lint fixture: edit failed)"; return 0; }
    mv "$d/p.json" "$d/policy.hujson"
    # stdin is /dev/null: if lint ever passed, the prompt aborts instead of pushing.
    out="$("$policy" --file "$d/policy.hujson" push 2>&1 </dev/null)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'lint failed; not pushing' <<<"$out"; then ok=1; fi
    live_ok "AC1.5 (lint stops a * grant source before any push)" "$ok" "rc=$rc"
}

check_ac1_5_validate() {
    local d="$tmp/validate" ok=0 rc=0 out
    mkrepo "$d" || { fail "AC1.5/AC1.7 (validate fixture: policy.sh pull failed)"; return 0; }
    json_edit "$d/policy.hujson" '.grants |= map(select(((.src == ["autogroup:member"]) and (.dst == ["autogroup:member"])) | not))' "$d/p.json" \
        || { fail "AC1.5/AC1.7 (validate fixture: edit failed)"; return 0; }
    mv "$d/p.json" "$d/policy.hujson"
    # stdin is /dev/null: if validate ever passed, the prompt aborts instead of pushing.
    out="$("$policy" --file "$d/policy.hujson" push 2>&1 </dev/null)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'validate failed; not pushing' <<<"$out"; then ok=1; fi
    live_ok "AC1.5/AC1.7 (validate runs the policy tests and stops a member lockout)" "$ok" "rc=$rc"
}

check_ac1_4() {
    local d="$tmp/stale" ok=0 rc=0 out
    mkrepo "$d" || { fail "AC1.4 (stale fixture: policy.sh pull failed)"; return 0; }
    prepend "$d/policy.hujson" '// smoke'
    # Stale If-Match (all-zero) -> Tailscale returns 412; the POST is refused by the API.
    out="$(printf 'y\n' | TS_POLICY_TEST_STALE_ETAG=1 "$policy" --file "$d/policy.hujson" push 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'live policy changed; run policy-diff' <<<"$out"; then ok=1; fi
    live_ok "AC1.4 (stale If-Match is refused with 412; live untouched)" "$ok" "rc=$rc"
}

check_ac1_8_refuse() {
    local d="$tmp/refuse" ok=0 rc=0 out
    mkdir -p "$d"
    "$policy" --file "$d/policy.hujson" pull >/dev/null 2>&1 \
        || { fail "AC1.8 (refuse fixture: policy.sh pull failed)"; return 0; }
    # The only commit is NOT live: live plus a line, so live matches no committed version.
    prepend "$d/policy.hujson" '// other lineage'
    commit_repo "$d"
    prepend "$d/policy.hujson" '// edit again'
    # stdin is /dev/null: if the lineage check ever passed, the prompt aborts instead of pushing.
    out="$("$policy" --file "$d/policy.hujson" push 2>&1 </dev/null)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'matches no committed version' <<<"$out" && grep -qF -- '--init' <<<"$out"; then ok=1; fi
    live_ok "AC1.8 (plain push refuses when live is not in the repo lineage)" "$ok" "rc=$rc"
}

check_ac1_8_init() {
    local d="$tmp/init" ok=0 rc=0 out
    mkdir -p "$d"
    "$policy" --file "$d/policy.hujson" pull >/dev/null 2>&1 \
        || { fail "AC1.8 (init fixture: policy.sh pull failed)"; return 0; }
    prepend "$d/policy.hujson" '// other lineage'
    commit_repo "$d"
    prepend "$d/policy.hujson" '// edit again'
    # Shows the diff and the WITHOUT If-Match prompt; answer n, so nothing is pushed.
    out="$(printf 'n\n' | "$policy" --file "$d/policy.hujson" push --init 2>&1)" || rc=$?
    if [ "$rc" -eq 1 ] && grep -qF 'WITHOUT If-Match (--init)' <<<"$out" && grep -qF 'aborted; nothing pushed' <<<"$out"; then ok=1; fi
    live_ok "AC1.8 (push --init shows the diff and aborts on n)" "$ok" "rc=$rc"
}

# rejected FILE: 0 only if Tailscale's validate refuses FILE (HTTP non-2xx, or 200
# with a non-empty .message). A credential problem (exit 2) counts as not rejected.
rejected() {
    local rc=0
    "$api" POST "/tailnet/${TAILNET}/acl/validate" -H 'Content-Type: application/hujson' \
        --data-binary "@$1" >"$tmp/vbody" 2>"$tmp/verr" || rc=$?
    case "$rc" in
        3) return 0 ;;
        0) [ -n "$(jq -r '.message // empty' "$tmp/vbody" 2>/dev/null)" ] ;;
        *) return 1 ;;
    esac
}

check_ac1_7_cxagents() {
    local d="$tmp/cx" ok=1 rc=0 out
    mkdir -p "$d"
    # (a) the cxagents grant removed: validate must reject (accept tag:cxagents:5173 fails).
    json_edit "$ts_root/policy.hujson" '.grants |= map(select((.dst == ["tag:cxagents"]) | not))' "$d/a.json" || ok=0
    # (b) the cxagents grant widened to every port: validate must reject (deny tag:cxagents:3100 fails).
    json_edit "$ts_root/policy.hujson" '.grants |= map(if .dst == ["tag:cxagents"] then .ip = ["tcp:1024-65535"] else . end)' "$d/b.json" || ok=0
    if [ "$ok" -eq 1 ]; then
        rejected "$d/a.json" || ok=0
        rejected "$d/b.json" || ok=0
    fi
    # (c) a tag as grant source: lint rejects it before any validate or push. tagOwners stays intact.
    if mkrepo "$d/c"; then
        json_edit "$d/c/policy.hujson" '.grants += [{"src":["tag:cxagents"],"dst":["autogroup:member"],"ip":["*"]}]' "$d/c/p.json" \
            && mv "$d/c/p.json" "$d/c/policy.hujson" || ok=0
        # stdin is /dev/null: if lint ever passed, the prompt aborts instead of pushing.
        out="$("$policy" --file "$d/c/policy.hujson" push 2>&1 </dev/null)" || rc=$?
        if [ "$rc" -eq 1 ] && grep -qF 'lint failed; not pushing' <<<"$out"; then :; else ok=0; fi
    else
        ok=0
    fi
    live_ok "AC1.7 (cxagents grant removed or widened fails validate; tag grant source fails lint)" "$ok" "rc=$rc"
}

check_ac2_4() {
    local ok=1 rc=0 zero detail acl_path="/tailnet/${TAILNET}/acl"
    # Writes are refused for the authkeys client. The all-zero If-Match means nothing
    # can be stored even if the scope were wrongly accepted: that would be 412, not 2xx.
    # Refusal is HTTP 403 or 404: the API answers 404 for ACL and DNS paths outside the
    # client's scopes (reads too), while the same paths answer 200 to the admin client.
    # Any other code (412, 2xx) is a FAIL.
    # 404 is also the API's generic answer for a nonexistent path, so the ACL path must
    # first be proven to exist: an admin GET on the same path string must succeed. If it
    # does not, FAIL without posting.
    zero="$(printf '%064d' 0)"
    if "$api" --client admin GET "$acl_path" -H 'Accept: application/hujson' >/dev/null 2>"$tmp/acl4.admin.err"; then
        rc=0
        "$api" --client authkeys --tags tag:cxagents POST "$acl_path" \
            -H 'Content-Type: application/hujson' -H "If-Match: \"${zero}\"" \
            --data-binary "@${ts_root}/policy.hujson" >/dev/null 2>"$tmp/acl4.err" || rc=$?
        if [ "$rc" -eq 3 ] && grep -qE 'HTTP (403|404)' "$tmp/acl4.err"; then :; else ok=0; fi
        detail="acl rc=$rc $(cat "$tmp/acl4.err" 2>/dev/null)"
    else
        ok=0; detail="acl admin GET failed, no ACL POST sent: $(cat "$tmp/acl4.admin.err" 2>/dev/null)"
    fi
    # DNS: re-send the current nameserver list, so a wrongly accepted call changes nothing.
    # If the admin read fails, FAIL without posting.
    if "$api" --client admin GET "/tailnet/${TAILNET}/dns/nameservers" >"$tmp/ns4.json" 2>/dev/null \
        && jq -e '.dns|type=="array"' "$tmp/ns4.json" >/dev/null 2>&1; then
        rc=0
        "$api" --client authkeys --tags tag:cxagents POST "/tailnet/${TAILNET}/dns/nameservers" \
            -H 'Content-Type: application/json' -d "{\"dns\":$(jq -c .dns "$tmp/ns4.json")}" \
            >/dev/null 2>"$tmp/dns4.err" || rc=$?
        if [ "$rc" -eq 3 ] && grep -qE 'HTTP (403|404)' "$tmp/dns4.err"; then :; else ok=0; fi
        detail="$detail; dns rc=$rc $(cat "$tmp/dns4.err" 2>/dev/null)"
    else
        ok=0; detail="$detail; admin DNS read failed, no DNS POST sent"
    fi
    live_ok "AC2.4 (authkeys client refused (403/404, never 412 or 2xx) on ACL and DNS nameserver writes)" "$ok" "$detail"
}

# epoch RFC3339: UTC epoch seconds (fractional seconds stripped; macOS date).
epoch() {
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s
}

check_ac5_2() {
    local key="" id="" rc=0 ok=1 dur=-1 c e ce ee
    key="$("${SCRIPT_DIR}/authkey.sh" tag:cxagents 2>"$tmp/ak.err")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$key" ]; then
        live_ok "AC5.2 (authkey.sh mints a key)" 0 "rc=$rc $(cat "$tmp/ak.err" 2>/dev/null)"
        return 0
    fi
    id="$(printf '%s' "$key" | cut -d- -f3)"
    unset key
    minted_id="$id"   # registered for the EXIT-trap DELETE before any assertion
    rc=0
    "$api" --client authkeys --tags tag:cxagents GET "/tailnet/${TAILNET}/keys/${id}" >"$tmp/key.json" 2>"$tmp/kget.err" || rc=$?
    [ "$rc" -eq 0 ] || ok=0
    jq -e '.capabilities.devices.create.reusable == false
        and .capabilities.devices.create.ephemeral == false
        and .capabilities.devices.create.preauthorized == true
        and .capabilities.devices.create.tags == ["tag:cxagents"]' "$tmp/key.json" >/dev/null 2>&1 || ok=0
    c="$(jq -r '.created // empty' "$tmp/key.json" 2>/dev/null)"
    e="$(jq -r '.expires // empty' "$tmp/key.json" 2>/dev/null)"
    ce="" ee=""
    if [ -n "$c" ] && [ -n "$e" ]; then
        ce="$(epoch "$c" 2>/dev/null)" && ee="$(epoch "$e" 2>/dev/null)" && dur=$((ee - ce))
    fi
    [ "$dur" -ge 0 ] && [ "$dur" -le 600 ] || ok=0
    # Delete, then the key must read as revoked/invalid (a GET after DELETE is 200, not 404).
    rc=0
    "$api" --client authkeys --tags tag:cxagents DELETE "/tailnet/${TAILNET}/keys/${id}" >/dev/null 2>"$tmp/kdel.err" || rc=$?
    if [ "$rc" -eq 0 ]; then
        minted_id=""
        "$api" --client authkeys --tags tag:cxagents GET "/tailnet/${TAILNET}/keys/${id}" >"$tmp/key2.json" 2>/dev/null \
            && jq -e '.invalid == true and .revoked != null' "$tmp/key2.json" >/dev/null 2>&1 || ok=0
    else
        ok=0
    fi
    live_ok "AC5.2 (minted key is single-use, pre-authorized, non-ephemeral, <=600 s; deleted and revoked)" "$ok" "dur=${dur}s delete rc=${rc}"
}

# Run all checks (live-touching checks end in live_ok, which asserts the live ETag is unchanged)
check_ac2_1
check_ac2_2
check_ac2_3
check_ac2_5
check_ac1_6
check_ac1_1
check_ac1_2
check_ac1_3
check_ac1_5_lint
check_ac1_5_validate
check_ac1_4
check_ac1_8_refuse
check_ac1_8_init
check_ac1_7_cxagents
check_ac2_4
check_ac5_2

[ "$__check_failed" -eq 0 ] || exit 1
