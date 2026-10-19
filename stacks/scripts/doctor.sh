#!/usr/bin/env bash
# stacks/scripts/doctor.sh
# Read-only diagnostic for the dotfiles stacks layer.
# Exits 0 if no FAILs, 1 otherwise. WARN never fails the run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check.sh
source "${SCRIPT_DIR}/lib/check.sh"

TAILSCALE="/opt/homebrew/bin/tailscale"

echo "--- Infrastructure ---"

# 1. Colima profiles Running
for profile in shared bridged; do
    status=$(colima list 2>/dev/null \
        | awk -v p="$profile" '$1 == p {print $2}')
    if [ "$status" = "Running" ]; then
        pass "colima profile '$profile' is Running"
    elif [ -z "$status" ]; then
        fail "colima profile '$profile' not found (run: dotfiles stacks vm-$profile)"
    else
        fail "colima profile '$profile' status is '$status' (expected Running)"
    fi
done

# 1b. Agents profile (on-demand). Always reported; OFF when not Running
# is informational, not a warning.
status=$(colima list 2>/dev/null \
    | awk '$1 == "agents" {print $2}')
if [ "$status" = "Running" ]; then
    pass "colima profile 'agents' is Running"
else
    off "colima profile 'agents' is ${status:-not created} (start with: dotfiles stacks vm-agents-up)"
fi

# 2. Docker contexts present and connectable
contexts=$(docker context ls --format '{{.Name}}' 2>/dev/null || true)
for ctx in colima-shared colima-bridged; do
    if echo "$contexts" | grep -qx "$ctx"; then
        if docker --context "$ctx" info >/dev/null 2>&1; then
            pass "docker context '$ctx' connects"
        else
            fail "docker context '$ctx' present but not connectable"
        fi
    else
        fail "docker context '$ctx' missing"
    fi
done

# 2b. Agents docker context. Always reported; OFF when not present /
# not connectable is informational (the context is created on VM start).
if echo "$contexts" | grep -qx "colima-agents"; then
    if docker --context colima-agents info >/dev/null 2>&1; then
        pass "docker context 'colima-agents' connects"
    else
        off "docker context 'colima-agents' not connectable"
    fi
else
    off "docker context 'colima-agents' not registered"
fi

# 3. socket_vmnet daemon — must be Colima's bridged-mode instance
# (/opt/colima/bin, started by `colima start -p bridged`), not just any
# socket_vmnet: the Homebrew shared-mode LaunchDaemon also matches a bare
# `pgrep -x socket_vmnet` but does nothing for the bridged VM.
if pgrep -f 'socket_vmnet --vmnet-mode bridged' >/dev/null; then
    pass "socket_vmnet daemon (bridged mode) running"
elif pgrep -x socket_vmnet >/dev/null; then
    fail "socket_vmnet running, but not Colima's bridged-mode instance (bridged VM networking will fail; start via: dotfiles stacks vm-bridged-up)"
else
    fail "socket_vmnet daemon not running (bridged-profile networking will fail)"
fi

# 4. just version
if command -v just >/dev/null 2>&1; then
    just_version=$(just --version | awk '{print $2}')
    # Compare major.minor numerically against 1.13
    major=$(echo "$just_version" | cut -d. -f1)
    minor=$(echo "$just_version" | cut -d. -f2)
    if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 13 ]; }; then
        pass "just $just_version (>=1.13 supports subsequent deps)"
    else
        fail "just $just_version is too old; need >=1.13 for 'recipe: dep && post' syntax"
    fi
else
    fail "just not on PATH"
fi

# 5. Tailscale CLI reachable
if [ -x "$TAILSCALE" ]; then
    pass "tailscale CLI present at $TAILSCALE"
else
    fail "tailscale CLI missing at $TAILSCALE (run: brew install tailscale)"
fi

