#!/usr/bin/env bash
# stacks/cxagents/scripts/doctor-test.sh — proves each cxagents doctor FAIL path
# (AC4.5) with fixtures. Each case runs scripts/doctor.sh with seams and asserts
# on its output. The real node is never touched: the forwarder is never stopped
# (the "forwarder stopped" case names a container that does not exist), the
# state volume is only ever read through a read-only mount, and the throwaway
# volume cxagents_doctortest_empty is removed by the EXIT trap. The "missing
# volume" case proves doctor created nothing.
#
# The problem strings in the fake `check` outputs are copied from
# stacks/cxagents/forwarder/internal/check/check.go.
#
# Exit: 0 all fixtures pass; 1 any fixture failed; 2 the agents VM is not running.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"

doctor="${SCRIPT_DIR}/doctor.sh"
empty_vol=cxagents_doctortest_empty
absent_vol=cxagents_doctortest_absent
missing_container=cxagents-doctortest-missing

tmp="$(mktemp -d)"
cleanup() {
    D volume rm "$empty_vol" >/dev/null 2>&1 || true
    D volume rm "$absent_vol" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

failures=0
pass_fixture() { echo "PASS doctor-fixture $1"; }
fail_fixture() { echo "FAIL doctor-fixture $1: $2" >&2; failures=$((failures + 1)); }

if ! D info >/dev/null 2>&1; then
    echo "doctor-test: colima-agents is not running (start it: dotfiles stacks vm-agents-up)" >&2
    exit 2
fi
if D volume inspect "$absent_vol" >/dev/null 2>&1; then
    echo "doctor-test: ${absent_vol} exists; remove it before running" >&2
    exit 2
fi
D volume create "$empty_vol" >/dev/null || { echo "doctor-test: cannot create ${empty_vol}" >&2; exit 2; }

# run ARGS...: doctor with ARGS (VAR=value) as overrides, inherited seams cleared.
# Output (stdout+stderr) lands in $out.
run() {
    out="$(env -u CXAGENTS_STATE_VOLUME -u DOCTOR_CXAGENTS_CONTAINER -u DOCTOR_CXAGENTS_ROUTES \
        -u DOCTOR_CXAGENTS_CHECK_CMD env "$@" "$doctor" 2>&1)"
}

# Assertions accumulate into $reason; verdict LABEL reports and resets it.
reason=""
need() { grep -qF -- "$1" <<<"$out" || reason="${reason}; missing '$1'"; }
forbid_fail() {   # no [FAIL] line matches the extended regex $1
    if grep '^\[FAIL\]' <<<"$out" | grep -qE -- "$1"; then reason="${reason}; unexpected FAIL matching '$1'"; fi
    return 0
}
verdict() {
    if [ -z "$reason" ]; then
        pass_fixture "$1"
    else
        fail_fixture "$1" "${reason#; }"; sed 's/^/    /' <<<"$out" >&2
    fi
    reason=""
}

# fake_check FILE PROBLEM...: a DOCTOR_CXAGENTS_CHECK_CMD that prints the forwarder
# `check` format with the given problem lines and exits 1, as check does on a problem.
fake_check() {
    local f="$1"; shift
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "cat <<'EOF'"
        printf '%s\n' 'node:   cxagents-1 (cxagents-1.faun-fir.ts.net)'
        printf '%s\n' 'id:     n0000000000000000'
        printf '%s\n' 'tags:   tag:cxagents'
        printf '%s\n' 'online: yes'
        printf '%s\n' 'cert:   expires 2027-01-01 (400 days)'
        for p in "$@"; do printf 'problem: %s\n' "$p"; done
        printf '%s\n' 'EOF'
        printf '%s\n' 'exit 1'
    } > "$f"
    chmod 755 "$f"
}

# baseline: the real node passes, no FAIL anywhere in the cxagents section
run DOCTOR_TEST=baseline
need "[OK]   cxagents: state holds node "
need "[OK]   cxagents: node cxagents (cxagents.faun-fir.ts.net) tags tag:cxagents"
forbid_fail '.'
verdict baseline

