# cxagents Node Implementation Plan — Phase 2 of 7: adguard on the shared credential; doctor tailnet section

**Goal:** `tailnet-dns.sh` authenticates through `tailscale/scripts/api.sh` (admin client); `TAILSCALE_PAT` disappears from the tracked repo; `doctor` gains a `--- Tailnet ---` section that checks the declared tailnet state (policy, clients, identity, settings, credentials file).

**Architecture:** `tailnet-dns.sh` keeps its subcommands, guards, messages and exit codes (0/2/3) and swaps only its auth/transport for `api.sh`. The tailnet doctor checks live in `tailscale/scripts/doctor.sh` (so credential key names stay inside `tailscale/`, AC2.5) and print `[OK]/[FAIL]/[WARN]` lines that `stacks/scripts/doctor.sh` re-emits, exactly like it already does for `connectome/scripts/lint.sh`. A fixture runner `tailscale/scripts/doctor-test.sh` proves each FAIL/WARN path using override env vars, never by editing the live tailnet.

**Tech Stack:** bash, curl, jq, `/opt/homebrew/bin/tailscale` CLI, Tailscale API v2.

**Scope:** Phase 2 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`.

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file" (`wt`, `main`, `J`, no `dotfiles` alias, never read `.env` values).

**State found at verification:**
- `stacks/adguard/scripts/tailnet-dns.sh` (136 lines): lines 22–29 locate and `source` `stacks/adguard/.env`; 31–34 check `TAILSCALE_PAT`; 36 `api="https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers"`; 37 builds `hdr` with the PAT **in curl argv**; 40–44 GET preflight (exit 3 + manual-recovery hint); 109 `fallback="${TAILNET_DNS_FALLBACK:-1.1.1.1}"`; 120–125 POST (exit 3). Guards and messages in between stay unchanged.
- `stacks/adguard/.env.example` (22 lines): `TAILSCALE_PAT` at line 16 with comment block lines 1–15; `TAILNET_DNS_FALLBACK` at line 22.
- `stacks/adguard/README.md`: PAT/rotation text at lines 92–120 and 147–152.
- `stacks/scripts/doctor.sh`: `--- DNS failover ---` at line 210 (warn text "PAT missing or API unreachable" at line 230); `--- Agents ---` at 280; `--- Stack identity & env ---` at 368; exit at 423–425. Lint lines are re-emitted at 358–365 with the `case "$line" in "[OK]"*) … "[FAIL]"*) … *) warn` pattern.
- `CLAUDE.md` mentions `TAILSCALE_PAT` at lines 108 and 112 (DNS failover section).
- Live state: `tailscale status --json` → `CurrentTailnet.Name=cxreiff.github`, `MagicDNSSuffix=faun-fir.ts.net`, `MagicDNSEnabled=true`; `tailscale lock status` → `Tailnet Lock is NOT enabled.`

**The live system keeps using the PAT until this branch is merged** (the boot daemon runs `main`'s `tailnet-dns.sh`). So the operator's live `stacks/adguard/.env` keeps `TAILSCALE_PAT` and the PAT is revoked only in the post-merge cutover (Task 7). Inside the worktree, Task 1 replaces the `stacks/adguard/.env` symlink with a worktree-local, secret-free file so the new code can be proven with no `TAILSCALE_PAT` anywhere.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC2: Credentials are shared, declared and least-privilege (Phases 1, 3)
- **cxagents-node.AC2.6 Failure:** doctor FAILs when a client's granted scopes (the `scope` field of its token exchange) or tags differ from `tailscale/clients.conf`, including extra scopes. *(Phase 2: scopes; the tags comparison is added in Phase 3 with the first tagged client.)*
- **cxagents-node.AC2.5:** `tailscale/.env` is mode 0600 and gitignored; no file outside `tailscale/` contains a Tailscale client secret, PAT or auth key key name. *(Phase 2 completes it: `TAILSCALE_PAT` joins the scan.)*

### cxagents-node.AC3: adguard uses the shared credential (Phase 2)
- **cxagents-node.AC3.1 Success:** `tailnet-dns-on/off/status` behave exactly as before with no `TAILSCALE_PAT` in any file.
- **cxagents-node.AC3.2 Failure:** with `tailscale/.env` missing, `tailnet-dns.sh on` exits non-zero with the recovery hint and leaves Global NS unchanged; `adguard up` surfaces that exit code.
- **cxagents-node.AC3.3:** `TAILSCALE_PAT` is absent from `stacks/adguard/.env.example`, the adguard README and scripts.

### cxagents-node.AC4: doctor covers the tailnet and the node (Phases 2, 7)
- **cxagents-node.AC4.1 Success:** `--- Tailnet ---` reports `[OK]` when repo SHA-256 equals the live ETag.
- **cxagents-node.AC4.2 Failure:** it reports `[FAIL]` when the live policy differs from the repo (e.g. after an admin-console edit).
- **cxagents-node.AC4.3 Edge:** missing `tailscale/.env` or unreachable API is `[WARN]`, not `[FAIL]`; `tailscale/.env` with wrong mode or missing keys is `[FAIL]`.
- **cxagents-node.AC4.6:** doctor still reads only `.env` key names, never values (aside from the existing BRIDGE_USERNAME exception). *(Phase 2 keeps it for the new section; Phase 7 re-verifies for the cxagents section.)*
- **cxagents-node.AC4.7 Failure:** doctor FAILs when `tailscale status --json` MagicDNS suffix or tailnet name differs from `tailscale/tailnet.conf`, when MagicDNS is off, or when Tailnet Lock is on; WARNs when a `TAILSCALE_PAT` key name exists in any `.env`.

---

<!-- START_TASK_1 -->
### Task 1: Worktree-local, secret-free `stacks/adguard/.env`

**Verifies:** None (test fixture setup for AC3.1).

**Files:** `$wt/stacks/adguard/.env` (untracked; replaces the Phase 1 symlink).

**Step 1 (executor runs; no secret is read or copied):**
```bash
cd "$wt"
rm stacks/adguard/.env                       # removes the symlink only
umask 077; printf 'TAILNET_DNS_FALLBACK=1.1.1.1\n' > stacks/adguard/.env
stat -f %Lp stacks/adguard/.env; sed 's/=.*//' stacks/adguard/.env
```
Expected: `600`; `TAILNET_DNS_FALLBACK`. (The live `$main/stacks/adguard/.env` is untouched and still carries the PAT for the live system.)

**Commit:** none (untracked file).
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: `tailnet-dns.sh` authenticates through `api.sh`

**Verifies:** cxagents-node.AC3.1, AC3.2, AC3.3 (script part).

**Files:**
- Modify: `stacks/adguard/scripts/tailnet-dns.sh` lines 8–11 (header exit codes), 22–44 (env + auth + GET), 109 (fallback), 120–125 (POST).

**Implementation:**

Header (lines 8–11) becomes:
```bash
# Exit codes:
#   0 — success (or no-op when state already matches target)
#   2 — preflight failure (args / VM / node IP / tailscale/.env credentials)
#   3 — Tailscale API failure, or the dns-forward relay not answering
#
# Auth: tailscale/scripts/api.sh --client admin (OAuth, tailscale/.env).
# stacks/adguard/.env is optional and only supplies TAILNET_DNS_FALLBACK.
```

Lines 22–44 (from the `# Source .env …` comment through the GET block) are replaced by:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ts_scripts="${repo_root}/tailscale/scripts"
# shellcheck source=../../../tailscale/scripts/lib/conf.sh
source "${ts_scripts}/lib/conf.sh"          # TAILNET

