#!/usr/bin/env bash
# tailscale/scripts/api.sh — authenticated Tailscale API calls. The ONLY code
# that reads the OAuth client secrets (tailscale/.env).
#
#   api.sh [--client admin|authkeys] [--tags "tag:a tag:b"] METHOD PATH [curl args...]
#       PATH is relative to https://api.tailscale.com/api/v2 (e.g. /tailnet/-/acl).
#       stdout: response body (also on an HTTP error, for callers that parse it).
#   api.sh [--client NAME] [--tags T] --granted-scopes
#       stdout: the space-separated `scope` of a fresh token exchange.
#   api.sh [--client NAME] [--tags T] --granted
#       stdout: one line, `scope<TAB>tags`, from one fresh token exchange (the
#       tags are the client's, as the exchange reports them; empty if none).
#       Give --tags only to test a request; doctor calls --granted without it.
#
# Exit: 0 on 2xx; 2 missing/placeholder/deprecated credentials (nothing sent);
#       3 HTTP/API error ("<what> -> HTTP <code>: <message>" on stderr).
# Never prints a secret or token: the secret reaches curl on stdin, the token
# and response bodies stay in memory (no temp files), and the bearer header
# comes from a process substitution. TAILSCALE_ENV_FILE overrides tailscale/.env
# (tests).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${TAILSCALE_ENV_FILE:-${SCRIPT_DIR}/../.env}"
base="https://api.tailscale.com/api/v2"

client=admin tags="" mode=call
while [ $# -gt 0 ]; do
    case "$1" in
        --client) [ $# -ge 2 ] || { echo "api.sh: $1 needs a value" >&2; exit 2; }
                  client="$2"; shift 2 ;;
        --tags) [ $# -ge 2 ] || { echo "api.sh: $1 needs a value" >&2; exit 2; }
                tags="$2"; shift 2 ;;
        --granted-scopes) mode=scopes; shift ;;
        --granted) mode=granted; shift ;;
        *) break ;;
    esac
done
case "$client" in
    admin|authkeys) ;;
    *) echo "api.sh: unknown client '${client}' (admin|authkeys)" >&2; exit 2 ;;
esac
if [ "$mode" = call ] && [ $# -lt 2 ]; then
    echo "usage: api.sh [--client admin|authkeys] [--tags T] METHOD PATH [curl args...]" >&2
    exit 2
fi

hint="see tailscale/.env.example and tailscale/README.md (Clients)"
if [ ! -f "$env_file" ]; then
    echo "api.sh: ${env_file} missing — ${hint}" >&2; exit 2
fi
if grep -qE '^TS_OAUTH_CLIENT_(ID|SECRET)=' "$env_file"; then
    echo "api.sh: ${env_file} has deprecated TS_OAUTH_CLIENT_ID/TS_OAUTH_CLIENT_SECRET — rename them to TS_ADMIN_CLIENT_ID/TS_ADMIN_CLIENT_SECRET (and the escrow copy)" >&2
    exit 2
fi
prefix="TS_$(printf '%s' "$client" | tr '[:lower:]' '[:upper:]')_CLIENT"
val() { sed -n "s/^$1=//p" "$env_file" | tail -1; }
id="$(val "${prefix}_ID")"
secret="$(val "${prefix}_SECRET")"
if [ -z "$id" ] || [ -z "$secret" ] || [[ "${id}${secret}" == *CHANGE_ME* ]]; then
    echo "api.sh: ${prefix}_ID / ${prefix}_SECRET missing or placeholder in ${env_file} — ${hint}" >&2
    exit 2
fi

# Both the token and every response body stay in shell variables: nothing is
# written to disk, so a crash or SIGKILL leaves no key or token behind. curl
# appends the HTTP code as a final line ('\n%{http_code}'); the split below
# restores the body byte-for-byte (only the one separator newline is removed).
# jq reads the values through a pipe, never argv or a here-string (bash 3.2
# spills here-strings to a temp file).
ex=(-sS -w '\n%{http_code}'
    --data-urlencode "grant_type=client_credentials"
    --data-urlencode "client_id=${id}"
    --data-urlencode "client_secret@-")
[ -n "$tags" ] && ex+=(--data-urlencode "tags=${tags}")
out="$(printf '%s' "$secret" | curl "${ex[@]}" "${base}/oauth/token")" || {
    echo "api.sh: token exchange failed (network)" >&2; exit 3; }
unset secret
code="${out##*$'\n'}"
tok="${out%$'\n'*}"
unset out
case "$code" in
    2??) ;;
    *) echo "api.sh: token exchange (${client}) -> HTTP ${code}: $(printf '%s' "$tok" | jq -r '.message // .error_description // .error // empty' 2>/dev/null)" >&2
       exit 3 ;;
esac
case "$mode" in
    scopes) printf '%s' "$tok" | jq -r '.scope // empty'; exit 0 ;;
    # one line: scope<TAB>tags (tags: space-separated string or array; "" if absent)
    granted) printf '%s' "$tok" | jq -r '[(.scope // ""), (.tags // "" | if type == "array" then join(" ") else . end)] | @tsv'; exit 0 ;;
esac
token="$(printf '%s' "$tok" | jq -r '.access_token // empty')"
unset tok
[ -n "$token" ] || { echo "api.sh: token exchange returned no access_token" >&2; exit 3; }

method="$1" path="$2"; shift 2
out="$(curl -sS -w '\n%{http_code}' -X "$method" \
    -H @<(printf 'Authorization: Bearer %s\n' "$token") "$@" "${base}${path}")" || {
    echo "api.sh: ${method} ${path}: request failed (network)" >&2; exit 3; }
unset token
code="${out##*$'\n'}"
body="${out%$'\n'*}"
unset out
printf '%s' "$body"
case "$code" in
    2??) exit 0 ;;
    *) echo "api.sh: ${method} ${path} -> HTTP ${code}: $(printf '%s' "$body" | jq -r '.message // empty' 2>/dev/null)" >&2
       exit 3 ;;
esac
