# cxagents Node Implementation Plan — Phase 5 of 7: `stacks/cxagents` stack and login

**Goal:** The cxagents node runs in the agents VM as container `cxagents-forwarder`, logged in as `tag:cxagents` with a single-use auth key that is never stored, with static lints enforcing its lockdown and the stack wired into the `stacks` aggregates.

**Architecture:** New stack `stacks/cxagents/` (Docker context `colima-agents`, compose project `cxagents`) that owns Docker network `cxagents` and named volume `cxagents_state`. `scripts/login.sh` walks the state/device matrix and pipes `tailscale/scripts/authkey.sh tag:cxagents` into a one-shot `tailnet-forwarder login` container. `scripts/up.sh` refuses to start on empty state. `scripts/lint.sh` checks the policy, compose file, routes and every stack's `.env`/compose environment; `lint-test.sh` proves each invariant.

**Tech Stack:** bash, jq, Docker Compose 5.1.3 / Docker 29.2.1 on `colima-agents`, `tailnet-forwarder:local` (Phase 4), Tailscale API (Phases 1–3).

**Scope:** Phase 5 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`. Depends on Phases 3 and 4.

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file".

**State found at verification:**
- `stacks/justfile` lines 1–6 `mod adguard … mod wallabag`; `up-all` loop (line 19) `adguard freshrss homebridge onecli connectome wallabag`; `down-all` (35–41) connectome, onecli, wallabag, homebridge, freshrss, adguard; `ps-all` (43–49) and `pull-all` (51–57) list every stack; `backup-all` (63–70). Module recipes run with cwd `stacks/` and call `just <stack> <recipe>` (never `{{justfile()}}`).
- Model stack: `stacks/onecli/` — `compose.yaml` owns a network with an explicit `name: onecli-agents` (line 145) and uses an `x-common` hardening anchor (`restart`, `platform: linux/arm64`, `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]`); its `down` recipe refuses while connectome containers exist (they hold the network). `stacks/connectome/compose.yaml` has `x-hardening` with the same keys; neither uses `read_only`, `logging` or `healthcheck` yet.
- `stacks/connectome/scripts/lint.sh` / `lint-test.sh` are the lint model (`--flag F` overrides, `cjson` = `docker compose -f F config --no-interpolate --format json`, `mk`/`expect_only`/`expect_none`).
- Agents VM networks today: `bridge`, `connectome_connectome`, `host`, `none`, `onecli-agents` (172.19.0.0/16), `onecli_onecli`. Containers: `connectome`, `connectome-shell`, `onecli-*`.
- `connectome-shell` (container name) is the first target; it is attached to the `cxagents` network only in Phase 6.

**Live-system note:** the compose file binds `./routes` by a path relative to the compose file. While this plan executes, the stack runs from the worktree; **after merge it must be re-created from the main checkout** (`dotfiles stacks cxagents up` from `main`), or the bind keeps pointing into the worktree. Collected in Phase 7's post-merge list. **A host reboot before the merge** runs `main`'s `startup.sh` → `main`'s `up-all`, which knows nothing of cxagents (the forwarder still restarts by its `restart: unless-stopped` policy) and, from Phase 6 on, recreates `connectome-shell` without the overlay and with `main`'s `recipes/`. After any pre-merge reboot, re-run `$J stacks cxagents up` and `$J stacks connectome up` from the worktree (or merge promptly).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC5: The node is tagged, locked down and logged in without a stored key (Phases 3, 5)
- **cxagents-node.AC5.3 Failure:** once the node exists, no tailnet peer's packet filter lists the cxagents node's IPs as a source (checked on cxmini via `tailscale debug netmap`).
- **cxagents-node.AC5.4 Success:** `dotfiles stacks cxagents login` on empty state with no existing device registers a node named exactly `cxagents`, tagged `tag:cxagents`, key expiry disabled; the key goes in on stdin to a one-shot container and appears in no compose file, `.env`, or `docker inspect` output.
- **cxagents-node.AC5.5 Edge:** `login` across the state/device matrix — state valid + device present → no-op; state empty + device present → stops before minting and prints that device's admin-console URL; state present + device missing → confirms, wipes state, re-registers; image missing → stops before minting with "run `cxagents build`".
- **cxagents-node.AC5.6 Success:** the node keeps its name and identity across `restart`, `down`/`up`, and an agents VM restart.
- **cxagents-node.AC5.7 Failure:** `cxagents up` (and therefore `up-all` and the boot daemon) on empty state refuses with "run `dotfiles stacks cxagents login`" instead of starting a forwarder that waits on an interactive login.

### cxagents-node.AC8: The forwarder is isolated (Phases 4, 5)
- **cxagents-node.AC8.1 Failure:** from inside the forwarder's network namespace, `connectome:18768` and the onecli gateway are unreachable.
- **cxagents-node.AC8.2:** the forwarder container runs non-root (uid 65532) with `cap_drop: ALL`, `no-new-privileges`, read-only root, no published ports, bounded json-file logging, and only the `cxagents` network (lint-enforced).
- **cxagents-node.AC8.3:** lint fails if any grant has `tag:cxagents` as a source, if any grant to `tag:cxagents` includes a `routes` deny port, or if an auth-key/OAuth key name appears in a stack `.env` or compose environment; lint-test proves each.

---

<!-- START_TASK_1 -->
### Task 1: `routes`, `compose.yaml`, volume/network ownership

**Verifies:** cxagents-node.AC8.2 (declaration; enforced by Task 2's lint).

**Files:**
- Create: `stacks/cxagents/routes`, `stacks/cxagents/compose.yaml`, `stacks/cxagents/scripts/lib/stack.sh`.

**Step 1: `routes`**
```
# stacks/cxagents/routes — port routing for the cxagents node (read-only bind
# into the forwarder). The master for deny ports: tailscale/policy.hujson's
# member -> tag:cxagents grant is this range minus these ports (cxagents lint).
# target = a Docker container name (unique per daemon). Ranges must not
# overlap; a new target splits a range. Ports < 1024 are never routed.
# target            ports        deny
connectome-shell    1024-65535   3100
```

**Step 2: `compose.yaml`**
```yaml
name: cxagents

