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

# Exit status: 1 if any FAIL, 0 otherwise (WARN does not fail).
[ "$__check_failed" -eq 0 ] || exit 1
exit 0
