#!/usr/bin/env bash
# stacks/onecli/scripts/bootstrap.sh
# onecli v2 fresh-vault bootstrap (no browser): sign up — or sign in if the
# account exists — the operator account, fetch the user API key, and point
# the host onecli CLI at http://127.0.0.1:10256. Registration is open in v2
# with no switch, so run this immediately after the first `up`.
# Idempotent: exits early if the CLI already holds a working key.
#
# Exit codes: 0 ok; 2 missing prerequisite; 3 API failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/api.sh
source "${SCRIPT_DIR}/lib/api.sh"

for tool in "$ONECLI_BIN" jq curl; do
    command -v "$tool" >/dev/null || { echo "bootstrap: $tool not found" >&2; exit 2; }
done

until curl -fsS -o /dev/null "${ONECLI_API}/v1/health" 2>/dev/null; do
    [ "${waited:=0}" -ge 60 ] && { echo "bootstrap: API not healthy at ${ONECLI_API} (run: dotfiles stacks onecli up)" >&2; exit 2; }
    sleep 2; waited=$((waited + 2))
done

"$ONECLI_BIN" config set api-host "$ONECLI_API" >/dev/null
if operator_key >/dev/null 2>&1 && api GET /v1/user >/dev/null 2>&1; then
    echo "bootstrap: host CLI already authenticated against ${ONECLI_API}; nothing to do"
    exit 0
fi

read -r -p "onecli operator email: " email
read -r -s -p "onecli operator password (min 8 chars): " password; echo

jar_dir=$(mktemp -d); chmod 700 "$jar_dir"; jar="${jar_dir}/cookies"
trap 'rm -rf "$jar_dir"' EXIT
# Password via env, not jq argv.
creds=$(OB_EMAIL="$email" OB_PASS="$password" jq -cn '{email:env.OB_EMAIL, password:env.OB_PASS, name:(env.OB_EMAIL|split("@")[0])}')
unset password

auth_post() {  # auth_post <sign-up|sign-in> [output-file]
    local out="${3:-}"
    if [ -n "$out" ]; then
        printf '%s' "$creds" | curl -sS -o "$out" -w '%{http_code}' -c "$jar" -b "$jar" \
            -H 'Content-Type: application/json' --data-binary @- \
            "${ONECLI_API}/auth/$1/email"
    else
        printf '%s' "$creds" | curl -sS -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" \
            -H 'Content-Type: application/json' --data-binary @- \
            "${ONECLI_API}/auth/$1/email"
    fi
}
resp_file=$(mktemp)
trap 'rm -f "$resp_file"' EXIT
code=$(auth_post sign-up "$resp_file")
if [ "$code" -lt 400 ]; then
    echo "bootstrap: registered operator account ${email}"
else
    # Only fall back to sign-in if the user already exists (422) or the body mentions "exist".
    if [ "$code" = 422 ] || grep -qi exist "$resp_file"; then
        code=$(auth_post sign-in "$resp_file")
        [ "$code" -lt 400 ] || { echo "bootstrap: sign-up and sign-in both failed (HTTP ${code}): $(head -c 200 "$resp_file")" >&2; exit 3; }
        echo "bootstrap: signed in to existing account"
    else
        echo "bootstrap: sign-up failed (HTTP ${code}): $(head -c 200 "$resp_file")" >&2
        exit 3
    fi
fi

# First session call provisions org, workspace and the user API key.
session=$(curl -fsS -b "$jar" "${ONECLI_API}/v1/auth/session") || { echo "bootstrap: /v1/auth/session failed" >&2; exit 3; }
ws=$(jq -r '.workspaceId // .session.workspaceId // empty' <<<"$session")
key=$(curl -fsS -b "$jar" ${ws:+-H "X-Workspace-Id: $ws"} "${ONECLI_API}/v1/user/api-key" | jq -r '.apiKey // empty')
case "$key" in oc_*) ;; *) echo "bootstrap: could not read user API key" >&2; exit 3 ;; esac

# The CLI only accepts the key as a flag. This is a brief Mac-local argv
# exposure, the same as the v1 flow; containers never see this key.
"$ONECLI_BIN" auth login --api-key "$key" >/dev/null
unset key
"$ONECLI_BIN" agents list >/dev/null && echo "bootstrap: host CLI authenticated; 'onecli agents list' works"
