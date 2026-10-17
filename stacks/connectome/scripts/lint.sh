#!/bin/bash
# stacks/connectome/scripts/lint.sh
# Static lints for the connectome security invariants (design Phase 2,
# invariants 1, 2, 4, 6, 7, 8, 9). Reads the tracked recipe / compose files /
# Dockerfile and the KEY NAMES of .env files — never .env values.
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
[ -n "$c" ] || fail "lint: cannot parse ${compose}"
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
           and ((.modules.fleet.allowedRecipes // []) | length > 0 and all(startswith("/agent/recipes/"))))'; then
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
oc_env_has_private=$(keys "$oc_env" | grep -cx GATEWAY_ALLOW_PRIVATE_DESTINATIONS || true)
host_gw=$(printf '%s\n%s\n' "$c" "$oc" | jq -s '[.[] | .services[]? | (.extra_hosts // empty) | tostring | select(test("host-gateway"))] | length' 2>/dev/null || echo 1)
if [ -z "$bad_keys" ] && ! grep -qE '(^|,)172\.' <<<"$gw_private" && [ "$oc_env_has_private" = 0 ] && [ "$host_gw" = 0 ]; then
    pass "invariant 6: no onecli user API key; no 172.16/12 private allowance; no host-gateway"
else
    fail "invariant 6: ${bad_keys:+api-key-like keys [$(tr '\n' ' ' <<<"$bad_keys")] }${gw_private:+private allowance [$gw_private] }$([ "$oc_env_has_private" != 0 ] && echo 'GATEWAY_ALLOW_PRIVATE_DESTINATIONS set in onecli .env (value not inspected) ')$([ "$host_gw" != 0 ] && echo 'extra_hosts host-gateway')"
fi

# 7 — GATE_TELEMETRY unset everywhere
if ! printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -qx GATE_TELEMETRY && ! grep -q 'GATE_TELEMETRY' "$dockerfile"; then
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
if grep -q 'OBSERVERS_FILE=/agent/recipes/observers.json' "$dockerfile" \
   && cj '(.services.connectome.environment // {} | has("OBSERVERS_FILE") | not)
          and ([.services.connectome.volumes[]? | select(.target=="/agent/recipes") | .read_only] == [true])'; then
    pass "invariant 9: OBSERVERS_FILE points at the read-only /agent/recipes mount"
else
    fail "invariant 9: OBSERVERS_FILE overridden or /agent/recipes not mounted read-only"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