# Fallback NS for `off`; the only value read from stacks/adguard/.env (not sourced).
env_file="${SCRIPT_DIR}/../.env"
fallback="1.1.1.1"
if [ -f "$env_file" ]; then
    v="$(sed -n 's/^TAILNET_DNS_FALLBACK=//p' "$env_file" | tail -1)"
    [ -n "$v" ] && fallback="$v"
fi

ns_path="/tailnet/${TAILNET}/dns/nameservers"
api_fail() {   # $1 = api.sh exit code, $2 = verb
    if [ "$1" -eq 2 ]; then
        echo "tailnet-dns: Tailscale API credentials unavailable — restore tailscale/.env (see tailscale/README.md, Credentials)" >&2
        exit 2
    fi
    echo "tailnet-dns: API $2 failed (see api.sh message above)" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}

# GET current Global NS — also serves as connectivity preflight
current_json="$("${ts_scripts}/api.sh" --client admin GET "$ns_path")" || api_fail $? GET
```
(`x="$(cmd)" || f $?` passes `cmd`'s exit status; `set -e` does not fire on the left side of `||`.)

Line 109 `fallback="${TAILNET_DNS_FALLBACK:-1.1.1.1}"` is deleted (the variable is now set above); the following `target=` line keeps using `$fallback`.

Lines 120–125 (POST) become:
```bash
resp="$("${ts_scripts}/api.sh" --client admin POST "$ns_path" \
    -H 'Content-Type: application/json' -d "$body")" || api_fail $? POST
