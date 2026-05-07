#!/usr/bin/env bash
# stacks/onecli/scripts/bootstrap.sh
# Trigger lazy local-admin creation in the onecli container, mint an API
# key for the host CLI, and persist it via `onecli auth login`. Idempotent.
#
# Onecli runs in AUTH_MODE=local (no NEXTAUTH_SECRET → single-user
# local-admin, hardcoded admin@localhost). The first authenticated HTTP
# hit lazy-creates the user, organization, project, and an API key.
# This script does that hit, then registers the resulting key with the
# host `onecli` CLI so `onecli secrets list` works from any shell.
#
# Exit codes:
#   0 — success (bootstrap done, or already done idempotently)
#   1 — unexpected state (script can't safely proceed without human input)
#   2 — missing prerequisite (.env, container, host CLI, jq)
#   3 — upstream failure (HTTP error, CLI error)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
context="colima-agents"

# --- Preflight: host tools ---
for tool in onecli jq curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "onecli bootstrap: '${tool}' not on PATH" >&2
        case "$tool" in
            onecli) echo "  recover: curl -fsSL onecli.sh/cli/install | sh" >&2 ;;
            jq|curl) echo "  recover: brew install ${tool}" >&2 ;;
        esac
        exit 2
    fi
done

# --- Preflight: .env exists and isn't set up for oauth ---
if [ ! -f "$env_file" ]; then
    echo "onecli bootstrap: ${env_file} missing" >&2
    echo "  recover: cp .env.example .env && chmod 600 .env && fill in" >&2
    exit 2
fi

# env_file: injects every .env key into the container. A NEXTAUTH_SECRET
# entry would flip onecli into oauth mode, which this stack isn't
# configured for — 401 every request, no usable bootstrap path.
if grep -qE '^NEXTAUTH_SECRET=' "$env_file"; then
    echo "onecli bootstrap: this stack runs in AUTH_MODE=local, but" >&2
    echo "  ${env_file} sets NEXTAUTH_SECRET (which forces oauth mode)." >&2
    echo "  recover: remove the NEXTAUTH_SECRET line, then re-run:" >&2
    echo "           dotfiles stacks onecli down && dotfiles stacks onecli up" >&2
    echo "           dotfiles stacks onecli bootstrap" >&2
    exit 1
fi

# --- Resolve gateway URL from .env (with the same defaults compose uses) ---
set -a; source "$env_file"; set +a
bind_host="${ONECLI_BIND_HOST:-127.0.0.1}"
app_port="${ONECLI_APP_PORT:-10254}"
url="http://${bind_host}:${app_port}"

# --- Preflight: container running ---
if ! docker --context "$context" compose ps --status running 2>/dev/null \
        | grep -qE '\bonecli\b'; then
    echo "onecli bootstrap: onecli container not running on ${context}" >&2
    echo "  recover: dotfiles stacks vm-agents-up && dotfiles stacks onecli up" >&2
    exit 2
fi

# --- Wait for the dashboard to respond ---
echo "Waiting for onecli to respond at ${url}..."
deadline=$(($(date +%s) + 60))
until curl -fsS -o /dev/null "${url}/api/health" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "onecli bootstrap: gateway did not become ready within 60s" >&2
        echo "  recover: dotfiles stacks onecli logs" >&2
        exit 2
    fi
    sleep 2
done

# --- Mint / fetch the API key ---
# In local mode, GET /api/user/api-key triggers lazy create (user, org,
# project, default agent, api_key) on first call and returns the same
# key on every subsequent call.
echo "Fetching local-admin API key..."
api_key_json=$(curl -fsS "${url}/api/user/api-key" 2>&1) || {
    echo "onecli bootstrap: GET /api/user/api-key failed" >&2
    echo "${api_key_json}" >&2
    echo "  If the response is 401/AUTH_REQUIRED: NEXTAUTH_SECRET is leaking" >&2
    echo "  in from somewhere (.env or shell). Fix and re-run." >&2
    exit 3
}

api_key=$(echo "$api_key_json" | jq -r '.apiKey // empty')
if [ -z "$api_key" ]; then
    echo "onecli bootstrap: API response had no .apiKey field" >&2
    echo "${api_key_json}" >&2
    exit 3
fi

# --- Register with the host CLI (idempotent) ---
echo "Configuring host CLI..."
onecli config set api-host "$url" >/dev/null
onecli auth login --api-key "$api_key" >/dev/null

# --- Verify ---
if ! onecli secrets list >/dev/null 2>&1; then
    echo "onecli bootstrap: 'onecli secrets list' failed after auth login" >&2
    echo "  recover: onecli auth status; check ~/.onecli/credentials/" >&2
    exit 3
fi

echo "Bootstrap complete. 'onecli secrets list' is now available from the host."
exit 0
