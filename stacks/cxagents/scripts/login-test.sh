#!/usr/bin/env bash
# stacks/cxagents/scripts/login-test.sh — the login state/device matrix (AC5.5)
# and up's empty-state refusal (AC5.7), against throwaway state volumes.
#
# The copies of cxagents_state hold the node's keys. They are only ever
# (a) copied, by the digest-pinned builder with `cp -a` (ownership kept), and
# (b) read through `check --state-only` (directly or via login.sh). No
# forwarder is ever run on a copy, and the EXIT trap removes every throwaway
# volume. The real cxagents_state is read-only here: a read-only mount in
# the ID checks, and case 2 runs login.sh with CXAGENTS_LOGIN_DRY_RUN=1 so a
# regression that reached the mint step could not write to the real state.
# The fake authkey command only records that it was reached (`minted`).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"
# shellcheck source=../../../tailscale/scripts/lib/conf.sh
source "${cx_repo_root}/tailscale/scripts/lib/conf.sh"
# shellcheck source=../../../stacks/scripts/lib/check.sh
source "${cx_repo_root}/stacks/scripts/lib/check.sh"

login_sh="${SCRIPT_DIR}/login.sh"
up_sh="${SCRIPT_DIR}/up.sh"
api="${cx_repo_root}/tailscale/scripts/api.sh"
real_vol=cxagents_state
empty_vol=cxagents_logintest_empty
copy_vol=cxagents_logintest_copy
corrupt_vol=cxagents_logintest_corrupt
builder="$(sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' "${cx_stack_dir}/forwarder/Dockerfile")"
[ -n "$builder" ] || { echo "login-test: no builder FROM line in forwarder/Dockerfile" >&2; exit 2; }

