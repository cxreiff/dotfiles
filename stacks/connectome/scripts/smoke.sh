#!/usr/bin/env bash
# stacks/connectome/scripts/smoke.sh
# Smoke test against the running stack (restarts containers; restores state).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
repo_root="$(cd "$stack_dir/../.." && pwd)"

# shellcheck source=../../scripts/lib/check.sh
source "$repo_root/stacks/scripts/lib/check.sh"

D() { docker --context colima-agents "$@"; }
X() { D exec "$@"; }

# One EXIT handler for the whole run (bash keeps a single EXIT trap): checks
# register restore steps here; they run in reverse order on any exit,
# including set -e aborts and Ctrl-C. Restore steps must be idempotent.
cleanups=()
add_cleanup() { cleanups+=("$1"); }
run_cleanups() {
    local i
    for (( i=${#cleanups[@]}-1; i>=0; i-- )); do "${cleanups[$i]}" || true; done
}
trap run_cleanups EXIT

# Exec-based checks must not pass vacuously against a stopped container.
running() {
    local c
    for c in "$@"; do
        [ "$(D inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || return 1
    done
}
heartbeat_cfg() {  # heartbeat_cfg HOURS: set the persisted interval via the heartbeat server
    X connectome env HEARTBEAT_CONFIG_FILE=/agent/state/heartbeat/config.json \
        HEARTBEAT_REMINDERS_FILE=/agent/state/heartbeat/reminders.json \
        /opt/node/bin/node /opt/connectome-tests/mcp-call.mjs heartbeat_configure \
        "{\"intervalHours\":$1}" -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio >/dev/null 2>&1
}
# The MCP children (discord, heartbeat, term-sessions) spawn after the
# container is Running; checks that scan processes must wait for them.
wait_children() {
    local _ n
    for _ in $(seq 1 60); do
        n=$(X connectome sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null; echo; done' 2>/dev/null \
            | grep -cE 'discord-mcpl/dist|heartbeat-mcpl/dist|mcp-stdio-server' || true)
        [ "${n:-0}" -ge 3 ] && return 0
        sleep 2
    done
    return 1
}
# Set 4 h back and restart connectome so the live heartbeat server (which
# holds its config in memory) rereads it. No-op when already 4 h.
restore_heartbeat_config() {
    running connectome || return 0
    X connectome grep -q '"intervalSeconds": 14400' /agent/state/heartbeat/config.json && return 0
    heartbeat_cfg 4 || true
    D restart connectome >/dev/null 2>&1 || true
    wait_children || true
}
restore_stack() {  # gateway first (connectome's entrypoint waits for it), then connectome
    D start onecli-gateway >/dev/null 2>&1 || true
    local _
    for _ in $(seq 1 30); do
        [ "$(D inspect -f '{{.State.Health.Status}}' onecli-gateway 2>/dev/null)" = healthy ] && break
        sleep 2
    done
    D start connectome >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do running connectome && break; sleep 1; done
    wait_children || true
}

check_ac5_1() {
    local c_uid s_uid
    c_uid=$(X connectome sh -c 'id -u' | tr -d ' ')
    s_uid=$(X connectome-shell sh -c 'id -u' | tr -d ' ')

    if [ "$c_uid" -eq 0 ] || [ "$s_uid" -eq 0 ]; then
        fail "AC5.1 (uid is 0: connectome=$c_uid shell=$s_uid)"
        return
    fi

    # Check CapDrop and SecurityOpt for both containers
    local container caps sec
    for container in connectome connectome-shell; do
        caps=$(D inspect -f '{{json .HostConfig.CapDrop}}' "$container")
        sec=$(D inspect -f '{{json .HostConfig.SecurityOpt}}' "$container")
        if ! echo "$caps" | grep -q '"ALL"' || ! echo "$sec" | grep -q 'no-new-privileges:true'; then
            fail "AC5.1 ($container caps/sec)"
            return
        fi
    done

    pass "AC5.1"
}

check_ac5_2() {
    local out
    out=$(X connectome touch /agent/cwd/mcpl-servers.agent.json 2>&1 || true)
    if ! echo "$out" | grep -q 'Permission denied'; then
        fail "AC5.2 (agent.json touch should fail: $out)"
        return
    fi

    local files
    files=$(X connectome ls -A /agent/cwd | tr '\n' ' ')
    if [ "$files" != "logs mcpl-servers.json " ] && [ "$files" != "mcpl-servers.json logs " ]; then
        fail "AC5.2 (cwd listing: got '$files')"
        return
    fi

    out=$(X connectome sh -c 'echo x >> /agent/cwd/mcpl-servers.json' 2>&1 || true)
    if ! echo "$out" | grep -qE 'Read-only|Permission denied'; then
        fail "AC5.2 (mcpl-servers.json not RO: $out)"
        return
    fi

    pass "AC5.2"
}

check_ac5_3() {
    local out
    out=$(X connectome touch /agent/recipes/x 2>&1 || true)
    if echo "$out" | grep -q 'Read-only file system'; then
        pass "AC5.3"
    else
        fail "AC5.3 (expected RO: $out)"
    fi
}

check_ac5_5() {
    add_cleanup restore_heartbeat_config
    if ! running connectome; then fail "AC5.5 (connectome not running)"; return; fi
    local before_sha after_sha _
    before_sha=$(X connectome sha256sum /agent/state/heartbeat/config.json | cut -d" " -f1)
    heartbeat_cfg 5 || true
    after_sha=$(X connectome sha256sum /agent/state/heartbeat/config.json | cut -d" " -f1)
    if [ "$before_sha" = "$after_sha" ] || ! X connectome grep -q '"intervalSeconds": 18000' /agent/state/heartbeat/config.json; then
        fail "AC5.5 (heartbeat_configure did not change the file to 18000)"
        restore_heartbeat_config || true
        return
    fi
    # Persistence across a container restart.
    D restart connectome >/dev/null
    for _ in $(seq 1 30); do running connectome && break; sleep 1; done
    if ! X connectome grep -q '"intervalSeconds": 18000' /agent/state/heartbeat/config.json; then
        fail "AC5.5 (18000 not kept across restart)"
        restore_heartbeat_config || true
        return
    fi
    heartbeat_cfg 4 || true
    # The live heartbeat server holds its config in memory: restart so it
    # rereads 14400.
    D restart connectome >/dev/null
    wait_children || true
    if X connectome grep -q '"intervalSeconds": 14400' /agent/state/heartbeat/config.json; then
        pass "AC5.5"
    else
        fail "AC5.5 (could not set back to 14400)"
    fi
}

check_ac5_6_stale() {
    X connectome sh -c 'mkdir -p /agent/state/data/children/smoke && : > /agent/state/data/children/smoke/headless.pid && : > /agent/state/data/children/smoke/ipc.sock'
    D restart connectome >/dev/null
    sleep 10

    if X connectome sh -c '[ ! -f /agent/state/data/children/smoke/headless.pid ] && [ ! -f /agent/state/data/children/smoke/ipc.sock ]'; then
        X connectome sh -c 'rmdir /agent/state/data/children/smoke 2>/dev/null || true'
        pass "AC5.6-stale"
    else
        fail "AC5.6-stale (files not deleted)"
    fi
}

check_ac5_6_wait() {
    add_cleanup restore_stack
    D stop connectome >/dev/null
    D stop onecli-gateway >/dev/null

    # Time only the compose run.
    local before_time after_time elapsed output
    before_time=$(date +%s)
    local rc
    output=$("$stack_dir/scripts/compose.sh" run --rm --no-deps -e GATEWAY_WAIT_SECONDS=6 connectome 2>&1) && rc=0 || rc=$?
    after_time=$(date +%s)
    elapsed=$((after_time - before_time))

    restore_stack
    if ! running onecli-gateway connectome; then
        fail "AC5.6-wait (could not restore gateway/connectome)"
        return
    fi
    # entrypoint.sh exits 4 when the gateway stays unreachable.
    if [ "$rc" -eq 4 ] && echo "$output" | grep -q 'unreachable after 6s' && [ "$elapsed" -lt 20 ]; then
        pass "AC5.6-wait"
    else
        fail "AC5.6-wait (rc=$rc want 4, elapsed=$elapsed, 'unreachable' found: $(echo "$output" | grep -c 'unreachable after 6s' || echo 0))"
    fi
}

check_ac5_7() {
    if ! running connectome connectome-shell; then fail "AC5.7 (containers not running)"; return; fi
    local c_output s_output
    c_output=$(X connectome sh -c 'env; grep -rIhoE "(^|[^a])oc_[0-9a-f]{32,}" /agent /home /workspace /etc /tmp 2>/dev/null' 2>&1 || true)
    s_output=$(X connectome-shell sh -c 'env; grep -rIhoE "(^|[^a])oc_[0-9a-f]{32,}" /agent /home /workspace /etc /tmp 2>/dev/null' 2>&1 || true)

    local c_tokens s_tokens
    c_tokens=$(echo "$c_output" | grep -cE '(^|[^a])oc_[0-9a-f]{32,}' || echo 0)
    s_tokens=$(echo "$s_output" | grep -cE '(^|[^a])oc_[0-9a-f]{32,}' || echo 0)
    c_tokens=$(echo "$c_tokens" | tr -d ' \n')
    s_tokens=$(echo "$s_tokens" | tr -d ' \n')

    if [ "$c_tokens" -ne 0 ] || [ "$s_tokens" -ne 0 ]; then
        fail "AC5.7 (tokens found: c=$c_tokens s=$s_tokens)"
        return
    fi

    local mac_key_check
    mac_key_check=$(cut -d= -f1 "$stack_dir/.env" | grep -ciE 'API_KEY|ONECLI_KEY|^OC_' || echo 0)
    mac_key_check=$(echo "$mac_key_check" | tr -d ' \n')
    if [ "$mac_key_check" -eq 0 ]; then
        pass "AC5.7"
    else
        fail "AC5.7 (Mac side key names)"
    fi
}

smoke_secrets_file=""
rm_secrets_file() { [ -z "$smoke_secrets_file" ] || rm -f "$smoke_secrets_file"; }
check_ac5_8() {
    if ! running connectome connectome-shell; then fail "AC5.8 (containers not running)"; return; fi
    if ! wait_children; then fail "AC5.8 (MCP children not running; cmdline scan would be vacuous)"; return; fi
    local secrets_file
    secrets_file=$(umask 077; mktemp)
    smoke_secrets_file="$secrets_file"
    add_cleanup rm_secrets_file

    local discord_token webui_pass host_token shell_token session_token
    discord_token=$(grep '^DISCORD_TOKEN=' "$stack_dir/.env" | cut -d= -f2-)
    webui_pass=$(grep '^WEBUI_PASS=' "$stack_dir/.env" | cut -d= -f2-)
    host_token=$(grep '^HOST_ONECLI_TOKEN=' "$stack_dir/.env" | cut -d= -f2-)
    shell_token=$(grep '^SHELL_ONECLI_TOKEN=' "$stack_dir/.env" | cut -d= -f2-)
    session_token=$(grep '^SESSION_SERVER_TOKEN=' "$stack_dir/.env" | cut -d= -f2-)

    {
        echo "$discord_token"
        echo "$webui_pass"
        echo "$host_token"
        echo "$shell_token"
        echo "$session_token"
    } > "$secrets_file"

    local c_output s_output
    c_output=$(X connectome sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f"; echo; done' 2>&1 || true)
    s_output=$(X connectome-shell sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f"; echo; done' 2>&1 || true)

    local c_matches s_matches
    c_matches=$(echo "$c_output" | grep -cF -f "$secrets_file" || echo 0)
    s_matches=$(echo "$s_output" | grep -cF -f "$secrets_file" || echo 0)
    c_matches=$(echo "$c_matches" | tr -d ' \n')
    s_matches=$(echo "$s_matches" | tr -d ' \n')

    if [ "$c_matches" -eq 0 ] && [ "$s_matches" -eq 0 ]; then
        pass "AC5.8"
    else
        fail "AC5.8 (cmdline matches: c=$c_matches s=$s_matches)"
    fi
}

check_ac7_3() {
    local filters_count
    filters_count=$(X connectome sh -c 'cat /proc/*/environ 2>/dev/null | tr "\0" "\n" | grep -c "^DISCORD_FILTERS_FILE=" || echo 0')
    filters_count=$(echo "$filters_count" | tr -d ' \n')

    if [ "$filters_count" -ne 0 ]; then
        fail "AC7.3 (DISCORD_FILTERS_FILE found: $filters_count)"
        return
    fi

    if jq -e '.mcpServers.discord.disabledTools | (index("filters_update") and index("create_text_channel") and index("delete_channel"))' "$stack_dir/recipes/agent.json" >/dev/null 2>&1; then
        pass "AC7.3"
    else
        fail "AC7.3 (disabledTools in recipe)"
    fi
}

check_ac7_6() {
    local watermark_status dm_notices_status muted_channels_status

    # Check watermark.json (must exist)
    if X connectome ls /agent/state/discord | grep -q watermark.json; then
        watermark_status="[ON]"
    else
        watermark_status="[OFF]"
    fi

    # Check dm-notices.json (report status)
    if X connectome ls /agent/state/discord 2>/dev/null | grep -q dm-notices.json; then
        dm_notices_status="[ON]"
    else
        dm_notices_status="[OFF]"
    fi

    # Check muted-channels.json (report status)
    if X connectome ls /agent/state/discord 2>/dev/null | grep -q muted-channels.json; then
        muted_channels_status="[ON]"
    else
        muted_channels_status="[OFF]"
    fi

    if [ "$watermark_status" = "[ON]" ]; then
        pass "AC7.6 (watermark $watermark_status dm-notices $dm_notices_status muted-channels $muted_channels_status)"
    else
        fail "AC7.6 (watermark.json missing)"
    fi
}

check_ac8_2() {
    local webui_user webui_pass
    webui_user=$(grep '^WEBUI_USER=' "$stack_dir/.env" | cut -d= -f2-)
    webui_pass=$(grep '^WEBUI_PASS=' "$stack_dir/.env" | cut -d= -f2-)

    # Test from shell container (should get 401)
    local shell_code
    shell_code=$(X connectome-shell curl -s -o /dev/null -w '%{http_code}' http://connectome:18768/ 2>/dev/null || echo 0)
    shell_code=$(echo "$shell_code" | tr -d ' ')

    # Test from Mac localhost (should get 401)
    local mac_code
    mac_code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18768/ 2>/dev/null || echo 0)
    mac_code=$(echo "$mac_code" | tr -d ' ')

    # Test with correct creds
    local auth_code
    auth_code=$(curl -s -K <(printf 'user = "%s:%s"\n' "$webui_user" "$webui_pass") -o /dev/null -w '%{http_code}' http://127.0.0.1:18768/ 2>/dev/null || echo 0)
    auth_code=$(echo "$auth_code" | tr -d ' ')

    if [ "$shell_code" = "401" ] && [ "$mac_code" = "401" ] && [ "$auth_code" = "200" ]; then
        pass "AC8.2"
    else
        fail "AC8.2 (shell=$shell_code mac=$mac_code auth=$auth_code)"
    fi
}

check_ac8_3() {
    local obs_content
    obs_content=$(X connectome cat /agent/recipes/observers.json)

    if [ "$obs_content" != '{"observers":[]}' ]; then
        fail "AC8.3 (content: $obs_content)"
        return
    fi

    local out
    out=$(X connectome touch /agent/recipes/observers.json 2>&1 || true)
    if echo "$out" | grep -q 'Read-only'; then
        pass "AC8.3"
    else
        fail "AC8.3 (not read-only: $out)"
    fi
}

check_ac9_3() {
    if X connectome-shell sh -c 'rm -rf /tmp/hw && git clone --depth 1 https://github.com/octocat/Hello-World /tmp/hw && git -C /tmp/hw log --oneline -1' >/dev/null 2>&1; then
        pass "AC9.3"
    else
        fail "AC9.3 (git clone failed)"
    fi
}

check_ac9_4() {
    local out
    out=$(X connectome-shell ls /agent/state 2>&1 || true)
    if ! echo "$out" | grep -qE 'No such file|No such directory'; then
        fail "AC9.4 (shell can read /agent/state: $out)"
        return
    fi

    # Invariant 4: outbox is the only named volume mounted in BOTH containers
    # (each may have others: state in connectome, workspace in shell).
    local c_volumes s_volumes shared
    c_volumes=$(D inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}}{{"\n"}}{{end}}{{end}}' connectome | sort -u)
    s_volumes=$(D inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}}{{"\n"}}{{end}}{{end}}' connectome-shell | sort -u)
    shared=$(comm -12 <(printf '%s\n' "$c_volumes" | sed '/^$/d') <(printf '%s\n' "$s_volumes" | sed '/^$/d') | tr '\n' ' ' | sed 's/ $//')
    if [ "$shared" != "connectome_outbox" ]; then
        fail "AC9.4 (volumes shared by both containers: '${shared}', want only connectome_outbox)"
        return
    fi
    local c_rw s_rw
    c_rw=$(D inspect -f '{{range .Mounts}}{{if eq .Name "connectome_outbox"}}{{.RW}}{{end}}{{end}}' connectome)
    s_rw=$(D inspect -f '{{range .Mounts}}{{if eq .Name "connectome_outbox"}}{{.RW}}{{end}}{{end}}' connectome-shell)
    if [ "$c_rw" = "false" ] && [ "$s_rw" = "true" ]; then
        pass "AC9.4"
    else
        fail "AC9.4 (outbox RO/RW: connectome=$c_rw shell=$s_rw)"
    fi
}

check_ac9_5() {
    if ! X connectome-shell sh -c 'echo smoke > /workspace/.smoke-persist'; then
        fail "AC9.5 (write failed)"
        return
    fi

    D restart connectome-shell >/dev/null
    sleep 3

    if X connectome-shell cat /workspace/.smoke-persist | grep -q smoke; then
        X connectome-shell rm /workspace/.smoke-persist
        pass "AC9.5"
    else
        fail "AC9.5 (file lost after restart)"
    fi
}

# Run all checks
check_ac5_1
check_ac5_2
check_ac5_3
check_ac5_5
check_ac5_6_stale
check_ac5_6_wait
check_ac5_7
check_ac5_8
check_ac7_3
check_ac7_6
check_ac8_2
check_ac8_3
check_ac9_3
check_ac9_4
check_ac9_5

[ "$__check_failed" -eq 0 ] || exit 1