# forwarder-stopped (AC4.5): the container is missing or stopped
run DOCTOR_CXAGENTS_CONTAINER="$missing_container"
need "[FAIL] cxagents: ${missing_container} is missing"
verdict forwarder-stopped

# missing-volume (AC4.5): the state volume does not exist; doctor must not create it
run CXAGENTS_STATE_VOLUME="$absent_vol"
need "[FAIL] cxagents: state volume ${absent_vol} missing"
if D volume inspect "$absent_vol" >/dev/null 2>&1; then
    reason="${reason}; doctor created ${absent_vol}"
fi
verdict missing-volume

# empty-state (AC4.5): the state volume exists but holds no node
run CXAGENTS_STATE_VOLUME="$empty_vol"
need "[FAIL] cxagents: state empty"
verdict empty-state

# renamed, untagged, offline, cert-expiring (AC4.5): one problem line each, copied from check.go
fake_check "$tmp/check-renamed.sh" "node is named cxagents-1, not cxagents (stale device? see login)"
run DOCTOR_CXAGENTS_CHECK_CMD="$tmp/check-renamed.sh"
need "[FAIL] cxagents: node is named cxagents-1, not cxagents (stale device? see login)"
verdict renamed

fake_check "$tmp/check-untagged.sh" "tags are [], want exactly [tag:cxagents]"
run DOCTOR_CXAGENTS_CHECK_CMD="$tmp/check-untagged.sh"
need "[FAIL] cxagents: tags are [], want exactly [tag:cxagents]"
verdict untagged

fake_check "$tmp/check-offline.sh" "node is offline"
run DOCTOR_CXAGENTS_CHECK_CMD="$tmp/check-offline.sh"
need "[FAIL] cxagents: node is offline"
verdict offline

fake_check "$tmp/check-cert.sh" "cert expires in 10 days; must be more than 14"
run DOCTOR_CXAGENTS_CHECK_CMD="$tmp/check-cert.sh"
need "[FAIL] cxagents: cert expires in 10 days; must be more than 14"
verdict cert-expiring

# target-not-running (AC4.5): a routes target with no running container
printf '%s\n' 'no-such-container 1024-65535 3100' > "$tmp/routes-dead"
run DOCTOR_CXAGENTS_ROUTES="$tmp/routes-dead"
need "[FAIL] cxagents: routes target no-such-container not running"
verdict target-not-running

# image-missing: the image is absent. Doctor reports the image, skips the state
# check (no "cannot read state" line) and never runs or pulls a container. A PATH
# shim logs every docker call and then runs the real docker.
shimdir="$tmp/shim"; mkdir -p "$shimdir"
dockerlog="$tmp/docker-calls.log"; : > "$dockerlog"
real_docker="$(command -v docker)"
cat > "$shimdir/docker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$dockerlog"
exec "$real_docker" "\$@"
EOF
chmod 755 "$shimdir/docker"
run PATH="$shimdir:$PATH" CXAGENTS_IMAGE=tailnet-forwarder:missing
need "[FAIL] cxagents: image missing"
if grep -qF 'cannot read state' <<<"$out"; then reason="${reason}; 'cannot read state' printed for a missing image"; fi
if grep -E '(^| )(run|pull)( |$)' "$dockerlog" >&2; then
    reason="${reason}; docker run or pull attempted (see the calls above)"
fi
verdict image-missing

# no-env-read (AC4.6, static): doctor.sh never names an environment file at all
if grep -n '\.env' "$doctor"; then
    fail_fixture no-env-read "doctor.sh mentions an environment file (see matches above)"
else
    pass_fixture no-env-read
fi

if [ "$failures" -eq 0 ]; then
    echo "All fixtures passed"
    exit 0
fi
echo "${failures} fixture(s) failed" >&2
exit 1
