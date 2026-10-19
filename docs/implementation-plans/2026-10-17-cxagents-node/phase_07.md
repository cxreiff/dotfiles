# cxagents Node Implementation Plan — Phase 7 of 7: doctor, docs, recovery

**Goal:** The new pieces are observable in `doctor`, every doc matches the recipes, and rebuilding a lost machine is one documented sequence.

**Architecture:** The cxagents doctor checks live in `stacks/cxagents/scripts/doctor.sh` (same pattern as `tailscale/scripts/doctor.sh`: `[OK]/[FAIL]/[WARN]/[OFF]` lines that `stacks/scripts/doctor.sh` re-emits under `--- cxagents ---`), with a fixture runner proving each FAIL. Documentation updates are operational: CLAUDE.md, `stacks/README.md`, `stacks/connectome/README.md`, `stacks/cxagents/README.md`, `tailscale/README.md`, `docs/migration-recovery.md`.

**Tech Stack:** bash, Docker on `colima-agents`, Markdown.

**Scope:** Phase 7 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`. Depends on Phase 6.

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file".

**State found at verification (before this plan):**
- `stacks/scripts/doctor.sh`: `--- Agents (onecli + connectome) ---` at line 280 (wrapped in `if ! $A info …; then off …`, `A="docker --context colima-agents"`), connectome lint re-emitted at 358–365, `--- Stack identity & env ---` at 368. Phases 1–2 changed line 404 (`stat -L`) and added `--- Tailnet ---` before `--- DNS failover ---`, so line numbers below are approximate: anchor on the header strings.
- `CLAUDE.md` (dated 2026-10-16): `## Repo shape` says "Three independent areas" and lists `archive/`, `stow/`, `stacks/` (+ `stacks/scripts/`, `docs/`); the `dotfiles` alias text says `just -f ~/Developer/dotfiles/justfile` while the real alias is `just -f $CX_WORKSPACE/dotfiles/justfile` (`stow/base/.config/zsh/zshrc/aliases.zsh:21`); `## Reproducible vs runtime` table at ~35–45; `## Common commands` ~73–103; `## DNS failover state machine` ~106 (PAT text already replaced in Phase 2); `## Colima architecture` table (agents row "onecli, connectome"); `## Port and .env conventions` last bullet names what bakes in `tailscale ip -4` (dns-forward plist, tailnet Global NS).
- `docs/migration-recovery.md`: `## Prerequisites` (21), `## Clean-slate procedure` (38; steps `# 1.`–`# 12.`, onecli step 6 at 64, connectome step 7 at 70), `## On a fresh device` (108), `### onecli v2 and connectome on a fresh device` (116; clone/patch loop 122–143; connectome 162–182), `## When the bridged VM IP changes` (193).
- `stacks/README.md`: `## Architecture` (5), `## Stage 3` (70), `## Recipes` → `### Composite (across stacks)` (118).
- `stacks/connectome/README.md`: `## Sources and local patches` (70; Phase 6 added the WebUI patch), `## Architecture` (185), `## Security invariants` (268), `## Known exposures (accepted)` (291), `## Operations` (336).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC4: doctor covers the tailnet and the node (Phases 2, 7)
- **cxagents-node.AC4.4 Success:** `--- cxagents ---` reports, via `docker exec cxagents-forwarder /tailnet-forwarder check`, the node online as exactly `cxagents` with tags `[tag:cxagents]` and the cert valid >14 days.
- **cxagents-node.AC4.5 Failure:** forwarder stopped, empty state, node offline/untagged/renamed (e.g. `cxagents-1`), cert ≤14 days, or a `routes` target with no running container → `[FAIL]`.
- **cxagents-node.AC4.6:** doctor still reads only `.env` key names, never values (aside from the existing BRIDGE_USERNAME exception).

### cxagents-node.AC9: connectome is the first target (Phase 6)
- **cxagents-node.AC9.4 Success:** `up-all` brings up onecli, cxagents, connectome in that order; `down-all` stops connectome before cxagents.

