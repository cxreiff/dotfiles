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

# 3. socket_vmnet daemon
if pgrep -x socket_vmnet >/dev/null; then
    pass "socket_vmnet daemon running"
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

echo
echo "--- Backups ---"

backups_dir="${HOME}/.volume-backups/daily"
for stack in adguard freshrss homebridge wallabag; do
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
echo "--- DNS failover ---"

agh_state=$(docker --context colima-bridged inspect adguardhome \
    --format '{{.State.Running}}' 2>/dev/null || echo "false")
vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')

tailnet_dns="${SCRIPT_DIR}/../adguard/scripts/tailnet-dns.sh"
if [ -x "$tailnet_dns" ]; then
    ns_json=$("$tailnet_dns" status 2>/dev/null | jq -r '.dns | @json' 2>/dev/null || true)
else
    ns_json=""
fi

if [ -z "$ns_json" ]; then
    warn "tailnet-dns status unavailable (PAT missing or API unreachable)"
elif [ "$agh_state" = "true" ] && [ "$ns_json" = "[\"${vm_ip}\"]" ]; then
    pass "AGH Up + tailnet NS points at AGH (${vm_ip})"
elif [ "$agh_state" = "true" ] && [ "$ns_json" != "[\"${vm_ip}\"]" ]; then
    warn "AGH Up but tailnet NS = ${ns_json} (expected [\"${vm_ip}\"])"
elif [ "$agh_state" = "false" ] && [ "$ns_json" = "[\"${vm_ip}\"]" ]; then
    fail "AGH Down but tailnet NS still points at AGH — DNS bricked!"
else
    pass "AGH Down + tailnet NS pointed away from AGH (${ns_json})"
fi

echo
echo "--- IP coupling ---"

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
for stack in adguard freshrss homebridge wallabag; do
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
