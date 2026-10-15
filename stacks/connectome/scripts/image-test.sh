#!/usr/bin/env bash
# stacks/connectome/scripts/image-test.sh
# Static assertions against the built images (13 checks covering ACs 4.2-4.5, 5.2, 7.5, 9.1-9.2)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
repo_root="$(cd "$stack_dir/../.." && pwd)"

# shellcheck source=../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

D() { docker --context colima-agents "$@"; }
X() { D exec "$@"; }

# Test 1: AC4.3 — images are linux/arm64
check_ac 4.3 "images are linux/arm64"
imgs=$(D image inspect -f '{{.Os}}/{{.Architecture}}' connectome-host:local connectome-shell:local)
if echo "$imgs" | grep -q "linux/arm64" && [ "$(echo "$imgs" | grep -c "linux/arm64")" -eq 2 ]; then
    pass "4.3"
else
    fail "4.3" "not both linux/arm64: $imgs"
fi

# Test 2: AC4.3 — gateway CA fingerprint matches in both images
check_ac 4.3 "gateway CA fingerprint"
gw_sha=$(D exec onecli-gateway cat /app/data/gateway/ca.pem 2>/dev/null | sha256sum | awk '{print $1}')
for img in connectome-host:local connectome-shell:local; do
    img_sha=$(D run --rm --entrypoint sh "$img" -c 'sha256sum /usr/local/share/ca-certificates/onecli-gateway.crt' 2>/dev/null | awk '{print $1}')
    if [ "$gw_sha" = "$img_sha" ]; then
        : # ok
    else
        fail "4.3" "CA mismatch in $img: gw=$gw_sha vs img=$img_sha"
    fi
done
pass "4.3"

# Test 3: AC4.3 — CA body is in system trust store
check_ac 4.3 "CA in system trust store"
ca_body=$(D exec onecli-gateway cat /app/data/gateway/ca.pem 2>/dev/null | sed -n '2p' | cut -c1-60)
for img in connectome-host:local connectome-shell:local; do
    if D run --rm --network none --entrypoint sh "$img" -c "grep -cF '$ca_body' /etc/ssl/certs/ca-certificates.crt" >/dev/null 2>&1; then
        : # ok
    else
        fail "4.3" "CA body not found in trust store in $img"
    fi
done
pass "4.3"

# Test 4: AC4.4 — connectome has real Node (not Bun symlink)
check_ac 4.4 "connectome has real Node"
node_ver=$(D run --rm --network none --entrypoint sh connectome-host:local -c '/opt/node/bin/node -p "process.versions.bun ? \"BUN\" : process.version"')
if [[ "$node_ver" == v22.* ]]; then
    pass "4.4"
else
    fail "4.4" "expected v22.*, got $node_ver"
fi

# Test 5: AC4.4 — WebUI and Codex present
check_ac 4.4 "WebUI and Codex"
check_out=$(D run --rm --network none --entrypoint sh connectome-host:local -c 'test -f /opt/connectome/dist/web/index.html && codex --version' 2>&1)
if echo "$check_out" | grep -q "codex-cli 0.162.1"; then
    pass "4.4"
else
    fail "4.4" "WebUI or Codex check failed"
fi

