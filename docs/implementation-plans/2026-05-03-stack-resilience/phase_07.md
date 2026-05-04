# Phase 7: Documentation hardening + pin generator + bootstrap fail-loudly

**Goal:** Bundle three robustness upgrades around existing pieces — (a) documentation that captures hidden invariants (CLAUDE.md "reproducible vs runtime", homebridge "pairing identity"), (b) a HomeKit pin generator that rejects reserved pins, (c) extracting the existing inline `bootstrap` recipes for wallabag and homebridge into `scripts/bootstrap.sh` files with a fail-loudly contract (explicit assumptions, structured exit codes, recovery hints).

**Architecture:** Each existing inline `bootstrap` recipe in `stacks/wallabag/justfile` and `stacks/homebridge/justfile` moves into `scripts/bootstrap.sh` with an added preamble that validates assumptions before the existing logic runs (FOSUserBundle command exists; default `wallabag` user state is sane; auth.json/setup-wizard expectation matches what the script assumes). Exit codes: `0=success`, `1=unexpected-state`, `2=missing-prereq`, `3=upstream-API-error`. The justfile recipes become one-line delegations. The pin generator (`stacks/homebridge/scripts/gen-pin.sh`) is a small bash script that loops random 8-digit pins until non-reserved.

**Tech Stack:** bash + jq + curl (already in the existing recipes), no new dependencies. HomeKit reserved-pin list (12 entries — confirmed by community implementations: openHAB, HomeSpan, Homebridge implementations).

**Scope:** Phase 7 of 8. Depends on Phase 1 (doctor — for the new homebridge identity check).

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC5: Sanity recipes
- **stack-resilience.AC5.4 Success:** `doctor` never reads any `.env` value — only counts keys via `grep -c '^KEY='` and similar (auditable from script source). *(Phase 7 ships the first .env-key-presence check, exercising the contract.)*
- **stack-resilience.AC5.8 Success:** `doctor` warns/fails when homebridge `BRIDGE_USERNAME` from `.env` doesn't match `~/.volumes/homebridge/config.json` `bridge.username`.
- **stack-resilience.AC5.9 Failure:** Homebridge `bootstrap` invoked when `setupWizardComplete: true` AND `auth.json` lacks `ADMIN_USERNAME` exits with code 1 and prints "detected X but expected Y" + a one-line recovery hint.
- **stack-resilience.AC5.10 Failure:** Wallabag `bootstrap` invoked when default `wallabag` user is already deactivated AND `ADMIN_USERNAME` user does not exist exits with code 1 + description + recovery hint.
- **stack-resilience.AC5.11 Failure:** Bootstrap recipes exit with code 2 when prerequisites are missing (env key absent, container not running, API unreachable for preflight); code 3 when an upstream API/CLI returns an error during the actual bootstrap operation.

### stack-resilience.AC6: Documentation hardening + pin generator validation
- **stack-resilience.AC6.1 Success:** `CLAUDE.md` contains a "Reproducible vs runtime" section enumerating what's in repo vs runtime/environment.
- **stack-resilience.AC6.2 Success:** `CLAUDE.md` has a note about Colima first-start config mutations being expected (rare lifecycle event, not runtime churn) and that we commit them.
- **stack-resilience.AC6.3 Success:** `stacks/homebridge/README.md` has a "Pairing identity" section explaining `BRIDGE_USERNAME` and `HOMEKIT_PIN` are pairing-identity-critical, never regenerate after pairing, restoring `~/.volumes/homebridge/` is the only "same identity" path.
- **stack-resilience.AC6.4 Success:** `stacks/homebridge/scripts/gen-pin.sh` exists and produces valid `XXX-XX-XXX` 8-digit pins on stdout.
- **stack-resilience.AC6.5 Failure:** Running `gen-pin.sh` 100 times in a loop produces zero pins matching the 12-entry HomeKit reserved list.
- **stack-resilience.AC6.6 Success:** `stacks/homebridge/.env.example` `HOMEKIT_PIN` comment references `gen-pin.sh` as the canonical generator.

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.3 Success:** `stacks/wallabag/scripts/{bootstrap.sh}`, `stacks/homebridge/scripts/{bootstrap.sh, gen-pin.sh}` exist.

---

## Operational Context (read before executing)

This phase **mostly authors documentation and small scripts**. The bootstrap-extraction tasks (3 and 4) preserve the existing logic byte-for-byte — they wrap the existing body in a fail-loudly preamble and move it into a script file. The user's existing wallabag admin account and homebridge pairing are unaffected.

**The pin generator does NOT change the user's currently-paired pin.** It's a new tool for future setups. The user's existing `HOMEKIT_PIN=031-45-154` in `.env` remains and is not on the reserved list (verified — `031-45-154` is neither a repeating-digit pattern nor `123-45-678`/`876-54-321`).

**Pre-flight (verify before starting):**
- All previous phases complete. `dotfiles stacks doctor` is all-green.
- Both wallabag and homebridge bootstrap recipes work today (verified at original setup time; not re-run for this phase).

