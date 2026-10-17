#!/usr/bin/env bash
# stacks/connectome/scripts/image-test.sh
# Static assertions against the built images (no running stack needed; the
# onecli gateway must be up for the CA checks). Every check runs a throwaway
# container with --network none and an overridden entrypoint. One pass/fail
# line per check, naming the AC; exit 1 if any check fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
repo_root="$(cd "$stack_dir/../.." && pwd)"
# shellcheck source=../../scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

ctx=colima-agents
host_img=connectome-host:local
shell_img=connectome-shell:local
# run_in IMAGE 'script': run a shell snippet in a throwaway container.
run_in() { docker --context "$ctx" run --rm --network none --entrypoint sh "$1" -c "$2" 2>&1; }

# 1. AC4.3 — both images linux/arm64
arch=$(docker --context "$ctx" image inspect -f '{{.Os}}/{{.Architecture}}' "$host_img" "$shell_img" 2>&1 | sort -u)
[ "$arch" = linux/arm64 ] && pass "AC4.3 images are linux/arm64" || fail "AC4.3 image platforms: $(tr '\n' ' ' <<<"$arch")"

# 2–3. AC4.3 — gateway CA baked in and trusted
gw_pem=$(docker --context "$ctx" exec onecli-gateway cat /app/data/gateway/ca.pem 2>/dev/null)
if [ -z "$gw_pem" ]; then
    fail "AC4.3 cannot read the gateway CA (is onecli up?)"
    fail "AC4.3 CA trust-store check skipped"
else
    gw_sha=$(printf '%s\n' "$gw_pem" | shasum -a 256 | awk '{print $1}')
    body=$(printf '%s\n' "$gw_pem" | sed -n 2p | cut -c1-60)
    sha_ok=1 trust_ok=1 detail=""
    for img in "$host_img" "$shell_img"; do
        s=$(run_in "$img" 'sha256sum /usr/local/share/ca-certificates/onecli-gateway.crt' | awk '{print $1}')
        [ "$s" = "$gw_sha" ] || { sha_ok=0; detail="$detail ${img}:sha=${s:-none}"; }
        n=$(run_in "$img" "grep -cF '$body' /etc/ssl/certs/ca-certificates.crt")
        [ "${n:-0}" -ge 1 ] 2>/dev/null || { trust_ok=0; detail="$detail ${img}:trust=${n}"; }
    done
    [ "$sha_ok" = 1 ] && pass "AC4.3 gateway CA fingerprint matches in both images" || fail "AC4.3 CA fingerprint mismatch:${detail}"
    [ "$trust_ok" = 1 ] && pass "AC4.3 gateway CA in both system trust stores" || fail "AC4.3 CA not in trust store:${detail}"
fi

# 4. AC4.4 — real Node 22 for MCP servers (not the Bun shim)
v=$(run_in "$host_img" "/opt/node/bin/node -p 'process.versions.bun ? \"BUN\" : process.version'")
[[ "$v" == v22.* ]] && pass "AC4.4 real node ${v}" || fail "AC4.4 node: $v"

# 5. AC4.4 — WebUI built and pinned Codex CLI. Stdout only: without the state
# volume codex warns on stderr that CODEX_HOME does not exist.
v=$(docker --context "$ctx" run --rm --network none --entrypoint sh "$host_img" \
    -c 'test -f /opt/connectome/dist/web/index.html && codex --version' 2>/dev/null)
[ "$v" = "codex-cli 0.162.1" ] && pass "AC4.4 WebUI present, ${v}" || fail "AC4.4 webui/codex: $v"

