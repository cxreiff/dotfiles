#!/usr/bin/env bash
# stacks/cxagents/scripts/smoke.sh — live checks for the cxagents node.
#   Phase 5: AC5.3 packet filter, AC8.1 netns isolation, AC5.6 identity across
#            restart and down/up.
#   Phase 6: end-to-end through the forwarder (AC6.1-6.7, AC6.10, AC7.1, AC7.3,
#            AC7.4, AC9.5) against stdlib servers started in connectome-shell.
# Usage: smoke.sh [--long]   --long also runs AC6.3's 10-minute idle (about 11 min).
# Restarts the forwarder and connectome (AC5.6 down/up runs last); never changes
# the forwarder's policy. No `-e`: every check runs and reports.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"
# shellcheck source=lib/ac5_3.sh
source "${SCRIPT_DIR}/lib/ac5_3.sh"
# shellcheck source=../../../stacks/scripts/lib/check.sh
source "${cx_repo_root}/stacks/scripts/lib/check.sh"

ts=/opt/homebrew/bin/tailscale
# Pinned to the digest used when this check was written (no network install).
probe_image=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
fwd=cxagents-forwarder
shell_ctr=connectome-shell
smoke_dir="${cx_stack_dir}/scripts/smoke"

# Tailnet identity from tailscale/tailnet.conf via tailscale/scripts/lib/conf.sh
# (never hardcoded).
suffix="$(. "${cx_repo_root}/tailscale/scripts/lib/conf.sh" && printf '%s' "${TAILNET_DNS_SUFFIX:-}")"
if [ -z "$suffix" ]; then echo "smoke: TAILNET_DNS_SUFFIX missing from tailscale/tailnet.conf" >&2; exit 2; fi
H="${cx_host}.${suffix}"   # the cxagents node (forwarder); cx_host from lib/stack.sh
M="cxmini.${suffix}"     # this Mac (WebUI behind tailscale serve)

long=0
case "$#:${1:-}" in
    0:) ;;
    1:--long) long=1 ;;
    *) echo "usage: smoke.sh [--long]" >&2; exit 2 ;;
esac