---

<!-- START_TASK_1 -->
### Task 1: Add "Reproducible vs runtime" section + Colima-mutation note to `CLAUDE.md`

**Verifies:** stack-resilience.AC6.1, stack-resilience.AC6.2

**Files:**
- Modify: `CLAUDE.md`

**Implementation:**

Insert two new sections in `CLAUDE.md`. After the existing `## Repo shape` section (currently lines 5-19), add:

```markdown
## Reproducible vs runtime

What's in the repo vs what's environment-specific:

| In repo (tracked) | Runtime / environment (gitignored or external) |
|---|---|
| `stacks/<stack>/{justfile, compose.yaml, README.md, .env.example}` | `stacks/<stack>/.env` (mode 0600) |
| `stacks/<stack>/scripts/*.sh` | Container state inside Colima VMs |
| `stacks/<stack>/conf/...` templates (e.g., `homebridge/config.json.template`) | Live files under `~/.volumes/<stack>/` |
| `stow/<package>/...` | Stowed symlinks under `$HOME` |
| `stow/colima/.colima/<profile>/colima.yaml` | Live VM disks under `~/.colima/_lima/`, qemu MAC, DHCP-leased IP |
| `~/.volume-backups/` is gitignored | Tarballs accumulate locally; restore via `stacks <stack> restore` |
| `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` is per-machine | Installed by `dotfiles stacks backup-install` |

Things that look like "runtime drift" but are actually fine:
- Bridged VM IP changing rarely (router reservation pins it; `dotfiles
  stacks bridged-ip-changed` re-coordinates everything else).
- Tailscale Global Nameservers being toggled by `tailnet-dns-on/off` —
  not configuration drift, an intentional state machine.

## Colima first-start config mutations

When you first `colima start -p <profile>`, Colima rewrites the stowed
`colima.yaml` to add resolved fields (the `vmnet` socket path, the user's
home dir absolute path, etc.). This is a one-time lifecycle event, NOT
runtime churn:

- The mutated yaml IS committed to the repo when it changes (`stow
  restow` keeps the symlink pointing at the repo file, so `git diff` shows
  the new resolved fields after first start on a fresh device).
- Subsequent `colima start`/`stop`/`restart` do NOT mutate the yaml.
- If `colima.yaml` shows up in `git status` after a routine restart on
  an existing setup, that's a regression worth investigating — Colima is
  not supposed to rewrite the file outside of first-start.
```

**Verification:**

```bash
grep -c "Reproducible vs runtime" CLAUDE.md
# Expected: 1
grep -c "Colima first-start config mutations" CLAUDE.md
# Expected: 1
```

Read the rendered file. Confirm the table makes sense and the second section is short + operationally useful.

**Commit:**
```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: add reproducible-vs-runtime + Colima-mutation sections"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Add "Pairing identity" section to `stacks/homebridge/README.md`

**Verifies:** stack-resilience.AC6.3

**Files:**
- Modify: `stacks/homebridge/README.md`

**Implementation:**

Add a new `## Pairing identity` section near the top of the README, after the introductory paragraph (line 6) and before `## Fresh-device setup` (line 8):

```markdown
## Pairing identity

`BRIDGE_USERNAME` (a MAC-format ID) and `HOMEKIT_PIN` are pairing-identity
critical. Once HomeKit accessories are paired against a bridge with a
specific `BRIDGE_USERNAME` + `HOMEKIT_PIN`, those values become permanent
identifiers in the user's iOS Home database.

**Never regenerate `BRIDGE_USERNAME` or `HOMEKIT_PIN` on a paired
bridge.** Doing so silently breaks the HomeKit pairing — accessories
appear "responding" in Home but commands silently fail, until the user
deletes the bridge from Home and re-pairs every accessory.

Restoring `~/.volumes/homebridge/` from a backup is the **only** path that
preserves the pairing identity across a device move:

```sh
# On the old device
dotfiles stacks homebridge backup    # writes ~/.volume-backups/daily/homebridge-YYYY-MM-DD.tgz

# On the new device, before first homebridge up
dotfiles stacks homebridge restore /path/to/homebridge-YYYY-MM-DD.tgz --force
dotfiles stacks homebridge up        # init sees existing config.json, doesn't reseed
```

`config.json` (rendered from `config.json.template` at first `up` via
envsubst) bakes `BRIDGE_USERNAME`, `HOMEKIT_PIN`, and `HAP_PORT` into the
runtime config. The init recipe is intentionally idempotent — it skips
re-seeding if `config.json` already exists, so restoring a backup before
first `up` is the right pattern.
```

**Verification:**

Read the rendered file. Confirm the new section sits between the intro and the `## Fresh-device setup` table. Cross-check that the existing "Reproducibility on a new device" section (currently lines 64-83) doesn't contradict this — it actually reinforces the same point. Consider rewording to mention that `## Pairing identity` is the canonical statement and "Reproducibility on a new device" is the operational walkthrough.

```bash
grep -c "Pairing identity" stacks/homebridge/README.md
# Expected: 1
grep -c "BRIDGE_USERNAME" stacks/homebridge/README.md
# Expected: at least 3 (existing references + new section)
```

**Commit:**
```bash
git add stacks/homebridge/README.md
git commit -m "homebridge/README: add Pairing identity section"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `stacks/homebridge/scripts/gen-pin.sh` (HomeKit setup-pin generator)

**Verifies:** stack-resilience.AC6.4, stack-resilience.AC6.5

**Files:**
- Create: `stacks/homebridge/scripts/gen-pin.sh` (executable, mode 755)

**Implementation:**

Loop random 8-digit pins formatted as `XXX-XX-XXX` until one isn't on the 12-entry reserved list. Print to stdout exactly one pin per invocation. Exit 0 on success.

Reserved list (12 entries — confirmed across openHAB / HomeSpan / Homebridge community implementations):
- `000-00-000`, `111-11-111`, `222-22-222`, `333-33-333`, `444-44-444`, `555-55-555`, `666-66-666`, `777-77-777`, `888-88-888`, `999-99-999`
- `123-45-678`
- `876-54-321`

Random source: `$RANDOM` is fine (zsh/bash both expose it; quality is sufficient for setup-code generation, which is sub-1-bit-of-entropy-per-digit before the reserved-pin filter anyway).

```bash
#!/usr/bin/env bash
# stacks/homebridge/scripts/gen-pin.sh
# Generate a HomeKit setup pin (XXX-XX-XXX) that is NOT on Apple's reserved
# list. Prints exactly one pin per invocation. Use to seed HOMEKIT_PIN in
# stacks/homebridge/.env on a fresh setup.
set -euo pipefail

reserved=(
    000-00-000 111-11-111 222-22-222 333-33-333 444-44-444
    555-55-555 666-66-666 777-77-777 888-88-888 999-99-999
    123-45-678 876-54-321
)

is_reserved() {
    local pin="$1" r
    for r in "${reserved[@]}"; do
        if [ "$pin" = "$r" ]; then return 0; fi
    done
    return 1
}

while true; do
    # Generate 8 random digits as 3-2-3 grouping
    a=$(printf '%03d' "$((RANDOM % 1000))")
    b=$(printf '%02d' "$((RANDOM % 100))")
    c=$(printf '%03d' "$((RANDOM % 1000))")
    pin="${a}-${b}-${c}"
    if ! is_reserved "$pin"; then
        echo "$pin"
        exit 0
    fi
done
```

**Verification:**

```bash
chmod +x stacks/homebridge/scripts/gen-pin.sh

# Single invocation
./stacks/homebridge/scripts/gen-pin.sh
# Expected: a pin like "248-31-907", exit 0

# Format check
pin=$(./stacks/homebridge/scripts/gen-pin.sh)
echo "$pin" | grep -E '^[0-9]{3}-[0-9]{2}-[0-9]{3}$' && echo "format OK"
# Expected: "format OK"

# AC6.5: 100 invocations, zero reserved pins
matches=0
for i in $(seq 1 100); do
    pin=$(./stacks/homebridge/scripts/gen-pin.sh)
    case "$pin" in
        000-00-000|111-11-111|222-22-222|333-33-333|444-44-444|555-55-555|666-66-666|777-77-777|888-88-888|999-99-999|123-45-678|876-54-321)
            matches=$((matches + 1))
            ;;
    esac
done
echo "reserved matches in 100 runs: $matches"
# Expected: "reserved matches in 100 runs: 0"
```

**Commit:**
```bash
git add stacks/homebridge/scripts/gen-pin.sh
git commit -m "homebridge: add gen-pin.sh (rejects HomeKit reserved pins)"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Update `stacks/homebridge/.env.example` to reference `gen-pin.sh`

**Verifies:** stack-resilience.AC6.6

**Files:**
- Modify: `stacks/homebridge/.env.example`

**Implementation:**

Currently lines 11-12 of `stacks/homebridge/.env.example`:
```
# HAP_PORT — port for the HomeKit Accessory Protocol server (any free port).
# HOMEKIT_PIN — 8-digit setup pin in XXX-XX-XXX format used during pairing.
```

Change line 12 to add the gen-pin.sh reference:
```
# HOMEKIT_PIN — 8-digit setup pin in XXX-XX-XXX format used during pairing.
#   Generate with: ./scripts/gen-pin.sh (rejects HomeKit reserved pins).
#   DO NOT regenerate after pairing — see "Pairing identity" in README.
```

**Verification:**

```bash
grep -c "gen-pin.sh" stacks/homebridge/.env.example
# Expected: 1
grep -c "Pairing identity" stacks/homebridge/.env.example
# Expected: 1
```

**Commit:**
```bash
git add stacks/homebridge/.env.example
git commit -m "homebridge/.env.example: point HOMEKIT_PIN at gen-pin.sh"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Extract wallabag bootstrap to `stacks/wallabag/scripts/bootstrap.sh` with fail-loudly contract

**Verifies:** stack-resilience.AC5.10, stack-resilience.AC5.11

**Files:**
- Create: `stacks/wallabag/scripts/bootstrap.sh` (executable, mode 755)
- Modify: `stacks/wallabag/justfile` (recipe becomes one-line delegation)

**Implementation:**

Existing recipe body (`stacks/wallabag/justfile` lines 32-55) does:
1. Source `.env`.
2. Wait for wallabag to respond at `/api/info`.
3. `fos:user:create $ADMIN_USERNAME $ADMIN_EMAIL $ADMIN_PASSWORD --super-admin --env=prod -n` (with `|| echo "(user already exists; skipping)"`).
4. If `$ADMIN_USERNAME` != "wallabag", `fos:user:deactivate wallabag --env=prod -n` (with `|| echo "..."`).
5. Print success message.

Extract into `stacks/wallabag/scripts/bootstrap.sh` with these additions:

**Preflight (exit 2 on missing prereq):**
- `.env` exists.
- `ADMIN_USERNAME`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` are non-empty in env.
- wallabag container is currently running on `colima-shared`.

**Unexpected-state check (exit 1):**
- Query `fos:user:list` early. Detect the case where the default `wallabag` user is **deactivated** AND the configured `ADMIN_USERNAME` does **not** exist. This is the AC5.10 scenario — the previous run partially completed (deactivated default but failed to create admin), and a naive re-run would result in nobody being able to log in. Print "detected X but expected Y" with a clear recovery hint: "edit .env to revert ADMIN_USERNAME to a known account, OR docker exec into the container and re-activate the wallabag user manually with `bin/console fos:user:activate wallabag --env=prod`".

**Bootstrap (exit 3 on FOSUserBundle CLI failure):**
- The fos:user:create + deactivate logic from the existing recipe, but with explicit error capture: if `fos:user:create` fails for any reason **other than** "user already exists", exit 3 with the captured stderr.
- "User already exists" detection: FOSUserBundle's create command exits non-zero with stderr including "Username already in use" or similar. Match against that to silently treat as success (idempotency).

```bash
#!/usr/bin/env bash
# stacks/wallabag/scripts/bootstrap.sh
# Replace the hardcoded default `wallabag:wallabag` admin with credentials
# from .env. Fail-loudly: structured exit codes + recovery hints.
#
# Exit codes:
#   0 — success (bootstrap done, or already done idempotently)
#   1 — unexpected state (script can't safely proceed without human input)
#   2 — missing prerequisite (.env, env keys, container)
#   3 — upstream CLI failure (FOSUserBundle errored during operation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
context="colima-shared"

# --- Preflight: .env + required keys ---
if [ ! -f "$env_file" ]; then
    echo "wallabag bootstrap: ${env_file} missing" >&2
    echo "  recover: cp .env.example .env && chmod 600 .env && edit ADMIN_*" >&2
    exit 2
fi
# shellcheck disable=SC1090
set -a; source "$env_file"; set +a

for key in ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD; do
    if [ -z "${!key:-}" ]; then
        echo "wallabag bootstrap: ${key} not set in ${env_file}" >&2
        echo "  recover: edit .env, set ${key}=..." >&2
        exit 2
    fi
done

# --- Preflight: container running ---
if ! docker --context "$context" compose ps --status running 2>/dev/null \
        | grep -q wallabag; then
    echo "wallabag bootstrap: wallabag container not running on ${context}" >&2
    echo "  recover: dotfiles stacks wallabag up" >&2
    exit 2
fi

# --- Wait for HTTP API ---
echo "Waiting for wallabag to respond..."
deadline=$(($(date +%s) + 180))
until docker --context "$context" compose exec -T wallabag \
        curl -fs --user-agent healthcheck http://localhost/api/info >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "wallabag bootstrap: API did not become ready within 180s" >&2
        echo "  recover: check 'dotfiles stacks wallabag logs'" >&2
        exit 2
    fi
    sleep 2
done

# --- Unexpected-state check (AC5.10) ---
# List users. Look for two states:
# - default "wallabag" user is present and ENABLED
# - configured ADMIN_USERNAME user is present
user_list=$(docker --context "$context" compose exec -T wallabag \
    bin/console fos:user:list --env=prod 2>/dev/null || true)

# fos:user:list output format includes username on each line; "(disabled)"
# suffix when deactivated. Exact format may vary across wallabag versions
# — match conservatively.
default_present=$(echo "$user_list" | grep -E '^wallabag\b' || true)
default_active=$(echo "$default_present" | grep -v 'disabled' || true)
admin_present=$(echo "$user_list" | grep -E "^${ADMIN_USERNAME}\b" || true)

# AC5.10: default wallabag deactivated AND configured admin missing → fatal
if [ -n "$default_present" ] && [ -z "$default_active" ] && [ -z "$admin_present" ]; then
    cat >&2 <<EOF
wallabag bootstrap: detected default 'wallabag' user is deactivated AND
                    configured admin '${ADMIN_USERNAME}' does not exist.
                    No active user will exist if we proceed.

  recover: docker --context ${context} compose exec wallabag \\
              bin/console fos:user:activate wallabag --env=prod
           ...then re-run bootstrap, or set ADMIN_USERNAME=wallabag in .env.
EOF
    exit 1
fi

# --- Create admin (idempotent) ---
echo "Creating admin user '${ADMIN_USERNAME}'..."
create_rc=0
create_out=$(docker --context "$context" compose exec -T wallabag \
    bin/console fos:user:create "$ADMIN_USERNAME" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
        --super-admin --env=prod -n 2>&1) || create_rc=$?

if [ "$create_rc" -ne 0 ]; then
    if echo "$create_out" | grep -qiE '(already in use|already exists)'; then
        echo "  user '${ADMIN_USERNAME}' already exists — skipping create"
    else
        echo "wallabag bootstrap: fos:user:create failed (exit ${create_rc})" >&2
        echo "$create_out" >&2
        echo "  recover: investigate above stderr; this is an upstream CLI failure" >&2
        exit 3
    fi
fi

# --- Deactivate default (idempotent, only if ADMIN_USERNAME != wallabag) ---
if [ "$ADMIN_USERNAME" != "wallabag" ]; then
    echo "Deactivating default 'wallabag' user..."
    deact_rc=0
    deact_out=$(docker --context "$context" compose exec -T wallabag \
        bin/console fos:user:deactivate wallabag --env=prod -n 2>&1) || deact_rc=$?
    if [ "$deact_rc" -ne 0 ]; then
        if echo "$deact_out" | grep -qiE '(already.*disabled|not found)'; then
            echo "  default 'wallabag' user already deactivated or removed — skipping"
        else
            echo "wallabag bootstrap: fos:user:deactivate failed (exit ${deact_rc})" >&2
            echo "$deact_out" >&2
            exit 3
        fi
    fi
fi

echo "Bootstrap complete. Log in at https://${PUBLIC_HOST}:${PUBLIC_PORT} as '${ADMIN_USERNAME}'."
exit 0
```

**Modify `stacks/wallabag/justfile`:** replace the existing `bootstrap` recipe (lines 32-55) with a one-line delegation:

```just
bootstrap:
    @./scripts/bootstrap.sh
```

**Verification:**

```bash
chmod +x stacks/wallabag/scripts/bootstrap.sh

# Idempotent re-run on healthy state — should report "user already exists; skipping"
dotfiles stacks wallabag bootstrap
echo "exit=$?"
# Expected: exit 0, "user already exists" + "default already deactivated"

# AC5.11 — remove a required env key, expect exit 2
sed -i.bak 's/^ADMIN_USERNAME=.*/ADMIN_USERNAME=/' stacks/wallabag/.env
dotfiles stacks wallabag bootstrap; echo "exit=$?"
# Expected: "ADMIN_USERNAME not set" + recovery hint, exit 2
mv stacks/wallabag/.env.bak stacks/wallabag/.env
chmod 600 stacks/wallabag/.env

