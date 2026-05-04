# Phase 5: `tailnet-dns` recipe + adguard up/down auto-hooks

**Goal:** Toggle Tailscale's tailnet-wide Global Nameservers between AGH (the bridged-VM IP) and a public fallback (`1.1.1.1`) via the Tailscale REST API. Auto-trigger from `dotfiles stacks adguard up`/`down` so planned maintenance never strands the tailnet on a dead resolver.

**Architecture:** A new `stacks/adguard/scripts/tailnet-dns.sh` script with three subcommands (`on`, `off`, `status`) that read/write Tailscale Global NS via `POST /api/v2/tailnet/-/dns/nameservers`. Idempotent via GET-then-POST comparison so re-runs don't churn the API. A second new script `stacks/adguard/scripts/wait-healthy.sh` polls AGH with `dig` until it answers (or 60s deadline). The `adguard up` recipe gains `wait-healthy.sh && tailnet-dns.sh on` after `compose up`; `adguard down` runs `tailnet-dns.sh off` BEFORE `compose down`. A new `TAILSCALE_PAT` lives in `stacks/adguard/.env`.

**Tech Stack:** Tailscale REST API (`api.tailscale.com`, Bearer auth, `dns:write` scope or its current equivalent), `dig` (`/usr/bin/dig` confirmed), `curl`, `jq` (already on host at `/usr/bin/jq`).

**Scope:** Phase 5 of 8. Depends on Phase 1 (doctor — for the new state-consistency check). Adguard is also the one stack that requires creating a `.env.example` from scratch since it doesn't have one today.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC2: DNS resilience
- **stack-resilience.AC2.1 Success:** `dotfiles stacks adguard tailnet-dns-on` sets Tailscale Global Nameservers to `[<bridged-vm-ip>]` via `POST /api/v2/tailnet/-/dns/nameservers`.
- **stack-resilience.AC2.2 Success:** `dotfiles stacks adguard tailnet-dns-off` sets Tailscale Global Nameservers to `["1.1.1.1"]` via the same endpoint.
- **stack-resilience.AC2.3 Success:** `dotfiles stacks adguard tailnet-dns-status` reports the current Global Nameservers JSON from the API.
- **stack-resilience.AC2.4 Success:** `dotfiles stacks adguard up` invokes `tailnet-dns-on` AFTER `wait-healthy.sh` confirms AGH responds to `dig`.
- **stack-resilience.AC2.5 Success:** `dotfiles stacks adguard down` invokes `tailnet-dns-off` BEFORE `compose down`.
- **stack-resilience.AC2.6 Success:** With AGH stopped via `dotfiles stacks adguard down`, the Mac resolves `example.com` successfully (DNS not bricked).
- **stack-resilience.AC2.7 Edge:** `tailnet-dns-on` or `-off` run twice in a row makes no second API write call (idempotent via GET comparison).
- **stack-resilience.AC2.8 Failure:** Tailscale API unreachable during `adguard up` — recipe exits non-zero with the curl error AND a recovery hint; AGH container remains running.
- **stack-resilience.AC2.9 Failure:** Tailscale API unreachable during `adguard down` — recipe exits non-zero with recovery hint; AGH container is NOT stopped (don't brick DNS while we can't fail it over first).

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.3 Success:** `stacks/adguard/scripts/{tailnet-dns.sh, wait-healthy.sh}` exist (this phase ships both).

---

## Operational Context (read before executing — IMPORTANT)

This phase **mutates Tailscale tailnet state**, which affects every connected device — phone, Mac, anything else on the tailnet. The `tailnet-dns-off` write to `1.1.1.1` is the safety mechanism, not the regression risk; the regression risk is leaving the tailnet pointed at a dead AGH IP.

**The user must obtain a Tailscale Personal Access Token (PAT) before this phase can be run.**

The PAT must have the `dns` scope (which currently grants both read and write per Tailscale docs as of 2026; the design plan called this `dns:write` based on prior naming — confirm current scope name in the Tailscale admin UI when generating). Generate at: <https://login.tailscale.com/admin/settings/keys> → Generate access token → set scope to `dns` (or `dns:write` if shown as a separate scope) → max recommended expiry 90 days.

The PAT lives in `stacks/adguard/.env`, mode 0600, gitignored. **Never commit it.**

