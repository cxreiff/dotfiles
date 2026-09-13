#!/usr/bin/env bash
# stacks/scripts/doctor.sh
# Read-only diagnostic for the dotfiles stacks layer.
# Exits 0 if no FAILs, 1 otherwise. WARN never fails the run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check.sh
source "${SCRIPT_DIR}/lib/check.sh"

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

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
    fail "tailscale CLI missing at $TAILSCALE (install Tailscale.app)"
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
for stack in adguard freshrss homebridge onecli wallabag; do
    # onecli's backup recipe is a no-op when colima-agents is down, so
    # the >36h rule would FAIL daily on hosts that keep agents off.
    # Report [OFF] in that case; otherwise apply the normal rule.
    if [ "$stack" = "onecli" ] && [ "$agents_up" -eq 0 ]; then
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
    warn "tailnet-dns status unavailable (PAT missing or API unreachable)"
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
for stack in adguard freshrss homebridge onecli wallabag; do
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
