# Phase 2: Backup + restore mechanism (host-bind stacks)

**Goal:** Per-stack `backup` and `restore` recipes for the two stacks that already use host bind mounts (adguard, homebridge). Proves the shared-backup-script mechanism end-to-end before extending it to freshrss/wallabag in Phase 3.

**Architecture:** Single shared `stacks/scripts/backup.sh <stack>` that tars `~/.volumes/<stack>/` into `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz`. Single shared `stacks/scripts/restore.sh <stack> <tarball>` that extracts back, refusing to overwrite a non-empty destination unless `--force`. Per-stack quiesce is declared at the **justfile** level via just's `recipe: down && up` subsequent-dependency syntax (added in just 1.13). The scripts themselves contain no quiesce logic, so they're trivially shared across all four stacks.

**Tech Stack:** bsdtar 3.5.3 (macOS default; `czf` and `tzf` work identically to GNU tar for our use), POSIX bash, just 1.50.0 subsequent dependencies.

**Scope:** Phase 2 of 8. Adds backup mechanism for adguard + homebridge only; freshrss/wallabag come in Phase 3 once they have host bind mounts to back up.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC1: Data durability
- **stack-resilience.AC1.5 Success:** `dotfiles stacks <stack> backup` creates `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz`; `tar tzf` lists expected paths. *(Phase 2 establishes for adguard + homebridge; Phase 3 extends to freshrss + wallabag.)*
- **stack-resilience.AC1.10 Success:** AGH container `Up` time crosses the AGH backup operation (AGH NEVER stopped during backup).
- **stack-resilience.AC1.11 Failure:** `dotfiles stacks <stack> restore <tarball>` against a non-empty `~/.volumes/<stack>/` exits non-zero unless `--force` is passed.
- **stack-resilience.AC1.12 Edge:** Same-day re-run of `backup` cleanly overwrites today's tarball without error.

