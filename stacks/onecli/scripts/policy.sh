#!/usr/bin/env bash
# stacks/onecli/scripts/policy.sh [RATE_LIMIT_PER_HOUR | --grants-only]
# Reconcile onecli v2 state for the connectome stack (idempotent):
#   1. agents connectome-host and connectome-shell exist (bring-your-own);
#   2. org policy rules match the design's identities table, in order;
#   3. only connectome-host holds the openai (LLM) grant — new LLM secrets
#      and new agents auto-attach, so every other agent's openai grant is
#      removed explicitly.
# Rule 1 is the hard usage ceiling: provisional 60/hour until the Phase 3
# calibration passes a measured value.
#
# Usage:
#   policy.sh [RATE_LIMIT_PER_HOUR]  — do all three (agents, rules, grants)
#   policy.sh --grants-only           — reconcile grants only (skip agents/rules)
#
# Exit codes: 0 ok; 2 prereq; 3 API failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/api.sh
source "${SCRIPT_DIR}/lib/api.sh"

grants_only=false
rate_provided=false
rate=""
if [ "${1:-}" = "--grants-only" ]; then
    grants_only=true
else
    if [ -n "${1:-}" ]; then
        rate="$1"
        rate_provided=true
        [[ "$rate" =~ ^[0-9]+$ ]] && [ "$rate" -ge 1 ] || { echo "policy: rate must be a positive integer" >&2; exit 2; }
    fi
fi

