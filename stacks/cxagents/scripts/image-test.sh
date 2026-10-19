#!/usr/bin/env bash
# stacks/cxagents/scripts/image-test.sh
# Static and hardened-runtime assertions against tailnet-forwarder:local (build
# it first with build.sh). Every run is a throwaway container: --network none,
# --read-only, --cap-drop ALL, no-new-privileges. One pass/fail line per check,
# naming the AC; exit 1 if any check fails.
#
# Bounded runs use a poll loop instead of GNU timeout (not installed on macOS
# and not a dependency of this repo): a run still going after SECS is stopped.
#
# Throwaway state: volume cxagents_imagetest_state (recreated each run) and a
# temp dir under DARWIN_USER_TEMP_DIR (/var/folders is mounted into the agents
# VM read-only; $TMPDIR is not). Both are removed by the EXIT trap.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
repo_root="$(cd "$stack_dir/../.." && pwd)"
# shellcheck source=../../scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

ctx=colima-agents
img=tailnet-forwarder:local
vol=cxagents_imagetest_state
lock="${stack_dir}/build.lock"
src="${stack_dir}/forwarder"
builder="$(sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' "${src}/Dockerfile")"
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges:true --network none)
ext=cxagents-imagetest-extract
tmp="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)cxagents-imagetest.XXXXXX")"