```
keeping the existing success output after it.

No other line changes: subcommands, the `on` guards (bridged VM IP, node IP, AGH wizard/bind checks, `dig` relay preflight), the idempotency check and every message stay as they are.

**Step 1:** Make the edits.

**Step 2: Verify (read-only / idempotent live calls)**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J stacks adguard tailnet-dns-status | jq -c .                     # same JSON shape as before
$J stacks adguard tailnet-dns-on; echo "rc=$?"                     # AGH is up: expect "already [...] — no change", rc=0
before=$($J stacks adguard tailnet-dns-status | jq -c .dns)
TAILSCALE_ENV_FILE=/nonexistent ./stacks/adguard/scripts/tailnet-dns.sh on; echo "rc=$?"   # AC3.2
after=$($J stacks adguard tailnet-dns-status | jq -c .dns); [ "$before" = "$after" ] && echo "OK: NS unchanged"
TAILSCALE_ENV_FILE=/nonexistent $J stacks adguard up; echo "rc=$?"   # AC3.2: up surfaces the exit
```
Expected: status JSON with `.dns`; `rc=0` and the no-change message; with `TAILSCALE_ENV_FILE=/nonexistent` stderr `… restore tailscale/.env …` and `rc=2`; `OK: NS unchanged`; `adguard up` prints the same hint and exits non-zero (its `compose up -d` is a no-op on the running container).

**Step 3: Operator-gated full cycle (AC3.1 "off" path) — ask the user first.** `off` briefly points the tailnet's Global NS at the fallback (`1.1.1.1`) before `on` restores it. Only with the user's go-ahead:
```bash
$J stacks adguard tailnet-dns-off; $J stacks adguard tailnet-dns-status | jq -c .dns   # ["1.1.1.1"]
$J stacks adguard tailnet-dns-on;  $J stacks adguard tailnet-dns-status | jq -c .dns   # ["100.70.208.32"]
```