if [ "$grants_only" = false ]; then
    # --- 1. agents ---
    for ident in connectome-host connectome-shell; do
        if [ -z "$(agent_field "$ident" id)" ]; then
            api POST /v1/agents "$(jq -cn --arg i "$ident" '{name:$i, identifier:$i, kind:"byo"}')" >/dev/null
            echo "policy: created agent ${ident}"
        fi
    done

    # --- 2. org rules (name → desired spec), in evaluation order ---
    # Rule shape (validations/policy.ts): {name, action: allow|block, enabled,
    # rateLimit?, rateLimitWindow?, targets: [{kind: network, hostPattern,
    # pathPattern?, method?}]}. No `identities` = applies to every agent (org
    # rules); a rate limit is a modifier on an allow (design rule 1).
    net() { jq -cn --arg h "$1" --arg p "${2:-}" --arg m "${3:-}" \
        '{kind:"network", hostPattern:$h} + (if $p != "" then {pathPattern:$p} else {} end) + (if $m != "" then {method:$m} else {} end)'; }

    # If rate was not explicitly provided, look up the existing rule 1 limit by name.
    # On first creation (rule doesn't exist), default to 60.
    if [ "$rate_provided" = false ]; then
        existing_rate=$(api GET /v1/org/policy/rules | jq -r --arg n "cx-1-codex-responses-limit" '(if type=="array" then . else (.rules // .data // []) end)[] | select(.name==$n) | .rateLimit? // empty')
        if [ -n "$existing_rate" ]; then
            rate="$existing_rate"
        else
            rate=60
        fi
    fi

    specs=$(jq -cn --argjson rate "$rate" \
    --argjson t1 "$(net chatgpt.com '/backend-api/codex/responses*' POST)" \
    --argjson t2 "$(net chatgpt.com '/backend-api/codex/*')" \
    --argjson t3 "$(net chatgpt.com /backend-api/wham/usage GET)" \
    --argjson t4 "$(net chatgpt.com /backend-api/wham/accounts/check GET)" \
    --argjson t5 "$(net chatgpt.com /backend-api/wham/rate-limit-reset-credits GET)" \
    --argjson b1 "$(net chatgpt.com)" --argjson b2 "$(net '*.chatgpt.com')" \
    --argjson b3 "$(net '*.openai.com')" --argjson b4 "$(net api.openai.com)" '[
  {name:"cx-1-codex-responses-limit", action:"allow", enabled:true, rateLimit:$rate, rateLimitWindow:"hour", targets:[$t1]},
  {name:"cx-2-codex-allow",           action:"allow", enabled:true, targets:[$t2]},
  {name:"cx-3-wham-usage",            action:"allow", enabled:true, targets:[$t3]},
  {name:"cx-4-wham-accounts-check",   action:"allow", enabled:true, targets:[$t4]},
  {name:"cx-5-wham-reset-credits",    action:"allow", enabled:true, targets:[$t5]},
  {name:"cx-6-block-openai-hosts",    action:"block", enabled:true, targets:[$b1,$b2,$b3,$b4]}
]')
    list_rules() { api GET /v1/org/policy/rules | jq -c 'if type=="array" then . else (.rules // .data // []) end'; }
    existing=$(list_rules)
    ordered=()
    while IFS= read -r spec; do
        name=$(printf '%s' "$spec" | jq -r .name)
        id=$(printf '%s' "$existing" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')
        if [ -z "$id" ]; then
            id=$(api POST /v1/org/policy/rules "$spec" | jq -r '.id // .rule.id')
            echo "policy: created rule ${name}"
        else
            api PATCH "/v1/org/policy/rules/${id}" "$(printf '%s' "$spec" | jq -c 'del(.name)')" >/dev/null
        fi
        ordered+=("$id")
    done < <(jq -c '.[]' <<<"$specs")
    # Ours first (in table order), then any other pre-existing rules after them.
    others=$(list_rules | jq -r --argjson ours "$(printf '%s\n' "${ordered[@]}" | jq -R . | jq -cs .)" '.[] | select(.id as $i | $ours | index($i) | not) | .id')
    all_ids=$( { printf '%s\n' "${ordered[@]}"; if [ -n "$others" ]; then printf '%s\n' "$others"; fi; } | jq -R . | jq -cs .)
    api PUT /v1/org/policy/rules/order "$(jq -cn --argjson ids "$all_ids" '{orderedIds:$ids}')" >/dev/null
    echo "policy: ${#ordered[@]} rules in order; rule 1 limit ${rate}/hour"
fi

# --- 3. grants: only connectome-host holds the openai secret ---
openai_ids=$(api GET /v1/org/secrets | jq -r '(if type=="array" then . else (.secrets // .data // []) end)[] | select(.type=="openai") | .id')
if [ -z "$openai_ids" ]; then
    echo "policy: no openai secret yet (run: dotfiles stacks onecli import-openai); grants skipped" >&2
    exit 0
fi

# Validate agents list and require connectome-host to exist.
agents_list=$(api GET /v1/agents) || exit 3
# Strict validation: must be array, non-empty, and contain connectome-host.
printf '%s' "$agents_list" | jq -e 'if type=="array" then . elif type=="object" then (.agents // .data // []) else empty end | if length > 0 then . else empty end' >/dev/null || \
    { echo "policy: agents list is empty or invalid" >&2; exit 3; }
host_id=$(printf '%s' "$agents_list" | jq -r '(if type=="array" then . else (.agents // .data // []) end)[] | select(.identifier=="connectome-host") | .id' | head -1)
[ -n "$host_id" ] || { echo "policy: connectome-host agent not found; run 'dotfiles stacks onecli policy' without --grants-only to create agents" >&2; exit 3; }

# Grant each openai secret to the host.
for openai_id in $openai_ids; do
    api PUT "/v1/agents/${host_id}/grants/secrets/${openai_id}" '{}' >/dev/null
done

# Remove openai grants from all non-host agents.
while read -r aid; do
    grants=$(api GET "/v1/agents/${aid}/grants") || exit 3
    # Validate grants response structure.
    printf '%s' "$grants" | jq -e 'has("secrets") and (.secrets|type=="array")' >/dev/null || \
        { echo "policy: agent ${aid} grants response missing .secrets array" >&2; exit 3; }
    # Remove each openai secret grant from this agent.
    for openai_id in $openai_ids; do
        count=$(printf '%s' "$grants" | jq -r --arg s "$openai_id" '[.secrets[]|select(.secretId==$s)]|length')
        if [ "$count" -gt 0 ]; then
            api DELETE "/v1/agents/${aid}/grants/secrets/${openai_id}" >/dev/null
            echo "policy: removed openai grant from agent ${aid}"
        fi
    done
done < <(printf '%s' "$agents_list" | jq -r '(if type=="array" then . else (.agents // .data // []) end)[] | select(.identifier!="connectome-host") | .id')
echo "policy: grants reconciled (openai → connectome-host only)"