# 6. AC5.2 — /agent/cwd is immutable for the image user and holds only the two links
out=$(run_in "$host_img" 'id -u; ls -A /agent/cwd | tr "\n" " "; echo; readlink /agent/cwd/mcpl-servers.json /agent/cwd/logs | tr "\n" " "; echo
touch /agent/cwd/mcpl-servers.agent.json 2>&1; touch /agent/cwd/x 2>&1; echo rc=$?')
uid=$(sed -n 1p <<<"$out"); listing=$(sed -n 2p <<<"$out"); links=$(sed -n 3p <<<"$out")
if [ "$uid" != 0 ] && [ "$listing" = "logs mcpl-servers.json " ] \
   && [ "$links" = "/agent/recipes/mcpl-servers.json /agent/state/logs " ] \
   && [ "$(grep -c 'Permission denied' <<<"$out")" = 2 ] && grep -q '^rc=1$' <<<"$out"; then
    pass "AC5.2 /agent/cwd read-only, only the two symlinks (uid $uid)"
else
    fail "AC5.2 /agent/cwd layout: $(tr '\n' '|' <<<"$out")"
fi

# 7–8. AC4.5 — heartbeat refuses recurring reminders under 900 s, accepts 900 s
hb() {
    run_in "$host_img" "cd /tmp && env HEARTBEAT_CONFIG_FILE=/tmp/c.json HEARTBEAT_REMINDERS_FILE=/tmp/r.json \
        /opt/node/bin/node /opt/connectome-tests/mcp-call.mjs reminder_add '{\"message\":\"x\",\"everySeconds\":$1}' \
        -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio" | tail -1
}
r=$(hb 60)
jq -e '.isError == true and (.text | contains("900"))' >/dev/null 2>&1 <<<"$r" \
    && pass "AC4.5 heartbeat refuses a 60 s reminder" || fail "AC4.5 60 s reminder: $r"
r=$(hb 900)
jq -e '.isError == false' >/dev/null 2>&1 <<<"$r" \
    && pass "AC4.5 heartbeat accepts a 900 s reminder" || fail "AC4.5 900 s reminder: $r"

# 9. AC7.5 — attachment guard in the shipped discord-mcpl build
r=$(run_in "$host_img" 'mkdir -p /tmp/ob && echo hi > /tmp/ob/ok.txt && ln -s /etc/passwd /tmp/ob/evil
cd /tmp && /opt/node/bin/node --input-type=module -e "
const { loadAttachment } = await import(\"/opt/mcpl/discord-mcpl/dist/src/attachment-guard.js\");
const t = (p, root) => { try { loadAttachment(p, root); return \"ok\"; } catch { return \"refused\"; } };
console.log([t(\"/tmp/ob/ok.txt\", \"/tmp/ob\"), t(\"/proc/self/environ\", \"/tmp/ob\"), t(\"/tmp/ob/evil\", \"/tmp/ob\"), t(\"/tmp/ob/ok.txt\", undefined)].join(\" \"));
"' | tail -1)
[ "$r" = "ok refused refused refused" ] && pass "AC7.5 attachment guard: $r" || fail "AC7.5 attachment guard: $r"

# 10. AC9.1 — shell toolchain, native arm64
out=$(run_in "$shell_img" 'set -e; uname -m; node -v; tsc -v; cargo -V; rustc -V; python3 -V; pip -V; uv -V; rg -V; fd -V; jq -V; git --version; gh --version | head -1; gcc --version | head -1; make -v | head -1; echo ALL_OK')
if [ "$(sed -n 1p <<<"$out")" = aarch64 ] && grep -q '^ALL_OK$' <<<"$out"; then
    pass "AC9.1 shell toolchain present (aarch64)"
else
    fail "AC9.1 shell toolchain: $(tr '\n' '|' <<<"$out")"
fi

# 11. AC9.2 — no way to root in shell
out=$(run_in "$shell_img" 'id -u; command -v sudo || echo NO_SUDO; su -c true root </dev/null >/dev/null 2>&1; echo rc=$?')
if [ "$(sed -n 1p <<<"$out")" != 0 ] && grep -q '^NO_SUDO$' <<<"$out" && ! grep -q '^rc=0$' <<<"$out"; then
    pass "AC9.2 shell has no sudo and su fails"
else
    fail "AC9.2 shell root escape: $(tr '\n' '|' <<<"$out")"
fi

# 12. Both images run as uid 1000 (shared outbox ownership relies on it)
u1=$(run_in "$host_img" 'id -u'); u2=$(run_in "$shell_img" 'id -u')
[ "$u1" = 1000 ] && [ "$u2" = 1000 ] && pass "uid 1000 in both images" || fail "uids: host=$u1 shell=$u2"

# 13. AC4.2 — sources.lock: SHAs, versions, patch subjects, no diff content
lock="${stack_dir}/sources.lock"
host_sha=$(awk '$1=="source" && $2=="connectome-host" {sub("sha=","",$3); print $3}' "$lock" 2>/dev/null)
if [ -f "$lock" ] \
   && [ "$(grep -cE '^source [a-z-]+ sha=[0-9a-f]{40} ' "$lock")" = 4 ] \
   && git -C "${HOME}/Developer/connectome/connectome-host" merge-base --is-ancestor 406dcc1 "$host_sha" 2>/dev/null \
   && grep -qx 'npm term-sessions-mcp 1.6.0' "$lock" \
   && grep -q '^patch connectome-host local: recipe-configurable subagent' "$lock" \
   && grep -q '^patch connectome-host local: empty optional subagent' "$lock" \
   && grep -qx 'patch heartbeat-mcpl local: refuse reminders below a 900 s floor' "$lock" \
   && grep -q '^patch discord-mcpl local: confine attachments' "$lock" \
   && ! grep -qE '^[-+][^-+]' "$lock"; then
    pass "AC4.2 sources.lock records SHAs and patch subjects only"
else
    fail "AC4.2 sources.lock incomplete or contains diff content"
fi

[ "$__check_failed" -eq 0 ] || exit 1