# AC5.10 — synthetic test of the unexpected-state branch.
# This requires temporarily breaking state in a recoverable way:
# 1. Confirm current state: ADMIN_USERNAME exists + active; wallabag default
#    deactivated.
# 2. To exercise AC5.10, you'd need to delete the admin user AND keep
#    wallabag deactivated. fos:user has no `delete`, so the cleanest test
#    is: temporarily change ADMIN_USERNAME in .env to a NEW name that
#    doesn't exist, AND ensure wallabag is deactivated (it is, by default).
sed -i.bak 's/^ADMIN_USERNAME=.*/ADMIN_USERNAME=fictitious_test_admin/' \
    stacks/wallabag/.env
dotfiles stacks wallabag bootstrap; echo "exit=$?"
# Expected: exit 1, with the AC5.10 message
#   "detected default 'wallabag' user is deactivated AND configured admin
#    'fictitious_test_admin' does not exist"
# plus the recovery hint pointing at fos:user:activate. The script runs the
# unexpected-state check BEFORE attempting fos:user:create, so it catches
# this scenario without first creating fictitious_test_admin.
mv stacks/wallabag/.env.bak stacks/wallabag/.env
chmod 600 stacks/wallabag/.env
# RESTORE: re-run normal bootstrap to confirm no damage
dotfiles stacks wallabag bootstrap
# Expected: clean exit 0, original admin still present
```

**Commit:**
```bash
git add stacks/wallabag/scripts/bootstrap.sh stacks/wallabag/justfile
git commit -m "wallabag: extract bootstrap to script with fail-loudly contract"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Extract homebridge bootstrap to `stacks/homebridge/scripts/bootstrap.sh` with fail-loudly contract