### stack-resilience.AC5: Sanity recipes
- **stack-resilience.AC5.6 Success:** `doctor` warns/fails when the latest backup tarball for any stack is older than 36 hours. *(Phase 2 ships this as WARN initially, since the launchd timer doesn't exist until Phase 4. Phase 4 promotes it to FAIL.)*

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.2 Success:** `stacks/scripts/` contains `backup.sh`, `restore.sh` (extends Phase 1 — adds these two; rotation/install scripts come in Phase 4).
- **stack-resilience.AC7.3 Success:** No per-stack `backup.sh`/`restore.sh` — single shared script.

---

## Operational Context (read before executing)

This phase **modifies live container state for homebridge** (the just `down && up` subsequent restarts the container during backup). For adguard, the backup runs while the container stays up — so AGH continues serving DNS to the LAN throughout. **At no point in this phase is the user's tailnet DNS bricked.**

**Failure trade-off accepted (matches design Additional Considerations):** just's subsequent dependencies don't provide an "always after" hook. If `backup.sh` itself fails (disk full, permission error), the homebridge container will be left stopped and the user must manually `dotfiles stacks homebridge up`. This is acceptable for Phase 2/3 because backup runs are user-initiated and the failure is visible. Phase 4's launchd timer captures stderr to a log so unattended-run failures are still discoverable.

**Pre-flight (verify before starting):**
- Phase 1 is complete (`dotfiles stacks doctor` exits 0; `stacks/scripts/lib/check.sh` exists).
- `~/.volumes/adguard/` and `~/.volumes/homebridge/` exist and are non-empty (the user's running stacks have already populated them).
- `~/.volume-backups/` does not exist yet (Task 1 creates it on first backup run; if it does exist, that's fine — `mkdir -p` is idempotent).

---

<!-- START_TASK_1 -->
### Task 1: Create the shared backup script (`stacks/scripts/backup.sh`)

**Verifies:** stack-resilience.AC1.5, stack-resilience.AC1.10, stack-resilience.AC1.12

**Files:**
- Create: `stacks/scripts/backup.sh` (executable, mode 755)

**Implementation:**

Single argument: `<stack-name>`. Behavior:
- `mkdir -p ~/.volume-backups/daily/`
- `tar -C ~/.volumes -czf ~/.volume-backups/daily/<stack>-$(date +%Y-%m-%d).tgz <stack>` (overwrites same-day tarball cleanly per `tar`'s default behavior).
- Refuses if `~/.volumes/<stack>/` doesn't exist or is empty (caller error).
- Refuses if no stack-name argument supplied.
- Prints the resulting tarball path on success (so callers can pipe / log).
- No quiesce logic — quiesce belongs at the justfile level.

`tar -C <dir>` changes into `<dir>` before reading, so tarball entries are stack-relative (`adguard/conf/...`), which makes `restore.sh`'s extract-into-`~/.volumes/` symmetric.

```bash
#!/usr/bin/env bash
# stacks/scripts/backup.sh
# Tar ~/.volumes/<stack>/ into ~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz.
# Quiesce, if needed, is the caller's responsibility (declared at justfile level).
#
# Usage: backup.sh <stack-name>
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: backup.sh <stack-name>" >&2
    exit 2
fi
stack="$1"

src="${HOME}/.volumes/${stack}"
if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    echo "backup.sh: ${src} missing or empty — nothing to back up" >&2
    exit 2
fi

dst_dir="${HOME}/.volume-backups/daily"
mkdir -p "$dst_dir"
dst="${dst_dir}/${stack}-$(date +%Y-%m-%d).tgz"

tar -C "${HOME}/.volumes" -czf "$dst" "$stack"
echo "$dst"
```

**Verification:**

```bash
chmod +x stacks/scripts/backup.sh

# Argument missing — exits 2
./stacks/scripts/backup.sh; echo "exit=$?"
# Expected: usage line on stderr, exit 2

# Non-existent stack — exits 2 (no tarball created)
./stacks/scripts/backup.sh nonexistent-stack; echo "exit=$?"
# Expected: missing-or-empty message, exit 2

# Real backup — creates tarball, prints path
./stacks/scripts/backup.sh adguard
ls -la ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz
tar tzf ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz | head -10
# Expected: tarball exists, listing shows adguard/conf/, adguard/work/ entries

# AC1.12 same-day re-run — clean overwrite
./stacks/scripts/backup.sh adguard
echo "exit=$?"
# Expected: exit 0, tarball mtime updates, no error
```

**Commit:**
```bash
git add stacks/scripts/backup.sh
git commit -m "stacks: add shared backup script"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create the shared restore script (`stacks/scripts/restore.sh`)

**Verifies:** stack-resilience.AC1.11

**Files:**
- Create: `stacks/scripts/restore.sh` (executable, mode 755)

**Implementation:**

Two required arguments: `<stack-name> <tarball-path>`. Optional third: `--force`. Behavior:
- Validates tarball exists.
- Refuses if `~/.volumes/<stack>/` exists and is non-empty UNLESS `--force` is in args.
- Creates `~/.volumes/<stack>/` if missing.
- `tar -C ~/.volumes -xzf <tarball>` (extracts back; tarball entries are already `<stack>/...`).
- Caller is responsible for stopping the stack first if it's running. Restore is intended for clean-slate recovery, where the container hasn't been started yet against this volume directory.

```bash
#!/usr/bin/env bash
# stacks/scripts/restore.sh
# Extract a backup tarball back into ~/.volumes/<stack>/.
# Refuses non-empty destination unless --force is passed.
# Caller stops the stack first; this script does not touch container state.
#
# Usage: restore.sh <stack-name> <tarball-path> [--force]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: restore.sh <stack-name> <tarball-path> [--force]" >&2
    exit 2
fi
stack="$1"
tarball="$2"
force=""
if [ "${3:-}" = "--force" ]; then
    force=1
fi

if [ ! -f "$tarball" ]; then
    echo "restore.sh: tarball not found: ${tarball}" >&2
    exit 2
fi

dst="${HOME}/.volumes/${stack}"
if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ] && [ -z "$force" ]; then
    echo "restore.sh: ${dst} is not empty; pass --force to overwrite" >&2
    exit 1
fi

mkdir -p "${HOME}/.volumes"
tar -C "${HOME}/.volumes" -xzf "$tarball"
echo "Restored ${stack} from ${tarball}"
```

**Verification:**

```bash
chmod +x stacks/scripts/restore.sh

# Missing args — exit 2
./stacks/scripts/restore.sh; echo "exit=$?"
# Expected: usage line, exit 2

# Tarball not found — exit 2
./stacks/scripts/restore.sh adguard /tmp/nonexistent.tgz; echo "exit=$?"
# Expected: not-found error, exit 2

# AC1.11: refuse non-empty destination
./stacks/scripts/restore.sh adguard ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz
echo "exit=$?"
# Expected: "is not empty; pass --force" + exit 1
```

Do **not** run `--force` against `~/.volumes/adguard/` on the live host — that would overwrite the running AGH state. The contract is exercised by reading the script source (the `--force` branch is a single conditional and is auditable).

**Commit:**
```bash
git add stacks/scripts/restore.sh
git commit -m "stacks: add shared restore script"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Wire `backup` and `restore` recipes into `stacks/adguard/justfile`

**Verifies:** stack-resilience.AC1.5, stack-resilience.AC1.10

**Files:**
- Modify: `stacks/adguard/justfile`

**Implementation:**

AGH MUST stay up during backup (AC1.10: zero AGH downtime — DNS query log is append-only and a partial last line is harmless). So the adguard `backup` recipe has **no `down && up` subsequent**: it just calls the shared backup script while the container is live.

`restore` recipe: caller stops the stack first if it's running. Recipe takes a `tarball` parameter just like a positional arg.

Append after the `advertise` recipe (currently the last lines, lines 41-50 of `stacks/adguard/justfile`):

```just

backup:
    @../scripts/backup.sh adguard

restore tarball:
    @../scripts/restore.sh adguard {{tarball}}
```

The leading blank line preserves visual recipe separation. `@` suppresses just's command echo so the script's own output is what the user sees. just-recipe relative paths resolve against the directory containing the justfile, so `../scripts/backup.sh` correctly references `stacks/scripts/backup.sh`.

**Verification:**

```bash
# Confirm container Up time before
docker --context colima-bridged inspect adguardhome --format '{{.State.StartedAt}}'

dotfiles stacks adguard backup
# Expected: prints ~/.volume-backups/daily/adguard-YYYY-MM-DD.tgz path, exit 0

# Confirm container Up time AFTER — should be unchanged (AC1.10 — AGH never stopped)
docker --context colima-bridged inspect adguardhome --format '{{.State.StartedAt}}'
```

The two `StartedAt` timestamps MUST match. If they differ, AGH was restarted during backup — the recipe is wrong.

```bash
# Inspect tarball
tar tzf ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz | head
# Expected: adguard/conf/AdGuardHome.yaml, adguard/work/data/...

# Restore recipe — verify it refuses to clobber the live volume
dotfiles stacks adguard restore ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz
echo "exit=$?"
# Expected: "is not empty; pass --force" + exit 1
```

**Commit:**
```bash
git add stacks/adguard/justfile
git commit -m "adguard: add backup/restore recipes (no quiesce — AGH stays up)"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Wire `backup` and `restore` recipes into `stacks/homebridge/justfile`

**Verifies:** stack-resilience.AC1.5

**Files:**
- Modify: `stacks/homebridge/justfile`

**Implementation:**

Homebridge persists Node module state, plugin caches, and SQLite-backed pairing/auth state under `~/.volumes/homebridge/` — restarting cleanly is necessary so SQLite isn't mid-transaction during tar. Use just's subsequent-dependency syntax `recipe: down && up` so the body runs between a `down` and a follow-on `up`.

just's `recipe: dep && post` semantics (verified in just 1.50.0, supported since 1.13):
- `dep` runs first.
- The recipe body runs.
- If the body succeeds, `post` runs.
- If the body fails, `post` is **skipped** (the documented trade-off — homebridge stays down on backup failure; user runs `dotfiles stacks homebridge up` to recover).

Append after the `serve` recipe (currently the last lines, lines 89-94 of `stacks/homebridge/justfile`):

```just

backup: down && up
    @../scripts/backup.sh homebridge

restore tarball:
    @../scripts/restore.sh homebridge {{tarball}}
```

The `down && up` pre+post pattern: `down` runs before the body, `up` runs after a successful body.

**Verification:**

```bash
# Capture container start time before
before=$(docker --context colima-bridged inspect homebridge --format '{{.State.StartedAt}}')
echo "before: $before"

dotfiles stacks homebridge backup
# Expected: prints ~/.volume-backups/daily/homebridge-YYYY-MM-DD.tgz, exit 0

# Container should have been restarted (start time newer than 'before')
after=$(docker --context colima-bridged inspect homebridge --format '{{.State.StartedAt}}')
echo "after: $after"
# Expected: $after > $before — confirming the down+up ran

# Inspect tarball
tar tzf ~/.volume-backups/daily/homebridge-$(date +%Y-%m-%d).tgz | head
# Expected: homebridge/config.json, homebridge/persist/, homebridge/auth.json, etc.
```

**Pause for user confirmation before next task:** the user should verify that HomeKit accessories still work after the restart. (They will — homebridge restart is benign — but this is a "live homelab" moment worth checking.)

**Commit:**
```bash
git add stacks/homebridge/justfile
git commit -m "homebridge: add backup/restore recipes (down && up for SQLite quiesce)"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Extend doctor with the latest-backup-age check (initially WARN)

**Verifies:** stack-resilience.AC5.6 (initial WARN form; Phase 4 promotes to FAIL)

**Files:**
- Modify: `stacks/scripts/doctor.sh`

**Implementation:**

Add a second section, `--- Backups ---`, after the existing infrastructure section. For each of `adguard` and `homebridge` (the two stacks with backups so far; Phase 3 extends to `freshrss`+`wallabag`, Phase 4 changes WARN to FAIL):

- If `~/.volume-backups/daily/<stack>-*.tgz` files exist, find the newest by mtime.
- If newest is older than 36 hours: `warn` "<stack> latest backup is X hours old (>36h)".
- If no tarballs exist for the stack: `warn` "<stack> has no backups yet".
- Otherwise: `pass` "<stack> latest backup <Xh ago>".

Use `stat -f` (BSD stat — confirmed bsdtar/macOS user) for mtime, or `find -mtime` for the threshold check (more portable). Doctor must stay <5s — `find` on a small backups dir is microseconds.

Insert the new section AFTER the existing infrastructure block and BEFORE the final `[ "$__check_failed" -eq 0 ] || exit 1` line. Preserve the existing five infrastructure checks unmodified.

```bash
echo
echo "--- Backups ---"

backups_dir="${HOME}/.volume-backups/daily"
for stack in adguard homebridge; do
    if [ ! -d "$backups_dir" ]; then
        warn "${stack} has no backups yet (no ~/.volume-backups/daily/)"
        continue
    fi
    # Find most-recent tarball for this stack
    latest=$(find "$backups_dir" -maxdepth 1 -name "${stack}-*.tgz" -print 2>/dev/null \
        | sort | tail -1)
    if [ -z "$latest" ]; then
        warn "${stack} has no backups yet"
        continue
    fi
    # mtime in epoch seconds (BSD stat syntax — macOS default)
    mtime=$(stat -f %m "$latest")
    now=$(date +%s)
    age_hours=$(( (now - mtime) / 3600 ))
    if [ "$age_hours" -gt 36 ]; then
        warn "${stack} latest backup is ${age_hours}h old (>36h)"
    else
        pass "${stack} latest backup is ${age_hours}h old"
    fi
done
```

**Verification:**

```bash
dotfiles stacks doctor
```

Expected: a new `--- Backups ---` section appears below `--- Infrastructure ---`. Both adguard and homebridge show `[OK]` with an age in hours (probably 0h since you just made the backups in Tasks 3+4).

To exercise the WARN branch (without waiting 36 hours):

```bash
# Temporarily backdate one tarball and re-run (BSD touch syntax)
touch -t $(date -v-2d +%Y%m%d0000) ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz
dotfiles stacks doctor                 # adguard line should be [WARN]
echo "exit=$?"                         # exit 0 — WARN does not fail
# Restore: re-run backup to refresh
dotfiles stacks adguard backup
dotfiles stacks doctor                 # back to [OK]
```

`touch -t YYYYMMDDhhmm` is BSD touch syntax (correct for macOS).

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: warn when stack backup older than 36h"
```
<!-- END_TASK_5 -->

---

## Done When

- `dotfiles stacks adguard backup` writes a valid tarball to `~/.volume-backups/daily/adguard-YYYY-MM-DD.tgz`. The AGH container's `StartedAt` timestamp is unchanged across the operation (AC1.10 verified).
- `dotfiles stacks homebridge backup` writes a valid tarball to `~/.volume-backups/daily/homebridge-YYYY-MM-DD.tgz`. The homebridge container's `StartedAt` timestamp shifts forward (down+up restarted it). HomeKit pairing still works after.
- Both tarballs extract correctly with `tar tzf` and contain the expected per-stack subtree.
- `dotfiles stacks adguard restore <existing-tarball>` against the live `~/.volumes/adguard/` exits 1 with the "is not empty; pass --force" message (AC1.11 verified).
- Same-day re-run of either backup recipe overwrites today's tarball cleanly with no error (AC1.12 verified).
- `dotfiles stacks doctor` adds a `--- Backups ---` section, reports `[OK]` for both stacks, total runtime still <5s.
- Five commits land: `backup.sh`, `restore.sh`, `adguard/justfile` recipes, `homebridge/justfile` recipes, `doctor.sh` backup-age check.
