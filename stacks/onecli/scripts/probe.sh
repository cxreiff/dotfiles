#!/usr/bin/env bash
# stacks/onecli/scripts/probe.sh
# Read-only gateway probes for the connectome identities/policy checks.
# Each line prints PASS/FAIL with the observed HTTP status and body snippet.
# Exit 1 if any probe FAILs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/api.sh
source "${SCRIPT_DIR}/lib/api.sh"
ctx=colima-agents
failed=0

HOST_TOKEN=$(agent_field connectome-host accessToken)
SHELL_TOKEN=$(agent_field connectome-shell accessToken)
export HOST_TOKEN SHELL_TOKEN
case "$HOST_TOKEN:$SHELL_TOKEN" in aoc_*:aoc_*) ;; *) echo "probe: agent tokens unavailable (run: dotfiles stacks onecli policy)" >&2; exit 2 ;; esac
[ "$HOST_TOKEN" != "$SHELL_TOKEN" ] && echo "PASS AC3.1 distinct aoc_ tokens" || { echo "FAIL AC3.1 tokens identical"; failed=1; }

ca_dir=$(mktemp -d); trap 'rm -rf "$ca_dir"' EXIT
docker --context "$ctx" exec onecli-gateway cat /app/data/gateway/ca.pem > "$ca_dir/ca.pem"

# probe <label> <token-var|none> <expected-status> <expected-body-substring|-> <curl args...>
probe() {
    local label="$1" tokvar="$2" want="$3" wantbody="$4"; shift 4
    local proxy_setup=''
    if [ "$tokvar" = none ]; then
        proxy_setup='https_proxy=http://gateway:10255'
    else
        proxy_setup="https_proxy=\"http://x:\${${tokvar}}@gateway:10255\""
    fi
    local out
    out=$(docker --context "$ctx" run --rm --network onecli-agents \
        -e HOST_TOKEN -e SHELL_TOKEN -v "$ca_dir:/ca:ro" --entrypoint sh curlimages/curl -c \
        "export ${proxy_setup}; curl -sS --path-as-is --cacert /ca/ca.pem -o /tmp/b -w 'STATUS %{http_code} %{http_connect}' $* ; echo; head -c 300 /tmp/b 2>/dev/null" 2>&1)
    local code connect body
    # A refused CONNECT (407, or a 401 issued at CONNECT time) leaves
    # http_code=000 and puts the proxy's status in http_connect.
    read -r code connect < <(grep -oE 'STATUS [0-9]{3} [0-9]{3}' <<<"$out" | awk '{print $2, $3}')
    [ "${code:-000}" = 000 ] && code="${connect:-}"
    body="$out"
    if [ "$code" = "$want" ] && { [ "$wantbody" = - ] || grep -qF "$wantbody" <<<"$body"; }; then
        echo "PASS $label ($code)"
    else
        echo "FAIL $label: want $want/${wantbody}, got ${code:-none}: $(tr '\n' ' ' <<<"$out" | head -c 300)"; failed=1
    fi
}

probe "AC3.6 no token -> 407"            none        407 -                  https://chatgpt.com/
probe "AC3.4 shell -> chatgpt 401"       SHELL_TOKEN 401 access_restricted  https://chatgpt.com/backend-api/codex/models
probe "AC3.4 shell dot-segment 401"      SHELL_TOKEN 401 access_restricted  https://chatgpt.com/backend-api/codex/../me
probe "AC3.5 host /backend-api/me 403"   HOST_TOKEN  403 blocked_by_policy  https://chatgpt.com/backend-api/me
probe "AC3.5 host api.openai.com 403"    HOST_TOKEN  403 blocked_by_policy  https://api.openai.com/v1/models
probe "uncredentialed internet 200"      SHELL_TOKEN 200 -                  https://example.com/

exit "$failed"