**Verifies:** stack-resilience.AC5.9, stack-resilience.AC5.11

**Files:**
- Create: `stacks/homebridge/scripts/bootstrap.sh` (executable, mode 755)
- Modify: `stacks/homebridge/justfile` (recipe becomes one-line delegation)

**Implementation:**

Existing recipe body (`stacks/homebridge/justfile` lines 54-85) does:
1. Source `.env`.
2. Verify `jq` is on host.
3. Resolve bridged VM IP via colima awk.
4. Wait for `/api/auth/settings` to respond.
5. Check `setupWizardComplete` — if true, exit 0 silently.
6. Otherwise: GET setup-wizard token, POST create-first-user.

Extract into `stacks/homebridge/scripts/bootstrap.sh` adding:

**Preflight (exit 2):**
- `.env` exists; `ADMIN_USERNAME`, `ADMIN_PASSWORD` non-empty.
- `jq` on PATH.
- Bridged VM running.
- `/api/auth/settings` reachable.

**Unexpected-state check (AC5.9, exit 1):**
- After fetching auth settings, if `setupWizardComplete: true` BUT `auth.json` is missing the configured `ADMIN_USERNAME`: this is the partial-completion case. Read `auth.json` (which is a JSON array of user records under `~/.volumes/homebridge/auth.json`) and check whether ADMIN_USERNAME appears in the `username` field of any record. If wizard is complete and admin missing → exit 1.