echo
echo "--- Stack volumes ---"
for stack in adguard freshrss homebridge wallabag; do
    dir="${HOME}/.volumes/${stack}"
    if [ ! -d "$dir" ]; then
        fail "${stack} host volume dir missing: ${dir}"
    elif [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        fail "${stack} host volume dir empty: ${dir}"
    else
        pass "${stack} host volume dir present and non-empty"
    fi
done

# onecli stores its vault in Docker named volumes inside the agents VM
# (NOT under ~/.volumes/onecli/) — see stacks/onecli/README.md "Volumes"
# for the threat-model rationale. Check the named volumes when the VM
# is up; report [OFF] otherwise.
if docker --context colima-agents info >/dev/null 2>&1; then
    onecli_volumes=$(docker --context colima-agents volume ls --format '{{.Name}}' 2>/dev/null || true)
    for vol in onecli_pgdata onecli_app-data; do
        if echo "$onecli_volumes" | grep -qx "$vol"; then
            pass "onecli named volume '$vol' present in colima-agents"
        else
            fail "onecli named volume '$vol' missing in colima-agents (run: dotfiles stacks onecli up)"
        fi
    done
    for vol in connectome_state connectome_workspace connectome_outbox; do
        if echo "$onecli_volumes" | grep -qx "$vol"; then
            pass "connectome named volume '$vol' present in colima-agents"
        else
            fail "connectome named volume '$vol' missing in colima-agents (run: dotfiles stacks connectome up)"
        fi
    done
else
    off "onecli volumes not checked (colima-agents not running)"
fi

echo
echo "--- Backups ---"

backups_dir="${HOME}/.volume-backups/daily"
agents_up=0
if docker --context colima-agents info >/dev/null 2>&1; then
    agents_up=1
fi
for stack in adguard connectome freshrss homebridge onecli wallabag; do
    # onecli's and connectome's backup recipes are no-ops when colima-agents is down, so
    # the >36h rule would FAIL daily on hosts that keep agents off.
    # Report [OFF] in that case; otherwise apply the normal rule.
    if { [ "$stack" = "onecli" ] || [ "$stack" = "connectome" ]; } && [ "$agents_up" -eq 0 ]; then
        off "${stack} backup-age skipped (colima-agents not running)"
        continue
    fi
    if [ ! -d "$backups_dir" ]; then
        fail "${stack} has no backups yet (no ~/.volume-backups/daily/)"
        continue
    fi
    # Find most-recent tarball for this stack
    latest=$(find "$backups_dir" -maxdepth 1 -name "${stack}-*.tgz" -print 2>/dev/null \
        | sort | tail -1)
    if [ -z "$latest" ]; then
        fail "${stack} has no backups yet"
        continue
    fi
    # mtime in epoch seconds (BSD stat syntax — macOS default)
    mtime=$(stat -f %m "$latest")
    now=$(date +%s)
    age_hours=$(( (now - mtime) / 3600 ))
    if [ "$age_hours" -gt 36 ]; then
        fail "${stack} latest backup is ${age_hours}h old (>36h)"
    else
        pass "${stack} latest backup is ${age_hours}h old"
    fi
done

echo
echo "--- DNS forwarder ---"

# The dns-forward LaunchDaemon relays this node's Tailscale IP :53 -> the
# bridged VM's AGH :53, so tailnet clients resolve via a native 100.x node IP
# instead of the subnet-routed VM LAN IP. Global NS (DNS failover, below)
# points at node_ip, so the relay is a hard dependency of that "on" state.
node_ip=$("$TAILSCALE" ip -4 2>/dev/null | head -1)
dnsfwd_plist="/Library/LaunchDaemons/com.cxreiff.dotfiles.dns-forward.plist"
if [ ! -f "$dnsfwd_plist" ]; then
    off "dns-forward daemon not installed (tailnet DNS relay; run: dotfiles stacks dns-forward-install)"
elif [ -z "$node_ip" ]; then
    warn "dns-forward installed but node Tailscale IP unreadable (is Tailscale up?)"
else
    # Process + probe cross-check. A dig answer alone is NOT proof the relay
    # works: mDNSResponder holds wildcard *:53 whenever Internet Sharing
    # machinery is up (e.g. a shared-mode vmnet daemon) and answers UDP
    # probes on node_ip whenever socat is down — real but UNFILTERED
    # answers, which masked a dead relay from 2026-06-09 to 2026-07-26.
    # Healthy = both socat listeners exist AND the probe answers.
    udp_pid=$(pgrep -f "socat.*UDP4-RECVFROM:53,bind=${node_ip}" | head -1)
    tcp_pid=$(pgrep -f "socat.*TCP4-LISTEN:53,bind=${node_ip}" | head -1)
    dig_ok=""
    dig +time=2 +tries=1 "@${node_ip}" google.com >/dev/null 2>&1 && dig_ok=1

    if [ -n "$udp_pid" ] && [ -n "$tcp_pid" ] && [ -n "$dig_ok" ]; then
        pass "dns-forward relay answering at ${node_ip}:53 (socat UDP pid ${udp_pid}, TCP pid ${tcp_pid})"
    elif [ -z "$udp_pid" ] && [ -z "$tcp_pid" ] && [ -n "$dig_ok" ]; then
        fail "${node_ip}:53 answers but no socat relay is running — mDNSResponder *:53 imposter; tailnet DNS is bypassing AdGuard (check: sudo launchctl print system/com.cxreiff.dotfiles.dns-forward)"
    elif [ -z "$udp_pid" ] || [ -z "$tcp_pid" ]; then
        fail "dns-forward relay degraded (UDP socat: ${udp_pid:-down}, TCP socat: ${tcp_pid:-down}) — see ~/Library/Logs/com.cxreiff.dotfiles.dns-forward.err.log"
    else
        fail "dns-forward socat listeners running but ${node_ip}:53 not answering (bridged VM IP changed? AGH down?)"
    fi
fi

echo
echo "--- Tailnet ---"

# Declared tailnet state (tailscale/): policy drift, OAuth client scopes,
# identity, settings, credentials file. Key names only; never .env values.
tailnet_lines=0
while IFS= read -r line; do
    tailnet_lines=$((tailnet_lines + 1))
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "tailnet: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../../tailscale/scripts/doctor.sh" 2>&1)
[ "$tailnet_lines" -gt 0 ] || warn "tailnet: tailscale/scripts/doctor.sh produced no output"