# One EXIT handler for the run; checks register restore steps (reverse order).
cleanups=()
add_cleanup() { cleanups+=("$1"); }
run_cleanups() {
    local i
    for (( i=${#cleanups[@]}-1; i>=0; i-- )); do "${cleanups[$i]}" || true; done
}
trap run_cleanups EXIT
trap 'exit 130' INT TERM

# refused_rc RC: curl exit codes for "nothing answered" (7 refused, 52 empty
# reply, 56 connection reset). DNS (6), timeout (28), TLS (35) are not a pass.
refused_rc() { case "$1" in 7|52|56) return 0 ;; *) return 1 ;; esac; }

running() {  # running CONTAINER...: all running
    local c
    for c in "$@"; do
        [ "$(D inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || return 1
    done
}
just_cx() { just -f "${cx_repo_root}/justfile" stacks cxagents "$@"; }
just_connectome() { just -f "${cx_repo_root}/justfile" stacks connectome "$@"; }
X() { D exec "$shell_ctr" "$@"; }

# The node ID from the state volume (read-only mount; never the live forwarder).
state_id() {
    D run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
        -v "${cx_volume}:/state:ro" "$cx_image" check --state-only 2>/dev/null | sed -n 's/^state: node //p'
}
# `check` from inside the running forwarder: prints node/id/tags/online/cert lines.
fwd_check() { D exec "$fwd" /tailnet-forwarder check; }
wait_healthy() {
    local _ s
    for _ in $(seq 1 90); do
        s="$(D inspect -f '{{.State.Health.Status}}' "$fwd" 2>/dev/null || true)"
        [ "$s" = healthy ] && return 0
        sleep 2
    done
    return 1
}
restore_forwarder() { running "$fwd" || just_cx up >/dev/null 2>&1 || true; }
restore_connectome() { just_connectome up >/dev/null 2>&1 || true; }

check_ac5_3() {
    local ips srcs bad
    ips="$("$ts" status --json | jq -r '.Peer[]? | select(.HostName == "cxagents") | .TailscaleIPs[]?')"
    if [ -z "$ips" ]; then fail "AC5.3 (cxagents not a peer on cxmini)"; return; fi
    # Every source prefix in the live netmap, through the same extraction and
    # verdict that smoke-test.sh checks against fixtures (lib/ac5_3.sh).
    srcs="$("$ts" debug netmap 2>/dev/null | ac5_3_sources)"
    if [ -z "$srcs" ]; then fail "AC5.3 (netmap has no packet-filter source list)"; return; fi
    bad="$(ac5_3_verdict "$ips" "$srcs")"
    if [ -z "$bad" ]; then
        pass "cxagents-node.AC5.3 no packet-filter source lists the cxagents IPs ($(printf '%s\n' "$srcs" | wc -l | tr -d ' ') source prefixes checked)"
    else
        fail "cxagents-node.AC5.3 (cxagents reachable by source: ${bad})"
    fi
}

check_ac8_1() {
    running "$fwd" connectome onecli-gateway || { fail "AC8.1 (forwarder, connectome or onecli-gateway not running)"; return; }
    local fip cips gips gw targets out rc=0 total checked=0 bad=""
    fip="$(D inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$fwd" | awk '{print $1}')"
    cips="$(D inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' connectome | tr ' ' '\n' | grep -v '^$' || true)"
    gips="$(D inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' onecli-gateway | tr ' ' '\n' | grep -v '^$' || true)"
    gw="$(D network inspect cxagents -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
    if [ -z "$fip" ] || [ -z "$cips" ] || [ -z "$gips" ] || [ -z "$gw" ]; then
        fail "AC8.1 (missing addresses: forwarder='${fip}' connectome='${cips}' gateway='${gips}' cxagents-gw='${gw}')"; return
    fi
    # One line per probe: "IP PORT WANT" (WANT open|closed). The first row is
    # the positive control: the status port must answer from the forwarder's own IP.
    targets="$(mktemp)"
    {
        printf '%s 8080 open\n' "$fip"
        for ip in $cips; do printf '%s 18768 closed\n' "$ip"; done
        for ip in $gips; do printf '%s 10255 closed\n' "$ip"; done
        printf '%s 18768 closed\n%s 10255 closed\n' "$gw" "$gw"
    } >"$targets"
    total="$(wc -l <"$targets" | tr -d ' ')"
    out="$(D run --rm -i --read-only --cap-drop ALL --security-opt no-new-privileges:true \
        --network "container:${fwd}" "$probe_image" sh -c '
            while read -r ip port want; do
                if nc -z -w2 "$ip" "$port" >/dev/null 2>&1; then got=open; else got=closed; fi
                echo "$ip $port $want $got"
            done
            for n in connectome onecli-gateway; do
                [ -z "$(getent hosts "$n")" ] || echo "resolves $n"
            done' <"$targets" 2>/dev/null)" || rc=$?
    rm -f "$targets"
    while IFS= read -r line; do
        case "$line" in
            resolves\ *) bad="${bad:+$bad, }${line}" ;;
            *) set -- $line
               checked=$((checked + 1))
               [ "$3" = "$4" ] || bad="${bad:+$bad, }$1:$2 wanted $3 got $4" ;;
        esac
    done <<<"$out"
    if [ "$rc" -ne 0 ] || [ "$checked" -ne "$total" ]; then
        fail "AC8.1 (probe incomplete: rc=${rc} checked ${checked}/${total})"; return
    fi
    if [ -z "$bad" ]; then
        pass "cxagents-node.AC8.1 forwarder reaches its status port ${fip}:8080; connectome:18768, the onecli gateway:10255 and the cxagents gateway are unreachable (${checked} probes)"
    else
        fail "cxagents-node.AC8.1 (${bad})"
    fi
}

check_ac5_6_restart() {
    running "$fwd" || { fail "AC5.6 restart (${fwd} not running)"; return; }
    local id0 id1 info0 info1 rc
    id0="$(state_id)"; info0="$(fwd_check 2>/dev/null)"
    just_cx restart >/dev/null 2>&1 || { fail "AC5.6 restart (just cxagents restart failed)"; return; }
    if ! wait_healthy; then fail "AC5.6 restart (not healthy within 180 s)"; return; fi
    id1="$(state_id)"; info1="$(fwd_check 2>/dev/null)"; rc=$?
    if [ -n "$id0" ] && [ "$id0" = "$id1" ] && [ "$rc" -eq 0 ] \
        && grep -qx "node:  *${cx_host} (${H//./\\.})" <<<"$info1" \
        && grep -qx 'tags:  *tag:cxagents' <<<"$info1" && grep -qx 'online: *yes' <<<"$info1"; then
        pass "cxagents-node.AC5.6 restart keeps identity (${id1}; name cxagents, tag:cxagents, online)"
    else
        fail "AC5.6 restart (id ${id0} -> ${id1}; check rc=${rc}; before: $(awk '/^node:/{print $2}' <<<"$info0"))"
    fi
}