**Bootstrap (exit 3):**
- The existing token + create-first-user logic. Wrap each curl call in error capture; if a 4xx/5xx is returned, exit 3 with the body + recovery hint.

```bash
#!/usr/bin/env bash
# stacks/homebridge/scripts/bootstrap.sh
# Complete the Config UI X setup wizard non-interactively, creating the
# admin user from ADMIN_* in .env. Fail-loudly: structured exit codes +
# recovery hints.
#
# Exit codes:
#   0 — success (bootstrap done, or wizard already complete idempotently)
#   1 — unexpected state (script can't safely proceed without human input)
#   2 — missing prerequisite (.env, env keys, jq, container, API)
#   3 — upstream API failure (Config UI X HTTP error)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"

# --- Preflight ---
if [ ! -f "$env_file" ]; then
    echo "homebridge bootstrap: ${env_file} missing" >&2
    echo "  recover: cp .env.example .env && chmod 600 .env && edit ADMIN_*" >&2
    exit 2
fi
# shellcheck disable=SC1090
set -a; source "$env_file"; set +a

for key in ADMIN_USERNAME ADMIN_PASSWORD INTERNAL_PORT PUBLIC_HOST PUBLIC_PORT; do
    if [ -z "${!key:-}" ]; then
        echo "homebridge bootstrap: ${key} not set in ${env_file}" >&2
        exit 2
    fi
done

if ! command -v jq >/dev/null 2>&1; then
    echo "homebridge bootstrap: jq not on PATH (brew install jq)" >&2
    exit 2
fi

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "homebridge bootstrap: bridged VM not running" >&2
    echo "  recover: dotfiles stacks vm-bridged" >&2
    exit 2
fi

base="http://${vm_ip}:${INTERNAL_PORT}"

# --- Wait for API ---
echo "Waiting for Homebridge UI at ${base} ..."
deadline=$(($(date +%s) + 180))
until curl -fs "${base}/api/auth/settings" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "homebridge bootstrap: UI did not become ready within 180s" >&2
        echo "  recover: dotfiles stacks homebridge logs" >&2
        exit 2
    fi
    sleep 2
done

# --- Read wizard state ---
settings=$(curl -fs "${base}/api/auth/settings")
wizard_done=$(echo "$settings" | jq -r '.env.setupWizardComplete')

# --- Idempotent already-bootstrapped path ---
if [ "$wizard_done" = "true" ]; then
    # AC5.9: but check that auth.json contains ADMIN_USERNAME — otherwise
    # we're in the partial-completion case where wizard ran but the user
    # we expected isn't there.
    auth_json="${HOME}/.volumes/homebridge/auth.json"
    if [ ! -f "$auth_json" ]; then
        cat >&2 <<EOF
homebridge bootstrap: detected setupWizardComplete=true but auth.json is
                      missing at ${auth_json}.
  recover: stop homebridge, restore from backup, or remove
           ~/.volumes/homebridge/auth.json + ~/.volumes/homebridge/.uix-secrets
           and re-run bootstrap (will re-trigger setup wizard).
EOF
        exit 1
    fi
    if ! jq -e --arg u "$ADMIN_USERNAME" 'any(.username == $u)' \
            "$auth_json" >/dev/null; then
        cat >&2 <<EOF
homebridge bootstrap: detected setupWizardComplete=true but auth.json
                      lacks user '${ADMIN_USERNAME}'.
  Existing users in auth.json:
$(jq -r 'map("    " + .username) | .[]' "$auth_json")
  recover: log in as one of the above and create '${ADMIN_USERNAME}' via
           the UI, OR remove ~/.volumes/homebridge/auth.json and
           ~/.volumes/homebridge/.uix-secrets and re-run bootstrap.
EOF
        exit 1
    fi
    echo "Setup wizard already complete and ${ADMIN_USERNAME} present — nothing to do."
    exit 0
fi

# --- Run the wizard ---
echo "Running setup wizard for user '${ADMIN_USERNAME}'..."
token_resp=$(curl -fsS "${base}/api/setup-wizard/get-setup-wizard-token" 2>&1) || {
    echo "homebridge bootstrap: setup-wizard token endpoint failed: ${token_resp}" >&2
    echo "  recover: investigate; check homebridge logs" >&2
    exit 3
}
token=$(echo "$token_resp" | jq -r '.access_token')
if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "homebridge bootstrap: empty access_token from setup-wizard endpoint" >&2
    echo "$token_resp" >&2
    exit 3
fi

create_resp=$(curl -fsS -X POST "${base}/api/setup-wizard/create-first-user" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" \
            '{username:$u, password:$p, name:$u, admin:true}')" 2>&1) || {
    echo "homebridge bootstrap: create-first-user endpoint failed: ${create_resp}" >&2
    exit 3
}

echo "Bootstrap complete. Log in at https://${PUBLIC_HOST}:${PUBLIC_PORT} as '${ADMIN_USERNAME}'."
exit 0
```