### cxagents-node.AC10: Rebuild path is defined (Phase 7)
- **cxagents-node.AC10.1:** `docs/migration-recovery.md` covers, in order: restore `tailscale/.env` from escrow, `cxagents build`, delete stale `cxagents` (and `cxmini`) devices if `login`/`tailscale up` report them, `cxagents login`, then connectome; following it on a fresh device yields doctor with no FAILs.
- **cxagents-node.AC10.2:** `tailscale/README.md` documents both bootstrap paths (first adoption via `policy-pull`; new tailnet via `policy-push --init`), the client-creation order, the tailnet settings checklist, and PAT revocation.
- **cxagents-node.AC10.3:** CLAUDE.md reflects the four repo areas, the `tailscale/` module, OAuth in place of the PAT rotation section, the new reproducible-vs-runtime rows, and adds the `policy.hujson` cxmini host entry to the list of artifacts to update after a node-IP change.
- **cxagents-node.AC10.4:** the operator step to set exact-host matching on saved `*.faun-fir.ts.net` logins in the password manager is documented, and the residual same-site exposure is listed in `stacks/cxagents/README.md`.

---

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->
<!-- START_TASK_1 -->
### Task 1: `stacks/cxagents/scripts/doctor.sh`

**Verifies:** cxagents-node.AC4.4, AC4.5, AC4.6.

**Files:**
- Create: `stacks/cxagents/scripts/doctor.sh` (755).