# ---- Phase 6: end-to-end through the forwarder ------------------------------
e2e_skip=0   # set to 1 when e2e_setup fails: every e2e check then FAILs as setup failed
netrc_dir=""
netrc_file=""
cleanup_netrc() { if [ -n "$netrc_dir" ]; then rm -rf "$netrc_dir"; fi; }

# Registered first so it runs last at EXIT (after the restores that bring the
# shell back). Stops the fixture servers and removes their copies in the shell.
e2e_cleanup() {
    running "$shell_ctr" || return 0
    X pkill -f /tmp/cxsmoke >/dev/null 2>&1 || true
    X pkill -f 'http.server 4780' >/dev/null 2>&1 || true
    if ! X rm -rf /tmp/cxsmoke >/dev/null 2>&1; then
        warn "AC6 cleanup (could not remove /tmp/cxsmoke in ${shell_ctr}; remove it by hand)"
    fi
}
add_cleanup e2e_cleanup

# e2e_ok LABEL: the shell and the forwarder must both be running; FAILs otherwise.
e2e_ok() {
    if [ "$e2e_skip" -eq 1 ]; then fail "$1 (e2e setup failed; see the AC6 setup line)"; return 1; fi
    running "$shell_ctr" "$fwd" && return 0
    fail "$1 (${shell_ctr} or ${fwd} not running)"
    return 1
}
# shell_listens PORT: connectome-shell has a listening socket on PORT.
shell_listens() {
    local out
    out="$(X ss -ltn 2>/dev/null)"
    grep -q ":$1 " <<<"$out"
}
wait_shell_listens() {  # wait_shell_listens PORT: up to 20 s
    local _
    for _ in $(seq 1 20); do
        shell_listens "$1" && return 0
        sleep 1
    done
    return 1
}
# e2e_setup: copies the stdlib servers into connectome-shell and starts them.
e2e_setup() {
    running "$shell_ctr" || { fail "AC6 setup (${shell_ctr} not running)"; return 1; }
    # Streamed as a tar so the files are owned by the shell user (uid 1000) and
    # caches are never copied in (a Mac-side __pycache__ would keep uid 501 and
    # could not be removed by the shell's cleanup).
    tar -C "$smoke_dir" --exclude='__pycache__' --exclude='*.pyc' -cf - . \
        | D exec -i "$shell_ctr" sh -c 'mkdir -p /tmp/cxsmoke && tar -C /tmp/cxsmoke -xf - --no-same-owner' \
        || { fail "AC6 setup (copy of the smoke servers failed)"; return 1; }
    D exec -d "$shell_ctr" python3 -B /tmp/cxsmoke/ws_echo_server.py 47801
    D exec -d "$shell_ctr" python3 -B /tmp/cxsmoke/echo_server.py 47803
    D exec -d "$shell_ctr" python3 -B /tmp/cxsmoke/banner_server.py 47804
    D exec -d "$shell_ctr" python3 -B -m http.server 47806 --bind 127.0.0.1 -d /tmp/cxsmoke
    local p
    for p in 47801 47803 47804 47806; do
        wait_shell_listens "$p" || { fail "AC6 setup (port ${p} not listening in ${shell_ctr} within 20 s)"; return 1; }
    done
}

check_ac6_1() {
    e2e_ok "cxagents-node.AC6.1" || return
    local body
    body="$(curl -fsS --max-time 15 "https://${H}:47801/" 2>/dev/null)" \
        || { fail "cxagents-node.AC6.1 (https://${H}:47801/ failed)"; return; }
    if grep -q cxsmoke-ws <<<"$body"; then
        pass "cxagents-node.AC6.1 https://${H}:47801/ serves the page (system trust, no -k)"
    else
        fail "cxagents-node.AC6.1 (page does not contain cxsmoke-ws)"
    fi
}

