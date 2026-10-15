# stacks/onecli/scripts/lib/api.sh — sourced, not executed.
# Helpers for the onecli v2 REST API on the agents-VM loopback (forwarded to
# the Mac by Colima). Secrets travel in curl config read from a process
# substitution (curl -K), never argv.
ONECLI_API="${ONECLI_API:-http://127.0.0.1:10256}"
ONECLI_BIN="${ONECLI_BIN:-onecli}"

# operator_key: print the operator's user API key stored by the host CLI.
operator_key() {
    local k
    # JSON first; fall back to scraping the key if the 2.x CLI prints text.
    k=$("$ONECLI_BIN" auth api-key 2>/dev/null | { jq -r '.apiKey // .api_key // .key // empty' 2>/dev/null || true; })
    [ -n "$k" ] || k=$("$ONECLI_BIN" auth api-key 2>/dev/null | grep -oE 'oc_[0-9a-f]{64}' | head -1)
    case "$k" in
        oc_*) printf '%s' "$k" ;;
        *) echo "onecli: no operator API key (run: dotfiles stacks onecli bootstrap)" >&2; return 2 ;;
    esac
}

# api METHOD PATH [JSON-BODY]: authenticated call with the operator key.
# Prints the response body; fails (rc 3) on HTTP >= 400, with the body on stderr.
# NOTE: no local named `path` — in zsh, `path` is tied to PATH, and this file
# is also sourced from interactive (zsh) verification snippets.
api() {
    local method="$1" api_path="$2" body="${3:-}" key out code
    key=$(operator_key) || return 2
    out=$(mktemp)
    # A transport failure (API down) must not look like an empty success.
    if [ -n "$body" ]; then
        code=$(printf '%s' "$body" | curl -sS -o "$out" -w '%{http_code}' -X "$method" "${ONECLI_API}${api_path}" \
            -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") \
            -H 'Content-Type: application/json' --data-binary @-) \
            || { echo "onecli API unreachable at ${ONECLI_API}" >&2; rm -f "$out"; return 3; }
    else
        code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${ONECLI_API}${api_path}" \
            -K <(printf 'header = "Authorization: Bearer %s"\n' "$key")) \
            || { echo "onecli API unreachable at ${ONECLI_API}" >&2; rm -f "$out"; return 3; }
    fi
    if [ "$code" -ge 400 ]; then
        echo "onecli API ${method} ${api_path} -> HTTP ${code}: $(head -c 500 "$out")" >&2
        rm -f "$out"; return 3
    fi
    cat "$out"; rm -f "$out"
}

# agent_field IDENTIFIER JQ-FIELD: read one field of an agent from GET /v1/agents.
agent_field() {
    api GET /v1/agents | jq -r --arg id "$1" --arg f "$2" \
        '(if type=="array" then . else (.agents // .data // []) end)[] | select(.identifier==$id) | .[$f] // empty'
}
