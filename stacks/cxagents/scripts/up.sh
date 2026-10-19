#!/usr/bin/env bash
# stacks/cxagents/scripts/up.sh — start the forwarder; refuses on a missing
# image or empty state so boot/up-all never start a node waiting on a login.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"
D image inspect "$cx_image" >/dev/null 2>&1 || {
    echo "cxagents: image ${cx_image} missing — run \`dotfiles stacks cxagents build\`" >&2; exit 1; }
cx_ensure_volume
cx_read_state
case "$CX_STATE_KIND" in
    node) ;;
    empty) echo "cxagents: no node in state — run \`dotfiles stacks cxagents login\`" >&2; exit 1 ;;
    *) echo "cxagents: cannot read state in ${cx_volume} (state check rc=${CX_STATE_RC}); not starting" >&2; exit 1 ;;
esac
[ "$cx_volume" = cxagents_state ] || { echo "cxagents: test volume ${cx_volume}: preflight ok, not starting"; exit 0; }
DC up -d --wait --wait-timeout 180