check_ac6_2() {
    e2e_ok "cxagents-node.AC6.2" || return
    local body
    body="$(curl -fsS --max-time 15 "http://${H}:47801/" 2>/dev/null)" \
        || { fail "cxagents-node.AC6.2 (http://${H}:47801/ failed)"; return; }
    if grep -q cxsmoke-ws <<<"$body"; then
        pass "cxagents-node.AC6.2 http://${H}:47801/ serves the page (plain HTTP on the same port)"
    else
        fail "cxagents-node.AC6.2 (page does not contain cxsmoke-ws)"
    fi
}

check_ac6_3() {
    e2e_ok "cxagents-node.AC6.3" || return
    local out rc
    out="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "${smoke_dir}/ws_client.py" "wss://${H}:47801/" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = ok ]; then
        pass "cxagents-node.AC6.3 wss:// upgrade, masked echo over TLS"
    else
        fail "cxagents-node.AC6.3 (ws_client rc=${rc}: ${out})"
    fi
    if [ "$long" -eq 1 ]; then
        out="$(PYTHONDONTWRITEBYTECODE=1 python3 -B "${smoke_dir}/ws_client.py" "wss://${H}:47801/" --idle 600 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ] && [ "$out" = ok ]; then
            pass "cxagents-node.AC6.3 idle 10 min, then the websocket still echoes"
        else
            fail "cxagents-node.AC6.3 idle 10 min (ws_client rc=${rc}: ${out})"
        fi
    else
        off "AC6.3 idle 10 min (run: dotfiles stacks cxagents smoke --long)"
    fi
}

check_ac6_4() {
    e2e_ok "cxagents-node.AC6.4" || return
    local echo_out banner
    echo_out="$(printf 'ping\n' | nc -w 5 "$H" 47803 2>/dev/null)"
    banner="$(nc -w 5 "$H" 47804 </dev/null 2>/dev/null | head -1)"
    banner="${banner%$'\r'}"
    if [ "$echo_out" = ping ] && [ "$banner" = "SSH-2.0-cxsmoke" ]; then
        pass "cxagents-node.AC6.4 raw TCP echo on 47803 and banner-first on 47804"
    else
        fail "cxagents-node.AC6.4 (echo='${echo_out}' banner='${banner}')"
    fi
}

check_ac6_5() {
    e2e_ok "cxagents-node.AC6.5" || return
    local start end rc up=0
    start=$(date +%s)
    curl -sS --max-time 10 -o /dev/null "http://${H}:47805/" >/dev/null 2>&1; rc=$?
    end=$(date +%s)
    if ! refused_rc "$rc" || [ $((end - start)) -gt 3 ]; then
        fail "cxagents-node.AC6.5 (nothing on 47805: want curl rc 7, 52 or 56 within 3 s; curl rc=${rc}, $((end - start)) s)"
        return
    fi
    D exec -d "$shell_ctr" python3 -B -m http.server 47805 --bind 0.0.0.0 -d /tmp/cxsmoke
    if wait_shell_listens 47805 && curl -fsS --max-time 10 -o /dev/null "http://${H}:47805/" 2>/dev/null; then
        up=1
    fi
    X pkill -f 'http.server 47805' >/dev/null 2>&1 || true
    if [ "$up" -eq 1 ]; then
        pass "cxagents-node.AC6.5 nothing on 47805 fails fast (curl rc=${rc}, $((end - start)) s); the same URL works once the shell listens"
    else
        fail "cxagents-node.AC6.5 (shell listening on 47805 but the forwarded request failed)"
    fi
}

check_ac6_6() {
    e2e_ok "cxagents-node.AC6.6" || return
    if ! shell_listens 3100; then
        fail "cxagents-node.AC6.6 (connectome-shell is not listening on 3100, so the deny check proves nothing)"
        return
    fi
    if nc -z -w 3 "$H" 3100 >/dev/null 2>&1 || nc -z -w 3 "$H" 80 >/dev/null 2>&1; then
        fail "cxagents-node.AC6.6 (3100 or 80 reachable through the forwarder)"
    else
        pass "cxagents-node.AC6.6 3100 (listening in the shell) and 80 (nothing) are unreachable through the forwarder"
    fi
}

check_ac6_7() {
    e2e_ok "cxagents-node.AC6.7" || return
    local rc
    curl -sS --max-time 5 -o /dev/null "http://${H}:47806/" >/dev/null 2>&1; rc=$?
    if refused_rc "$rc"; then
        pass "cxagents-node.AC6.7 loopback-only 47806 in the shell is unreachable from cxmini (curl rc=${rc})"
    else
        fail "cxagents-node.AC6.7 (47806 through the forwarder: want curl rc 7, 52 or 56; got rc=${rc})"
    fi
}

