#!/usr/bin/env bash
# stacks/onecli/scripts/import-openai.sh
# One-time: run a DEDICATED `codex login --device-auth` into a throwaway
# CODEX_HOME, upload its auth.json to onecli as the org `openai` secret (OAuth
# mode; onecli derives host chatgpt.com and refreshes/persists rotated tokens
# itself), then delete the throwaway login. That login must never be used
# anywhere else: refresh-token rotation would invalidate one side.
#
# Exit codes: 0 ok; 1 secret already exists (pass --replace); 2 prereq; 3 API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/api.sh
source "${SCRIPT_DIR}/lib/api.sh"

codex_bin=$(type -P codex || true)   # bypass the token-meter shell function
[ -n "$codex_bin" ] || { echo "import-openai: codex CLI not found on PATH" >&2; exit 2; }

existing=$(api GET /v1/org/secrets | jq -r '(if type=="array" then . else (.secrets // .data // []) end)[] | select(.type=="openai") | .id')
if [ -n "$existing" ] && [ "${1:-}" != "--replace" ]; then
    echo "import-openai: an openai secret already exists (${existing}); re-run with: dotfiles stacks onecli import-openai --replace" >&2
    exit 1
fi

tmp_home=$(mktemp -d); chmod 700 "$tmp_home"
trap 'rm -rf "$tmp_home"' EXIT
echo "import-openai: starting a dedicated ChatGPT device-code login (complete it in your browser)"
# File store, so the dedicated login can't land in the macOS keychain.
CODEX_HOME="$tmp_home" "$codex_bin" login --device-auth -c cli_auth_credentials_store="file"
[ -s "$tmp_home/auth.json" ] || { echo "import-openai: login produced no auth.json" >&2; exit 3; }
jq -e '.tokens.access_token and .tokens.refresh_token' "$tmp_home/auth.json" >/dev/null \
    || { echo "import-openai: auth.json is not a ChatGPT OAuth login" >&2; exit 3; }

body=$(jq -c '{name:"openai", type:"openai", valueSource:"inline", hostPattern:"chatgpt.com", value:(. | tojson)}' "$tmp_home/auth.json")
created=$(api POST /v1/org/secrets "$body") || { echo "import-openai: POST /v1/org/secrets failed; keeping auth.json at ${tmp_home}/auth.json for manual recovery" >&2; trap - EXIT; exit 3; }
unset body
for id in $existing; do api DELETE "/v1/org/secrets/${id}" >/dev/null; done
secret_id=$(jq -r '.id' <<<"$created")
echo "import-openai: created secret ${secret_id}"

# Auto-reconcile grants: new LLM secrets auto-attach to every agent, so run
# the grants-only reconciliation now. If it fails, operator must run it manually.
if ! "${SCRIPT_DIR}/policy.sh" --grants-only; then
    echo "import-openai: NOTE: secret created, but grants reconciliation failed — run 'dotfiles stacks onecli policy' now to fix grants." >&2
    exit 3
fi
echo "import-openai: reconciled grants (openai → connectome-host only)"
# trap removes $tmp_home (the only copy of the dedicated login)
