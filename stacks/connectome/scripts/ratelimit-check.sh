#!/usr/bin/env bash
# AC10.3: exhaust a temporary 2/hour rule 1 and expect the gateway refusal.
# Sets rule 1 to 2/hour, restarts the gateway, POSTs 3 times, asserts the
# third is rate-limited (HTTP 429), restores the original rule 1 in a trap.
# Refuse to start within 60 s of the top of the hour.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
repo_root="$(cd "$stack_dir/../.." && pwd)"

# shellcheck source=../../../stacks/onecli/scripts/lib/api.sh
source "${repo_root}/stacks/onecli/scripts/lib/api.sh"

log() { echo "[ratelimit-check] $*" >&2; }
D() { docker --context colima-agents "$@"; }

# Refuse to start within 60 s of the top of the hour (window rolls over).
minute_in_hour=$(date +%M)
second_in_minute=$(date +%S)
seconds_until_top=$((3600 - (10#$minute_in_hour * 60 + 10#$second_in_minute)))  # 10#: "08" is not octal
if [ "$seconds_until_top" -lt 60 ] || [ "$seconds_until_top" -gt 3540 ]; then
    log "too close to the top of the hour (${seconds_until_top}s remaining); wait and retry"
    exit 2
fi

# Read the current rule-1 limit and remember it.
rule_json=$(api GET /v1/org/policy/rules 2>/dev/null || echo '[]')
original_limit=$(echo "$rule_json" | jq -r '(if type=="array" then . else (.rules // .data) end)[] | select(.name=="cx-1-codex-responses-limit") | .rateLimit // empty' || echo '')
if [ -z "$original_limit" ]; then
    log "could not read current rule-1 limit" >&2
    exit 1
fi
log "original rule-1 limit: $original_limit/hour"

# Trap to always restore rule 1.
restore_rule() {
    log "restoring rule 1 to $original_limit via policy.sh"
    if [ -n "$original_limit" ]; then
        if ! "${repo_root}/stacks/onecli/scripts/policy.sh" "$original_limit" >/dev/null; then
            log "ERROR: could not restore rule 1 — the agent is still capped at 2/hour."
            log "ERROR: fix now with: dotfiles stacks onecli policy $original_limit"
            exit 3
        fi
        log "rule 1 restored to $original_limit/hour"
    fi
}
trap restore_rule EXIT

# Set rule 1 to 2/hour.
log "setting rule 1 to 2/hour via policy.sh"
"${repo_root}/stacks/onecli/scripts/policy.sh" 2 >/dev/null || { log "policy.sh 2 failed" >&2; exit 1; }

# Restart the gateway and wait for healthy.
log "restarting gateway to reset in-memory counter"
D stop onecli-gateway >/dev/null 2>&1 || true
sleep 2
D start onecli-gateway >/dev/null 2>&1 || { log "gateway start failed" >&2; exit 1; }

# Wait for healthy (bounded, ~60 s).
deadline=$((SECONDS + 60))
while true; do
    health=$(D inspect -f '{{.State.Health.Status}}' onecli-gateway 2>/dev/null || echo 'none')
    [ "$health" = healthy ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
        log "gateway did not become healthy within 60s" >&2
        exit 1
    fi
    sleep 2
done
log "gateway healthy; proceeding with POST tests"

# Read HOST_TOKEN from .env (never echo it).
HOST_TOKEN=$(grep '^HOST_ONECLI_TOKEN=' "$stack_dir/.env" | cut -d= -f2-)
if [ -z "$HOST_TOKEN" ]; then
    log "HOST_ONECLI_TOKEN not in .env" >&2
    exit 1
fi
export HOST_TOKEN

# Set up CA directory.
ca_dir=$(mktemp -d)
trap 'rm -rf "$ca_dir"; restore_rule' EXIT
D exec onecli-gateway cat /app/data/gateway/ca.pem > "$ca_dir/ca.pem"

# Helper: POST {} to chatgpt.com/backend-api/codex/responses and capture status.
post_request() {
    local n="$1"
    local proxy="http://x:\${HOST_TOKEN}@gateway:10255"
    local out
    out=$(D run --rm --network onecli-agents \
        -e HOST_TOKEN -v "$ca_dir:/ca:ro" --entrypoint sh curlimages/curl -c \
        "curl -sS --path-as-is --cacert /ca/ca.pem -x '$proxy' -w 'STATUS %{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' https://chatgpt.com/backend-api/codex/responses 2>&1; echo" 2>&1)
    local code body
    code=$(grep -oE 'STATUS [0-9]{3}' <<<"$out" | awk '{print $2}' || echo 'error')
    body="$out"
    echo "POST $n: $code"
    echo "$code" "$body"
}

# POST three times and capture results.
result1=$(post_request 1)
code1=$(echo "$result1" | head -1 | cut -d' ' -f3)

result2=$(post_request 2)
code2=$(echo "$result2" | head -1 | cut -d' ' -f3)

result3=$(post_request 3)
code3=$(echo "$result3" | head -1 | cut -d' ' -f3)

# Assert the third response is HTTP 429 with rate-limit refusal.
failed=0
if [ "$code3" = 429 ] && printf '%s' "$result3" | grep -qiE 'rate|limit'; then
    log "PASS: POST 3 is rate-limited (HTTP 429)"
else
    log "FAIL: POST 3 is not rate-limited; got HTTP $code3"
    failed=1
fi

# Confirm first two are not refused by the gateway (may be 4xx from chatgpt.com).
if [ "$code1" != 429 ]; then
    log "PASS: POST 1 not rate-limited (HTTP $code1)"
else
    log "FAIL: POST 1 is rate-limited; should not be (HTTP $code1)"
    failed=1
fi

if [ "$code2" != 429 ]; then
    log "PASS: POST 2 not rate-limited (HTTP $code2)"
else
    log "FAIL: POST 2 is rate-limited; should not be (HTTP $code2)"
    failed=1
fi

# Check gateway stdout for RATE LIMITED line.
if D logs onecli-gateway --tail 100 2>/dev/null | grep -qE 'RATE LIMITED'; then
    log "PASS: gateway log shows RATE LIMITED"
else
    log "FAIL: gateway log does not show RATE LIMITED"
    failed=1
fi

exit "$failed"