check_ac6_10_e2e() {
    e2e_ok "cxagents-node.AC6.10" || return
    local ip rc
    ip="$("$ts" status --json 2>/dev/null | jq -r '.Peer[]? | select(.HostName == "cxagents") | .TailscaleIPs[0]' 2>/dev/null | head -1)"
    if [ -z "$ip" ]; then fail "cxagents-node.AC6.10 (cxagents has no tailnet IP on cxmini)"; return; fi
    # No SNI: the forwarder's TLS side must fail the handshake cleanly (curl 35).
    curl -sk --max-time 10 -o /dev/null "https://${ip}:47801/" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 35 ]; then
        pass "cxagents-node.AC6.10 TLS by IP without SNI fails the handshake (curl exit 35)"
    else
        fail "cxagents-node.AC6.10 (curl exit ${rc}, want 35)"
    fi
}

check_ac7_1() {
    e2e_ok "cxagents-node.AC7.1" || return
    local text json miss=""
    text="$(X curl -fsS http://cxagents-forwarder:8080/status 2>/dev/null)" \
        || { fail "cxagents-node.AC7.1 (status endpoint not reachable from ${shell_ctr})"; return; }
    grep -qxF 'target: connectome-shell' <<<"$text" || miss="${miss} target"
    grep -qxF "node:   https://${H}:<port>" <<<"$text" || miss="${miss} node"
    grep -qxF 'range:  1024-65535   deny: 3100' <<<"$text" || miss="${miss} range"
    grep -qxF "  47801  http=yes   https://${H}:47801" <<<"$text" || miss="${miss} 47801-line"
    grep -qxF "  47803  http=no    (raw TCP)  ${H}:47803" <<<"$text" || miss="${miss} 47803-line"
    json="$(X curl -fsS 'http://cxagents-forwarder:8080/status?format=json&ports=47801,47803' 2>/dev/null)"
    printf '%s' "$json" \
        | jq -e '.target == "connectome-shell" and (.listening | map(.port) | sort) == [47801, 47803]' >/dev/null 2>&1 \
        || miss="${miss} json"
    if [ -z "$miss" ]; then
        pass "cxagents-node.AC7.1 status text and JSON name connectome-shell, range 1024-65535, deny 3100, 47801 and 47803"
    else
        fail "cxagents-node.AC7.1 (missing:${miss})"
    fi
}

check_ac7_3() {
    e2e_ok "cxagents-node.AC7.3" || return
    local ss_out text
    ss_out="$(X ss -ltn 2>/dev/null)"
    text="$(X curl -fsS http://cxagents-forwarder:8080/status 2>/dev/null)"
    if ! grep -q '127.0.0.1:47806 ' <<<"$ss_out"; then
        fail "cxagents-node.AC7.3 (shell does not listen on 127.0.0.1:47806)"
    elif [ -z "$text" ]; then
        fail "cxagents-node.AC7.3 (status text unavailable)"
    elif grep -q 47806 <<<"$text"; then
        fail "cxagents-node.AC7.3 (status text lists 47806)"
    else
        pass "cxagents-node.AC7.3 127.0.0.1:47806 is listening in the shell and absent from the status text"
    fi
}

check_ac7_4() {
    e2e_ok "cxagents-node.AC7.4" || return
    local probe body rc ok_probe=0
    probe="$(D run --rm --network cxagents "$probe_image" sh -c 'printf "GET /status HTTP/1.0\r\nHost: x\r\n\r\n" | nc -w 5 cxagents-forwarder 8080' 2>/dev/null)"
    if grep -q ' 404 ' <<<"$probe" && grep -q 'not a cxagents target' <<<"$probe"; then ok_probe=1; fi
    body="$(curl -sS --max-time 5 "http://${H}:8080/status" 2>/dev/null)"; rc=$?
    if [ "$ok_probe" -eq 1 ] && ! grep -q 'target:' <<<"$body"; then
        pass "cxagents-node.AC7.4 non-target peer gets 404 'not a cxagents target'; :8080 from cxmini does not answer"
    else
        fail "cxagents-node.AC7.4 (peer probe ok=${ok_probe}; cxmini :8080 curl rc=${rc})"
    fi
}