**Step 4: Commit**
```bash
git add stacks/adguard/scripts/tailnet-dns.sh
git commit -m "stacks/adguard: tailnet-dns via tailscale/scripts/api.sh (OAuth admin client), no PAT"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Remove the PAT from tracked adguard files, CLAUDE.md DNS text and keyscan

**Verifies:** cxagents-node.AC3.3, AC2.5 (PAT part).

**Files:**
- Modify: `stacks/adguard/.env.example` (drop lines 1–16's PAT block; keep `TAILNET_DNS_FALLBACK` and its comment).
- Modify: `stacks/adguard/README.md` lines 92–120 (credential section) and 147–152 (half-down recovery).
- Modify: `CLAUDE.md` lines 108 and 112 (DNS failover section).
- Modify: `tailscale/scripts/keyscan.sh` — add `|TAILSCALE_PAT` to `names`.

**Implementation:**
- `.env.example` becomes a short file: a comment that tailnet DNS authenticates with the shared OAuth admin client in `tailscale/.env` (see `tailscale/README.md`), and `TAILNET_DNS_FALLBACK=1.1.1.1` with its existing comment.
- README credential section (replacing the "Generate a Tailscale PAT…" steps and the 90-day expiry warning): tailnet-dns uses `tailscale/scripts/api.sh --client admin` (OAuth client `dotfiles-admin`, non-expiring, scopes in `tailscale/clients.conf`); setup = restore/create `tailscale/.env` per `tailscale/README.md`; `stacks/adguard/.env` holds only `TAILNET_DNS_FALLBACK` and is optional. Keep the "Why the API and not Tailscale's multi-resolver fallback" paragraph and the manual-recovery URL. In the half-down recovery section, replace "revoked PAT" / "fix the PAT" with "missing/invalid `tailscale/.env` credentials" / "restore `tailscale/.env`". Do not name the `.env` key names of `tailscale/.env` in this README (AC2.5).
- `CLAUDE.md` line 108: `(Tailscale REST API, requires TAILSCALE_PAT in stacks/adguard/.env)` → `(Tailscale REST API via tailscale/scripts/api.sh — the shared OAuth admin client in tailscale/.env)`. Line 112 paragraph ("The `TAILSCALE_PAT` expires every 90 days …") is replaced by: "Credentials are the non-expiring `dotfiles-admin` OAuth client in `tailscale/.env` (0600, escrowed). If tailnet DNS is not using AGH after a reboot, check `dotfiles stacks adguard tailnet-dns-status` and `doctor`'s `--- Tailnet ---` section; a missing `tailscale/.env` makes `adguard up` fail with a restore hint." (Phase 7 does the broader CLAUDE.md update.)
- `keyscan.sh`: `names='TS_(ADMIN|AUTHKEYS|OAUTH)_CLIENT_(ID|SECRET)|TS_AUTH_?KEY|TS_CLIENT_(ID|SECRET)|TS_API_KEY|TAILSCALE_PAT'`.

**Step 1:** Make the edits.

**Step 2: Verify**
```bash
cd "$wt"
git grep -n 'TAILSCALE_PAT' -- stacks/adguard CLAUDE.md; echo "rc=$?"     # rc=1: no hits
tailscale/scripts/keyscan.sh --repo; echo "rc=$?"                          # rc=0, no output
```
Expected: no hits (`rc=1`); keyscan `rc=0`.

**Step 3: Commit**
```bash
git add stacks/adguard/.env.example stacks/adguard/README.md CLAUDE.md tailscale/scripts/keyscan.sh
git commit -m "stacks/adguard: drop TAILSCALE_PAT (shared OAuth credential); keyscan covers the PAT name"
```
<!-- END_TASK_3 -->

<!-- START_SUBCOMPONENT_A (tasks 4-6) -->
<!-- START_TASK_4 -->
### Task 4: `tailscale/scripts/doctor.sh` — the tailnet checks

**Verifies:** cxagents-node.AC2.6 (scopes), AC4.1, AC4.2, AC4.3, AC4.6, AC4.7.

**Files:**
- Create: `tailscale/scripts/doctor.sh` (755).
- Modify: `tailscale/scripts/policy.sh` — nothing (it already takes `--file`).

**Implementation:** read-only; prints only `[OK]`/`[FAIL]`/`[WARN]`/`[OFF]` lines (via `stacks/scripts/lib/check.sh`) prefixed `tailnet: `; never reads a `.env` value; exit status is informational (the caller re-emits lines). Overrides for the fixture runner: `TAILSCALE_ENV_FILE` (passed through to `api.sh`), `TAILSCALE_POLICY_FILE`, `TAILSCALE_CLIENTS_CONF`, `TAILSCALE_TAILNET_CONF` (read by `lib/conf.sh`), `TAILSCALE_STATUS_JSON` (a file used instead of `tailscale status --json`), `TAILSCALE_LOCK_STATUS` (a file used instead of `tailscale lock status`), `DOCTOR_ENV_FILES` (space-separated list instead of `$repo_root/tailscale/.env $repo_root/stacks/*/.env`).

Checks, in order:
1. **Credentials file** (`env="${TAILSCALE_ENV_FILE:-$ts_root/.env}"`): missing → `warn "tailnet: tailscale/.env missing — API checks skipped (restore from escrow; tailscale/README.md)"` and set `api_ok=0`. Present → `stat -L -f %Lp` must be `600` else `fail "tailnet: tailscale/.env mode ${mode} (chmod 600)"`; `git -C "$repo_root" check-ignore -q tailscale/.env` else fail; every key name in `tailscale/.env.example` (`grep -E '^[A-Z][A-Z0-9_]*=' | sed 's/=.*//'`) present (`grep -qE "^${key}="`) else `fail "tailnet: tailscale/.env missing keys: …"`; any `^TS_OAUTH_CLIENT_` key → `fail "tailnet: tailscale/.env has deprecated TS_OAUTH_CLIENT_* keys (rename; see api.sh)"`.
2. **Policy drift** (only if `api_ok`): `out=$("$ts_scripts/policy.sh" --file "${TAILSCALE_POLICY_FILE:-$ts_root/policy.hujson}" status 2>&1)`; `rc` 0 → `pass "tailnet: policy in-sync (sha256 = live ETag)"`; output `drift` → `fail "tailnet: live policy differs from tailscale/policy.hujson (admin-console edit? run: dotfiles tailscale policy-diff)"`; rc 2/3 → `warn "tailnet: policy status unavailable (API unreachable or credentials invalid)"`.
3. **Clients** (only if `api_ok`): for each non-comment row of `${TAILSCALE_CLIENTS_CONF:-$ts_root/clients.conf}` (`read -r name rest`; scopes = all fields but the last; tags = last field): `granted=$("$ts_scripts/api.sh" --client "$name" --granted-scopes 2>/dev/null)`; rc 2 → `fail "tailnet: client ${name}: credentials missing in tailscale/.env"`; rc 3 → `warn "tailnet: client ${name}: token exchange failed (API unreachable?)"`; else compare `tr ' ' '\n' | sort -u` of both: equal → `pass "tailnet: client ${name} scopes match clients.conf"`; different → `fail "tailnet: client ${name} scopes differ from clients.conf (extra: …; missing: …)"` (use `comm -13`/`comm -23`). (Tags: Phase 3.)
4. **Tailnet identity** (`st=$(cat "$TAILSCALE_STATUS_JSON" 2>/dev/null || /opt/homebrew/bin/tailscale status --json 2>/dev/null)`; empty → `warn "tailnet: tailscale status unavailable"`): `.CurrentTailnet.Name == $TAILNET` else fail naming both; `.CurrentTailnet.MagicDNSSuffix == $TAILNET_DNS_SUFFIX` else fail; `.CurrentTailnet.MagicDNSEnabled == true` else `fail "tailnet: MagicDNS is off (tailscale/README.md settings checklist)"`. All good → one `pass "tailnet: identity matches tailnet.conf (cxreiff.github, faun-fir.ts.net, MagicDNS on)"`.
5. **Tailnet Lock** (`ls=$(cat "$TAILSCALE_LOCK_STATUS" 2>/dev/null || /opt/homebrew/bin/tailscale lock status 2>/dev/null)`): contains `Tailnet Lock is NOT enabled` → pass; empty → warn; else `fail "tailnet: Tailnet Lock is on (must be off; tailscale/README.md settings checklist)"`.
6. **Policy lint:** re-emit `tailscale/scripts/lint.sh` lines with the same `case` pattern as `stacks/scripts/doctor.sh:358-365` (prefix `tailnet: `).
7. **Retired PAT:** for each file in `${DOCTOR_ENV_FILES:-$repo_root/tailscale/.env $repo_root/stacks/*/.env}`: `grep -qE '^TAILSCALE_PAT=' "$f"` → `warn "tailnet: ${f#$repo_root/} still has a TAILSCALE_PAT key (retired; see tailscale/README.md PAT revocation)"`. (Key name only.)
8. **Key names outside tailscale/:** `"$ts_scripts/keyscan.sh" --repo` non-zero → `fail "tailnet: Tailscale credential key names outside tailscale/: <files>"`, else pass.