**Modify `stacks/homebridge/justfile`:** replace the bootstrap recipe (lines 49-85) with:

```just
bootstrap:
    @./scripts/bootstrap.sh
```

**Verification:**

```bash
chmod +x stacks/homebridge/scripts/bootstrap.sh

# Idempotent re-run — wizard already complete + admin present
dotfiles stacks homebridge bootstrap
echo "exit=$?"
# Expected: "Setup wizard already complete..." exit 0

# AC5.11 — break .env, expect exit 2
sed -i.bak 's/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=/' stacks/homebridge/.env
dotfiles stacks homebridge bootstrap; echo "exit=$?"
# Expected: "ADMIN_PASSWORD not set" + recovery hint, exit 2
mv stacks/homebridge/.env.bak stacks/homebridge/.env
chmod 600 stacks/homebridge/.env

# AC5.9 — synthesize the unexpected-state branch.
# Set ADMIN_USERNAME in .env to a value that doesn't exist in auth.json:
sed -i.bak 's/^ADMIN_USERNAME=.*/ADMIN_USERNAME=fictitious_admin/' stacks/homebridge/.env
dotfiles stacks homebridge bootstrap; echo "exit=$?"
# Expected: "setupWizardComplete=true but auth.json lacks user 'fictitious_admin'"
#           + list of existing users + recovery hint, exit 1
mv stacks/homebridge/.env.bak stacks/homebridge/.env
chmod 600 stacks/homebridge/.env
# Restore by re-running with original ADMIN_USERNAME
dotfiles stacks homebridge bootstrap
# Expected: clean exit 0
```