# webui_code [CURL_ARGS...]: HTTP status of GET https://cxmini:8768/ with the netrc.
webui_code() {
    curl -sS --max-time 10 --netrc-file "$netrc_file" -o /dev/null -w '%{http_code}' "$@" \
        "https://${M}:8768/" 2>/dev/null
}
check_ac9_5() {
    e2e_ok "cxagents-node.AC9.5" || return
    local env_file="${cx_repo_root}/stacks/connectome/.env" user pass
    local c_same c_cross c_origin c_same_origin c_plain
    # Read into variables; never echoed. The netrc is mode 600 in a trap-cleaned temp dir.
    user="$(sed -n 's/^WEBUI_USER=//p' "$env_file" 2>/dev/null | head -1)"
    pass="$(sed -n 's/^WEBUI_PASS=//p' "$env_file" 2>/dev/null | head -1)"
    if [ -z "$user" ] || [ -z "$pass" ]; then
        fail "cxagents-node.AC9.5 (WEBUI_USER or WEBUI_PASS missing from stacks/connectome/.env)"
        return
    fi
    netrc_dir="$(mktemp -d)" || { fail "cxagents-node.AC9.5 (mktemp failed)"; return; }
    add_cleanup cleanup_netrc
    netrc_file="${netrc_dir}/netrc"
    (umask 077; printf 'machine %s login %s password %s\n' "$M" "$user" "$pass" >"$netrc_file")
    chmod 600 "$netrc_file"
    user=""; pass=""

    c_same="$(webui_code -H 'Sec-Fetch-Site: same-site')"
    c_cross="$(webui_code -H 'Sec-Fetch-Site: cross-site')"
    c_origin="$(webui_code -H "Origin: https://${H}:47801")"
    c_same_origin="$(webui_code -H 'Sec-Fetch-Site: same-origin' -H "Origin: https://${M}:8768")"
    c_plain="$(webui_code)"
    if [ "$c_same" = 403 ] && [ "$c_cross" = 403 ] && [ "$c_origin" = 403 ] \
        && [ "$c_same_origin" = 200 ] && [ "$c_plain" = 200 ]; then
        pass "cxagents-node.AC9.5 WebUI guard: same-site 403, cross-site 403, foreign Origin 403; same-origin 200, no headers 200"
    else
        fail "cxagents-node.AC9.5 (same-site=${c_same} cross-site=${c_cross} foreign-origin=${c_origin} same-origin=${c_same_origin} plain=${c_plain})"
    fi
}

check_ac5_6_downup() {
    add_cleanup restore_connectome
    add_cleanup restore_forwarder
    local id0 id1 info1 rc joined
    id0="$(state_id)"
    just_connectome down >/dev/null 2>&1 || { fail "AC5.6 down/up (just connectome down failed)"; return; }
    just_cx down >/dev/null 2>&1 || { fail "AC5.6 down/up (just cxagents down failed)"; return; }
    if running "$fwd"; then fail "AC5.6 down/up (${fwd} still running after down)"; return; fi
    just_cx up >/dev/null 2>&1 || { fail "AC5.6 down/up (just cxagents up failed)"; return; }
    if ! wait_healthy; then fail "AC5.6 down/up (not healthy within 180 s)"; return; fi
    just_connectome up >/dev/null 2>&1 || { fail "AC5.6 down/up (just connectome up failed)"; return; }
    id1="$(state_id)"; info1="$(fwd_check 2>/dev/null)"; rc=$?
    joined="$(D inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$shell_ctr" 2>/dev/null)"
    if [ -n "$id0" ] && [ "$id0" = "$id1" ] && [ "$rc" -eq 0 ] \
        && grep -qx "node:  *${cx_host} (${H//./\\.})" <<<"$info1" \
        && case " ${joined} " in *" cxagents "*) true ;; *) false ;; esac; then
        pass "cxagents-node.AC5.6 down/up keeps identity (${id1}); ${shell_ctr} is back on cxagents"
    else
        fail "AC5.6 down/up (id ${id0} -> ${id1}; check rc=${rc}; shell networks: ${joined})"
    fi
}

check_ac5_3
check_ac8_1
check_ac5_6_restart
e2e_setup || e2e_skip=1
check_ac6_1
check_ac6_2
check_ac6_3
check_ac6_4
check_ac6_5
check_ac6_6
check_ac6_7
check_ac6_10_e2e
check_ac7_1
check_ac7_3
check_ac7_4
check_ac9_5
check_ac5_6_downup

[ "$__check_failed" -eq 0 ] || exit 1
