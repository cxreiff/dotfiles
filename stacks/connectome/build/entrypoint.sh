#!/usr/bin/env bash
# connectome container entrypoint (runs as the image's non-root uid).
# 1. Prepare /agent/state layout (named volume, 0700).
# 2. Seed the heartbeat interval (4 h) — the recipe cannot set it.
# 3. Delete stale fleet IPC files: no child survives a container restart, and
#    a fresh PID namespace reuses small PIDs (fleet-protocol §4.3).
# 4. Refuse to start without the Codex stub (provision-codex).
# 5. Wait, bounded, for the onecli gateway — dockerd restarts containers in no
#    particular order at VM boot.
set -euo pipefail
log() { echo "[connectome-entrypoint] $*" >&2; }

state=/agent/state
umask 077
mkdir -p "$state/data/children" "$state/codex" "$state/logs" "$state/heartbeat" "$state/discord"

if [ ! -s "$state/heartbeat/config.json" ]; then
    printf '{"intervalSeconds": 14400}\n' > "$state/heartbeat/config.json"
    log "seeded heartbeat interval (14400 s)"
fi

find "$state/data" -maxdepth 3 \( -name ipc.sock -o -name headless.pid \) -print -delete \
    | sed 's/^/[connectome-entrypoint] removed stale /' >&2 || true

if [ ! -s "$state/codex/auth.json" ]; then
    log "no Codex stub at $state/codex/auth.json — run: dotfiles stacks connectome provision-codex"
    exit 3
fi

wait_s="${GATEWAY_WAIT_SECONDS:-120}"
deadline=$(( SECONDS + wait_s ))
until (exec 3<>/dev/tcp/gateway/10255) 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        log "onecli gateway (gateway:10255) unreachable after ${wait_s}s — start it with: dotfiles stacks onecli up"
        exit 4
    fi
    sleep 2
done
log "gateway reachable; starting connectome-host (logs: \$DATA_DIR/headless.log)"
exec bun /opt/connectome/src/index.ts /agent/recipes/agent.json --headless