cleanup() {
    docker --context "$ctx" rm -f "$ext" >/dev/null 2>&1 || true
    docker --context "$ctx" rm -f cxagents-imagetest-run >/dev/null 2>&1 || true
    docker --context "$ctx" volume rm -f "$vol" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

docker --context "$ctx" image inspect "$img" >/dev/null 2>&1 \
    || { echo "image-test: ${img} not found (run dotfiles stacks cxagents build first)" >&2; exit 1; }

# run_bounded SECS -- DOCKER_RUN_ARGS...
# Starts a detached container, stops it if still running after SECS, and sets
# RC (exit code, 124 if stopped by the watchdog) and OUT (combined output).
run_bounded() {
    local secs=$1; shift
    docker --context "$ctx" rm -f cxagents-imagetest-run >/dev/null 2>&1 || true
    if ! docker --context "$ctx" run -d --name cxagents-imagetest-run "$@" >/dev/null 2>&1; then
        RC=125; OUT="docker run failed"; return
    fi
    local i=0 running
    running=$(docker --context "$ctx" inspect -f '{{.State.Running}}' cxagents-imagetest-run 2>/dev/null)
    while [ "$running" = true ] && [ "$i" -lt "$secs" ]; do
        sleep 1; i=$((i + 1))
        running=$(docker --context "$ctx" inspect -f '{{.State.Running}}' cxagents-imagetest-run 2>/dev/null)
    done
    RC=124
    if [ "$running" != true ]; then
        RC=$(docker --context "$ctx" inspect -f '{{.State.ExitCode}}' cxagents-imagetest-run 2>/dev/null)
    else
        docker --context "$ctx" stop -t 0 cxagents-imagetest-run >/dev/null 2>&1 || true
    fi
    OUT=$(docker --context "$ctx" logs cxagents-imagetest-run 2>&1)
    docker --context "$ctx" rm -f cxagents-imagetest-run >/dev/null 2>&1 || true
}

# 1. AC8.2 — non-root user and the binary as the only entrypoint
user=$(docker --context "$ctx" image inspect -f '{{.Config.User}}' "$img" 2>&1)
entry=$(docker --context "$ctx" image inspect -f '{{json .Config.Entrypoint}}' "$img" 2>&1)
[ "$user" = 65532:65532 ] && [ "$entry" = '["/tailnet-forwarder"]' ] \
    && pass "AC8.2 user ${user}, entrypoint ${entry}" \
    || fail "AC8.2 user='${user}' entrypoint='${entry}'"

# 2. AC8.2 — no shell in the image
docker --context "$ctx" run --rm --network none --entrypoint /bin/sh "$img" -c true >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "AC8.2 no shell in image (/bin/sh exec fails, rc=${rc})" \
    || fail "AC8.2 /bin/sh runs inside the image"

# 3. AC8.4 — static, trimmed binary whose hash matches build.lock
docker --context "$ctx" rm -f "$ext" >/dev/null 2>&1 || true
mkdir -p "$tmp/bin"
if docker --context "$ctx" create --name "$ext" "$img" >/dev/null 2>&1 \
   && docker --context "$ctx" cp "$ext:/tailnet-forwarder" "$tmp/bin/tailnet-forwarder" >/dev/null 2>&1; then
    info=$(docker --context "$ctx" run --rm --network none -e GOTOOLCHAIN=local \
        -v "$tmp/bin:/b:ro" --entrypoint go "$builder" version -m /b/tailnet-forwarder 2>&1)
    tab=$'\t'
    bin_sha=$(shasum -a 256 "$tmp/bin/tailnet-forwarder" | awk '{print $1}')
    lock_sha=$(sed -n 's/^binary sha256:\([0-9a-f]*\) .*/\1/p' "$lock" 2>/dev/null)
    ok=1; detail=""
    for want in "build${tab}CGO_ENABLED=0" "build${tab}-trimpath=true" "go1.27.1" "tailscale.com${tab}v1.104.1"; do
        grep -qF "$want" <<<"$info" || { ok=0; detail="$detail missing:${want}"; }
    done
    [ -n "$lock_sha" ] && [ "$bin_sha" = "$lock_sha" ] || { ok=0; detail="$detail sha=${bin_sha} lock=${lock_sha:-none}"; }
    [ "$ok" = 1 ] && pass "AC8.4 static trimmed binary (CGO_ENABLED=0, -trimpath, go1.27.1, tailscale.com v1.104.1), sha matches build.lock" \
        || fail "AC8.4 binary check:${detail}"
else
    fail "AC8.4 cannot extract the binary from ${img}"
fi
docker --context "$ctx" rm -f "$ext" >/dev/null 2>&1 || true

# 4. AC8.2 — read-only root; state volume starts empty and owned by 65532
docker --context "$ctx" volume rm -f "$vol" >/dev/null 2>&1 || true
run_bounded 20 "${hardened[@]}" -v "$vol:/state" "$img" check --state-only
if [ "$RC" = 1 ] && grep -qx 'state: empty' <<<"$OUT"; then
    owner=$(docker --context "$ctx" run --rm -v "$vol:/state" --entrypoint stat "$builder" -c %u:%g /state 2>&1)
    [ "$owner" = 65532:65532 ] && pass "AC8.2 read-only root; empty state volume owned by ${owner}" \
        || fail "AC8.2 state volume owner: ${owner}"
else
    fail "AC8.2 hardened check --state-only: rc=${RC} out=$(tr '\n' ' ' <<<"$OUT")"
fi

# 5. AC6.8 — a routes file with overlapping ranges refuses to start
printf '%s\n' 'a 1024-5000 -' 'b 4000-6000 -' > "$tmp/routes-overlap"
run_bounded 20 "${hardened[@]}" -v "$vol:/state" \
    -v "$tmp/routes-overlap:/etc/forwarder/routes:ro" "$img" serve
if [ "$RC" != 124 ] && [ "$RC" != 0 ] && grep -q 'overlaps line' <<<"$OUT"; then
    pass "AC6.8 overlapping routes refused (rc=${RC})"
else
    fail "AC6.8 overlapping routes: rc=${RC} out=$(tr '\n' ' ' <<<"$OUT")"
fi

# 6. AC5.7 — valid routes, empty state: refuses before any network check
printf '%s\n' 'a 1024-5000 -' > "$tmp/routes-ok"
run_bounded 20 "${hardened[@]}" -v "$vol:/state" \
    -v "$tmp/routes-ok:/etc/forwarder/routes:ro" "$img" serve
if [ "$RC" != 124 ] && [ "$RC" != 0 ] && grep -qF 'run `dotfiles stacks cxagents login`' <<<"$OUT"; then
    pass "AC5.7 empty state refuses serve with the login hint (rc=${RC})"
else
    fail "AC5.7 empty-state serve: rc=${RC} out=$(tr '\n' ' ' <<<"$OUT")"
fi

[ "$__check_failed" -eq 0 ] || exit 1