**Implementation:** read-only; sources `stacks/scripts/lib/check.sh` and `lib/stack.sh`; every message prefixed `cxagents: `; reads no `.env` file at all. Seams for the fixture runner: `DOCTOR_CXAGENTS_CONTAINER` (default `cxagents-forwarder`), `DOCTOR_CXAGENTS_ROUTES` (default `stacks/cxagents/routes`), `CXAGENTS_STATE_VOLUME` (via `lib/stack.sh`), `DOCTOR_CXAGENTS_CHECK_CMD` (a command whose stdout/exit replace `docker exec <container> /tailnet-forwarder check`). Checks:
1. agents VM down (`D info` fails) → `off "cxagents: checks skipped (colima-agents not running)"` and exit 0.
2. image `tailnet-forwarder:local` present else `fail "cxagents: image missing (run: dotfiles stacks cxagents build)"`.
3. state: first `cx_volume_exists` — missing → `fail "cxagents: state volume ${cx_volume} missing (run: dotfiles stacks cxagents login)"` and skip `cx_state` (mounting a missing volume would create it; doctor is read-only). Otherwise `cx_state` → `state: node <ID>` → `pass "cxagents: state holds node <ID>"`; `state: empty` → `fail "cxagents: state empty (run: dotfiles stacks cxagents login)"`.
4. container: `D inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container"` — `running healthy` → pass; anything else (incl. missing/stopped/unhealthy) → `fail "cxagents: ${container} is <status> (run: dotfiles stacks cxagents up)"`, and skip check 5.
5. node: `out=$(${DOCTOR_CXAGENTS_CHECK_CMD:-D exec "$container" /tailnet-forwarder check} 2>&1); rc=$?`. rc 0 → `pass "cxagents: node <the node: line> tags <tags: line> cert <cert: line>"` (AC4.4); else one `fail "cxagents: <problem>"` per `problem:` line (renamed `cxagents-1`, untagged/extra tags, offline, `NeedsLogin`, cert ≤14 days — evaluated by the forwarder's `check`, unit-tested in Phase 4) or, with no `problem:` line, `fail "cxagents: check failed: <first line>"`.
6. routes targets: for each target in `$DOCTOR_CXAGENTS_ROUTES` (awk, skip comments): `D inspect -f '{{.State.Running}}' "$t"` is `true` → `pass "cxagents: routes target ${t} running"`, else `fail "cxagents: routes target ${t} not running"`; if running but not attached to network `cxagents` (`D network inspect cxagents -f '{{range .Containers}}{{.Name}} {{end}}'`) → `warn "cxagents: ${t} not attached to network cxagents (connectome up without the overlay?)"`.
7. lint: re-emit `stacks/cxagents/scripts/lint.sh` lines with the `case` pattern (prefix `cxagents: `).

**Step 1:** Create the script. **Step 2: Verify:** `cd "$wt" && stacks/cxagents/scripts/doctor.sh` → all `[OK]`, including the node line naming `cxagents`, `tag:cxagents` and a cert expiry > 14 days out.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/doctor.sh
git commit -m "stacks/cxagents: doctor checks (image, state, health, node identity/cert, routes targets, lint)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: `--- cxagents ---` in `stacks/scripts/doctor.sh`

**Verifies:** cxagents-node.AC4.4 (surfacing), AC4.6.

**Files:**
- Modify: `stacks/scripts/doctor.sh` — insert after the connectome lint loop (the `done < <("${SCRIPT_DIR}/../connectome/scripts/lint.sh" 2>&1)` line) and before `echo "--- Stack identity & env ---"`'s preceding `echo`.

**Implementation:**
```bash
echo
echo "--- cxagents ---"

# The cxagents tailnet node (stacks/cxagents): health, identity, cert, routes
# targets, lockdown lints. Reads no .env file.
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "cxagents: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../cxagents/scripts/doctor.sh" 2>&1)
```
Also update the header comment of `doctor.sh` if it lists sections (it does not today — line 3 says "Read-only diagnostic for the dotfiles stacks layer"; leave it).

**Step 1:** Edit. **Step 2: Verify (AC4.6)**
```bash
cd "$wt" && ./stacks/scripts/doctor.sh; echo "rc=$?"
grep -nE '\.env' stacks/cxagents/scripts/doctor.sh tailscale/scripts/doctor.sh | grep -vE 'sed .s/=\.\*//|grep -(q|o)E .\^|stat -L|check-ignore|\.env\.example|TAILSCALE_ENV_FILE|DOCTOR_ENV_FILES|#'
```
Expected: doctor ends `rc=0` with no `[FAIL]`; the grep prints nothing (every `.env` mention is a key-name, mode, ignore or override reference — inspect any line it does print and confirm it reads no value; the only value read in `stacks/scripts/doctor.sh` remains `BRIDGE_USERNAME`).

**Step 3: Commit**
```bash
git add stacks/scripts/doctor.sh
git commit -m "stacks/doctor: --- cxagents --- section"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: `stacks/cxagents/scripts/doctor-test.sh`

**Verifies:** cxagents-node.AC4.5.

**Files:**
- Create: `stacks/cxagents/scripts/doctor-test.sh` (755).
- Modify: `stacks/cxagents/justfile` — add:
```just
# Prove each doctor cxagents FAIL path with fixtures (never stops the real node)
doctor-test:
    @./scripts/doctor-test.sh
```

**Implementation** (fixture-runner style; temp dir + throwaway volume `cxagents_doctortest_empty`, trap-cleaned; each case runs `stacks/cxagents/scripts/doctor.sh` with seams and asserts a specific `[FAIL]`):
- `baseline` — no seams → no `[FAIL]`.
- `forwarder-stopped` — `DOCTOR_CXAGENTS_CONTAINER=cxagents-doctortest-missing` → `[FAIL] cxagents: cxagents-doctortest-missing is missing`. (Equivalent to a stopped/removed forwarder without touching the live one.)
- `missing-volume` — `CXAGENTS_STATE_VOLUME=cxagents_doctortest_absent` (never created) → `[FAIL] cxagents: state volume cxagents_doctortest_absent missing`, and afterwards `docker volume inspect cxagents_doctortest_absent` still fails (doctor created nothing).
- `empty-state` — `CXAGENTS_STATE_VOLUME=cxagents_doctortest_empty` (created by the test with `docker volume create` before the case) → `[FAIL] cxagents: state empty`.
- `renamed`, `untagged`, `offline`, `cert-expiring` — `DOCTOR_CXAGENTS_CHECK_CMD` = a fixture script printing the real `check` format with `problem: node is named cxagents-1, not cxagents …` (resp. the untagged, offline, `cert expires in 10 days` problems — copy the exact problem strings from `internal/check/check.go`) and exiting 1 → the matching `[FAIL] cxagents: …`.
- `target-not-running` — `DOCTOR_CXAGENTS_ROUTES` = fixture `no-such-container 1024-65535 3100` → `[FAIL] cxagents: routes target no-such-container not running`.

**Step 1:** Create; add the recipe. **Step 2: Verify:** `$J stacks cxagents doctor-test` → all `PASS doctor-fixture …`, `All fixtures passed`.

**Step 3: Operator-optional live confirmation of the "forwarder stopped" path:** with the user's go-ahead, `docker --context colima-agents stop cxagents-forwarder`, run `$wt/stacks/scripts/doctor.sh | grep cxagents` (expect `[FAIL] cxagents: cxagents-forwarder is exited …`), then `$J stacks cxagents up`. (Agent previews are unavailable for that minute.)

**Step 4: Commit**
```bash
git add stacks/cxagents/scripts/doctor-test.sh stacks/cxagents/justfile
git commit -m "stacks/cxagents: doctor-test (stopped, empty state, renamed/untagged/offline/cert, dead target)"
```
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_4 -->
### Task 4: Verify aggregate ordering

**Verifies:** cxagents-node.AC9.4.

**Files:** none.

**Step 1: Static (executor)**
```bash
cd "$wt"
just -f "$wt/justfile" --show stacks::up-all | grep -o 'for s in [a-z ]*'
just -f "$wt/justfile" --show stacks::down-all
```
Expected: `for s in adguard freshrss homebridge onecli cxagents connectome wallabag`; down-all lists `just connectome down` before `just cxagents down` before `just onecli down`. (If `--show stacks::up-all` is not accepted by just 1.50, use `just -f "$wt/stacks/justfile" --show up-all`.)

**Step 2: Operational (operator-gated; restarts every stack incl. DNS failover)** — offer the user a full `down-all` / `up-all` cycle from the worktree; only with their go-ahead:
```bash
J="just -f $wt/justfile"; $J stacks down-all && $J stacks up-all 2>&1 | grep '^=== '
```
Expected: `=== onecli up ===`, `=== cxagents up ===`, `=== connectome up ===` in that order, `up-all: all stacks up`. If the user declines, the static check stands and this is listed under human verification.

**Commit:** none.
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: CLAUDE.md

**Verifies:** cxagents-node.AC10.3.

**Files:**
- Modify: `CLAUDE.md`.

**Changes:**
1. Header date → `Last updated: <execution date>`.
2. `## Repo shape`: "Four independent areas" — `archive/`, `stow/`, `stacks/` (add `cxagents/` to the per-stack list), and new **`tailscale/`** — "the tailnet, declared: `policy.hujson` (source of truth, with policy tests), `tailnet.conf`, `clients.conf`, `.env` (OAuth client secrets, 0600, escrowed; only `scripts/api.sh` reads it). Tailnet-global: stacks read it, it never references a stack. Recipes: `dotfiles tailscale policy-pull|policy-diff|policy-push [--init]|policy-status|authkey <tag>|lint|lint-test|doctor-test|smoke`." Fix the alias line to `alias dotfiles="just -f $CX_WORKSPACE/dotfiles/justfile"` (`stow/base/.config/zsh/zshrc/aliases.zsh`; `CX_WORKSPACE` from `params.zsh`). Root justfile: `mod stacks` / `mod stow` / `mod tailscale`.
3. `## Reproducible vs runtime` — add rows:
   - `tailscale/policy.hujson` | live tailnet policy (doctor FAILs on drift: repo SHA-256 vs live ETag)
   - `tailscale/clients.conf`, `tailscale/tailnet.conf` | OAuth clients `dotfiles-admin`/`dotfiles-authkeys` and tailnet settings in the admin console (doctor checks scopes, tags, identity, MagicDNS, Tailnet Lock)
   - `tailscale/.env.example` | `tailscale/.env` (0600, escrowed)
   - `stacks/cxagents/{compose.yaml,routes,forwarder/,build.lock}` | image `tailnet-forwarder:local` and Docker named volume `cxagents_state` in the `agents` VM (node keys + cert cache; disposable, not backed up) and the `cxagents` tailnet device
4. `## Common commands` — add `dotfiles tailscale …` lines; `dotfiles stacks cxagents build|image-test|test|login|up|down|smoke|lint|lint-test|login-test|doctor-test`; update `up-all`/`down-all` comments to the new order ("onecli, cxagents before connectome"; "connectome before cxagents/onecli"); the doctor line lists 10 sections (… Agents, cxagents, Stack identity & env, plus Tailnet).
5. `## DNS failover state machine` — confirm Phase 2's OAuth text; nothing names `TAILSCALE_PAT`.
6. `## Colima architecture` — agents row: `onecli`, `connectome`, `cxagents` (tsnet node `cxagents-forwarder`); one paragraph: cxagents owns network `cxagents`, connectome's `shell` joins it through the optional `compose.cxagents.yaml` overlay (`stacks/connectome/scripts/compose.sh`); the node is `tag:cxagents`, receives only, publishes agent servers at `https://cxagents.faun-fir.ts.net:<port>` (see `stacks/cxagents/README.md`).
7. `## Port and .env conventions` last bullet — the list of things that bake in `tailscale ip -4` / cxmini's node IP becomes: the dns-forward plist, tailnet Global NS, **and `tailscale/policy.hujson`'s `hosts.cxmini` entry (edit, then `dotfiles tailscale policy-push`)**. Note the cxagents node needs nothing after an IP change (everything uses its MagicDNS name).
8. `## When editing` — add: "Tailnet changes go through `tailscale/policy.hujson` + `policy-push`, never the admin console (doctor flags console edits as drift)."
9. Grep: `tailscale/scripts/keyscan.sh --repo` still exits 0 (CLAUDE.md must not name credential key names).

**Step 1:** Edit. **Step 2: Verify** every recipe CLAUDE.md names exists: `just -f "$wt/justfile" --list --list-submodules` (or per module `--list`), and `keyscan.sh --repo` rc 0.

**Step 3: Commit**
```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md for the tailscale module, cxagents stack, OAuth credentials"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Stack READMEs (stacks, connectome, cxagents) and tailscale README completion

**Verifies:** cxagents-node.AC10.2, AC10.4.

**Files:**
- Modify: `stacks/README.md` — `## Architecture` (agents VM holds cxagents), `## Stage 3` (cxagents setup pointer: needs `tailscale/` set up with both clients), `### Composite (across stacks)` (new up-all/down-all order).
- Modify: `stacks/connectome/README.md` — `## Architecture`: the `cxagents` overlay (shell only; soft opt-in; `scripts/compose.sh`; warning when absent); `## Security invariants`: add a row "only `shell` joins `cxagents`" (checked by the overlay file content + `stacks cxagents smoke`); `## Known exposures (accepted)`: agent servers are reachable from the operator's devices on every allowed port; the WebUI is same-site with agent pages and is protected by the cross-site guard patch.
- Modify: `stacks/cxagents/README.md` — add `## Accepted exposures` (from the design's "Accepted exposures", each as one bullet: same-site with cxmini services — residual: while logged in to AdGuard/FreshRSS/Wallabag/Homebridge, an agent page could send forged same-site requests and set `Domain=faun-fir.ts.net` cookies; mitigated by the WebUI guard and password-manager host matching; every allowed port reachable; agents in different targets reach each other; status endpoint unauthenticated on the bridge; `http://` works; the lockdown limits the node, not the agent's own egress; the hostname is in CT logs) and `## Operator step: password manager` ("set **exact host** URI matching on every saved `*.faun-fir.ts.net` login (FreshRSS, Wallabag, Homebridge, AdGuard, connectome WebUI) so the password manager never offers them on `cxagents.faun-fir.ts.net`; it is a per-login setting that syncs with the vault"); `## Doctor` (what `--- cxagents ---` checks, `doctor-test`).
- Modify: `tailscale/README.md` — confirm it has both bootstrap paths, client-creation order (admin → push policy declaring `tag:cxagents` → authkeys), the numbered settings checklist with which doctor checks cover each item (MagicDNS/suffix/name: `tailscale status --json`; Tailnet Lock: `tailscale lock status`; HTTPS certificates: the cxagents cert check; device approval: none — manual), and the PAT revocation section (Phase 2). Add `doctor-test` and `authkey` to its recipe list if missing.

**Step 1:** Edit (describe credential handling in words; never spell credential env/key names outside `tailscale/README.md` — Phase 1 conventions). **Step 2: Verify** every recipe each README names exists (`just -f <module justfile> --list`), and `tailscale/scripts/keyscan.sh --repo` rc 0 (`docs/migration-recovery.md` is scanned too: Task 7 must refer to "`tailscale/.env` (both OAuth clients)", not to key names).

**Step 3: Operator:** ask the user to set exact-host matching in their password manager now (or confirm they will); note the answer in the completion summary.

**Step 4: Commit**
```bash
git add stacks/README.md stacks/connectome/README.md stacks/cxagents/README.md tailscale/README.md
git commit -m "docs: stack and tailscale READMEs for cxagents (overlay, exposures, password-manager step)"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: `docs/migration-recovery.md`

**Verifies:** cxagents-node.AC10.1.

**Files:**
- Modify: `docs/migration-recovery.md` — `## Prerequisites`, `## Clean-slate procedure`, `## On a fresh device`, and a new `### New tailnet` subsection.

**Changes:**
1. `## Prerequisites`: escrowed `tailscale/.env` (both OAuth clients) joins the list of secrets to have at hand.
2. `## On a fresh device` → new subsection `### Tailnet and cxagents on a fresh device`, placed **before** `### onecli v2 and connectome on a fresh device`, in this order:
   1. Restore `tailscale/.env` from escrow (`chmod 600`); `dotfiles tailscale policy-status` → `in-sync` (if `drift`, `policy-diff` and decide; never push blind).
   2. If `tailscale up` on the new Mac reports the name `cxmini` is taken, delete the stale `cxmini` device in the admin console first (then re-run; node IP changes → update `tailscale/policy.hujson` `hosts.cxmini`, `policy-push`, and the other node-IP artifacts per CLAUDE.md).
   3. `dotfiles stacks cxagents build` (and `image-test`).
   4. `dotfiles stacks cxagents login` — if it prints a stale `cxagents` device URL, delete that device, re-run.
   5. `dotfiles stacks cxagents up`.
   6. Then onecli and connectome as in the next subsection (connectome joins `cxagents` automatically).
   7. `dotfiles stacks doctor` — no FAILs.
3. `## Clean-slate procedure` (same machine): after the onecli step (6) and before the connectome step (7), insert a step: `dotfiles stacks cxagents build && dotfiles stacks cxagents login && dotfiles stacks cxagents up` (state is disposable: an existing device whose state was wiped is reported by `login` with its URL — delete it, re-run). Renumber the following steps.
4. New `### New tailnet` (end of the fresh-device section): create `dotfiles-admin` per `tailscale/README.md`, fill `tailscale/.env`, update `tailscale/tailnet.conf` (name, DNS suffix) and the cxmini `hosts` entry, `dotfiles tailscale policy-push --init`, work through the settings checklist, create `dotfiles-authkeys`, then continue with "Tailnet and cxagents on a fresh device" from step 3.

**Step 1:** Edit. **Step 2: Verify:** every command in the new text is a real recipe (`just -f "$wt/justfile" tailscale --list`, `just -f "$wt/stacks/justfile" cxagents --list`); read the fresh-device section top to bottom and confirm the AC10.1 order: `tailscale/.env` → `cxagents build` → stale devices → `cxagents login` → connectome. Following it on a real fresh device is a human verification item (not possible here); the current host's `doctor` with no FAILs is the automated proxy.

**Step 3: Commit**
```bash
git add docs/migration-recovery.md
git commit -m "docs: migration-recovery covers tailscale/.env, cxagents build/login, stale devices, new tailnet"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Final verification and the post-merge list

**Verifies:** cxagents-node.AC4.6, AC10.1 (automated proxy).

**Files:** none.

**Step 1: Everything, from the worktree**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J tailscale lint && $J tailscale lint-test && $J tailscale doctor-test && $J tailscale smoke
$J stacks cxagents test && $J stacks cxagents image-test && $J stacks cxagents lint && $J stacks cxagents lint-test \
  && $J stacks cxagents login-test && $J stacks cxagents doctor-test
$J stacks connectome lint && $J stacks connectome lint-test
./stacks/scripts/doctor.sh; echo "doctor rc=$?"
```
Expected: all pass; doctor `rc=0`, no `[FAIL]` (WARNs informational). `stacks cxagents smoke` and `stacks connectome smoke` were run in Phase 6; re-run them only if anything they cover changed since.

**Step 2: Hand the user this post-merge checklist (include it verbatim in the completion summary):**
1. Merge `cxagents-node` into `main`.
2. From the main checkout: `dotfiles stacks cxagents up` (re-creates the forwarder so its `routes` bind points at `main`, not the worktree).
3. `dotfiles stacks connectome up` (re-creates connectome so `./recipes` binds from `main` and the overlay is applied from `main`).
4. PAT cutover per `tailscale/README.md` "PAT revocation" (remove `TAILSCALE_PAT` from the live `stacks/adguard/.env` and its escrow copy, then revoke the token).
5. `dotfiles stacks doctor` from `main` → no FAIL and no `TAILSCALE_PAT` WARN.
6. Remove the worktree (`git worktree remove .worktrees/cxagents-node`) — its `.env` files are symlinks to `main`'s except the secret-free `stacks/adguard/.env`, which goes with it.
7. Password-manager exact-host matching (if not done in Task 6).

**Commit:** none.
<!-- END_TASK_8 -->

---

**Phase 7 done when:** `dotfiles stacks doctor` (from the worktree) has no FAILs and shows `--- Tailnet ---` and `--- cxagents ---`; `stacks cxagents doctor-test` proves every AC4.5 FAIL path; `up-all`/`down-all` order verified; CLAUDE.md, the READMEs and `docs/migration-recovery.md` match the recipes; the post-merge checklist is handed to the user.