echo
echo "--- DNS failover ---"

agh_state=$(docker --context colima-bridged inspect adguardhome \
    --format '{{.State.Running}}' 2>/dev/null || echo "false")
# $NF ~ dotted-quad guard: when the bridged VM is Running but col0 has no
# DHCP lease, `colima list` leaves ADDRESS empty and $NF is the RUNTIME
# column ("docker") — vm_ip must come back empty, not garbage.
vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" && $NF ~ /^([0-9]+\.){3}[0-9]+$/ {print $NF}')

tailnet_dns="${SCRIPT_DIR}/../adguard/scripts/tailnet-dns.sh"
if [ -x "$tailnet_dns" ]; then
    ns_json=$("$tailnet_dns" status 2>/dev/null | jq -r '.dns | @json' 2>/dev/null || true)
else
    ns_json=""
fi

# Global NS "on" target is this node's Tailscale IP (the dns-forward relay),
# NOT the bridged VM IP — see "DNS forwarder" above and tailnet-dns.sh.
on_target="[\"${node_ip}\"]"
if [ -z "$ns_json" ]; then
    warn "tailnet-dns status unavailable (tailscale/.env missing or API unreachable)"
elif [ -z "$node_ip" ]; then
    warn "node Tailscale IP unreadable — cannot evaluate tailnet NS (is Tailscale up?)"
elif [ "$agh_state" = "true" ] && [ "$ns_json" = "$on_target" ]; then
    pass "AGH Up + tailnet NS points at node relay (${node_ip})"
elif [ "$agh_state" = "true" ] && [ "$ns_json" != "$on_target" ]; then
    warn "AGH Up but tailnet NS = ${ns_json} (expected ${on_target})"
elif [ "$agh_state" = "false" ] && [ "$ns_json" = "$on_target" ]; then
    fail "AGH Down but tailnet NS still points at node relay — DNS bricked!"
else
    pass "AGH Down + tailnet NS pointed away from relay (${ns_json})"
fi

echo
echo "--- IP coupling ---"

if [ -z "$vm_ip" ]; then
    fail "bridged VM has no LAN IP (not Running, or col0 DHCP lease missing — recover: dotfiles stacks vm-bridged-down && dotfiles stacks vm-bridged-up); skipping IP-coupling checks"