**API endpoint shapes (verified via Tailscale REST API docs):**
- `GET https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers` → `{"dns": [...], "magicDNSEnabled": true|false}`
- `POST https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers` with body `{"dns": ["1.2.3.4"]}` → updates Global NS.
- The `-` placeholder means "the authenticated user's default tailnet."
- **Critical:** clearing all nameservers (`{"dns": []}`) auto-disables MagicDNS. Always send a non-empty list when using `off`.
- Bearer auth: `Authorization: Bearer ${TAILSCALE_PAT}`.

**Pre-flight (verify before starting):**
- Phase 1 complete (doctor exists).
- AGH is currently running and healthy (`dotfiles stacks doctor` green; `dig @<bridged-vm-ip> example.com +short` returns an answer).
- User has generated a Tailscale PAT with the `dns` scope and is ready to paste it into `.env`.

**Recovery if anything goes wrong:**
- Tailnet DNS pointing at a dead host: visit <https://login.tailscale.com/admin/dns> manually and edit Global Nameservers to `1.1.1.1` from the web UI. Total recovery time: 30 seconds.

---

<!-- START_TASK_1 -->
### Task 1: Create `stacks/adguard/.env.example` (today's adguard has no .env at all)

**Verifies:** Foundation for AC2.1-AC2.3 (without `TAILSCALE_PAT` the script can't run).

**Files:**
- Create: `stacks/adguard/.env.example`

**Implementation:**

Adguard's compose.yaml currently does not reference any environment variables (verified — `stacks/adguard/compose.yaml` lines 1-9 reference no `${VAR}`s). So `.env`/`.env.example` are entirely net-new for this stack and serve only the new `tailnet-dns.sh` script.

Match the homebridge `.env.example` shape (commented header explaining each variable, then key=value lines). Single variable initially; future fallback-IP customization can be added if ever needed.

```sh
# Tailscale REST API token used by `tailnet-dns.sh` to toggle the tailnet's
# Global Nameservers between AGH (when AGH is up) and a public fallback
# (when AGH is down). This is what prevents AGH maintenance from bricking
# Mac DNS.
#
# Generate at:
#   https://login.tailscale.com/admin/settings/keys
#   → "Generate access token..."
#   → Description: "dotfiles tailnet-dns"
#   → Scope: "dns" (grants read+write on DNS settings)
#   → Expiry: 90 days (max). Rotate before expiry; doctor doesn't auto-rotate.
TAILSCALE_PAT=tskey-api-CHANGE_ME

# Public fallback resolver used when AGH is down (set as Global Nameservers
# during `adguard down`). 1.1.1.1 is Cloudflare; 8.8.8.8 is Google. Pick one
# the user trusts; this is the resolver every tailnet device falls back to
# during AGH maintenance.
TAILNET_DNS_FALLBACK=1.1.1.1
```

The fallback is parameterized so the user can change it without editing the script.

**Verification:**

```bash
ls -la stacks/adguard/.env.example
# Expected: file present, mode 644

cat stacks/adguard/.env.example
# Expected: the two keys with comments

# Confirm .gitignore allowlist still covers it (.env.example is whitelisted
# after the *.env block at .gitignore:13)
git check-ignore -v stacks/adguard/.env.example
# Expected: empty (file is NOT ignored — allowlist works)
```

**Commit:**
```bash
git add stacks/adguard/.env.example
git commit -m "adguard: add .env.example for TAILSCALE_PAT (Phase 5 prereq)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: User creates `stacks/adguard/.env` from the example (manual step — pause here)

**Verifies:** Direct prerequisite for AC2.1-AC2.3.

**Files:**
- User-created: `stacks/adguard/.env` (gitignored, mode 0600).

**Implementation:**

This is a **human action**, not a script step. The plan executor pauses and prompts the user to:

```sh
cd stacks/adguard
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

In `.env`:
1. Replace `tskey-api-CHANGE_ME` with the actual PAT from <https://login.tailscale.com/admin/settings/keys>. (Format starts with `tskey-api-` for the standard PAT class.)
2. Either keep `TAILNET_DNS_FALLBACK=1.1.1.1` or change to a preferred resolver.

**STOP — do not proceed until the user confirms `.env` is in place.**

**Verification:**

```bash
ls -la stacks/adguard/.env
# Expected: -rw------- (mode 600), present

# Sanity-check the PAT is non-empty and not still CHANGE_ME (auditable from
# script source — never echo the actual value)
grep -q '^TAILSCALE_PAT=tskey-api-' stacks/adguard/.env && \
    [ "$(grep '^TAILSCALE_PAT=' stacks/adguard/.env | cut -d= -f2)" != "tskey-api-CHANGE_ME" ] \
    && echo "PAT looks set" || echo "PAT not set or still CHANGE_ME"
# Expected: "PAT looks set"

# Confirm gitignored
git check-ignore -v stacks/adguard/.env
# Expected: line containing `.env` rule — file IS ignored
```

**Commit:** None — `.env` is gitignored.
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `stacks/adguard/scripts/wait-healthy.sh`

**Verifies:** Foundation for AC2.4 (the `up` hook waits before flipping NS).

**Files:**
- Create: `stacks/adguard/scripts/wait-healthy.sh` (executable, mode 755)

**Implementation:**

Poll the bridged VM IP for an A-record response with per-attempt timeout 2s, total deadline 60s, sleep 1s between attempts. Per Phase 1 internet research: `dig +tries=1 +time=2 +short`; exit 0 = response received (any RCODE, including NXDOMAIN); exit 9 = no reply within 2s.

For an AGH health probe, "any response" is sufficient — if AGH is answering at all, it's serving DNS. Use `example.com` as the query domain (commonly available, low TTL volatility).

Resolve the bridged VM IP using the established `colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}'` idiom (matches `stacks/adguard/justfile:37`). If the VM is not running, exit 1 with a clear message — wait-healthy can't probe a non-existent server.

```bash
#!/usr/bin/env bash
# stacks/adguard/scripts/wait-healthy.sh
# Poll AGH at the bridged-VM IP until it answers a DNS query or the deadline
# expires.
#
# Exit codes:
#   0 — AGH is responding to DNS, OR AGH is in first-run-wizard state (no
#       bind_hosts populated yet — the wizard hasn't been completed). The
#       latter case is a benign no-op for the up hook; the caller (`adguard
#       up`) interprets exit 0 as "safe to proceed", and the chained
#       `tailnet-dns.sh on` then either flips Global NS (wizard done) or
#       quietly no-ops (wizard pending — user hasn't yet pointed AGH at
#       col0; flipping Global NS at AGH would brick DNS).
#   1 — bridged VM not running, OR AGH is wizard-complete + bind_hosts
#       populated but DNS isn't responding within 60s (real failure).
set -euo pipefail

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "wait-healthy: bridged VM not running" >&2
    exit 1
fi

# First-run-wizard guard: if AGH yaml is missing, or has no bind_hosts entry
# yet, AGH is in wizard mode (only the :3000 web UI is listening; no DNS
# bind on col0). Exit 0 with a clear message — no DNS to wait for.
agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
if [ ! -f "$agh_yaml" ] \
    || ! awk '/^[[:space:]]+bind_hosts:/{f=1; next} f && /^[[:space:]]+- /{print; exit}' \
            "$agh_yaml" | grep -qE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b'; then
    echo "wait-healthy: AGH wizard not yet complete (no bind_hosts in ${agh_yaml})"
    echo "  Complete the wizard at http://${vm_ip}:3000 (bind to col0 — see adguard/README.md)."
    echo "  Then re-run: dotfiles stacks adguard restart"
    exit 0
fi

deadline=$(($(date +%s) + 60))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if dig "@${vm_ip}" example.com +tries=1 +time=2 +short >/dev/null 2>&1; then
        # Exit 0 from dig means we got a response — AGH is up.
        echo "wait-healthy: AGH at ${vm_ip} responding"
        exit 0
    fi
    sleep 1
done

echo "wait-healthy: AGH at ${vm_ip} did not respond within 60s" >&2
exit 1
```

**Companion guard in `tailnet-dns.sh on`** (Task 4, see below): the `on` subcommand should similarly no-op (exit 0 with a clear message) if AGH yaml shows no `bind_hosts` populated yet — flipping Global NS to point at AGH while AGH isn't listening for DNS would brick the tailnet. So Task 4's script needs the same wizard-pending check before issuing the API write. Keep both guards: defense in depth.

**Verification:**

```bash
chmod +x stacks/adguard/scripts/wait-healthy.sh

# AGH is up — should succeed quickly
./stacks/adguard/scripts/wait-healthy.sh
echo "exit=$?"
# Expected: "wait-healthy: AGH at 192.168.1.78 responding", exit 0, <2s wall time
time ./stacks/adguard/scripts/wait-healthy.sh >/dev/null
# Expected: real time well under 1s in healthy state
```

To test the deadline path safely without stopping AGH (which would brick DNS for the duration), modify the script's `vm_ip=` line temporarily to point at an unreachable IP (e.g., `127.0.0.99`), run, observe 60s deadline + non-zero exit, then revert the change.

**Commit:**
```bash
git add stacks/adguard/scripts/wait-healthy.sh
git commit -m "adguard: add wait-healthy.sh (dig poll with 60s deadline)"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Create `stacks/adguard/scripts/tailnet-dns.sh` with `on`/`off`/`status`

**Verifies:** stack-resilience.AC2.1, stack-resilience.AC2.2, stack-resilience.AC2.3, stack-resilience.AC2.7, stack-resilience.AC2.8, stack-resilience.AC2.9

**Files:**
- Create: `stacks/adguard/scripts/tailnet-dns.sh` (executable, mode 755)

**Implementation:**

Subcommands:
- `status` — `GET /api/v2/tailnet/-/dns/nameservers`, pretty-print the JSON.
- `on` — read VM IP via colima awk; if current Global NS already equals `[<vm-ip>]`, print "already on, no change" and exit 0; else `POST` with `{"dns":["<vm-ip>"]}`.
- `off` — if current Global NS already equals `[<TAILNET_DNS_FALLBACK>]`, print "already off, no change" and exit 0; else `POST` with `{"dns":["<TAILNET_DNS_FALLBACK>"]}`.

Idempotency (AC2.7) is enforced by the GET-then-compare-then-POST flow — repeated invocations with no change produce zero write API calls.

**Comparison-shape assumption (single-element array):** the script compares `current` and `target` as `@json`-serialized strings (e.g., `["192.168.1.78"]`). This works because the design's `on`/`off` writes always produce a single-element array — never a multi-IP list. If the design ever extends to set-multiple-NS-at-once, the comparison would need order-insensitive set equality. Acceptable for the current binary-toggle scope; not a code change.

Failure-mode contract:
- `TAILSCALE_PAT` not in `.env`: exit 2 with hint to `.env.example`.
- `api.tailscale.com` unreachable: exit 3 with the curl error and a recovery hint pointing to the manual web UI URL.
- API returns non-2xx: exit 3 with body and recovery hint.
- bridged VM not running (only matters for `on`): exit 2 with hint to `dotfiles stacks vm-bridged`.

The script sources `.env` directly (not `lib/check.sh`) — it's an action script, not a doctor extension.

```bash
#!/usr/bin/env bash
# stacks/adguard/scripts/tailnet-dns.sh
# Toggle Tailscale tailnet Global Nameservers between AGH and a public
# fallback. Idempotent — compares against current state before writing.
#
# Usage: tailnet-dns.sh on|off|status
#
# Exit codes:
#   0 — success (or no-op when state already matches target)
#   2 — preflight failure (.env / VM / args)
#   3 — Tailscale API failure
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
    on|off|status) ;;
    *) echo "usage: tailnet-dns.sh on|off|status" >&2; exit 2 ;;
esac

# Source .env from the same dir as this script's parent (stacks/adguard/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
if [ ! -f "$env_file" ]; then
    echo "tailnet-dns: ${env_file} missing — copy .env.example, fill in TAILSCALE_PAT" >&2
    exit 2
fi
# shellcheck disable=SC1090
set -a; source "$env_file"; set +a

if [ -z "${TAILSCALE_PAT:-}" ] || [ "$TAILSCALE_PAT" = "tskey-api-CHANGE_ME" ]; then
    echo "tailnet-dns: TAILSCALE_PAT not set in ${env_file}" >&2
    exit 2
fi

api="https://api.tailscale.com/api/v2/tailnet/-/dns/nameservers"
hdr=(-H "Authorization: Bearer ${TAILSCALE_PAT}" -H "Content-Type: application/json")

# GET current Global NS — also serves as connectivity preflight
current_json="$(curl -fsS "${hdr[@]}" "$api" 2>&1)" || {
    echo "tailnet-dns: API GET failed: $current_json" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}
current="$(echo "$current_json" | jq -r '.dns | @json')"

case "$cmd" in
    status)
        echo "$current_json" | jq .
        exit 0
        ;;

    on)
        vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
        if [ -z "$vm_ip" ]; then
            echo "tailnet-dns: bridged VM not running (run: dotfiles stacks vm-bridged)" >&2
            exit 2
        fi
        # First-run-wizard guard (matches wait-healthy.sh): never flip Global
        # NS to point at AGH if AGH hasn't completed its wizard yet — AGH
        # isn't listening for DNS in that state, and pointing the tailnet at
        # it would brick all tailnet DNS resolution.
        agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
        if [ ! -f "$agh_yaml" ] \
            || ! awk '/^[[:space:]]+bind_hosts:/{f=1; next} f && /^[[:space:]]+- /{print; exit}' \
                    "$agh_yaml" | grep -qE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b'; then
            echo "tailnet-dns: AGH wizard not yet complete — refusing to set Global NS"
            echo "  Complete wizard at http://${vm_ip}:3000 (see adguard/README.md), then re-run."
            exit 0
        fi
        target="[\"${vm_ip}\"]"
        ;;

    off)
        fallback="${TAILNET_DNS_FALLBACK:-1.1.1.1}"
        target="[\"${fallback}\"]"
        ;;
esac

if [ "$current" = "$target" ]; then
    echo "tailnet-dns: Global NS already ${target} — no change"
    exit 0
fi

echo "tailnet-dns: setting Global NS ${current} -> ${target}"
body="{\"dns\":${target}}"
resp="$(curl -fsS -X POST "${hdr[@]}" -d "$body" "$api" 2>&1)" || {
    echo "tailnet-dns: API POST failed: $resp" >&2
    echo "tailnet-dns: recover via https://login.tailscale.com/admin/dns (manual)" >&2
    exit 3
}
echo "$resp" | jq -r '.dns | @json'
```

**Verification:**

```bash
chmod +x stacks/adguard/scripts/tailnet-dns.sh

# Status — should print current Global NS JSON, exit 0
./stacks/adguard/scripts/tailnet-dns.sh status
echo "exit=$?"
# Expected: { "dns": ["..."], "magicDNSEnabled": true|false }, exit 0

# On — sets to bridged VM IP
./stacks/adguard/scripts/tailnet-dns.sh on
echo "exit=$?"
# Expected: "setting Global NS [...] -> [192.168.1.78]" or "already on, no change", exit 0

# Re-run on — idempotent (AC2.7)
./stacks/adguard/scripts/tailnet-dns.sh on
# Expected: "Global NS already [...] — no change", exit 0

# Off — sets to fallback (DOES affect tailnet — BUT we're about to flip back via `on` immediately)
./stacks/adguard/scripts/tailnet-dns.sh off
echo "exit=$?"
# Expected: "setting Global NS [...] -> [1.1.1.1]", exit 0

# Re-run off — idempotent
./stacks/adguard/scripts/tailnet-dns.sh off
# Expected: "already off, no change", exit 0

# Restore to AGH so other devices still benefit from filtering
./stacks/adguard/scripts/tailnet-dns.sh on
```

**Failure-mode tests:**

```bash
# AC2.8/AC2.9: Temporarily corrupt the PAT to simulate API failure
sed -i.bak 's/^TAILSCALE_PAT=tskey-api-.*/TAILSCALE_PAT=tskey-api-INVALID/' stacks/adguard/.env
./stacks/adguard/scripts/tailnet-dns.sh on; echo "exit=$?"
# Expected: "API GET failed: ..." + recovery hint, exit 3
# RESTORE
mv stacks/adguard/.env.bak stacks/adguard/.env
chmod 600 stacks/adguard/.env

# Verify restoration worked
./stacks/adguard/scripts/tailnet-dns.sh status
# Expected: clean JSON
```

**Commit:**
```bash
git add stacks/adguard/scripts/tailnet-dns.sh
git commit -m "adguard: add tailnet-dns.sh (toggle Global NS via Tailscale API)"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Wire `tailnet-dns-on/off/status` recipes + auto-hooks into `up`/`down`

**Verifies:** stack-resilience.AC2.4, stack-resilience.AC2.5, stack-resilience.AC2.8, stack-resilience.AC2.9

**Files:**
- Modify: `stacks/adguard/justfile`

**Implementation:**

Add three one-line delegations and modify the existing `up`/`down` recipes to invoke the hooks.

`stacks/adguard/justfile` currently has:
- Lines 13-14:
  ```just
  up: init
      docker --context {{context}} compose up -d
  ```
- Lines 16-17:
  ```just
  down:
      docker --context {{context}} compose down
  ```

Modify them to:

```just
up: init
    docker --context {{context}} compose up -d
    @./scripts/wait-healthy.sh && ./scripts/tailnet-dns.sh on

down:
    @./scripts/tailnet-dns.sh off
    docker --context {{context}} compose down
```

This honors the AC2.4/AC2.5 ordering:
- `up` brings the container up → waits for AGH to actually answer DNS → THEN flips Global NS to point at AGH. If `wait-healthy.sh` fails or `tailnet-dns.sh on` fails, the recipe exits non-zero with the script's error — AGH is left running (which is the right state — DNS just isn't yet failed-back).
- `down` flips Global NS to fallback FIRST → then runs `compose down`. If `tailnet-dns.sh off` fails (e.g., API unreachable), the `&&`-style ordering in `set -e`-mode just chains: just runs each line as a separate process. The way to enforce "don't run line 2 if line 1 failed" is to rely on just's per-recipe abort-on-error: just stops the recipe at the first failing line by default. Verify this behavior: `just` 1.13+ aborts at the first non-zero exit code. So if `tailnet-dns.sh off` exits 3, the `compose down` line never runs — AGH stays up — exactly the AC2.9 contract.

Add the three delegation recipes (one-line each per AC7.1) at the end of the file:

```just

tailnet-dns-on:
    @./scripts/tailnet-dns.sh on

tailnet-dns-off:
    @./scripts/tailnet-dns.sh off

tailnet-dns-status:
    @./scripts/tailnet-dns.sh status
```

**Verification:**

```bash
# AC2.3: status recipe via dotfiles
dotfiles stacks adguard tailnet-dns-status
# Expected: JSON output, exit 0

# AC2.4: up flips on AFTER wait-healthy
dotfiles stacks adguard tailnet-dns-off    # set NS to fallback first
dotfiles stacks adguard down               # bring AGH down (via the new down hook — should be no-op on tailnet-dns since we already off'd)
dotfiles stacks adguard up                 # bring up — wait-healthy polls, then tailnet-dns flips on
dotfiles stacks adguard tailnet-dns-status # verify NS is now bridged-VM IP
# Expected: NS is the bridged-VM IP

# AC2.5/AC2.6: down flips off BEFORE compose down — tailnet stays usable
dotfiles stacks adguard down               # NS flips to 1.1.1.1, then container stops
dotfiles stacks adguard tailnet-dns-status # NS should now be 1.1.1.1
dig example.com +short                     # Mac DNS should still work
# Expected: dig returns an A record (not "no servers could be reached")

# Restore — bring AGH back up
dotfiles stacks adguard up
dotfiles stacks adguard tailnet-dns-status
# Expected: NS is bridged-VM IP again
```

**Failure-mode tests:**

```bash
# AC2.9: simulate API failure during down — tailnet-dns.sh off fails, container stays up
sed -i.bak 's/^TAILSCALE_PAT=tskey-api-.*/TAILSCALE_PAT=tskey-api-INVALID/' stacks/adguard/.env
dotfiles stacks adguard down; echo "exit=$?"
# Expected: tailnet-dns API failure + recovery hint, exit 3
# AND THEN: container is STILL running (AGH not stopped)
docker --context colima-bridged ps --filter name=adguardhome
# Expected: adguardhome is Up

# Restore PAT and verify clean state
mv stacks/adguard/.env.bak stacks/adguard/.env
chmod 600 stacks/adguard/.env
dotfiles stacks adguard tailnet-dns-on   # ensure NS back on AGH
```

**Commit:**
```bash
git add stacks/adguard/justfile
git commit -m "adguard: hook tailnet-dns into up/down + add three delegation recipes"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Extend doctor with the AGH-NS state-consistency check

**Verifies:** Augments AC5.1 / AC5.2 (more checks).

**Files:**
- Modify: `stacks/scripts/doctor.sh`

**Implementation:**

Add a new `--- DNS failover ---` section after `--- Backups ---`. Single check:
- Get current Tailscale Global NS via `tailnet-dns.sh status` (parse JSON).
- Get AGH container state via `docker --context colima-bridged inspect adguardhome --format '{{.State.Running}}'`.
- Get bridged VM IP via the same colima awk idiom.
- Logical consistency:
  - AGH Up + NS = `[<vm-ip>]`: `pass`.
  - AGH Down + NS = `[<fallback>]`: `pass`.
  - AGH Up + NS != `[<vm-ip>]`: `warn` (might be an in-progress maintenance state, not a hard fail).
  - AGH Down + NS = `[<vm-ip>]`: `fail` ("DNS pointing at stopped AGH").
  - Anything else (e.g., NS empty): `warn`.

The check sources adguard's `.env` only to read `TAILNET_DNS_FALLBACK` (no PAT use here — `tailnet-dns.sh status` reads it itself). Keep doctor's "no `.env` value reads" rule (AC5.4) intact: doctor still doesn't read `TAILSCALE_PAT`. (Reading `TAILNET_DNS_FALLBACK` is a benign string compare, not a secret — but to stay strict with AC5.4, prefer to invoke `tailnet-dns.sh` to fetch the fallback rather than reading .env directly. The simplest correct path is to **defer to `tailnet-dns.sh status` for the current NS read** and to compare against a hardcoded list of "known-fallback IPs" the user is aware of, OR just check "AGH down → NS is anything other than the known VM IP".)

Pragmatic implementation that respects AC5.4:

```bash
echo
echo "--- DNS failover ---"

agh_state=$(docker --context colima-bridged inspect adguardhome \
    --format '{{.State.Running}}' 2>/dev/null || echo "false")
vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')

if [ -f "${HOME}/Developer/dotfiles/stacks/adguard/scripts/tailnet-dns.sh" ]; then
    ns_json=$(${HOME}/Developer/dotfiles/stacks/adguard/scripts/tailnet-dns.sh status 2>/dev/null \
        | jq -r '.dns | @json' 2>/dev/null || true)
else
    ns_json=""
fi

if [ -z "$ns_json" ]; then
    warn "tailnet-dns status unavailable (PAT missing or API unreachable)"
elif [ "$agh_state" = "true" ] && [ "$ns_json" = "[\"${vm_ip}\"]" ]; then
    pass "AGH Up + tailnet NS points at AGH (${vm_ip})"
elif [ "$agh_state" = "true" ] && [ "$ns_json" != "[\"${vm_ip}\"]" ]; then
    warn "AGH Up but tailnet NS = ${ns_json} (expected [\"${vm_ip}\"])"
elif [ "$agh_state" = "false" ] && [ "$ns_json" = "[\"${vm_ip}\"]" ]; then
    fail "AGH Down but tailnet NS still points at AGH — DNS bricked!"
else
    pass "AGH Down + tailnet NS pointed away from AGH (${ns_json})"
fi
```

Note: the script path `${HOME}/Developer/dotfiles/stacks/adguard/scripts/tailnet-dns.sh` is a touch hardcoded — better to resolve it relative to doctor.sh's own location. Use `${SCRIPT_DIR}/../adguard/scripts/tailnet-dns.sh`:

```bash
tailnet_dns="${SCRIPT_DIR}/../adguard/scripts/tailnet-dns.sh"
if [ -x "$tailnet_dns" ]; then
    ns_json=$("$tailnet_dns" status 2>/dev/null | jq -r '.dns | @json' 2>/dev/null || true)
else
    ns_json=""
fi
```

Use this resolved-path form in the actual script.

**Verification:**

```bash
dotfiles stacks doctor
# Expected: new --- DNS failover --- section with [OK] (AGH up + NS at AGH)

# Exercise the WARN path
dotfiles stacks adguard tailnet-dns-off
dotfiles stacks doctor
# Expected: [WARN] "AGH Up but tailnet NS = ..."
dotfiles stacks adguard tailnet-dns-on   # restore

# Restore
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0
```

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: check AGH state vs tailnet Global NS consistency"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Update `stacks/adguard/README.md` with the DNS failover section

**Verifies:** Supports AC7.4 (Phase 8 audit).

**Files:**
- Modify: `stacks/adguard/README.md`

**Implementation:**

Add a new `## DNS failover` section after `## First-run wizard` (before `## Manual steps not in the justfile`). Brief — the script and recipes are the operational surface.

```markdown
## DNS failover

`adguard up`/`down` automatically toggle the tailnet's Global Nameservers
between AGH (when up) and a public fallback (when down) so AGH maintenance
never strands devices on a dead resolver.

```sh
dotfiles stacks adguard tailnet-dns-status   # current Global NS JSON
dotfiles stacks adguard tailnet-dns-on       # set NS to bridged VM IP
dotfiles stacks adguard tailnet-dns-off      # set NS to TAILNET_DNS_FALLBACK
```

Setup:

1. Generate a Tailscale PAT at
   <https://login.tailscale.com/admin/settings/keys> with the `dns` scope
   (90-day expiry).
2. `cp .env.example .env && chmod 600 .env`; paste the PAT.

Why the API and not Tailscale's multi-resolver fallback: Tailscale's
client-side fallback ordering is unreliable on macOS
([tailscale#12677](https://github.com/tailscale/tailscale/issues/12677)),
so the only reliable mechanism is to **switch** Global NS as a deliberate
binary state. The CLI doesn't support this configuration
([tailscale#5430](https://github.com/tailscale/tailscale/issues/5430)),
so the API is the only path.

If `tailnet-dns` ever leaves the tailnet pointed at a dead AGH (PAT
expired, API outage), recover manually at
<https://login.tailscale.com/admin/dns>.

### First-time wizard

On a brand-new install, the very first `dotfiles stacks adguard up`
launches AGH in setup-wizard mode (only the `:3000` web UI is listening;
no DNS bind on `col0` yet). The new auto-hook detects this state via
`~/.volumes/adguard/conf/AdGuardHome.yaml` not containing a
`bind_hosts:` IP and **silently no-ops** instead of trying to flip
Tailscale Global NS at a non-listening server. Expected output of the
first `up`:

```
wait-healthy: AGH wizard not yet complete (no bind_hosts in ...)
  Complete the wizard at http://<vm-ip>:3000 (bind to col0 — see above).
  Then re-run: dotfiles stacks adguard restart
```

After completing the wizard (Listen interface = `col0`), run `dotfiles
stacks adguard restart` — the next `up` invocation finds `bind_hosts:`
populated, polls `dig`, and flips Global NS to AGH normally.

### Recovering from a half-down stack

`down-all` brings stacks down in DNS-aware order (apps before adguard).
If the adguard step fails because `tailnet-dns.sh off` can't reach the
Tailscale API (revoked PAT, network outage), the recipe halts with a
non-zero exit and AGH stays running — apps are already down. Recover:

```sh
dotfiles stacks adguard tailnet-dns-status   # diagnose API reachability
# either fix the PAT, or use the manual web-UI fallback at
# https://login.tailscale.com/admin/dns to set Global NS to 1.1.1.1
dotfiles stacks adguard down                 # retry the down (now succeeds)
```

`dotfiles stacks doctor`'s `--- DNS failover ---` check flags the
half-down state explicitly.
```

**Verification:**

Read the rendered file. Confirm the section sits between First-run wizard and Manual steps. Length is short, tone matches the rest of the README.

**Commit:**
```bash
git add stacks/adguard/README.md
git commit -m "adguard/README: document DNS failover (tailnet-dns)"
```
<!-- END_TASK_7 -->

---

## Done When

- `dotfiles stacks adguard tailnet-dns-status` prints the current Tailscale Global NS JSON.
- `dotfiles stacks adguard tailnet-dns-on` sets NS to the bridged-VM IP; re-run is a no-op (AC2.7 idempotent).
- `dotfiles stacks adguard tailnet-dns-off` sets NS to `1.1.1.1` (or `TAILNET_DNS_FALLBACK`); re-run is a no-op.
- `dotfiles stacks adguard down` flips NS to fallback BEFORE stopping the container; the Mac can `dig example.com` successfully while AGH is down (AC2.6 verified).
- `dotfiles stacks adguard up` waits for AGH to answer `dig` (`wait-healthy.sh`) and THEN flips NS back to AGH (AC2.4 verified).
- Failure-mode test: revoking/corrupting `TAILSCALE_PAT` makes both `up` and `down` exit 3 with the API error and a recovery hint; **AGH is not stopped during a failed `down`** (AC2.9 verified).
- `dotfiles stacks doctor` adds a `--- DNS failover ---` section, exits 0 when state is consistent, fails when AGH is Down + NS still points at AGH.
- Seven commits land: `.env.example`, `wait-healthy.sh`, `tailnet-dns.sh`, justfile recipe wire-up, doctor extension, README. (User's `.env` is gitignored, no commit for it.)
