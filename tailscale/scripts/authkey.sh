#!/usr/bin/env bash
# tailscale/scripts/authkey.sh TAG — mint one auth key for TAG and print it
# (stdout, nothing else). Single-use, pre-authorized, non-ephemeral, 10-minute
# expiry. Meant to be piped straight into the consumer (e.g. cxagents login);
# never store it. Exit: as api.sh (2 credentials, 3 API); 2 on a bad TAG.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/conf.sh
source "${SCRIPT_DIR}/lib/conf.sh"
[ $# -eq 1 ] || { echo "usage: authkey.sh tag:<name>" >&2; exit 2; }
tag="$1"
[[ "$tag" =~ ^tag:[a-z0-9-]+$ ]] || { echo "usage: authkey.sh tag:<name>" >&2; exit 2; }
body="$(jq -nc --arg t "$tag" '{capabilities:{devices:{create:{reusable:false,ephemeral:false,preauthorized:true,tags:[$t]}}},expirySeconds:600,description:("dotfiles authkey " + ($t | ltrimstr("tag:")))}')"
resp="$("${SCRIPT_DIR}/api.sh" --client authkeys --tags "$tag" POST "/tailnet/${TAILNET}/keys" \
    -H 'Content-Type: application/json' -d "$body")" || exit $?
# Pipe, not a here-string: bash 3.2 writes here-strings to a temp file in /var/tmp.
key="$(printf '%s' "$resp" | jq -r '.key // empty')"
unset resp
[ -n "$key" ] || { echo "authkey: API returned no key" >&2; exit 3; }
printf '%s\n' "$key"
