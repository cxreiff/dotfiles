#!/usr/bin/env bash
# stacks/cxagents/scripts/doctor.sh — read-only checks of the cxagents node:
# image, state volume, forwarder health, node identity and certificate (the
# forwarder's own `check`), routes targets, lockdown lints. Called by
# stacks/scripts/doctor.sh (--- cxagents ---), which re-emits its
# [OK]/[FAIL]/[WARN]/[OFF] lines. Never creates a volume, never changes a
# container, and reads no environment-file value (its lint reads key names only).
#
# Fixture overrides (scripts/doctor-test.sh):
#   DOCTOR_CXAGENTS_CONTAINER   forwarder container (default cxagents-forwarder)
#   DOCTOR_CXAGENTS_ROUTES      routes file (default stacks/cxagents/routes)
#   DOCTOR_CXAGENTS_CHECK_CMD   executable whose stdout and exit status replace
#                               `docker exec <container> /tailnet-forwarder check`
#   CXAGENTS_STATE_VOLUME, CXAGENTS_IMAGE (lib/stack.sh)
# Exit: 1 if any FAIL, 0 otherwise (the caller reads the printed lines).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"
# shellcheck source=../../../stacks/scripts/lib/check.sh
source "${cx_repo_root}/stacks/scripts/lib/check.sh"

container="${DOCTOR_CXAGENTS_CONTAINER:-cxagents-forwarder}"
routes="${DOCTOR_CXAGENTS_ROUTES:-${cx_stack_dir}/routes}"

# 1. Agents VM. Without it nothing below can be read: report OFF, not FAIL.
if ! D info >/dev/null 2>&1; then
    off "cxagents: checks skipped (colima-agents not running)"
    exit 0
fi

# 2. Image. Without it the state check cannot run the forwarder's `check`, so it is skipped.
image_ok=1
if D image inspect "$cx_image" >/dev/null 2>&1; then
    pass "cxagents: image present (${cx_image})"
else
    image_ok=0
    fail "cxagents: image missing (run: dotfiles stacks cxagents build)"
fi

# 3. State. A missing volume is reported, never mounted: a mount would create it.
if [ "$image_ok" -eq 0 ]; then
    off "cxagents: state check skipped (image missing)"
elif ! cx_volume_exists; then
    fail "cxagents: state volume ${cx_volume} missing (run: dotfiles stacks cxagents login)"
else
    cx_read_state
    case "$CX_STATE_KIND" in
        node)  pass "cxagents: state holds node ${CX_STATE_ID}" ;;
        empty) fail "cxagents: state empty (run: dotfiles stacks cxagents login)" ;;
        *)     fail "cxagents: cannot read state in ${cx_volume} (state check rc=${CX_STATE_RC})" ;;
    esac
fi

# 4. Forwarder container: running and healthy, or a FAIL that skips the node check
cstate="$(D inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "$container" 2>/dev/null)" \
    || cstate=missing
if [ "$cstate" = "running healthy" ]; then
    pass "cxagents: ${container} running and healthy"
    container_ok=1
else
    fail "cxagents: ${container} is ${cstate} (run: dotfiles stacks cxagents up)"
    container_ok=0
fi

# 5. Node identity and certificate, as judged by the forwarder's own check
if [ "$container_ok" -eq 1 ]; then
    if [ -n "${DOCTOR_CXAGENTS_CHECK_CMD:-}" ]; then
        check_out="$("$DOCTOR_CXAGENTS_CHECK_CMD" 2>&1)"; check_rc=$?
    else
        check_out="$(D exec "$container" /tailnet-forwarder check 2>&1)"; check_rc=$?
    fi
    if [ "$check_rc" -eq 0 ]; then
        field() { sed -n "s/^$1 *//p" <<<"$check_out" | head -1; }
        pass "cxagents: node $(field 'node:') tags $(field 'tags:') cert $(field 'cert:')"
    else
        problems="$(sed -n 's/^problem: //p' <<<"$check_out")"
        if [ -n "$problems" ]; then
            while IFS= read -r p; do
                fail "cxagents: ${p}"
            done <<<"$problems"
        else
            fail "cxagents: check failed: $(head -1 <<<"$check_out")"
        fi
    fi
fi

# 6. Routes targets: each must be running; running but off the cxagents network is a WARN
if [ ! -f "$routes" ]; then
    fail "cxagents: routes file missing (${routes})"
else
    targets="$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$routes")"
    attached=" $(D network inspect cxagents -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) "
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        running="$(D inspect -f '{{.State.Running}}' "$t" 2>/dev/null)" || running=false
        if [ "$running" = true ]; then
            pass "cxagents: routes target ${t} running"
            case "$attached" in
                *" ${t} "*) ;;
                *) warn "cxagents: ${t} not attached to network cxagents (connectome up without the overlay?)" ;;
            esac
        else
            fail "cxagents: routes target ${t} not running"
        fi
    done <<<"$targets"
fi

# 7. Static lockdown invariants (stacks/cxagents/scripts/lint.sh), re-emitted with the prefix
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "cxagents: ${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "cxagents: ${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "cxagents: ${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "cxagents: ${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "cxagents: lint: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/lint.sh" 2>&1)

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
