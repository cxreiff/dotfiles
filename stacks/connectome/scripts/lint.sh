#!/bin/bash
# stacks/connectome/scripts/lint.sh
# Static lints for the connectome security invariants (design Phase 2,
# invariants 1, 2, 4, 6, 7, 8, 9; cxagents Phase 6, invariant 11). Reads the
# tracked recipe / compose files / Dockerfile and the KEY NAMES of .env files
# — never .env values.
# Used by `dotfiles stacks doctor`; fixture paths are overridable for tests.
#
# Usage: lint.sh [--recipe F] [--compose F] [--dockerfile F] [--env F]
#                [--onecli-compose F] [--onecli-env F]
# Exit: 0 all pass; 1 any FAIL; 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${stack_dir}/../.." && pwd)"
# shellcheck source=../../scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

recipe="${stack_dir}/recipes/agent.json"
compose="${stack_dir}/compose.yaml"
dockerfile="${stack_dir}/build/connectome.Dockerfile"
envf="${stack_dir}/.env"
oc_compose="${repo_root}/stacks/onecli/compose.yaml"
oc_env="${repo_root}/stacks/onecli/.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --recipe) recipe="$2" ;; --compose) compose="$2" ;; --dockerfile) dockerfile="$2" ;;
        --env) envf="$2" ;; --onecli-compose) oc_compose="$2" ;; --onecli-env) oc_env="$2" ;;
        *) echo "lint: unknown argument $1" >&2; exit 2 ;;
    esac
    shift 2
done

