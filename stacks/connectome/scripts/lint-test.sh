#!/bin/bash
# stacks/connectome/scripts/lint-test.sh
# Generates single-violation fixtures on the fly (temp dir, trap-cleaned) for
# each security invariant. Each fixture makes exactly one check FAIL and others PASS.
# Exit: 0 all fixtures tested; 1 any fixture failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${stack_dir}/../.." && pwd)"

lint_sh="${SCRIPT_DIR}/lint.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Build baseline fixtures in the tmpdir: recipe, compose (JSON), env, onecli-compose (JSON), onecli-env, Dockerfile
echo "Building baseline fixtures..." >&2

# Recipe: copy the tracked file
cp "${stack_dir}/recipes/agent.json" "$tmpdir/recipe.json"

# Compose: convert YAML to JSON via docker compose config
docker compose -f "${stack_dir}/compose.yaml" config --no-interpolate --format json > "$tmpdir/compose.json" 2>/dev/null

# Env: extract key lines from .env.example (if .env exists, use it, else .env.example)
if [ -f "${stack_dir}/.env" ]; then
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${stack_dir}/.env" > "$tmpdir/env" || true
else
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${stack_dir}/.env.example" > "$tmpdir/env" || true
fi

# onecli compose: convert YAML to JSON
docker compose -f "${repo_root}/stacks/onecli/compose.yaml" config --no-interpolate --format json > "$tmpdir/onecli-compose.json" 2>/dev/null

# onecli env: extract key lines
if [ -f "${repo_root}/stacks/onecli/.env" ]; then
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${repo_root}/stacks/onecli/.env" > "$tmpdir/onecli-env" || true
else
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${repo_root}/stacks/onecli/.env.example" > "$tmpdir/onecli-env" || true
fi

# Dockerfile: copy the tracked file
cp "${stack_dir}/build/connectome.Dockerfile" "$tmpdir/Dockerfile"

# Test baseline: should have zero FAILs
baseline_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)

if echo "$baseline_output" | grep -q '^\[FAIL\]'; then
    echo "FAIL lint-fixture baseline: baseline itself has FAILs:" >&2
    echo "$baseline_output" >&2
    exit 1
fi
echo "PASS lint-fixture baseline" >&2

failures=0

# Test invariant 1: enable codeExecution
echo "Testing invariant 1 fixture..." >&2
cp "$tmpdir/recipe.json" "$tmpdir/recipe-inv1.json"
jq '.codeExecution = {"enabled": true}' "$tmpdir/recipe-inv1.json" > "$tmpdir/recipe-inv1.tmp" && mv "$tmpdir/recipe-inv1.tmp" "$tmpdir/recipe-inv1.json"
inv1_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe-inv1.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv1_output" | grep -q '^\[FAIL\] invariant 1:' && ! echo "$inv1_output" | grep '^\[FAIL\]' | grep -qv 'invariant 1:'; then
    echo "PASS lint-fixture 1" >&2
else
    echo "FAIL lint-fixture 1: did not fail exactly invariant 1" >&2
    echo "$inv1_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 2: fleet = true
echo "Testing invariant 2 fixture..." >&2
cp "$tmpdir/recipe.json" "$tmpdir/recipe-inv2.json"
jq '.modules.fleet = true' "$tmpdir/recipe-inv2.json" > "$tmpdir/recipe-inv2.tmp" && mv "$tmpdir/recipe-inv2.tmp" "$tmpdir/recipe-inv2.json"
inv2_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe-inv2.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv2_output" | grep -q '^\[FAIL\] invariant 2:' && ! echo "$inv2_output" | grep '^\[FAIL\]' | grep -qv 'invariant 2:'; then
    echo "PASS lint-fixture 2" >&2
else
    echo "FAIL lint-fixture 2: did not fail exactly invariant 2" >&2
    echo "$inv2_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 4: add shared volume to shell
echo "Testing invariant 4 fixture..." >&2
cp "$tmpdir/compose.json" "$tmpdir/compose-inv4.json"
jq '.services.shell.volumes += [{"type":"volume","source":"state","target":"/agent/state"}]' "$tmpdir/compose-inv4.json" > "$tmpdir/compose-inv4.tmp" && mv "$tmpdir/compose-inv4.tmp" "$tmpdir/compose-inv4.json"
inv4_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose-inv4.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv4_output" | grep -q '^\[FAIL\] invariant 4:' && ! echo "$inv4_output" | grep '^\[FAIL\]' | grep -qv 'invariant 4:'; then
    echo "PASS lint-fixture 4" >&2
else
    echo "FAIL lint-fixture 4: did not fail exactly invariant 4" >&2
    echo "$inv4_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 6: add ONECLI_API_KEY to env
echo "Testing invariant 6 fixture..." >&2
cp "$tmpdir/env" "$tmpdir/env-inv6"
echo "ONECLI_API_KEY=" >> "$tmpdir/env-inv6"
inv6_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env-inv6" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv6_output" | grep -q '^\[FAIL\] invariant 6:' && ! echo "$inv6_output" | grep '^\[FAIL\]' | grep -qv 'invariant 6:'; then
    echo "PASS lint-fixture 6" >&2
