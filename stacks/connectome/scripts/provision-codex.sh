#!/usr/bin/env bash
# stacks/connectome/scripts/provision-codex.sh
# Operator-side, once (and for recovery): write the onecli Codex stub into the
# connectome `state` volume as codex/auth.json (0600, image uid) plus
# codex/config.toml from the tracked template. The stub's tokens are the
# literal "onecli-managed"; tokens.account_id is set to the REAL ChatGPT
# account id (an identifier, not a credential — Codex >= 0.162 refuses a stub
# whose account id fails workspace routing discovery). The operator's onecli
# API key is used here on the Mac only; it never enters a container.
# Never use the WebUI "log in again" action: it runs account/logout, deletes
# this stub and starts a real login (which onecli rule 6 blocks anyway).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../onecli/scripts/lib/api.sh
source "${SCRIPT_DIR}/../../onecli/scripts/lib/api.sh"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"

account_id=$(api GET /v1/org/secrets \
    | jq -r '(if type=="array" then . else (.secrets // .data // []) end)[] | select(.type=="openai") | .metadata.accountId // empty' | head -1)
[ -n "$account_id" ] || { echo "provision-codex: openai secret has no accountId (run: dotfiles stacks onecli import-openai)" >&2; exit 3; }

stub=$(api GET /v1/credential-stubs/codex | jq -r 'if type=="object" and has("content") then .content else tojson end')
auth=$(A="$account_id" jq -c '.tokens.account_id = env.A' <<<"$stub") \
    || { echo "provision-codex: stub is not JSON" >&2; exit 3; }
jq -e '.tokens.access_token=="onecli-managed" and .tokens.refresh_token=="onecli-managed"' <<<"$auth" >/dev/null \
    || { echo "provision-codex: stub carries non-placeholder tokens; refusing" >&2; exit 3; }

"${stack_dir}/scripts/compose.sh" run --rm --no-deps -T \
    --entrypoint sh connectome -c '
        umask 077
        mkdir -p /agent/state/codex
        cat > /agent/state/codex/auth.json
        cp /agent/recipes/codex-config.toml /agent/state/codex/config.toml
        chmod 600 /agent/state/codex/auth.json /agent/state/codex/config.toml
        ls -ln /agent/state/codex' <<<"$auth"
unset auth stub
echo "provision-codex: wrote codex/auth.json (account id set) and codex/config.toml"