# KEY NAMES only (AC12.5): never source or read values.
keys() { [ -f "$1" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1; true; }
cjson() { docker compose -f "$1" config --no-interpolate --format json 2>/dev/null; }
rj() { jq -e "$1" "$recipe" >/dev/null 2>&1; }

c=$(cjson "$compose") || c=""
oc=$(cjson "$oc_compose") || oc=""
# Fail closed: an unreadable input must never let a check pass.
[ -n "$c" ] || fail "lint: cannot parse ${compose}"
[ -n "$oc" ] || fail "lint: cannot parse ${oc_compose}"
[ -f "$recipe" ] && jq -e . "$recipe" >/dev/null 2>&1 || fail "lint: cannot parse ${recipe}"
[ -f "$dockerfile" ] || fail "lint: cannot read ${dockerfile}"
cj() { jq -e "$1" >/dev/null 2>&1 <<<"$c"; }
env_keys=$(keys "$envf")
svc_env_keys=$(jq -r '.services[]?.environment // {} | keys[]' <<<"$c" 2>/dev/null)

# 1 — host-code-execution features off; no in-process workspace; subagents.maxDepth == 1
if rj '(.codeExecution == null or .codeExecution == false or .codeExecution.enabled == false)
       and ((.extensions // {}) | length == 0)
       and ((.modules.mcplAdmin // false) == false)
       and (.modules.workspace == false)
       and ((.modules.subagents // null) == null or (.modules.subagents.maxDepth == 1))'; then
    pass "invariant 1: codeExecution, mcplAdmin, extensions off; modules.workspace false; subagents.maxDepth 1"
else
    fail "invariant 1: codeExecution/mcplAdmin/extensions enabled or modules.workspace not false or subagents.maxDepth not 1 (${recipe})"
fi

# 2 — fleet never `true`; object form only, explicit children, allowedRecipes under /agent/recipes
if rj '(.modules.fleet == null)
       or ((.modules.fleet | type) == "object"
           and ((.modules.fleet.children // null) | type) == "array"
           and ((.modules.fleet.allowedRecipes // []) | length > 0 and all(startswith("/agent/recipes/") and (contains("/../") | not) and (endswith("/..") | not))))'; then
    pass "invariant 2: modules.fleet absent or explicit object form"
else
    fail "invariant 2: modules.fleet is true or lacks explicit children/allowedRecipes under /agent/recipes"
fi

# 4 — only `outbox` shared, read-only in connectome; connectome binds read-only; shell has no binds
if cj '([.services.connectome.volumes[]? | select(.type=="volume") | .source] as $a
        | [.services.shell.volumes[]? | select(.type=="volume") | .source] as $b
        | ($a - ($a - $b))) == ["outbox"]
       and ([.services.connectome.volumes[]? | select(.source=="outbox") | .read_only] == [true])
       and ([.services.connectome.volumes[]? | select(.type=="bind") | .read_only == true] | all)
       and ([.services.shell.volumes[]? | select(.type=="bind")] | length == 0)'; then
    pass "invariant 4: only outbox shared (ro in connectome); no writable binds"
else
    fail "invariant 4: volume sharing between connectome and shell violates the outbox-only rule"
fi

# 6 — no onecli user API key; private-destination allowance never covers 172.16/12; no host-gateway
bad_keys=$(printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -iE 'API_KEY|USER_KEY|ONECLI_KEY|^OC_' || true)
gw_private=$(jq -r '.services.gateway.environment.GATEWAY_ALLOW_PRIVATE_DESTINATIONS // ""' <<<"$oc" 2>/dev/null)
# A private-destination allowance must never reach the agents' Docker/VM
# networks (172.16.0.0/12). Each entry must be an IPv4 CIDR (or bare IPv4)
# that does not overlap that range; anything else is a violation (fail closed).
dec() { [[ "$1" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$1" -le 255 ]; }  # canonical decimal 0..255
# Prints CLEAN when no entry is a problem, else the first bad entry. Callers
# treat anything but CLEAN (bad entry, error, empty output) as a violation.
allowance_check() {
    local entry o1 o2 o3 o4 len o lo hi
    for entry in $(tr ', ' '\n\n' <<<"$1"); do
        [ -n "$entry" ] || continue
        # Strict IPv4[/len]: canonical decimal octets 0..255, prefix 0..32.
        [[ "$entry" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/(0|[1-9][0-9]?))?$ ]] \
            || { echo "$entry"; return; }
        # Copy the groups first: dec's own [[ =~ ]] overwrites BASH_REMATCH.
        o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]} len=${BASH_REMATCH[6]:-32}
        for o in "$o1" "$o2" "$o3" "$o4"; do dec "$o" || { echo "$entry"; return; }; done
        [ "$len" -le 32 ] || { echo "$entry"; return; }
        lo=$(( ( (10#$o1 << 24) + (10#$o2 << 16) + (10#$o3 << 8) + 10#$o4 ) & ( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ) ))
        hi=$(( lo + (1 << (32 - len)) - 1 ))
        # overlap with [172.16.0.0, 172.31.255.255]
        if [ "$lo" -le 2887778303 ] && [ "$hi" -ge 2886729728 ]; then echo "$entry"; return; fi
    done
    echo CLEAN
}
allow_result=$(allowance_check "$gw_private" 2>/dev/null)
[ "$allow_result" = CLEAN ] && gw_private_bad="" || gw_private_bad="${allow_result:-check error on [$gw_private]}"
oc_env_has_private=$(keys "$oc_env" | grep -cx GATEWAY_ALLOW_PRIVATE_DESTINATIONS || true)
host_gw=$(printf '%s\n%s\n' "$c" "$oc" | jq -s '[.[] | .services[]? | (.extra_hosts // empty) | tostring | select(test("host-gateway"))] | length' 2>/dev/null || echo 1)
if [ -n "$oc" ] && [ -z "$bad_keys" ] && [ -z "$gw_private_bad" ] && [ "$oc_env_has_private" = 0 ] && [ "$host_gw" = 0 ]; then
    pass "invariant 6: no onecli user API key; no 172.16/12 private allowance; no host-gateway"
else
    fail "invariant 6: ${bad_keys:+api-key-like keys [$(tr '\n' ' ' <<<"$bad_keys")] }${gw_private_bad:+private allowance covers 172.16/12 or is malformed [$gw_private_bad] }$([ "$oc_env_has_private" != 0 ] && echo 'GATEWAY_ALLOW_PRIVATE_DESTINATIONS set in onecli .env (value not inspected) ')$([ "$host_gw" != 0 ] && echo 'extra_hosts host-gateway')"
fi

# 7 — GATE_TELEMETRY unset everywhere
if [ -f "$dockerfile" ] && ! printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -qx GATE_TELEMETRY \
   && ! grep -vE '^[[:space:]]*#' "$dockerfile" | grep -q 'GATE_TELEMETRY'; then
    pass "invariant 7: GATE_TELEMETRY unset"
else
    fail "invariant 7: GATE_TELEMETRY is set (.env key, compose env, or Dockerfile)"
fi

# 8 — Discord filters fixed in the recipe; no filters file; dangerous tools disabled
if rj '(.mcpServers.discord.env | has("DISCORD_FILTERS_FILE") | not)
       and ((.mcpServers.discord.env.DISCORD_DM_USERS // "") | length > 0)
       and ((.mcpServers.discord.env.DISCORD_GUILD_ID // "") | length > 0)
       and ((.mcpServers.discord.disabledTools // []) as $d
            | ["filters_update","create_text_channel","delete_channel"] | all(. as $t | $d | index($t)))' \
   && ! printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -qx DISCORD_FILTERS_FILE; then
    pass "invariant 8: discord filters fixed, no filters file, filters_update/create/delete disabled"
else
    fail "invariant 8: discord filters file set, allowlist missing, or dangerous tools not disabled"
fi

# 9 — OBSERVERS_FILE on the read-only recipes mount, not overridden
# The last OBSERVERS_FILE assignment in non-comment Dockerfile lines wins.
obs_file=$( [ -f "$dockerfile" ] && grep -vE '^[[:space:]]*#' "$dockerfile" | grep -oE 'OBSERVERS_FILE=[^[:space:]\\]+' | tail -1 | cut -d= -f2- )
if [ "$obs_file" = /agent/recipes/observers.json ] \
   && cj '(.services.connectome.environment // {} | has("OBSERVERS_FILE") | not)
          and ([.services.connectome.volumes[]? | select(.target=="/agent/recipes") | .read_only] == [true])'; then
    pass "invariant 9: OBSERVERS_FILE points at the read-only /agent/recipes mount"
else
    fail "invariant 9: OBSERVERS_FILE overridden or /agent/recipes not mounted read-only"
fi

# 11 — WebUI allowedOrigins is exactly the cxmini tailnet origin (AC9.5). An
# empty list admits every Origin (checkOrigin allows all), a missing key falls
# back to localhost-only defaults, a wildcard admits any site. The origin is
# built from tailscale/tailnet.conf (TAILNET_DNS_SUFFIX) and the justfile's
# serve_port; either one unreadable fails closed.
suffix=$( (. "${repo_root}/tailscale/scripts/lib/conf.sh" && printf '%s' "${TAILNET_DNS_SUFFIX:-}") 2>/dev/null )
port=$(sed -n 's/^serve_port := "\([0-9][0-9]*\)"$/\1/p' "${stack_dir}/justfile" 2>/dev/null | head -1)
want_origin=""
if [ -n "$suffix" ] && [ -n "$port" ]; then want_origin="https://cxmini.${suffix}:${port}"; fi
if [ -n "$want_origin" ] && jq -e --arg o "$want_origin" '.modules.webui.allowedOrigins == [$o]' "$recipe" >/dev/null 2>&1; then
    pass "invariant 11: WebUI allowedOrigins is exactly [${want_origin}]"
else
    fail "invariant 11: webui.allowedOrigins is not exactly [${want_origin:-origin unavailable}] (empty, missing, wildcard or other origin; ${recipe})"
fi
# 11 (systemPrompt) — the agent's prompt gives the operator the cxagents URL
# (https://cxagents.<suffix>:<port>). A stale tailnet suffix there is silent: nothing
# else reads the prompt. Fails closed when the suffix is unreadable.
if [ -n "$suffix" ] && jq -e --arg h "cxagents.${suffix}" '(.agent.systemPrompt // "") | contains($h)' "$recipe" >/dev/null 2>&1; then
    pass "invariant 11: agent.systemPrompt names cxagents.${suffix}"
else
    fail "invariant 11: agent.systemPrompt does not name cxagents.${suffix:-<suffix unavailable>} (update the cxagents host in ${recipe})"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