else
    echo "FAIL lint-fixture 6: did not fail exactly invariant 6" >&2
    echo "$inv6_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 7: add GATE_TELEMETRY to env
echo "Testing invariant 7 fixture..." >&2
cp "$tmpdir/env" "$tmpdir/env-inv7"
echo "GATE_TELEMETRY=" >> "$tmpdir/env-inv7"
inv7_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env-inv7" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv7_output" | grep -q '^\[FAIL\] invariant 7:' && ! echo "$inv7_output" | grep '^\[FAIL\]' | grep -qv 'invariant 7:'; then
    echo "PASS lint-fixture 7" >&2
else
    echo "FAIL lint-fixture 7: did not fail exactly invariant 7" >&2
    echo "$inv7_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 8: add DISCORD_FILTERS_FILE to recipe
echo "Testing invariant 8 fixture..." >&2
cp "$tmpdir/recipe.json" "$tmpdir/recipe-inv8.json"
jq '.mcpServers.discord.env.DISCORD_FILTERS_FILE = "/agent/state/discord/filters.json"' "$tmpdir/recipe-inv8.json" > "$tmpdir/recipe-inv8.tmp" && mv "$tmpdir/recipe-inv8.tmp" "$tmpdir/recipe-inv8.json"
inv8_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe-inv8.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv8_output" | grep -q '^\[FAIL\] invariant 8:' && ! echo "$inv8_output" | grep '^\[FAIL\]' | grep -qv 'invariant 8:'; then
    echo "PASS lint-fixture 8" >&2
else
    echo "FAIL lint-fixture 8: did not fail exactly invariant 8" >&2
    echo "$inv8_output" >&2
    failures=$((failures + 1))
fi

# Test invariant 9: override OBSERVERS_FILE in connectome environment
echo "Testing invariant 9 fixture..." >&2
cp "$tmpdir/compose.json" "$tmpdir/compose-inv9.json"
jq '.services.connectome.environment.OBSERVERS_FILE = "/agent/state/observers.json"' "$tmpdir/compose-inv9.json" > "$tmpdir/compose-inv9.tmp" && mv "$tmpdir/compose-inv9.tmp" "$tmpdir/compose-inv9.json"
inv9_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose-inv9.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$inv9_output" | grep -q '^\[FAIL\] invariant 9:' && ! echo "$inv9_output" | grep '^\[FAIL\]' | grep -qv 'invariant 9:'; then
    echo "PASS lint-fixture 9" >&2
else
    echo "FAIL lint-fixture 9: did not fail exactly invariant 9" >&2
    echo "$inv9_output" >&2
    failures=$((failures + 1))
fi

# Test AC12.5: key names in env values only (should have zero FAILs)
echo "Testing AC12.5 fixture (key names in values only)..." >&2
cp "$tmpdir/env" "$tmpdir/env-ac125"
echo "NOTE=GATE_TELEMETRY ONECLI_API_KEY DISCORD_FILTERS_FILE" >> "$tmpdir/env-ac125"
ac125_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env-ac125" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if ! echo "$ac125_output" | grep -q '^\[FAIL\]'; then
    echo "PASS lint-fixture AC12.5" >&2
else
    echo "FAIL lint-fixture AC12.5: should have zero FAILs but got:" >&2
    echo "$ac125_output" >&2
    failures=$((failures + 1))
fi

# Test subagents.maxDepth == 2 (should fail invariant 1)
echo "Testing subagents.maxDepth=2 fixture (invariant 1)..." >&2
cp "$tmpdir/recipe.json" "$tmpdir/recipe-invsubagents.json"
jq '.modules.subagents.maxDepth = 2' "$tmpdir/recipe-invsubagents.json" > "$tmpdir/recipe-invsubagents.tmp" && mv "$tmpdir/recipe-invsubagents.tmp" "$tmpdir/recipe-invsubagents.json"
invsubagents_output=$("$lint_sh" \
    --recipe "$tmpdir/recipe-invsubagents.json" \
    --compose "$tmpdir/compose.json" \
    --dockerfile "$tmpdir/Dockerfile" \
    --env "$tmpdir/env" \
    --onecli-compose "$tmpdir/onecli-compose.json" \
    --onecli-env "$tmpdir/onecli-env" 2>&1 || true)
if echo "$invsubagents_output" | grep -q '^\[FAIL\] invariant 1:' && ! echo "$invsubagents_output" | grep '^\[FAIL\]' | grep -qv 'invariant 1:'; then
    echo "PASS lint-fixture subagents-maxDepth-check" >&2
else
    echo "FAIL lint-fixture subagents-maxDepth-check: did not fail exactly invariant 1" >&2
    echo "$invsubagents_output" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "FAIL: $failures fixture(s) failed" >&2
    exit 1
fi

echo "All fixtures passed" >&2
exit 0