tmp="$(mktemp -d)"
cleanup() {
    local v users
    for v in "$empty_vol" "$copy_vol" "$corrupt_vol"; do
        users="$(D ps -aq --filter "volume=${v}")"
        [ -z "$users" ] || D rm -f $users >/dev/null 2>&1 || true
        D volume rm "$v" >/dev/null 2>&1 || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

# state_of VOL: `check --state-only` on a read-only mount; prints "state: ..."
state_of() {
    D run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
        -v "$1:/state:ro" "$cx_image" check --state-only 2>/dev/null
}
state_id_of() { state_of "$1" | sed -n 's/^state: node //p'; }

# copy_real_state DEST: fresh copy of cxagents_state (ownership preserved).
copy_real_state() {
    D volume rm "$1" >/dev/null 2>&1 || true
    D run --rm --network none -v "${real_vol}:/from:ro" -v "$1:/to" "$builder" cp -a /from/. /to/
}

# run_login STDIN_FILE [VAR=VAL...] — sets rc; output in $tmp/out and $tmp/err.
rc=0
run_login() {
    local in="$1"; shift
    rc=0
    env CXAGENTS_AUTHKEY_CMD="$fake" CXAGENTS_LOGIN_DRY_RUN=1 "$@" \
        "$login_sh" <"$in" >"$tmp/out" 2>"$tmp/err" || rc=$?
}

# check_case LABEL WANT_RC NEEDLE: rc, a needle in stdout/stderr, and no mint.
check_case() {
    local label="$1" want_rc="$2" needle="$3" why=""
    [ "$rc" = "$want_rc" ] || why="rc=$rc want $want_rc"
    if [ -n "$needle" ] && ! grep -qF -- "$needle" "$tmp/out" "$tmp/err"; then
        why="${why:+$why; }missing output: $needle"
    fi
    [ ! -e "$tmp/minted" ] || why="${why:+$why; }auth key was minted"
    if [ -z "$why" ]; then pass "cxagents-node.AC5.5 ${label}"
    else fail "cxagents-node.AC5.5 ${label} (${why})"; fi
}

: >"$tmp/none"
printf 'n\n' >"$tmp/answer-n"
printf 'y\n' >"$tmp/answer-y"
printf 'YES\n' >"$tmp/answer-YES"
printf '#!/bin/sh\n: > %s\n' "$tmp/minted" >"$tmp/fake-authkey"
chmod 755 "$tmp/fake-authkey"
fake="$tmp/fake-authkey"
printf '{"devices":[]}\n' >"$tmp/no-devices.json"

# Preconditions: a real node in the real state, and the live device list.
real_id="$(state_id_of "$real_vol")"
if [ -z "$real_id" ]; then
    echo "login-test: ${real_vol} holds no node; these cases need the live state" >&2; exit 1
fi
if ! "$api" --client admin GET "/tailnet/${TAILNET}/devices" >"$tmp/devices.json" 2>"$tmp/api.err"; then
    cat "$tmp/api.err" >&2; echo "login-test: cannot read the device list" >&2; exit 1
fi

# Case 1 — image missing: stops before anything else.
rm -f "$tmp/minted"
run_login "$tmp/none" CXAGENTS_IMAGE=tailnet-forwarder:missing
check_case "1 image missing" 1 'run `dotfiles stacks cxagents build`'

# Case 2 — state valid + device present: the real volume and the real API; no-op.
rm -f "$tmp/minted"
run_login "$tmp/none"
check_case "2 state valid + device present" 0 "already logged in as cxagents"

# Case 2b — state owns a device that was renamed on the tailnet.
copy_real_state "$copy_vol" || { echo "login-test: copy failed (2b)" >&2; exit 1; }
jq --arg id "$real_id" --arg n "cxagents-1.${TAILNET_DNS_SUFFIX}" \
    '.devices |= map(if .nodeId == $id then .name = $n else . end)' "$tmp/devices.json" >"$tmp/renamed.json"
rm -f "$tmp/minted"
run_login "$tmp/none" CXAGENTS_STATE_VOLUME="$copy_vol" CXAGENTS_DEVICES_JSON="$tmp/renamed.json"
check_case "2b state owns a renamed device" 1 "not exactly cxagents"

# Case 3 — state empty + device present: stops and prints the device's URL.
rm -f "$tmp/minted"
run_login "$tmp/none" CXAGENTS_STATE_VOLUME="$empty_vol" CXAGENTS_DEVICES_JSON="$tmp/devices.json"
check_case "3 state empty + device present" 1 "https://login.tailscale.com/admin/machines/"
if ! grep -qF "delete it" "$tmp/err"; then fail "cxagents-node.AC5.5 3 state empty + device present (no 'delete it' hint)"; fi

# Case 4 — state present + device missing, declined: the copy keeps its node.
copy_real_state "$copy_vol" || { echo "login-test: copy failed (4)" >&2; exit 1; }
rm -f "$tmp/minted"
run_login "$tmp/answer-n" CXAGENTS_STATE_VOLUME="$copy_vol" CXAGENTS_DEVICES_JSON="$tmp/no-devices.json"
check_case "4 state present + device missing, declined" 1 "aborted; state kept"
if [ "$(state_id_of "$copy_vol")" = "$real_id" ]; then pass "cxagents-node.AC5.5 4 copy still holds ${real_id}"
else fail "cxagents-node.AC5.5 4 copy lost its node after a declined wipe"; fi

# Case 5 — state present + device missing, confirmed: the copy is wiped, the
# real forwarder and the real state are untouched.
copy_real_state "$copy_vol" || { echo "login-test: copy failed (5)" >&2; exit 1; }
rm -f "$tmp/minted"
run_login "$tmp/answer-y" CXAGENTS_STATE_VOLUME="$copy_vol" CXAGENTS_DEVICES_JSON="$tmp/no-devices.json"
check_case "5 state present + device missing, confirmed" 0 "dry run"
copy_state="$(state_of "$copy_vol")"   # check exits 1 on empty state: no pipe under pipefail
if [ "$copy_state" = "state: empty" ]; then pass "cxagents-node.AC5.5 5 copy wiped to state: empty"
else fail "cxagents-node.AC5.5 5 copy not empty after confirmed wipe"; fi
if [ "$(D inspect -f '{{.State.Running}}' cxagents-forwarder 2>/dev/null)" = true ] \
    && [ "$(state_id_of "$real_vol")" = "$real_id" ]; then
    pass "cxagents-node.AC5.5 5 real cxagents-forwarder still running; cxagents_state untouched (${real_id})"
else
    fail "cxagents-node.AC5.5 5 real forwarder not running or real state ID changed"
fi

# Case 5b — the confirmation accepts the usual spellings of yes, not only "y".
copy_real_state "$copy_vol" || { echo "login-test: copy failed (5b)" >&2; exit 1; }
rm -f "$tmp/minted"
run_login "$tmp/answer-YES" CXAGENTS_STATE_VOLUME="$copy_vol" CXAGENTS_DEVICES_JSON="$tmp/no-devices.json"
check_case "5b state present + device missing, confirmed with YES" 0 "dry run"

# Corrupt state: a throwaway volume whose tailscaled.state is not JSON (the
# builder writes it, owned 65532 as the forwarder would). The node in it is
# unreadable, not absent: login and up must say so, and must neither mint nor
# steer the operator to delete a device that may be healthy.
D volume rm "$corrupt_vol" >/dev/null 2>&1 || true
D volume create "$corrupt_vol" >/dev/null
D run --rm --network none -v "${corrupt_vol}:/to" "$builder" \
    sh -c 'printf "{not json" > /to/tailscaled.state && chown -R 65532:65532 /to' >/dev/null

# Case 6a — corrupt state + the node's device on the tailnet: refuse, no "delete it".
rm -f "$tmp/minted"
run_login "$tmp/none" CXAGENTS_STATE_VOLUME="$corrupt_vol" CXAGENTS_DEVICES_JSON="$tmp/devices.json"
check_case "6a corrupt state + device present" 1 "cannot read state in ${corrupt_vol}"
if grep -qF "delete it" "$tmp/err"; then fail "cxagents-node.AC5.5 6 corrupt state + device present (steers deleting a device)"; fi

# Case 6b — corrupt state + no device: refuse, do not mint onto unreadable state.
rm -f "$tmp/minted"
run_login "$tmp/none" CXAGENTS_STATE_VOLUME="$corrupt_vol" CXAGENTS_DEVICES_JSON="$tmp/no-devices.json"
check_case "6b corrupt state + no device" 1 "cannot read state in ${corrupt_vol}"

# Case 6c — AC5.7: up refuses on corrupt state, says so, and starts no container.
before="$(D ps -aq | sort)"
rc=0
env CXAGENTS_STATE_VOLUME="$corrupt_vol" "$up_sh" >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
after="$(D ps -aq | sort)"
if [ "$rc" = 1 ] && grep -qF "cannot read state in ${corrupt_vol}" "$tmp/err" && [ "$before" = "$after" ]; then
    pass "cxagents-node.AC5.7 up refuses on corrupt state (rc=1), says it cannot read state, no container started"
else
    fail "cxagents-node.AC5.7 up on corrupt state (rc=$rc, containers changed: $([ "$before" = "$after" ] && echo no || echo yes))"
fi

# Case 6d — AC5.7: up refuses on empty state and starts no container.
before="$(D ps -aq | sort)"
rc=0
env CXAGENTS_STATE_VOLUME="$empty_vol" "$up_sh" >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
after="$(D ps -aq | sort)"
if [ "$rc" = 1 ] && grep -qF 'run `dotfiles stacks cxagents login`' "$tmp/err" && [ "$before" = "$after" ]; then
    pass "cxagents-node.AC5.7 up refuses on empty state (rc=1), no container started"
else
    fail "cxagents-node.AC5.7 up on empty state (rc=$rc, containers changed: $([ "$before" = "$after" ] && echo no || echo yes))"
fi

[ "$__check_failed" -eq 0 ] || exit 1