**Step 1:** Create the script.

**Step 2: Verify against live**
```bash
cd "$wt" && tailscale/scripts/doctor.sh
```
Expected: `[OK]` for mode/ignore/keys, policy in-sync, client admin scopes, identity, Tailnet Lock off, the four policy lint lines, keyscan; **no** PAT WARN (in the worktree `stacks/adguard/.env` is Task 1's secret-free file). Run from `main` after merge but before Task 7's cutover, the same script WARNs about the live adguard `.env` — the intended reminder.

**Step 3: Commit**
```bash
git add tailscale/scripts/doctor.sh
git commit -m "tailscale: doctor checks (policy drift, client scopes, identity, Tailnet Lock, .env, PAT, keyscan)"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: `--- Tailnet ---` in `stacks/scripts/doctor.sh`

**Verifies:** cxagents-node.AC4.1–AC4.3, AC4.7 (surfacing).

**Files:**
- Modify: `stacks/scripts/doctor.sh` — insert a section immediately before `echo "--- DNS failover ---"` (line 210, preceded by `echo`), and change the warn text at line 230.
- Modify: `CLAUDE.md` "Common commands" doctor line ("read-only checks across 8 sections: …") — add `Tailnet` (9 sections). (Only that line; Phase 7 does the rest.)

**Implementation:**
```bash
echo
echo "--- Tailnet ---"

# Declared tailnet state (tailscale/): policy drift, OAuth client scopes,
# identity, settings, credentials file. Key names only; never .env values.
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "tailnet: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../../tailscale/scripts/doctor.sh" 2>&1)
```
Line 230: `warn "tailnet-dns status unavailable (PAT missing or API unreachable)"` → `warn "tailnet-dns status unavailable (tailscale/.env missing or API unreachable)"`.

**Step 1:** Make the edits.

**Step 2: Verify**
```bash
cd "$wt" && ./stacks/scripts/doctor.sh | sed -n '/--- Tailnet ---/,/--- DNS failover ---/p'
```
Expected: the Task 4 lines, re-emitted, between the two headers; no FAIL.

**Step 3: Commit**
```bash
git add stacks/scripts/doctor.sh CLAUDE.md
git commit -m "stacks/doctor: --- Tailnet --- section (tailscale/scripts/doctor.sh)"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: `tailscale/scripts/doctor-test.sh` — prove each FAIL/WARN path