**Commit:**
```bash
git add stacks/homebridge/scripts/bootstrap.sh stacks/homebridge/justfile
git commit -m "homebridge: extract bootstrap to script with fail-loudly contract"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Extend doctor with homebridge identity check + .env-keys-presence check

**Verifies:** stack-resilience.AC5.4, stack-resilience.AC5.8

**Files:**
- Modify: `stacks/scripts/doctor.sh`

**Implementation:**

Add a new `--- Stack identity & env ---` section after `--- IP coupling ---`. Two checks per stack where applicable:

**Check A (homebridge only): pairing identity intact.**
- `BRIDGE_USERNAME` from `~/.volumes/homebridge/.env` (presence, NOT value — for the comparison we DO need the value, but this is one of the few cases where reading is required for an integrity check; the AC5.4 prohibition is on doctor reading values that could be secrets, and `BRIDGE_USERNAME` is a MAC address, not a secret).

Actually — re-reading AC5.4 carefully: "doctor never reads any `.env` value — only counts keys via `grep -c '^KEY='`". Strict reading prevents AC5.8 from being implementable inside doctor (the check requires reading the BRIDGE_USERNAME value).

Reconcile this design conflict: AC5.4 was written to keep doctor auditable (no leakage, no surprises). For AC5.8, the value being read is the homebridge BRIDGE_USERNAME — a MAC-format pairing identifier, which the user already knows is not a secret (it's the public side of the pairing). The pragmatic resolution:

- doctor MAY read `BRIDGE_USERNAME` from homebridge `.env` for AC5.8.
- doctor MAY NEVER read `ADMIN_PASSWORD`, `WALLABAG_SECRET`, `TAILSCALE_PAT`, `ADMIN_API_PASSWORD`, etc.
- This exception is documented as a comment in doctor.sh next to the read.

This is the correct interpretation of AC5.4 — "auditable from script source" means no surprise reads, and the BRIDGE_USERNAME exception is explicit and source-visible.

**Check B (all four stacks): `.env` files have all keys from `.env.example`.**
For each `<stack>` where `.env.example` exists (all 4 after Phase 5):
- For each `KEY=` line in `.env.example`: confirm `grep -c '^KEY=' .env` returns ≥1.
- Use `grep -c '^[A-Z_]*='` to extract keys (no value reads).

```bash
echo
echo "--- Stack identity & env ---"

