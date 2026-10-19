#!/usr/bin/env bash
# stacks/cxagents/scripts/lib/stack.sh — source-only.
cx_ctx=colima-agents
cx_stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cx_repo_root="$(cd "${cx_stack_dir}/../.." && pwd)"
cx_image="${CXAGENTS_IMAGE:-tailnet-forwarder:local}"
cx_volume="${CXAGENTS_STATE_VOLUME:-cxagents_state}"
cx_host=cxagents
cx_tag=tag:cxagents
D()  { docker --context "$cx_ctx" "$@"; }
DC() { docker --context "$cx_ctx" compose -f "${cx_stack_dir}/compose.yaml" "$@"; }
# Create the state volume with compose's labels (so compose adopts it without
# warnings) when it does not exist yet; never touches an existing volume.
cx_ensure_volume() {
    D volume inspect "$cx_volume" >/dev/null 2>&1 && return 0
    D volume create --label com.docker.compose.project=cxagents \
        --label com.docker.compose.volume=state "$cx_volume" >/dev/null
}
cx_volume_exists() { D volume inspect "$cx_volume" >/dev/null 2>&1; }
# Prints "state: node <ID>" / "state: empty"; exit 0 = node present.
# Mounting a missing volume would create it: read-only callers (doctor) must
# check cx_volume_exists first; up/login call cx_ensure_volume first.
# The state is mounted :ro: a check never writes to it.
cx_state() {
    D run --rm --pull never --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true -v "${cx_volume}:/state:ro" \
        "$cx_image" check --state-only
}
# cx_read_state: classifies the state volume for up and login. Sets
#   CX_STATE_KIND  node  (rc 0 and "state: node <ID>"; CX_STATE_ID holds the ID)
#                  empty (rc 1 and exactly "state: empty")
#                  error (anything else: unparseable state, a failed docker run,
#                         an unexpected answer). Callers abort on error; an
#                         unreadable state is never treated as empty.
#   CX_STATE_RC    the exit code of cx_state.
# check's stderr is discarded: a JSON syntax error can quote a byte of the state
# file, so no state-derived text is ever printed.
cx_read_state() {
    local out rc=0
    CX_STATE_ID=""
    out="$(cx_state 2>/dev/null)" || rc=$?
    CX_STATE_RC=$rc
    CX_STATE_KIND=error
    if [ "$rc" = 0 ] && [[ "$out" == "state: node "* ]]; then
        CX_STATE_ID="${out#state: node }"
        if [[ "$CX_STATE_ID" =~ ^[A-Za-z0-9]+$ ]]; then CX_STATE_KIND=node; fi
    elif [ "$rc" = 1 ] && [ "$out" = "state: empty" ]; then
        CX_STATE_KIND=empty
    fi
}
