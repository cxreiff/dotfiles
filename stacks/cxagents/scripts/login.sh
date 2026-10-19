#!/usr/bin/env bash
# stacks/cxagents/scripts/login.sh — register the cxagents node. The auth key
# exists only in the pipe authkey.sh -> one-shot `tailnet-forwarder login`.
# Matrix: state valid + device present -> no-op; any other cxagents device ->
# stop and print its admin URL (delete it, re-run); state whose device is gone
# -> confirm, wipe state, continue; empty state, no device -> mint + log in.
# Test seams: CXAGENTS_IMAGE, CXAGENTS_STATE_VOLUME, CXAGENTS_DEVICES_JSON
# (file used instead of the API device list), CXAGENTS_AUTHKEY_CMD,
# CXAGENTS_LOGIN_DRY_RUN=1 (stop just before minting).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"
# shellcheck source=../../../tailscale/scripts/lib/conf.sh
source "${cx_repo_root}/tailscale/scripts/lib/conf.sh"
api="${cx_repo_root}/tailscale/scripts/api.sh"
authkey_cmd="${CXAGENTS_AUTHKEY_CMD:-${cx_repo_root}/tailscale/scripts/authkey.sh ${cx_tag}}"

# 1. image
D image inspect "$cx_image" >/dev/null 2>&1 || {
    echo "cxagents login: image ${cx_image} missing — run \`dotfiles stacks cxagents build\`" >&2; exit 1; }

# 2. local state and the tailnet's cxagents devices
cx_ensure_volume
# Only a readable state is acted on: "node" or "empty". An unreadable state
# (corrupt file, failed check) stops here, so nothing is minted onto it and no
# device is blamed for it.
cx_read_state
case "$CX_STATE_KIND" in
    node) state_id="$CX_STATE_ID" ;;
    empty) state_id="" ;;
    *) echo "cxagents login: cannot read state in ${cx_volume} (state check rc=${CX_STATE_RC}); nothing changed" >&2; exit 1 ;;
esac
if [ -n "${CXAGENTS_DEVICES_JSON:-}" ]; then devices="$(cat "$CXAGENTS_DEVICES_JSON")"
else devices="$("$api" --client admin GET "/tailnet/${TAILNET}/devices")"; fi
mine="$(jq -c --arg h "$cx_host" '[.devices[] | select(.hostname == $h or (.name | split(".")[0] | test("^" + $h + "(-[0-9]+)?$")))]' <<<"$devices")"

if [ -n "$state_id" ] && jq -e --arg id "$state_id" --arg h "$cx_host" \
        'any(.[]; .nodeId == $id and (.name | split(".")[0]) == $h)' <<<"$mine" >/dev/null; then
    echo "cxagents login: already logged in as ${cx_host} (${state_id}); nothing to do"
    exit 0
fi
if [ -n "$state_id" ] && jq -e --arg id "$state_id" 'any(.[]; .nodeId == $id)' <<<"$mine" >/dev/null; then
    echo "cxagents login: this state owns $(jq -r --arg id "$state_id" '.[] | select(.nodeId == $id) | "\(.name)  https://login.tailscale.com/admin/machines/\(.addresses[0])"' <<<"$mine") — not exactly ${cx_host}." >&2
    echo "cxagents login: delete that device and any other cxagents device, then re-run login (it will offer to wipe the state)" >&2
    exit 1
fi
if [ "$(jq length <<<"$mine")" -gt 0 ]; then
    echo "cxagents login: a cxagents device already exists on the tailnet, and this state does not own it:" >&2
    jq -r '.[] | "  \(.name)  nodeId=\(.nodeId)  https://login.tailscale.com/admin/machines/\(.addresses[0])"' <<<"$mine" >&2
    echo "cxagents login: delete it in the admin console, then re-run \`dotfiles stacks cxagents login\`" >&2
    exit 1
fi
if [ -n "$state_id" ]; then
    printf 'cxagents login: state holds node %s, which no longer exists on the tailnet. Wipe %s and re-register? [y/N] ' "$state_id" "$cx_volume" >&2
    read -r answer || answer=""
    case "$answer" in [Yy]|[Yy][Ee][Ss]) ;; *) echo "cxagents login: aborted; state kept" >&2; exit 1 ;; esac
    users="$(D ps -aq --filter "volume=${cx_volume}")"
    [ -z "$users" ] || D rm -f $users >/dev/null
    D volume rm "$cx_volume" >/dev/null
    cx_ensure_volume
fi

# 3. mint + log in (the key exists only in this pipe)
if [ "${CXAGENTS_LOGIN_DRY_RUN:-}" = 1 ]; then echo "cxagents login: dry run — would mint an auth key and log in"; exit 0; fi
$authkey_cmd | D run --rm -i --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -v "${cx_volume}:/state" \
    -e FORWARDER_HOSTNAME="$cx_host" -e FORWARDER_TAG="$cx_tag" -e FORWARDER_STATE_DIR=/state \
    -e TS_NO_LOGS_NO_SUPPORT=true -e TS_LOGS_DIR=/state/logs \
    "$cx_image" login

# 4. start
[ "$cx_volume" = cxagents_state ] && DC up -d --wait --wait-timeout 180
cx_state