# Test 6: AC5.2 — /agent/cwd layout and permissions
check_ac 5.2 "/agent/cwd layout"
check_out=$(D run --rm --network none --entrypoint sh connectome-host:local -c '
    uid=$(id -u)
    ls_out=$(ls -A /agent/cwd)
    links=$(readlink /agent/cwd/mcpl-servers.json /agent/cwd/logs)
    touch_test=$(touch /agent/cwd/mcpl-servers.agent.json 2>&1; touch /agent/cwd/x 2>&1; echo rc=$?)
    echo "uid=$uid|ls=$ls_out|links=$links|$touch_test"
')
if echo "$check_out" | grep -q "uid=1000" && \
   echo "$check_out" | grep -q "ls=logs mcpl-servers.json" && \
   echo "$check_out" | grep -q "/agent/recipes/mcpl-servers.json" && \
   echo "$check_out" | grep -q "/agent/state/logs" && \
   echo "$check_out" | grep -q "Permission denied" && \
   echo "$check_out" | grep -q "rc=1"; then
    pass "5.2"
else
    fail "5.2" "layout check failed: $check_out"
fi

# Test 7: AC4.5 — heartbeat refuses reminder floor (60s)
check_ac 4.5 "heartbeat refuses below 900s (60s test)"
hb_out=$(D run --rm --network none --entrypoint node connectome-host:local /opt/connectome-tests/mcp-call.mjs reminder_add '{"message":"x","everySeconds":60}' -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio 2>&1)
if echo "$hb_out" | jq -e '.isError==true and (.text | contains("900"))' >/dev/null 2>&1; then
    pass "4.5"
else
    fail "4.5" "should refuse 60s: $hb_out"
fi

# Test 8: AC4.5 — heartbeat accepts 900s
check_ac 4.5 "heartbeat accepts 900s"
hb_out=$(D run --rm --network none --entrypoint node connectome-host:local /opt/connectome-tests/mcp-call.mjs reminder_add '{"message":"x","everySeconds":900}' -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio 2>&1)
if echo "$hb_out" | jq -e '.isError==false' >/dev/null 2>&1; then
    pass "4.5"
else
    fail "4.5" "should accept 900s: $hb_out"
fi

# Test 9: AC7.5 — discord attachment guard
check_ac 7.5 "discord attachment guard"
attach_out=$(D run --rm --network none --entrypoint node connectome-host:local --input-type=module -e '
import { loadAttachment } from "/opt/mcpl/discord-mcpl/dist/src/attachment-guard.js";
const test_root = "/tmp/test_attach";
import fs from "fs";
fs.mkdirSync(test_root, { recursive: true });
fs.writeFileSync(test_root + "/ok.txt", "test");
let results = [];

try {
  const loaded = loadAttachment(test_root + "/ok.txt", test_root);
  results.push("ok");
} catch(e) {
  results.push("failed_ok");
}

try {
  loadAttachment("/proc/self/environ", test_root);
  results.push("failed_proc");
} catch(e) {
  results.push("refused");
}

try {
  fs.symlinkSync("/etc/passwd", test_root + "/evil");
  loadAttachment(test_root + "/evil", test_root);
  results.push("failed_symlink");
} catch(e) {
  results.push("refused");
}

try {
  loadAttachment(test_root + "/ok.txt");
  results.push("failed_unset");
} catch(e) {
  results.push("refused");
}

console.log(results.join(" "));
fs.rmSync(test_root, { recursive: true });
' 2>&1)
if [ "$attach_out" = "ok refused refused refused" ]; then
    pass "7.5"
else
    fail "7.5" "attachment guard failed: $attach_out"
fi

# Test 10: AC9.1 — shell has all required tools
check_ac 9.1 "shell tools"
tools_out=$(D run --rm --network none --entrypoint sh connectome-shell:local -c '
  uname -m && node -v && tsc -v && cargo -V && rustc -V && python3 -V && pip -V && uv -V && rg -V && fd -V && jq -V && git --version && gh --version && gcc --version | head -1 && make -v | head -1
' 2>&1)
if echo "$tools_out" | grep -q "aarch64" && \
   echo "$tools_out" | grep -q "^v22\." && \
   echo "$tools_out" | grep -q "cargo" && \
   echo "$tools_out" | grep -q "gcc"; then
    pass "9.1"
else
    fail "9.1" "tool check failed: $tools_out"
fi

# Test 11: AC9.2 — shell has no sudo
check_ac 9.2 "shell no sudo"
sudo_out=$(D run --rm --network none --entrypoint sh connectome-shell:local -c '
  id -u && (command -v sudo || echo NO_SUDO) && (su -c true root </dev/null 2>&1; echo rc=$?)
' 2>&1)
if echo "$sudo_out" | grep -q "NO_SUDO" && \
   ! echo "$sudo_out" | grep -q "^/"; then
    pass "9.2"
else
    fail "9.2" "sudo check failed: $sudo_out"
fi

# Test 12: AC— — both containers uid 1000
check_ac - "both containers uid 1000"
connectome_uid=$(D run --rm --network none --entrypoint sh connectome-host:local -c 'id -u' 2>&1)
shell_uid=$(D run --rm --network none --entrypoint sh connectome-shell:local -c 'id -u' 2>&1)
if [ "$connectome_uid" = "1000" ] && [ "$shell_uid" = "1000" ]; then
    pass -
else
    fail - "uid check: connectome=$connectome_uid, shell=$shell_uid"
fi

# Test 13: AC4.2 — sources.lock is well-formed
check_ac 4.2 "sources.lock format"
lock="$stack_dir/sources.lock"
if [ ! -f "$lock" ]; then
    fail "4.2" "sources.lock not found"
else
    # Check for 4 source lines with 40-hex sha
    if [ "$(grep -c '^source .* sha=[0-9a-f]\{40\}' "$lock")" -ne 4 ]; then
        fail "4.2" "should have 4 source lines with 40-hex sha"
    fi
    # Check connectome-host sha has 406dcc1 as ancestor
    chost_sha=$(grep '^source connectome-host' "$lock" | sed 's/.*sha=\([0-9a-f]*\).*/\1/')
    if ! git -C ~/Developer/connectome/connectome-host merge-base --is-ancestor 406dcc1 "$chost_sha" 2>/dev/null; then
        fail "4.2" "connectome-host sha $chost_sha does not have 406dcc1 as ancestor"
    fi
    # Check npm and codex lines
    if ! grep -q '^npm term-sessions-mcp 1\.6\.0' "$lock"; then
        fail "4.2" "missing npm term-sessions-mcp 1.6.0"
    fi
    if ! grep -q '^codex ' "$lock"; then
        fail "4.2" "missing codex version"
    fi
    # Check patch subjects
    if ! grep -q '^patch heartbeat-mcpl local: refuse reminders below a 900 s floor' "$lock"; then
        fail "4.2" "missing heartbeat patch subject"
    fi
    if ! grep -q '^patch discord-mcpl local: confine attachments' "$lock"; then
        fail "4.2" "missing discord patch subject"
    fi
    # Check no diff content
    if grep -E '^[-+]{1}[^-+]' "$lock" >/dev/null; then
        fail "4.2" "sources.lock has diff content, should only have subjects"
    fi
    pass "4.2"
fi

if [ "$__check_failed" -eq 0 ]; then
    exit 0
else
    exit 1
fi