# Check B: env-key presence (no value reads, AC5.4-compliant)
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
for stack in adguard freshrss homebridge wallabag; do
    example="${repo_root}/stacks/${stack}/.env.example"
    actual="${repo_root}/stacks/${stack}/.env"
    if [ ! -f "$example" ]; then
        # adguard had no .env.example before Phase 5 — so .example may or may
        # not exist depending on plan progress. Skip gracefully.
        continue
    fi
    if [ ! -f "$actual" ]; then
        warn "${stack}/.env missing (run: cp .env.example .env && chmod 600 .env)"
        continue
    fi
    # Count keys per file (just the LHS of `=`, ignore comments)
    expected_keys=$(grep -E '^[A-Z][A-Z0-9_]*=' "$example" | sed 's/=.*//' | sort -u)
    missing=()
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -qE "^${key}=" "$actual"; then
            missing+=("$key")
        fi
    done <<< "$expected_keys"
    if [ "${#missing[@]}" -eq 0 ]; then
        pass "${stack}/.env has all keys from .env.example"
    else
        fail "${stack}/.env missing keys: ${missing[*]}"
    fi
done

# Check A: homebridge BRIDGE_USERNAME matches config.json bridge.username
hb_env="${repo_root}/stacks/homebridge/.env"
hb_config="${HOME}/.volumes/homebridge/config.json"
if [ -f "$hb_env" ] && [ -f "$hb_config" ]; then
    # NOTE: Per AC5.4 doctor avoids reading .env *secret* values. BRIDGE_USERNAME
    # is the public MAC-format pairing identifier, not a secret. This read is
    # required to verify AC5.8 (pairing identity coherence). Do not extend this
    # to other .env keys without revisiting AC5.4.
    bridge_env=$(grep -E '^BRIDGE_USERNAME=' "$hb_env" | cut -d= -f2-)
    bridge_config=$(jq -r '.bridge.username' "$hb_config")
    if [ "$bridge_env" = "$bridge_config" ]; then
        pass "homebridge BRIDGE_USERNAME matches config.json bridge.username"
    else
        fail "homebridge BRIDGE_USERNAME (.env=${bridge_env}) != config.json (${bridge_config}) — pairing will break"
    fi
fi
```

**Verification:**

```bash
dotfiles stacks doctor
# Expected: --- Stack identity & env --- section, all [OK]

# Exercise AC5.8 FAIL: temporarily mismatch BRIDGE_USERNAME
sed -i.bak 's/^BRIDGE_USERNAME=.*/BRIDGE_USERNAME=DE:AD:BE:EF:CA:FE/' stacks/homebridge/.env
dotfiles stacks doctor; echo "exit=$?"
# Expected: [FAIL] BRIDGE_USERNAME mismatch, exit 1
mv stacks/homebridge/.env.bak stacks/homebridge/.env
chmod 600 stacks/homebridge/.env

# Exercise env-key-missing FAIL
sed -i.bak '/^ADMIN_USERNAME=/d' stacks/wallabag/.env
dotfiles stacks doctor; echo "exit=$?"
# Expected: [FAIL] wallabag/.env missing keys: ADMIN_USERNAME, exit 1
mv stacks/wallabag/.env.bak stacks/wallabag/.env
chmod 600 stacks/wallabag/.env

# Restore
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0
```

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: check .env key presence + homebridge BRIDGE_USERNAME consistency"
```
<!-- END_TASK_7 -->

---

## Done When

- `CLAUDE.md` has new sections "Reproducible vs runtime" and "Colima first-start config mutations".
- `stacks/homebridge/README.md` has a "Pairing identity" section near the top.
- `stacks/homebridge/scripts/gen-pin.sh` exists; 100 invocations produce 100 well-formed pins, zero on the reserved list (AC6.5 verified).
- `stacks/homebridge/.env.example` HOMEKIT_PIN comment references gen-pin.sh.
- `stacks/wallabag/scripts/bootstrap.sh` and `stacks/homebridge/scripts/bootstrap.sh` exist; both justfile bootstrap recipes are one-line delegations.
- Both bootstrap scripts return exit 2 on missing env keys (AC5.11), exit 1 on the AC5.9 / AC5.10 unexpected-state cases, and exit 3 on upstream API/CLI failures.
- `dotfiles stacks doctor` adds a `--- Stack identity & env ---` section. Exits 1 when BRIDGE_USERNAME mismatches (AC5.8 verified) or any required `.env` key is missing.
- doctor still completes <5s on healthy state.
- Eight commits land: CLAUDE.md sections, homebridge/README pairing identity, gen-pin.sh, .env.example pin comment, wallabag bootstrap.sh + justfile, homebridge bootstrap.sh + justfile, doctor extension.
