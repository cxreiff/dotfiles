# cxagents Node Implementation Plan — Phase 3 of 7: cxagents policy and auth-key minting

**Goal:** The tailnet knows `tag:cxagents`, grants members its allowed ports, gives it no outbound access, and single-use auth keys for it can be minted on demand with a least-privilege OAuth client.

**Architecture:** Policy changes go through `policy-push` (Phase 1) and are guarded by new policy `tests`. A second OAuth client `dotfiles-authkeys` (scope `auth_keys`, tag `tag:cxagents`) is created by the operator after the push; `tailscale/scripts/authkey.sh` mints one key per call through `api.sh --client authkeys`. Doctor's client check gains the tags comparison.

**Tech Stack:** bash, curl, jq, Tailscale API v2.

**Scope:** Phase 3 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`.

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file".

**State expected at start (from Phases 1–2):** `tailscale/policy.hujson` has `hosts.cxmini`, the member→member grant, Taildrive grant, SSH rules, `nodeAttrs`, member→cxmini `tests`; `tailscale/clients.conf` has only the `admin` row; `tailscale/.env.example` has only the admin keys; `api.sh` supports `--client authkeys` and `--tags`; `tailscale/scripts/doctor.sh` compares scopes but not tags.

**API facts used here, not yet live-probed** (Task 3 probes them before code depends on them): `POST /tailnet/{t}/keys` body `{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":[…]}}},"expirySeconds":600,"description":"…"}` returning `{id, key, created, expires, capabilities}`; `GET`/`DELETE /tailnet/{t}/keys/{id}`; whether the token-exchange response or any endpoint reachable with `auth_keys` reveals an OAuth client's tags. Tailscale requires an `auth_keys` OAuth client to carry tags and requires the same tags in the key-creation call (KB 1215, KB 1623).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC1: Tailnet policy is code (Phase 1, tests extended in Phase 3)
- **cxagents-node.AC1.7 Success:** `policy.hujson` carries policy `tests` asserting members reach cxmini on tcp:22 and tcp:53/udp:53 and the serve ports; members are denied `tag:cxagents` tcp:3100 and tcp:80; `tag:cxagents` reaches nothing on cxmini. A push that would break any of these is rejected by validate. *(Phase 3 completes it.)*

### cxagents-node.AC2: Credentials are shared, declared and least-privilege (Phases 1, 3)
- **cxagents-node.AC2.4 Failure:** the authkeys client is refused on `/tailnet/-/acl` writes and `/tailnet/-/dns/nameservers` writes.
- **cxagents-node.AC2.6 Failure:** doctor FAILs when a client's granted scopes (the `scope` field of its token exchange) or tags differ from `tailscale/clients.conf`, including extra scopes. *(Phase 3 completes it: tags.)*

### cxagents-node.AC5: The node is tagged, locked down and logged in without a stored key (Phases 3, 5)
- **cxagents-node.AC5.1 Success:** after the Phase 3 push, the user's devices still reach each other on all ports (existing cxmini serve URLs load from cxmacbook/cxphone; Taildrive and SSH unchanged).
- **cxagents-node.AC5.2 Success:** `dotfiles tailscale authkey tag:cxagents` prints one single-use, pre-authorized, non-ephemeral key expiring in ≤10 minutes.

---

<!-- START_TASK_1 -->
### Task 1: Policy — `tag:cxagents` owner, member grant, cxagents tests; push

**Verifies:** cxagents-node.AC1.7, AC5.1 (policy side).

**Files:**
- Modify: `tailscale/policy.hujson`.

**Implementation** (HuJSON style of the file; comments explain each rule):
1. `"tagOwners": { "tag:cxagents": ["autogroup:admin"] },` — comment: `// The agent-preview node (stacks/cxagents). Only admins may assign it.`
2. Add a grant after the member→member grant:
```hujson
		// Members reach agent servers on cxagents (stacks/cxagents/routes is the
		// master: these ranges are its range minus its deny ports; the cxagents
		// lint cross-checks them). Nothing grants tag:cxagents as a source.
		{
			"src": ["autogroup:member"],
			"dst": ["tag:cxagents"],
			"ip":  ["tcp:1024-3099", "tcp:3101-65535"],
		},
```
3. Append to `tests`:
```hujson
		{
			"src":    "cxreiff@github",
			"proto":  "tcp",
			"accept": ["tag:cxagents:5173"],
			"deny":   ["tag:cxagents:3100", "tag:cxagents:80"],
		},
		{
			// tag:cxagents reaches nothing on cxmini.
			"src":  "tag:cxagents",
			"deny": ["cxmini:22", "cxmini:53", "cxmini:8768"],
		},
```

**Step 1:** Make the edits; `$J tailscale lint` (expect four `[OK]`; invariant 2 now sees `tag:cxagents` declared).

**Step 2: Validate before pushing (read-only)**
```bash
cd "$wt/tailscale/scripts"
./api.sh POST /tailnet/cxreiff.github/acl/validate -H 'Content-Type: application/hujson' --data-binary @../policy.hujson; echo "rc=$?"
```
Expected: `rc=0` with an empty `message` (`{}` or empty body). If validate rejects the `tests` syntax (e.g. `tag:cxagents` not allowed as a test `src`, or a `tag:…:port` destination with no tagged device), STOP and report the exact message to the user — do not weaken or drop a test to get it through.

**Step 3: Prove validate rejects a lockout (AC1.7 "push that would break any of these is rejected")** — on a temp copy (never the repo file): remove the cxagents grant → validate must fail on the `tag:cxagents:5173` accept; change the grant `ip` to `["tcp:1024-65535"]` → validate must fail on the `tag:cxagents:3100` deny. Use the same `api.sh POST …/acl/validate` call on the temp files; each must return a failure (non-2xx or non-empty `.message`). These become permanent `smoke.sh` checks in Task 5.

**Step 4: Push (live write — show the user the diff and get approval before answering `y`)**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J tailscale policy-push      # answer y only after user approval
$J tailscale policy-status    # in-sync
```

**Step 5: Connectivity unchanged (AC5.1) — operator check.** Ask the user to confirm from cxmacbook and cxphone: `https://cxmini.faun-fir.ts.net:8765` (FreshRSS) and `:8768` (connectome WebUI) load; SSH to cxmini works; Taildrive shares still mount. Executor, on cxmini:
```bash
/opt/homebrew/bin/tailscale ping -c 1 cxmacbook; /opt/homebrew/bin/tailscale ping -c 1 cxcachy
```
Expected: pongs (or the device is offline — then it isn't a regression; note it).

**Step 6: Commit**
```bash
git add tailscale/policy.hujson
git commit -m "tailscale: tag:cxagents (admin-owned), member grant on its ports, lockout tests"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Operator creates `dotfiles-authkeys`; declarations updated

**Verifies:** None (operator step + declarations).

**Files:**
- Modify: `tailscale/.env.example` — append:
```
# dotfiles-authkeys: scope auth_keys, tag tag:cxagents (create after the policy
# declaring tag:cxagents is pushed). Used only by `dotfiles tailscale authkey`.
TS_AUTHKEYS_CLIENT_ID=CHANGE_ME
TS_AUTHKEYS_CLIENT_SECRET=CHANGE_ME
```
- Modify: `tailscale/clients.conf` — append the row (align columns with the admin row):
```
authkeys     auth_keys                                                                           tag:cxagents
```

**Step 1: Operator (secrets are typed by the user, never seen by the executor):**
1. https://login.tailscale.com/admin/settings/oauth → Generate OAuth client, description `dotfiles-authkeys`, scope **Auth Keys (write)** only, tag `tag:cxagents`.
2. Add `TS_AUTHKEYS_CLIENT_ID=…` and `TS_AUTHKEYS_CLIENT_SECRET=…` to `/Users/cxreiff/Developer/dotfiles/tailscale/.env` (keep mode 0600) and to the escrow copy.

**Step 2: Executor verifies (key names and mode only)**
```bash
f=/Users/cxreiff/Developer/dotfiles/tailscale/.env
sed 's/=.*//' "$f"; stat -f %Lp "$f"
cd "$wt/tailscale/scripts" && ./api.sh --client authkeys --granted-scopes
```
Expected: four key names (`TS_ADMIN_CLIENT_ID`, `TS_ADMIN_CLIENT_SECRET`, `TS_AUTHKEYS_CLIENT_ID`, `TS_AUTHKEYS_CLIENT_SECRET`); `600`; a scope string. If the granted scopes are not exactly `auth_keys` (plus any implicit scope Tailscale adds, e.g. `logs:configuration:read`), update the `authkeys` row in `clients.conf` to the exact granted set **only after** confirming with the user that the extra scope is implicit and not a creation mistake.

**Step 3: Commit**
```bash
git add tailscale/.env.example tailscale/clients.conf
git commit -m "tailscale: declare dotfiles-authkeys client (auth_keys, tag:cxagents)"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Probe key minting and client-tag visibility; doctor tags check

**Verifies:** cxagents-node.AC2.6 (tags).

**Files:**
- Modify: `tailscale/scripts/doctor.sh` — client check (Phase 2 Task 4, check 3).
- Modify: `tailscale/scripts/doctor-test.sh` — add the `tags-mismatch` case.

**Step 1: Probe (live; each key created here is deleted immediately)**
```bash
cd "$wt/tailscale/scripts"
# (a) does the exchange response carry tags?  (prints the response minus the token)
./api.sh --client authkeys --tags tag:cxagents --granted-scopes; echo "rc=$?"
# (b) is the tag set enforced at exchange?
./api.sh --client authkeys --tags tag:not-owned-by-client --granted-scopes; echo "rc=$?"
# (c) key create / get / delete shape (the key value is never printed)
body='{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:cxagents"]}}},"expirySeconds":600,"description":"dotfiles probe"}'
resp=$(./api.sh --client authkeys --tags tag:cxagents POST /tailnet/cxreiff.github/keys -H 'Content-Type: application/json' -d "$body"); echo "rc=$?"
id=$(jq -r .id <<<"$resp"); jq 'del(.key)' <<<"$resp"
./api.sh --client authkeys --tags tag:cxagents GET "/tailnet/cxreiff.github/keys/${id}" | jq 'del(.key)'
./api.sh --client authkeys --tags tag:cxagents DELETE "/tailnet/cxreiff.github/keys/${id}"; echo "delete rc=$?"
unset resp
```
To see whether the exchange response has a `tags` field, make an uncommitted probe copy outside the repo: `cp tailscale/scripts/api.sh "$SCRATCH/api-probe.sh"` (`$SCRATCH` = the session scratchpad directory), change its `--granted-scopes` line from `jq -r '.scope // empty'` to `jq 'del(.access_token)'`, and run it as `TAILSCALE_ENV_FILE=/Users/cxreiff/Developer/dotfiles/tailscale/.env "$SCRATCH/api-probe.sh" --client authkeys --tags tag:cxagents --granted-scopes` (the env override is needed because the copy's `SCRIPT_DIR/../.env` does not exist). Delete the copy afterwards.

Record in the commit message: whether (a) the exchange response lists tags, (b) a non-owned tag is refused at exchange, (c) the key create/get/delete field names (`id`, `expires`, `capabilities.devices.create.{reusable,ephemeral,preauthorized,tags}`).

Decision rule (no improvising):
- If the exchange response includes the client's tags → doctor compares them exactly with `clients.conf` (`tags` column, space-separated, `-` = none).
- Else, if (b) shows tags are enforced → doctor checks that an exchange requesting exactly the declared tags succeeds **and** an exchange requesting `tag:doctor-undeclared-probe` fails (a client allowed undeclared tags is a FAIL). Before implementing this branch, **tell the user** that extra tags on the client cannot be observed through the API with these scopes, and get agreement that this check satisfies AC2.6 for them.
- Else (tags neither visible nor enforced) → STOP and ask the user.
- If (c) fails or field names differ from the body above → STOP and report.

**Step 2: Implement the tags check** in `tailscale/scripts/doctor.sh` check 3 per the decision; message on mismatch: `fail "tailnet: client ${name} tags differ from clients.conf (declared: ${tags})"`; on match `pass "tailnet: client ${name} tags match clients.conf"`. Rows whose tags column is `-` skip the tag check.

**Step 3: doctor-test case** `tags-mismatch` — `TAILSCALE_CLIENTS_CONF` fixture where the authkeys row declares `tag:other` → `[FAIL] tailnet: client authkeys tags differ`.

**Step 4: Verify**
```bash
cd "$wt"; J="just -f $wt/justfile"
tailscale/scripts/doctor.sh | grep 'client '
$J tailscale doctor-test
```
Expected: `[OK]` scope and tags lines for both clients; all doctor fixtures pass.

**Step 5: Commit**
```bash
git add tailscale/scripts/doctor.sh tailscale/scripts/doctor-test.sh
git commit -m "tailscale: doctor checks OAuth client tags against clients.conf"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: `authkey.sh` and the `authkey <tag>` recipe

**Verifies:** cxagents-node.AC5.2.

**Files:**
- Create: `tailscale/scripts/authkey.sh` (755).
- Modify: `tailscale/justfile` — add:
```just
# Print one single-use, pre-authorized, non-ephemeral auth key for TAG (expires in 10 min)
authkey tag:
    @./scripts/authkey.sh {{tag}}
```

**Implementation:**
```bash
#!/usr/bin/env bash
# tailscale/scripts/authkey.sh TAG — mint one auth key for TAG and print it
# (stdout, nothing else). Single-use, pre-authorized, non-ephemeral, 10-minute
# expiry. Meant to be piped straight into the consumer (e.g. cxagents login);
# never store it. Exit: as api.sh (2 credentials, 3 API); 2 on a bad TAG.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/conf.sh
source "${SCRIPT_DIR}/lib/conf.sh"
tag="${1:-}"
[[ "$tag" =~ ^tag:[a-z0-9-]+$ ]] || { echo "usage: authkey.sh tag:<name>" >&2; exit 2; }
body="$(jq -nc --arg t "$tag" '{capabilities:{devices:{create:{reusable:false,ephemeral:false,preauthorized:true,tags:[$t]}}},expirySeconds:600,description:("dotfiles authkey " + $t)}')"
resp="$("${SCRIPT_DIR}/api.sh" --client authkeys --tags "$tag" POST "/tailnet/${TAILNET}/keys" \
    -H 'Content-Type: application/json' -d "$body")" || exit $?
key="$(jq -r '.key // empty' <<<"$resp")"
[ -n "$key" ] || { echo "authkey: API returned no key" >&2; exit 3; }
printf '%s\n' "$key"
```
(Adjust only the JSON field names if Task 3's probe showed different ones.)

**Step 1:** Create the script and recipe.

**Step 2: Verify without printing the key**
```bash
cd "$wt/tailscale/scripts"
k=$(./authkey.sh tag:cxagents); echo "rc=$? prefix=$(printf '%s' "$k" | cut -d- -f1-2)"   # prints only "tskey-auth", never the key
id=$(printf '%s' "$k" | cut -d- -f3); unset k
./api.sh --client authkeys --tags tag:cxagents GET "/tailnet/cxreiff.github/keys/${id}" \
  | jq '{reusable: .capabilities.devices.create.reusable, ephemeral: .capabilities.devices.create.ephemeral, preauthorized: .capabilities.devices.create.preauthorized, tags: .capabilities.devices.create.tags, created, expires}'
./api.sh --client authkeys --tags tag:cxagents DELETE "/tailnet/cxreiff.github/keys/${id}"; echo "deleted rc=$?"
./authkey.sh notatag; echo "rc=$?"
```
Expected: `rc=0`, prefix `tskey-auth`; `reusable:false, ephemeral:false, preauthorized:true, tags:["tag:cxagents"]`, `expires − created ≤ 600 s`; `deleted rc=0`; `rc=2` for the bad tag. (If the id is not the third `-` field of the key, take it from the create response instead: change the smoke in Task 5 accordingly.)

**Step 3: Commit**
```bash
git add tailscale/scripts/authkey.sh tailscale/justfile
git commit -m "tailscale: authkey <tag> (single-use, pre-authorized, 10 min)"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Extend `tailscale/scripts/smoke.sh`

**Verifies:** cxagents-node.AC1.7, AC2.4, AC5.2.

**Files:**
- Modify: `tailscale/scripts/smoke.sh` — add checks to the run list.

**Checks:**
- `check_ac1_7_cxagents` — on temp copies of `policy.hujson` (JSON from `hujson2json.pl` + jq): (a) cxagents grant removed, (b) grant `ip` widened to `["tcp:1024-65535"]`, (c) a new grant `{"src":["tag:cxagents"],"dst":["autogroup:member"],"ip":["*"]}` added with `tagOwners` intact (lint invariant 1 catches it first — assert `lint failed; not pushing` from `policy.sh --file … push` in a temp git repo). For (a) and (b) call `api.sh POST …/acl/validate` and assert failure (non-2xx or non-empty `.message`). Live ETag unchanged afterwards.
- `check_ac2_4` — `api.sh --client authkeys --tags tag:cxagents POST /tailnet/$TAILNET/acl -H 'Content-Type: application/hujson' -H "If-Match: \"$(printf '%064d' 0)\"" --data-binary @tailscale/policy.hujson` must exit 3 with `HTTP 403` in stderr (a `412` would mean the scope was accepted: FAIL; the all-zero If-Match guarantees nothing is written either way). Then `api.sh --client authkeys --tags tag:cxagents POST /tailnet/$TAILNET/dns/nameservers -H 'Content-Type: application/json' -d "{\"dns\":$(api.sh --client admin GET /tailnet/$TAILNET/dns/nameservers | jq -c .dns)}"` must exit 3 with `HTTP 403` (the body re-sends the current list, so even a wrongly accepted call changes nothing).
- `check_ac5_2` — mint with `authkey.sh tag:cxagents` into a variable (never printed), GET the key by id, assert `reusable==false`, `ephemeral==false`, `preauthorized==true`, `tags==["tag:cxagents"]`, `expires−created ≤ 600 s` (parse RFC3339 with `date -j -f '%Y-%m-%dT%H:%M:%SZ'`; strip fractional seconds first), then DELETE it (register the DELETE with the cleanup trap first, so a failed assertion still deletes the key).

**Step 1:** Add the checks.

**Step 2: Verify**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J tailscale smoke && $J tailscale lint-test
```
Expected: all `[OK]`, exit 0; fixtures pass.

**Step 3: Commit**
```bash
git add tailscale/scripts/smoke.sh
git commit -m "tailscale: smoke covers cxagents lockout tests, authkeys least privilege, authkey shape"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: README — authkeys client

**Verifies:** None (documentation).

**Files:**
- Modify: `tailscale/README.md` `## Clients` and recipe list.

**Content:** add the `authkey <tag>` recipe; in Clients, the authkeys client: created **after** the policy that declares `tag:cxagents` is pushed (Tailscale only lets a client carry tags that exist in `tagOwners`), scope Auth Keys (write) only, tag `tag:cxagents`; what doctor checks (exact scopes; tags per Task 3's decision, with the limitation stated if the enforcement-based check was chosen); that keys are minted per use, piped, never stored, expire in 10 minutes and are single-use.

**Step 1:** Edit. **Step 2:** `$J tailscale --list` shows every recipe the README names.

**Step 3: Commit**
```bash
git add tailscale/README.md
git commit -m "tailscale: README authkeys client and authkey recipe"
```
<!-- END_TASK_6 -->

---

**Phase 3 done when:** the pushed policy is `in-sync` and carries the cxagents grant and tests; member-to-member connectivity is unchanged (operator-confirmed); `authkey tag:cxagents` returns a single-use, pre-authorized, non-ephemeral key expiring within 10 minutes (deleted by the smoke); the authkeys client gets 403 on policy and DNS writes; doctor's `--- Tailnet ---` checks both clients' scopes and tags; `tailscale lint`, `lint-test`, `doctor-test`, `smoke` pass.