else
    # 1. AGH bind_hosts vs current VM IP
    agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
    if [ -f "$agh_yaml" ]; then
        bind=$(awk '
            /^[[:space:]]+bind_hosts:/ { in_bh=1; next }
            in_bh && /^[[:space:]]+- / { gsub(/^[[:space:]]+- /, ""); print; exit }
        ' "$agh_yaml")
        if [ "$bind" = "$vm_ip" ]; then
            pass "AGH bind_hosts matches bridged VM IP (${vm_ip})"
        else
            fail "AGH bind_hosts is ${bind} but VM IP is ${vm_ip} (run: dotfiles stacks bridged-ip-changed)"
        fi
    else
        warn "AGH yaml not found at ${agh_yaml} (AGH never started?)"
    fi

    # 2/3. Tailscale serve mappings
    serve_status=$("$TAILSCALE" serve status 2>/dev/null || true)
    for port in 8689 8767; do
        block=$(echo "$serve_status" | grep -A1 -E ":${port}[^0-9]" || true)
        if [ -z "$block" ]; then
            warn "tailscale serve has no mapping for :${port} (run: dotfiles stacks <stack> serve)"
        elif echo "$block" | grep -qF "${vm_ip}"; then
            pass "tailscale serve :${port} points at ${vm_ip}"
        else
            fail "tailscale serve :${port} not pointing at ${vm_ip} (run: dotfiles stacks bridged-ip-changed)"
        fi
    done
fi

echo
echo "--- Agents (onecli + connectome) ---"

# Image CA files to compare with the gateway CA; overridable for the
# AC12.3 fixture test (DOCTOR_CONNECTOME_IMAGES="img1 img2").
connectome_images="${DOCTOR_CONNECTOME_IMAGES:-connectome-host:local connectome-shell:local}"
llm_warn_mb="${DOCTOR_LLM_CALLS_WARN_MB:-500}"
hlog_warn_mb="${DOCTOR_HEADLESS_LOG_WARN_MB:-50}"
A="docker --context colima-agents"
if ! $A info >/dev/null 2>&1; then
    off "agents checks skipped (colima-agents not running)"
else
    for n in onecli-api onecli-web onecli-gateway; do
        h=$($A inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$n" 2>/dev/null || echo missing)
        [ "$h" = healthy ] && pass "$n healthy" || fail "$n is ${h} (run: dotfiles stacks onecli up)"
    done
    m=$($A inspect -f '{{.State.Status}} {{.State.ExitCode}}' onecli-migrations 2>/dev/null || echo "missing -")
    [ "$m" = "exited 0" ] && pass "onecli-migrations exited 0" || fail "onecli-migrations: ${m}"

    gw_uid=$($A exec onecli-gateway id -u 2>/dev/null || echo "?")
    ca_uid=$($A exec onecli-gateway stat -c %u /app/data/gateway/ca.pem 2>/dev/null || echo "??")
    [ "$gw_uid" = "$ca_uid" ] && pass "gateway CA owned by gateway uid (${gw_uid})" \
        || fail "gateway CA owner uid ${ca_uid} != gateway uid ${gw_uid}"

    gw_ca=$($A exec onecli-gateway cat /app/data/gateway/ca.pem 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    for img in $connectome_images; do
        if ! $A image inspect "$img" >/dev/null 2>&1; then
            fail "image ${img} missing (run: dotfiles stacks connectome build)"; continue
        fi
        img_ca=$($A run --rm --network none --entrypoint cat "$img" /usr/local/share/ca-certificates/onecli-gateway.crt 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
        [ "$img_ca" = "$gw_ca" ] && pass "${img} CA fingerprint matches gateway CA" \
            || fail "${img} CA fingerprint differs from onecli-gateway CA (fresh vault? run: dotfiles stacks connectome build)"
    done

    attached=$($A network inspect onecli-agents -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    if [ -z "$attached" ]; then
        fail "network onecli-agents missing (run: dotfiles stacks onecli up)"
    else
        for n in connectome connectome-shell; do
            grep -qE "(^| )${n}( |$)" <<<"$attached" && pass "${n} attached to onecli-agents" \
                || fail "${n} not attached to onecli-agents (run: dotfiles stacks connectome up)"
        done
    fi

    # Shell must hold no LLM grant (needs the operator key in the host CLI).
    # shellcheck source=../onecli/scripts/lib/api.sh
    source "${SCRIPT_DIR}/../onecli/scripts/lib/api.sh"
    if operator_key >/dev/null 2>&1; then
        shell_id=$(agent_field connectome-shell id 2>/dev/null || true)
        if [ -z "$shell_id" ]; then
            fail "connectome-shell agent not found, or the onecli API is unreachable (run: dotfiles stacks onecli policy)"
        else
            # The shell is granted nothing at all (design: connectome-shell ← nothing),
            # so count every secret grant. Fail closed: an API error or a response
            # without a .secrets array is not evidence of "no grants".
            llm=$(api GET "/v1/agents/${shell_id}/grants" 2>/dev/null \
                | jq -e 'if (.secrets | type) == "array" then .secrets | length else error("shape") end' 2>/dev/null) || llm="?"
            if [ "$llm" = 0 ]; then
                pass "connectome-shell has no LLM grant"
            elif [ "$llm" = "?" ]; then
                fail "connectome-shell grants unreadable (API error or unexpected response shape)"
            else
                fail "connectome-shell holds ${llm} secret grant(s) (run: dotfiles stacks onecli policy)"
            fi
        fi
    else
        warn "connectome-shell grant check skipped (host onecli CLI not authenticated)"
    fi

    if $A inspect connectome >/dev/null 2>&1; then
        llm_kb=$($A exec connectome sh -c 'du -ck /agent/state/data/llm-calls.*.jsonl 2>/dev/null | tail -1 | cut -f1' 2>/dev/null || echo 0)
        hlog_kb=$($A exec connectome sh -c 'du -k /agent/state/data/headless.log 2>/dev/null | cut -f1' 2>/dev/null || echo 0)
        [ "${llm_kb:-0}" -gt $(( llm_warn_mb * 1024 )) ] && warn "connectome llm-calls total $(( llm_kb / 1024 )) MiB > ${llm_warn_mb} MiB (pruned >14d by backup)" \
            || pass "connectome llm-calls total $(( ${llm_kb:-0} / 1024 )) MiB"
        [ "${hlog_kb:-0}" -gt $(( hlog_warn_mb * 1024 )) ] && warn "connectome headless.log $(( hlog_kb / 1024 )) MiB > ${hlog_warn_mb} MiB (capped by backup)" \
            || pass "connectome headless.log $(( ${hlog_kb:-0} / 1024 )) MiB"
    fi
fi

# Static security-invariant lints (key names only; never .env values).
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        *)         [ -n "$line" ] && warn "lint: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../connectome/scripts/lint.sh" 2>&1)

echo
echo "--- cxagents ---"

# The cxagents tailnet node (stacks/cxagents): health, identity, cert, routes
# targets, lockdown lints. Reads no .env value; the lint reads key names only.
cxagents_lines=0
while IFS= read -r line; do
    cxagents_lines=$((cxagents_lines + 1))
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "cxagents: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../cxagents/scripts/doctor.sh" 2>&1)
[ "$cxagents_lines" -gt 0 ] || warn "cxagents: doctor produced no output"

echo
echo "--- Stack identity & env ---"

# Check A: homebridge BRIDGE_USERNAME matches config.json bridge.username
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
hb_env="${repo_root}/stacks/homebridge/.env"
hb_config="${HOME}/.volumes/homebridge/config.json"
if [ -f "$hb_env" ] && [ -f "$hb_config" ]; then
    # NOTE: Per AC5.4 doctor avoids reading .env *secret* values. BRIDGE_USERNAME
    # is the public MAC-format pairing identifier, not a secret. This read is
    # required to verify AC5.8 (pairing identity coherence). Do not extend this
    # to other .env keys without revisiting AC5.4.
    bridge_env=$(grep -E '^BRIDGE_USERNAME=' "$hb_env" | cut -d= -f2-)
    bridge_config=$(jq -r '.bridge.username' "$hb_config")
    if [ "$bridge_env" = "$bridge_config" ]; then
        pass "homebridge BRIDGE_USERNAME matches config.json bridge.username"
    else
        fail "homebridge BRIDGE_USERNAME (.env=${bridge_env}) != config.json (${bridge_config}) — pairing will break"
    fi
fi

# Check B: env-key presence (no value reads, AC5.4-compliant)
for stack in adguard connectome freshrss homebridge onecli wallabag; do
    example="${repo_root}/stacks/${stack}/.env.example"
    actual="${repo_root}/stacks/${stack}/.env"
    if [ ! -f "$example" ]; then
        # adguard had no .env.example before Phase 5 — so .example may or may
        # not exist depending on plan progress. Skip gracefully.
        continue
    fi
    if [ ! -f "$actual" ]; then
        warn "${stack}/.env missing (run: cp .env.example .env && chmod 600 .env)"
        continue
    fi
    mode=$(stat -L -f %Lp "$actual")
    if [ "$mode" = 600 ]; then
        pass "${stack}/.env mode 0600"
    else
        fail "${stack}/.env mode ${mode} (run: chmod 600 stacks/${stack}/.env)"
    fi
    # Count keys per file (just the LHS of `=`, ignore comments)
    expected_keys=$(grep -E '^[A-Z][A-Z0-9_]*=' "$example" | sed 's/=.*//' | sort -u)
    missing=()
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -qE "^${key}=" "$actual"; then
            missing+=("$key")
        fi
    done <<< "$expected_keys"
    if [ "${#missing[@]}" -eq 0 ]; then
        pass "${stack}/.env has all keys from .env.example"
    else
        fail "${stack}/.env missing keys: ${missing[*]}"
    fi
done

# Exit status: 1 if any FAIL, 0 otherwise (WARN does not fail).
[ "$__check_failed" -eq 0 ] || exit 1
exit 0