**Verifies:** cxagents-node.AC2.6, AC4.2, AC4.3, AC4.6, AC4.7.

**Files:**
- Create: `tailscale/scripts/doctor-test.sh` (755).
- Modify: `tailscale/justfile` — add:
```just
# Prove each doctor tailnet FAIL/WARN path with fixtures (read-only against live)
doctor-test:
    @./scripts/doctor-test.sh
```

**Implementation** (lint-test style: temp dir + trap; each case runs `tailscale/scripts/doctor.sh` with overrides and asserts on its output; `PASS doctor-fixture <label>` / `FAIL …`; summary and exit like `lint-test.sh`). Cases:
- `baseline` — no overrides: no `[FAIL]` (AC4.1: contains `[OK]   tailnet: policy in-sync`).
- `policy-drift` (AC4.2) — `TAILSCALE_POLICY_FILE` = copy of `policy.hujson` with `// drift` appended → `[FAIL] tailnet: live policy differs`. (Equivalent to an admin-console edit from doctor's point of view: repo bytes ≠ live ETag. The live policy is not touched.)
- `env-missing` (AC4.3) — `TAILSCALE_ENV_FILE=$tmp/none` → `[WARN] tailnet: tailscale/.env missing` and **no** `[FAIL]` line mentioning `.env`, `policy` or `client`.
- `env-mode` (AC4.3) — a fixture env with the example's key names and dummy values, mode 644 → `[FAIL] tailnet: tailscale/.env mode 644`.
- `env-keys` (AC4.3) — fixture env (0600) lacking `TS_ADMIN_CLIENT_SECRET` → `[FAIL] … missing keys: TS_ADMIN_CLIENT_SECRET`.
- `api-unreachable` (AC4.3) — `TAILSCALE_ENV_FILE` = fixture env (0600) with all keys and dummy non-placeholder values (`x`) → token exchange fails (HTTP 401) → `[WARN] tailnet: policy status unavailable` and `[WARN] … token exchange failed`, no `[FAIL]` for policy/clients. *(The dummy id is sent to Tailscale's token endpoint and rejected; nothing secret is involved.)*
- `scope-extra` (AC2.6) — `TAILSCALE_CLIENTS_CONF` with the admin row plus `users:read` → `[FAIL] tailnet: client admin scopes differ … extra: … missing: users:read`. Also `scope-missing`: row without `dns` → FAIL listing `dns` as extra-granted.
- `tailnet-name`, `dns-suffix`, `magicdns-off` (AC4.7) — `TAILSCALE_STATUS_JSON` = live `tailscale status --json | jq '.CurrentTailnet.Name="other"'` (resp. `MagicDNSSuffix="x.ts.net"`, `MagicDNSEnabled=false`) → the matching `[FAIL]`.
- `lock-on` (AC4.7) — `TAILSCALE_LOCK_STATUS` = file with `Tailnet Lock is ENABLED.` → `[FAIL] tailnet: Tailnet Lock is on`.
- `pat-key` (AC4.7) — `DOCTOR_ENV_FILES=$tmp/adguard.env` with a line `TAILSCALE_PAT=x` → `[WARN] … TAILSCALE_PAT`.
- `no-values` (AC4.6) — run the baseline, capture stdout+stderr, and assert it contains neither the value of `TS_ADMIN_CLIENT_SECRET` (read into a variable only for the comparison, never printed) nor `tskey-`. (Do not use `bash -x`: api.sh's own xtrace would print the secret.) Then `grep -nE '^[[:space:]]*(source|\.)[[:space:]][^#]*\.env' tailscale/scripts/doctor.sh` returns nothing (no `.env` is ever sourced).

**Step 1:** Create the script; add the recipe.

**Step 2: Verify**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J tailscale doctor-test
```
Expected: `PASS doctor-fixture …` for every case, `All fixtures passed`.

**Step 3: Commit**
```bash
git add tailscale/scripts/doctor-test.sh tailscale/justfile
git commit -m "tailscale: doctor-test fixtures (drift, scopes, identity, lock, .env, PAT)"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_7 -->
### Task 7: Document PAT revocation and the post-merge cutover

**Verifies:** None (documentation; the cutover itself is an operator step after merge).

**Files:**
- Modify: `tailscale/README.md` — replace the Phase 1 `### PAT revocation` placeholder.

**Content:**
```markdown
### PAT revocation (one-time, after the OAuth migration is merged)

The adguard `dns_token` PAT (full-admin `all` scopes, expires 2026-11-22) is
retired. Until the migration is on `main`, the live boot path still uses it,
so do these in order, from the main checkout:

1. `dotfiles stacks adguard tailnet-dns-status` succeeds (now via OAuth).
2. Remove the `TAILSCALE_PAT=` line from `stacks/adguard/.env` (and its escrow copy).
3. `dotfiles stacks adguard tailnet-dns-status` still succeeds.
4. Revoke the token at https://login.tailscale.com/admin/settings/keys.
5. `dotfiles stacks doctor`: no `TAILSCALE_PAT` WARN in `--- Tailnet ---`.
```

**Step 1:** Edit the README.

**Step 2: Note for the final handoff:** the executor must list this cutover (and the other post-merge steps collected in Phases 5–7) in its completion summary to the user. If the PAT was exposed earlier (see the planning session), the user may already have rotated it; step 4 still applies to whatever PAT is live.

**Step 3: Commit**
```bash
git add tailscale/README.md
git commit -m "tailscale: README PAT revocation / post-merge cutover"
```
<!-- END_TASK_7 -->

---

**Phase 2 done when:** in the worktree, `tailnet-dns-status`/`-on` (and, with the user's go-ahead, `-off` then `-on`) work with no `TAILSCALE_PAT` in any worktree file; `TAILSCALE_ENV_FILE=/nonexistent tailnet-dns.sh on` exits 2 with the restore hint and leaves Global NS unchanged; `doctor` shows `--- Tailnet ---` all `[OK]`; `tailscale doctor-test` proves the drift, scope-mismatch, identity, Tailnet Lock, `.env` and PAT paths; `tailscale lint`, `lint-test`, `smoke` still pass.
