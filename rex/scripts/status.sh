#!/usr/bin/env bash
# rex/scripts/status.sh — read-only checks of the Rex remote-access setup.
# Exit 0 when every check passes, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

fails=0
ok()   { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
warn() { echo "[WARN] $*"; }

if launchctl print "${REX_DOMAIN}/${REX_LABEL}" >/dev/null 2>&1; then
    agent_pid="$(launchctl print "${REX_DOMAIN}/${REX_LABEL}" | awk '$1 == "pid" {print $3; exit}')"
    ok "LaunchAgent ${REX_LABEL} loaded (pid ${agent_pid:-none})"
else
    agent_pid=""
    fail "LaunchAgent ${REX_LABEL} not loaded (run: dotfiles rex install)"
fi

status="$(rex_cli server status 2>/dev/null)" || status=""
if [ -z "$status" ]; then
    fail "no Rex server answering on the local socket"
else
    server_pid="$(awk '$1 == "pid:" {print $2; exit}' <<<"$status")"
    if [ -n "$agent_pid" ] && [ "$server_pid" = "$agent_pid" ]; then
        ok "Rex server (pid ${server_pid}) is the LaunchAgent's"
    else
        fail "Rex server (pid ${server_pid:-?}) is not the LaunchAgent's; Rex.app likely launched its own (run: dotfiles rex restart)"
    fi
    if grep -q '^tailscale: running' <<<"$status"; then
        fail "built-in Tailscale node is running ($(awk '/^tailscale:/ {print $NF}' <<<"$status")); run: rex server tailscale logout"
    else
        ok "built-in Tailscale node off"
    fi
fi

if [ -S "$REX_SERVE_SOCK" ]; then
    ok "serve socket ${REX_SERVE_SOCK} present"
else
    fail "serve socket ${REX_SERVE_SOCK} missing"
fi

serve_status="$("$TAILSCALE" serve status --json 2>/dev/null || true)"
if grep -q "unix:${REX_SERVE_SOCK}" <<<"$serve_status"; then
    ok "tailscale serve forwards https:443 to the serve socket ($("$TAILSCALE" status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/https:\/\/\1/p' | head -1))"
else
    fail "tailscale serve has no entry for unix:${REX_SERVE_SOCK} (run: dotfiles rex serve)"
fi

[ "$(defaults read "$REX_APP_ID" rex.server.automatic-restart-enabled 2>/dev/null)" = "0" ] \
    && ok "Rex.app automatic server restart off" \
    || warn "Rex.app automatic server restart is on; an app update may relaunch the server without the listener"

exit $(( fails > 0 ))