# The cxagents tailnet node (tsnet; stacks/cxagents/forwarder). Owns network
# `cxagents` (targets such as connectome-shell join it as external) and the
# state volume (node keys + cert cache; disposable, not backed up — losing it
# costs a re-login). No auth key ever appears here: `login` feeds it on stdin
# to a one-shot container (scripts/login.sh).
services:
  forwarder:
    image: tailnet-forwarder:local
    container_name: cxagents-forwarder
    hostname: cxagents-forwarder
    platform: linux/arm64
    restart: unless-stopped
    user: "65532:65532"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      FORWARDER_HOSTNAME: cxagents
      FORWARDER_TAG: tag:cxagents
      FORWARDER_ROUTES: /etc/forwarder/routes
      FORWARDER_STATE_DIR: /state
      FORWARDER_STATUS_PORT: "8080"
      TS_NO_LOGS_NO_SUPPORT: "true"
      TS_LOGS_DIR: /state/logs
    volumes:
      - state:/state
      - ./routes:/etc/forwarder/routes:ro
    networks:
      - cxagents
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
    healthcheck:
      test: ["CMD", "/tailnet-forwarder", "check"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s

volumes:
  state:
    name: cxagents_state

networks:
  # Not internal: the node needs egress to Tailscale control/DERP.
  cxagents:
    name: cxagents
    driver: bridge
```

**Step 3: `scripts/lib/stack.sh`** (source-only constants and helpers shared by `up.sh`, `login.sh`, `login-test.sh`, `smoke.sh`):
```bash
#!/usr/bin/env bash
# stacks/cxagents/scripts/lib/stack.sh — source-only.
cx_ctx=colima-agents
cx_stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cx_repo_root="$(cd "${cx_stack_dir}/../.." && pwd)"
cx_image="${CXAGENTS_IMAGE:-tailnet-forwarder:local}"
cx_volume="${CXAGENTS_STATE_VOLUME:-cxagents_state}"
cx_host=cxagents
cx_tag=tag:cxagents
D()  { docker --context "$cx_ctx" "$@"; }
DC() { docker --context "$cx_ctx" compose -f "${cx_stack_dir}/compose.yaml" "$@"; }
# Create the state volume with compose's labels (so compose adopts it without
# warnings) when it does not exist yet; never touches an existing volume.
cx_ensure_volume() {
    D volume inspect "$cx_volume" >/dev/null 2>&1 && return 0
    D volume create --label com.docker.compose.project=cxagents \
        --label com.docker.compose.volume=state "$cx_volume" >/dev/null
}
cx_volume_exists() { D volume inspect "$cx_volume" >/dev/null 2>&1; }
# Prints "state: node <ID>" / "state: empty"; exit 0 = node present.
# Mounting a missing volume would create it: read-only callers (doctor) must
# check cx_volume_exists first; up/login call cx_ensure_volume first.
cx_state() {
    D run --rm --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true -v "${cx_volume}:/state" \
        "$cx_image" check --state-only
}
```

**Step 4: Verify (static)**
```bash
cd "$wt/stacks/cxagents"
docker compose -f compose.yaml config --no-interpolate --format json | jq -c '.services.forwarder | {user, read_only, cap_drop, networks: (.networks|keys), ports}'
```
Expected: `{"user":"65532:65532","read_only":true,"cap_drop":["ALL"],"networks":["cxagents"],"ports":null}`.

**Step 5: Commit**
```bash
git add stacks/cxagents/routes stacks/cxagents/compose.yaml stacks/cxagents/scripts/lib/stack.sh
git commit -m "stacks/cxagents: routes, hardened compose (owns network cxagents, volume cxagents_state)"
```
<!-- END_TASK_1 -->

<!-- START_SUBCOMPONENT_A (tasks 2-3) -->
<!-- START_TASK_2 -->
### Task 2: `lint.sh`

**Verifies:** cxagents-node.AC8.2, AC8.3.

**Files:**
- Create: `stacks/cxagents/scripts/lint.sh` (755).
- Modify: `tailscale/scripts/keyscan.sh` (`--names --no-pat`).

**Implementation** (model `stacks/connectome/scripts/lint.sh`: `#!/bin/bash`, `set -uo pipefail`, sources `stacks/scripts/lib/check.sh`, defaults are the real paths, `--policy F --compose F --routes F --stacks-dir D` overrides, fail-closed parse, numbered invariants, final exit). Inputs: policy JSON via `perl "$repo_root/tailscale/scripts/lib/hujson2json.pl" < policy | jq -c .`; compose JSON via `docker compose -f F config --no-interpolate --format json`; routes parsed in awk (skip `#`/blank; fields `target from-to deny`). Never read a `.env` value: `.env` files contribute key names only (`grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d =`). Invariants (each `pass`/`fail` prefixed `cxagents invariant N:`):
1. **`tag:cxagents` is never a policy source** — no `grants[].src[]`, `acls[].src[]` or `ssh[].src[]` equals `tag:cxagents`.
2. **Grants to `tag:cxagents` stay inside routes and avoid deny ports** — for every grant whose `dst` contains `tag:cxagents`: every `ip` entry matches `^tcp:[0-9]+(-[0-9]+)?$` (no `*`, no other protocol); each interval lies within one route's range and contains none of that route's deny ports. (Since every route starts at ≥1024 — invariant 6 — no port <1024 can be granted.)
3. **Forwarder hardening** — service `forwarder`: `container_name == "cxagents-forwarder"`; `networks` keys exactly `["cxagents"]` and the top-level network `cxagents` has `name: "cxagents"`; no `ports`; no `network_mode`; `cap_drop` contains `ALL`; `security_opt` contains `no-new-privileges:true`; `read_only == true`; `user == "65532:65532"`; `logging.driver == "json-file"` with `options."max-size"` and `options."max-file"` set; volumes are exactly the `state` volume at `/state` and a read-only bind at `/etc/forwarder/routes`.
4. **No auth-key/OAuth key names in any stack `.env` or compose environment** — collect key names from every `stacks/*/.env` (key names only) and every `environment` key of every service in every `stacks/*/compose*.yaml` (rendered), pipe them into `tailscale/scripts/keyscan.sh --names --no-pat`; any output → `fail "cxagents invariant 4: credential key name(s) in stack env/compose: …"` (names only). `--no-pat` excludes the retired PAT name: a leftover PAT line in the live `stacks/adguard/.env` before the post-merge cutover is doctor's `--- Tailnet ---` WARN (AC4.7), not a lockdown failure. **Modify `tailscale/scripts/keyscan.sh`** in this task to accept `--names --no-pat` (same as `--names`, with `TAILSCALE_PAT` removed from the pattern).
5. **Routes targets are container names** — every routes `target` equals some service `container_name` in the rendered `stacks/*/compose*.yaml` files.
6. **Routes parse, don't overlap, start at ≥1024, deny ports inside their range.**
7. **Identity matches** — forwarder `environment.FORWARDER_HOSTNAME == "cxagents"`, `FORWARDER_TAG == "tag:cxagents"`, and that tag is a key of the policy's `tagOwners`.

(`--stacks-dir` defaults to `$repo_root/stacks`; lint-test points it at a fixture tree.)

**Step 1:** Create the script.

**Step 2: Verify:** `cd "$wt" && stacks/cxagents/scripts/lint.sh` → seven `[OK]` lines, exit 0.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/lint.sh tailscale/scripts/keyscan.sh
git commit -m "stacks/cxagents: lint (no tag:cxagents source, grants within routes, hardening, no key names, targets)"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: `lint-test.sh`

**Verifies:** cxagents-node.AC8.3 (each invariant proven), AC8.2 (lint-enforced).

**Files:**
- Create: `stacks/cxagents/scripts/lint-test.sh` (755).

**Implementation** (model `stacks/connectome/scripts/lint-test.sh`; temp dir + trap; baseline fixtures: `policy.json` (converted real policy), `compose.json` (rendered real compose; lint must accept a pre-rendered JSON file — make `lint.sh` treat a `--compose` path ending in `.json` as already rendered, as connectome's lint-test does with its rendered fixtures), `routes` (copy), and a fixture stacks dir (`$tmpdir/stacks/<stack>/compose.yaml` copies of the real compose files and a `.env` per stack built from **key names only** of each `.env.example`, values `x`). Cases (`expect_only LABEL 'cxagents invariant N:' …` unless noted):
- `baseline` → `expect_none`.
- `inv1-grant-src` → grant `{"src":["tag:cxagents"],"dst":["autogroup:member"],"ip":["*"]}`; `inv1-acl-src` → an ACL with that src; `inv1-ssh-src` → an ssh rule with that src.
- `inv2-deny-port` → cxagents grant `ip` `["tcp:1024-65535"]` (includes 3100); `inv2-star` → `ip` `["*"]`; `inv2-below-1024` → `["tcp:80"]`; `inv2-udp` → `["udp:5000"]`.
- `inv3-extra-network`, `inv3-ports`, `inv3-no-readonly`, `inv3-caps`, `inv3-nnp`, `inv3-root-user`, `inv3-no-logging-limit` — one compose mutation each.
- `inv4-env-key` → fixture `stacks/onecli/.env` gains a line `TS_AUTHKEY=x`; `inv4-compose-env` → forwarder `environment.TS_AUTHKEY = "x"`; `inv4-oauth-name` → a fixture `.env` gains `TS_AUTHKEYS_CLIENT_SECRET=x`. (These names are written by the fixture generator via `keyscan.sh`-independent literals only inside the temp dir; to keep the names out of `stacks/` sources, `lint-test.sh` builds them from fragments, e.g. `k="TS_AUTH""KEY"`.)
- `inv5-unknown-target` → routes target `no-such-container`.
- `inv6-overlap` → second routes line `other 5000-6000 -`; `inv6-low` → `connectome-shell 80-65535 3100`.
- `inv7-hostname` → `FORWARDER_HOSTNAME: cxagents2`.

**Step 1:** Create the script (and the `.json` passthrough in `lint.sh`).

**Step 2: Verify:** `stacks/cxagents/scripts/lint-test.sh` → every `PASS lint-fixture …`, `All fixtures passed`; `tailscale/scripts/keyscan.sh --repo` still exits 0 (the fragment trick keeps the literal names out of tracked files).

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/lint.sh stacks/cxagents/scripts/lint-test.sh
git commit -m "stacks/cxagents: lint-test (one fixture per invariant)"
```
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_4 -->
### Task 4: `up.sh`, `login.sh` and the stack justfile

**Verifies:** cxagents-node.AC5.4, AC5.5, AC5.7 (behaviour; exercised in Tasks 6–7).

**Files:**
- Create: `stacks/cxagents/scripts/up.sh` (755), `stacks/cxagents/scripts/login.sh` (755), `stacks/cxagents/justfile`.

**Step 1: Probe the devices list shape (read-only)**
```bash
cd "$wt/tailscale/scripts"
./api.sh --client admin GET /tailnet/cxreiff.github/devices | jq '.devices[0] | {id, nodeId, name, hostname, addresses, tags, keyExpiryDisabled}'
```
Expected: those field names exist (values for cxmini). If any is missing or named differently, use the names the API returns throughout this task and Task 6, and note it in the commit message. Also open `https://login.tailscale.com/admin/machines/<cxmini's first address>` (ask the user to confirm in a browser that it opens cxmini's device page); if it doesn't, ask the user for the URL pattern their console uses and use that.

**Step 2: `up.sh`**
```bash
#!/usr/bin/env bash
# stacks/cxagents/scripts/up.sh — start the forwarder; refuses on a missing
# image or empty state so boot/up-all never start a node waiting on a login.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"
D image inspect "$cx_image" >/dev/null 2>&1 || {
    echo "cxagents: image ${cx_image} missing — run \`dotfiles stacks cxagents build\`" >&2; exit 1; }
cx_ensure_volume
cx_state >/dev/null 2>&1 || {
    echo "cxagents: no node in state — run \`dotfiles stacks cxagents login\`" >&2; exit 1; }
[ "$cx_volume" = cxagents_state ] || { echo "cxagents: test volume ${cx_volume}: preflight ok, not starting"; exit 0; }
DC up -d --wait --wait-timeout 180
```

**Step 3: `login.sh`** — order of checks exactly as the design's login section; every precondition is checked **before** a key is minted:
```bash
#!/usr/bin/env bash
# stacks/cxagents/scripts/login.sh — register the cxagents node. The auth key
# exists only in the pipe authkey.sh -> one-shot `tailnet-forwarder login`.
# Matrix: state valid + device present -> no-op; any other cxagents device ->
# stop and print its admin URL (delete it, re-run); state whose device is gone
# -> confirm, wipe state, continue; empty state, no device -> mint + log in.
# Test seams: CXAGENTS_IMAGE, CXAGENTS_STATE_VOLUME, CXAGENTS_DEVICES_JSON
# (file used instead of the API device list), CXAGENTS_AUTHKEY_CMD,
# CXAGENTS_LOGIN_DRY_RUN=1 (stop just before minting).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"
# shellcheck source=../../../tailscale/scripts/lib/conf.sh
source "${cx_repo_root}/tailscale/scripts/lib/conf.sh"
api="${cx_repo_root}/tailscale/scripts/api.sh"
authkey_cmd="${CXAGENTS_AUTHKEY_CMD:-${cx_repo_root}/tailscale/scripts/authkey.sh ${cx_tag}}"

# 1. image
D image inspect "$cx_image" >/dev/null 2>&1 || {
    echo "cxagents login: image ${cx_image} missing — run \`dotfiles stacks cxagents build\`" >&2; exit 1; }

# 2. local state and the tailnet's cxagents devices
cx_ensure_volume
state_id="$(cx_state 2>/dev/null | sed -n 's/^state: node //p' || true)"
if [ -n "${CXAGENTS_DEVICES_JSON:-}" ]; then devices="$(cat "$CXAGENTS_DEVICES_JSON")"
else devices="$("$api" --client admin GET "/tailnet/${TAILNET}/devices")"; fi
mine="$(jq -c --arg h "$cx_host" '[.devices[] | select(.hostname == $h or (.name | split(".")[0] | test("^" + $h + "(-[0-9]+)?$")))]' <<<"$devices")"

if [ -n "$state_id" ] && jq -e --arg id "$state_id" --arg h "$cx_host" \
        'any(.[]; .nodeId == $id and (.name | split(".")[0]) == $h)' <<<"$mine" >/dev/null; then
    echo "cxagents login: already logged in as ${cx_host} (${state_id}); nothing to do"
    exit 0
fi
if [ -n "$state_id" ] && jq -e --arg id "$state_id" 'any(.[]; .nodeId == $id)' <<<"$mine" >/dev/null; then
    echo "cxagents login: this state owns $(jq -r --arg id "$state_id" '.[] | select(.nodeId == $id) | "\(.name)  https://login.tailscale.com/admin/machines/\(.addresses[0])"' <<<"$mine") — not exactly ${cx_host}." >&2
    echo "cxagents login: delete that device and any other cxagents device, then re-run login (it will offer to wipe the state)" >&2
    exit 1
fi
if [ "$(jq length <<<"$mine")" -gt 0 ]; then
    echo "cxagents login: a cxagents device already exists on the tailnet, and this state does not own it:" >&2
    jq -r '.[] | "  \(.name)  nodeId=\(.nodeId)  https://login.tailscale.com/admin/machines/\(.addresses[0])"' <<<"$mine" >&2
    echo "cxagents login: delete it in the admin console, then re-run \`dotfiles stacks cxagents login\`" >&2
    exit 1
fi
if [ -n "$state_id" ]; then
    printf 'cxagents login: state holds node %s, which no longer exists on the tailnet. Wipe %s and re-register? [y/N] ' "$state_id" "$cx_volume" >&2
    read -r answer || answer=""
    case "$answer" in y|yes) ;; *) echo "cxagents login: aborted; state kept" >&2; exit 1 ;; esac
    users="$(D ps -aq --filter "volume=${cx_volume}")"
    [ -z "$users" ] || D rm -f $users >/dev/null
    D volume rm "$cx_volume" >/dev/null
    cx_ensure_volume
fi

# 3. mint + log in (the key exists only in this pipe)
if [ "${CXAGENTS_LOGIN_DRY_RUN:-}" = 1 ]; then echo "cxagents login: dry run — would mint an auth key and log in"; exit 0; fi
$authkey_cmd | D run --rm -i --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -v "${cx_volume}:/state" \
    -e FORWARDER_HOSTNAME="$cx_host" -e FORWARDER_TAG="$cx_tag" -e FORWARDER_STATE_DIR=/state \
    -e TS_NO_LOGS_NO_SUPPORT=true -e TS_LOGS_DIR=/state/logs \
    "$cx_image" login

# 4. start
[ "$cx_volume" = cxagents_state ] && DC up -d --wait --wait-timeout 180
cx_state
```
(The one-shot uses Docker's default bridge for egress to Tailscale control; the `cxagents` network may not exist yet on first login.)

**Step 4: `stacks/cxagents/justfile`** (model: other stacks — `context := "colima-agents"`, comments above recipes show in `just --list`):
```just
context := "colima-agents"

default:
    @just --list

# Run the forwarder's tests in the pinned builder, build the image, write build.lock
build:
    @./scripts/build.sh

# Static assertions against tailnet-forwarder:local
image-test:
    @./scripts/image-test.sh

# go test ./... in the pinned builder (no Go on the host)
test:
    @./scripts/go.sh test -count=1 ./...

# Register the node (mints a single-use auth key, piped; never stored)
login:
    @./scripts/login.sh

# Refuses on a missing image or empty state (run login first)
up:
    @./scripts/up.sh

# Refuses while targets (e.g. connectome-shell) still hold the cxagents network
down:
    #!/usr/bin/env bash
    set -euo pipefail
    others=$(docker --context {{context}} network inspect cxagents -f '{{"{{"}}range .Containers{{"}}"}}{{"{{"}}.Name{{"}}"}} {{"{{"}}end{{"}}"}}' 2>/dev/null | tr ' ' '\n' | grep -vx 'cxagents-forwarder' | grep -v '^$' || true)
    if [ -n "$others" ]; then
        echo "cxagents: network cxagents still in use by: ${others//$'\n'/ } — run \`dotfiles stacks connectome down\` first" >&2
        exit 1
    fi
    docker --context {{context}} compose down

restart:
    docker --context {{context}} compose restart

ps:
    docker --context {{context}} compose ps -a

logs:
    docker --context {{context}} compose logs -f --tail 100

# Base images are pinned by digest (nothing to refresh): fetch any that are missing locally
pull:
    #!/usr/bin/env bash
    set -euo pipefail
    for ref in $(sed -n 's/^FROM \([^ ]*@sha256:[0-9a-f]*\).*/\1/p' forwarder/Dockerfile); do
        docker --context {{context}} image inspect "$ref" >/dev/null 2>&1 || docker --context {{context}} pull "$ref"
    done

# Static lockdown invariants (also run by `dotfiles stacks doctor`)
lint:
    @./scripts/lint.sh

# Prove each lint fails on a fixture violating exactly its invariant
lint-test:
    @./scripts/lint-test.sh

# Login matrix with test seams (copies state into throwaway volumes)
login-test:
    @./scripts/login-test.sh

# Live checks (identity, isolation, packet filter; Phase 6 adds end-to-end)
smoke:
    @./scripts/smoke.sh
```
(`{{"{{"}}…{{"}}"}}` is just's escape for a literal `{{` in a Go template; check `just --dry-run cxagents down` prints `{{range .Containers}}{{.Name}} {{end}}`.)

**Step 5: Verify (static)**
```bash
cd "$wt"; J="just -f $wt/justfile"
just -f "$wt/stacks/cxagents/justfile" --list
just -f "$wt/stacks/cxagents/justfile" --dry-run down 2>&1 | grep -F '{{range .Containers}}'
```

**Step 6: Commit**
```bash
git add stacks/cxagents/scripts/up.sh stacks/cxagents/scripts/login.sh stacks/cxagents/justfile
git commit -m "stacks/cxagents: justfile, up (refuses empty state), login (state/device matrix, key on stdin)"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Wire `cxagents` into `stacks/justfile`

**Verifies:** None here (AC9.4 is verified in Phase 7 after the connectome overlay exists).

**Files:**
- Modify: `stacks/justfile` lines 1–6 (mods), 11–14 (comment), 19 (`up-all` loop), 32–41 (`down-all`), 43–49 (`ps-all`), 51–57 (`pull-all`).

**Implementation:**
- Add `mod cxagents` (alphabetical: after `mod connectome`).
- `up-all` loop: `adguard freshrss homebridge onecli cxagents connectome wallabag`; comment: "onecli precedes connectome (connectome joins onecli's network); cxagents precedes connectome (connectome's shell joins the cxagents network when it exists)."
- `down-all`: `just connectome down`, then `just cxagents down`, then `just onecli down`, … (comment: "connectome before cxagents and onecli: both own a network connectome joins").
- `ps-all`, `pull-all`: add `just cxagents ps` / `just cxagents pull` after connectome.
- `backup-all`: unchanged (cxagents state is disposable).

**Step 1:** Edit. **Step 2: Verify:** `just -f "$wt/justfile" stacks --list` lists `cxagents`; `grep -n cxagents "$wt/stacks/justfile"`.

**Step 3: Commit**
```bash
git add stacks/justfile
git commit -m "stacks: cxagents in up-all (before connectome), down-all (after connectome), ps-all, pull-all"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: First login and bring-up (live)

**Verifies:** cxagents-node.AC5.4, AC5.7.

**Files:** none (system state).

**Step 1: Preconditions**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J stacks cxagents build && $J stacks cxagents image-test && $J stacks cxagents lint
cd tailscale/scripts && ./api.sh --client admin GET /tailnet/cxreiff.github/devices | jq -r '.devices[] | .hostname' | grep -x cxagents; echo "cxagents devices rc=$?"
```
Expected: build, image-test, lint pass; `rc=1` (no cxagents device yet). If a cxagents device exists, STOP and ask the user.

**Step 2: AC5.7 before login**
```bash
$J stacks cxagents up; echo "rc=$?"
docker --context colima-agents ps -a --filter name=cxagents-forwarder --format '{{.Names}}'
```
Expected: `cxagents: no node in state — run \`dotfiles stacks cxagents login\``, `rc=1`, no container listed.

**Step 3: Login (live write: registers a tailnet device — tell the user first)**
```bash
$J stacks cxagents login
$J stacks cxagents ps
```
Expected: login prints the node summary (`node: cxagents (cxagents.faun-fir.ts.net.)`, `tags: tag:cxagents`, cert expiry ~90 days), then `state: node <ID>`; the container is `healthy`.

**Step 4: AC5.4 assertions**
```bash
cd "$wt/tailscale/scripts"
./api.sh --client admin GET /tailnet/cxreiff.github/devices | jq -c '.devices[] | select(.hostname=="cxagents") | {name, nodeId, tags, keyExpiryDisabled}'
docker --context colima-agents inspect cxagents-forwarder | grep -c 'tskey-'; echo "(expect 0)"
grep -rl --exclude='.env*' 'tskey-' "$wt/stacks/cxagents" ; echo "(expect no files)"
docker --context colima-agents exec cxagents-forwarder /tailnet-forwarder check; echo "rc=$?"
docker --context colima-agents run --rm --network none -v cxagents_state:/state tailnet-forwarder:local check --state-only
```
Expected: exactly one device, `name` `cxagents.faun-fir.ts.net`, `tags ["tag:cxagents"]`, `keyExpiryDisabled true`; `0`; no files; `check` rc=0 with no `problem:` lines; `state: node <ID>` whose ID equals the device's `nodeId` (confirms Phase 4's state parsing; if they differ, STOP).

**Commit:** none (no repo change).
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: `login-test.sh` — the state/device matrix

**Verifies:** cxagents-node.AC5.5, AC5.7.

**Files:**
- Create: `stacks/cxagents/scripts/login-test.sh` (755).

**Implementation:** sources `lib/stack.sh` and `stacks/scripts/lib/check.sh`; temp dir and throwaway volumes `cxagents_logintest_empty`, `cxagents_logintest_copy` removed by an EXIT trap; a fake authkey command `"$tmp/fake-authkey"` that `touch`es `"$tmp/minted"` and prints nothing. For each case, `rm -f "$tmp/minted"` first. Cases (each `pass "cxagents-node.AC5.5 <case>"` / `fail …`):
1. **image missing** — `CXAGENTS_IMAGE=tailnet-forwarder:missing CXAGENTS_AUTHKEY_CMD="$tmp/fake-authkey" login.sh` → rc 1, stderr contains `run \`dotfiles stacks cxagents build\``, `$tmp/minted` absent.
2. **state valid + device present** — real volume, real API, `CXAGENTS_AUTHKEY_CMD=fake` → rc 0, `already logged in as cxagents`, not minted.
2b. **state owns a renamed device** — copy volume (as in case 4) + `CXAGENTS_DEVICES_JSON` = the real device list with that device's `name` changed to `cxagents-1.<suffix>` → rc 1, `not exactly cxagents`, not minted.
3. **state empty + device present** — `CXAGENTS_STATE_VOLUME=cxagents_logintest_empty` → rc 1, stderr contains `https://login.tailscale.com/admin/machines/` and `delete it`, not minted.
4. **state present + device missing, declined** — copy real state: `D run --rm -v cxagents_state:/from:ro -v cxagents_logintest_copy:/to alpine cp -a /from/. /to/`; `CXAGENTS_DEVICES_JSON` = file `{"devices":[]}`; stdin `n` → rc 1, `aborted; state kept`, the copy still reports `state: node <ID>`, not minted.
5. **state present + device missing, confirmed** — same, stdin `y`, `CXAGENTS_LOGIN_DRY_RUN=1` → rc 0, `dry run`, the copy volume now reports `state: empty`, not minted, and the real `cxagents-forwarder` is still running (the wipe only touched containers using the copy volume — none).
6. **AC5.7** — `CXAGENTS_STATE_VOLUME=cxagents_logintest_empty up.sh` → rc 1 with `run \`dotfiles stacks cxagents login\``; `docker ps` shows no new container.

The copied state contains the node's keys; it is never run (only `check --state-only` reads it) and the trap removes the volume. Say so in the script header.

**Step 1:** Create the script. **Step 2: Verify:** `$J stacks cxagents login-test` → seven `[OK]` (cases 1, 2, 2b, 3, 4, 5, 6), exit 0.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/login-test.sh
git commit -m "stacks/cxagents: login-test (state/device matrix, up refuses empty state)"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: `smoke.sh` (Phase 5 checks) and identity across restarts

**Verifies:** cxagents-node.AC5.3, AC5.6, AC8.1.

**Files:**
- Create: `stacks/cxagents/scripts/smoke.sh` (755).

**Step 1: Probe the netmap shape (read-only, on cxmini)**
```bash
/opt/homebrew/bin/tailscale debug netmap 2>/dev/null | jq 'keys' | head -40
/opt/homebrew/bin/tailscale debug netmap 2>/dev/null | jq '.PacketFilter[0]' 2>/dev/null | head -20
```
Expected: a `PacketFilter` (or similarly named) array whose entries list source prefixes (e.g. `Srcs`). Use the field names shown; if no packet-filter field appears, STOP and ask the user.

**Implementation — `smoke.sh`** (model `stacks/connectome/scripts/smoke.sh`: `set -euo pipefail`, `check.sh`, `running()` guard, `check_acN_M` functions, run list):
- `check_ac5_3` — cxagents IPs from `tailscale status --json | jq -r '.Peer[] | select(.HostName=="cxagents") | .TailscaleIPs[]'` (must be non-empty, else FAIL "cxagents not a peer"); from `tailscale debug netmap`, collect every source prefix of every packet-filter rule; FAIL if any prefix is `*`, `0.0.0.0/0`, `::/0`, or contains a cxagents IP (`100.x.y.z/32` exact or a covering CIDR — compare with a small awk/`ipcalc`-free check: only `/32`, `/128` and the universal prefixes occur in practice; treat any other prefix length as a FAIL to inspect by hand).
- `check_ac8_1` — `nc` from inside the forwarder's netns via `D run --rm --network container:cxagents-forwarder alpine:3.20 sh -c '…'`: positive control `nc -z -w2 <forwarder-ip> 8080` succeeds; for every IPv4 of container `connectome` (all its networks, from `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}'`) `nc -z -w2 <ip> 18768` fails; for every IPv4 of `onecli-gateway`, `nc -z -w2 <ip> 10255` fails; the `cxagents` network's gateway (the VM host side, `D network inspect cxagents -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}'`) on 18768 and 10255 fails; `getent hosts connectome` / `onecli-gateway` return nothing.
- `check_ac5_6_restart` — node ID (`check --state-only`) and `check` name before; `$J stacks cxagents restart`; wait healthy (poll `docker inspect -f '{{.State.Health.Status}}'` ≤ 180 s); same ID, `check` rc 0.
- `check_ac5_6_downup` — same around `just cxagents down && just cxagents up` (in Phase 5 nothing else is on the network, so `down` succeeds; from Phase 6 on, the smoke stops connectome first and restores it with a cleanup — Phase 6 updates this check).
- Run list: `check_ac5_3 check_ac8_1 check_ac5_6_restart check_ac5_6_downup`, then the exit line.

**Step 2:** Create the script; run `$J stacks cxagents smoke` → all `[OK]`.

**Step 3: AC5.6 across an agents VM restart — operator-gated.** This stops onecli and connectome (the live agent) for a few minutes; ask the user first. Then:
```bash
id0=$(docker --context colima-agents run --rm --network none -v cxagents_state:/state tailnet-forwarder:local check --state-only)
just -f "$main/justfile" stacks vm-agents-down && just -f "$main/justfile" stacks vm-agents-up
just -f "$main/justfile" stacks onecli up
$J stacks cxagents up
just -f "$main/justfile" stacks connectome up
id1=$(docker --context colima-agents run --rm --network none -v cxagents_state:/state tailnet-forwarder:local check --state-only)
[ "$id0" = "$id1" ] && echo "OK: same node after VM restart"
docker --context colima-agents exec cxagents-forwarder /tailnet-forwarder check
```
Expected: `OK: same node after VM restart`; `check` shows `cxagents`, `tag:cxagents`, online, no problems. (onecli/connectome are brought back from `main`, the live configuration.)

**Step 4: Commit**
```bash
git add stacks/cxagents/scripts/smoke.sh
git commit -m "stacks/cxagents: smoke (packet filter, netns isolation, identity across restart/down-up)"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: `stacks/cxagents/README.md` (operational core)

**Verifies:** None (documentation; Phase 7 adds the accepted exposures and password-manager step).

**Files:**
- Create: `stacks/cxagents/README.md`.

**Content** (match `stacks/onecli/README.md`'s structure): `# cxagents stack` (what it is: one locked-down tailnet node, `https://cxagents.faun-fir.ts.net:<port>` → target container port); `## Fresh-device setup` (`tailscale/.env` restored with both clients → `dotfiles stacks cxagents build` → `image-test` → `login` → `up`; delete a stale `cxagents` device when `login` prints its URL); `## Recipes` (every recipe in the justfile, one line each); `## Routes` (format, master for deny ports, how to add a target: split a range, update the policy grant, `lint`); `## Login and identity` (state matrix, key on stdin only, `cxagents_state` disposable/not backed up, cert re-issued only after state loss — Let's Encrypt rate limits); `## Hardening` (the AC8.2 list and that lint enforces it); `## Dial behaviour` (the Phase 4 decision: closed port = connect then close; policy-blocked ports time out instead). Every recipe named must exist (`just -f stacks/cxagents/justfile --list`). Describe the "no auth key in the environment" property in words — do not spell credential env names (Phase 1 conventions).

**Step 1:** Write; then `"$wt/tailscale/scripts/keyscan.sh" --repo` must exit 0. **Step 2: Commit**
```bash
git add stacks/cxagents/README.md
git commit -m "stacks/cxagents: README (setup, recipes, routes, login, hardening)"
```
<!-- END_TASK_9 -->

---

**Phase 5 done when:** `login` registered exactly `cxagents`, tagged `tag:cxagents`, key expiry disabled, with no auth key in any compose file, `.env` or `docker inspect`; `login-test` passes every matrix case; `up` on empty state refuses; identity survives `restart`, `down`/`up` and (operator-approved) an agents VM restart; the node is absent from every packet-filter source list on cxmini; the forwarder cannot reach `connectome:18768` or the onecli gateway; `cxagents lint` and `lint-test` pass; `$wt/stacks/scripts/doctor.sh` shows no new FAIL.
