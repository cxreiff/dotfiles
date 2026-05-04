# Phase 3: Migrate freshrss + wallabag to host bind mounts

**Goal:** Move freshrss and wallabag from named Docker volumes to `~/.volumes/<stack>/` host bind mounts, then add `init` + `backup` + `restore` recipes that mirror the adguard/homebridge shape. Existing user data must survive the migration with no loss.

**Architecture:** Existing named volumes (`freshrss_data`, `freshrss_extensions`, `wallabag_data`, `wallabag_images`) are migrated into host directories under `~/.volumes/freshrss/` and `~/.volumes/wallabag/` using the assumptions-first procedure (verify, snapshot, copy, swap, smoke-test). Compose files are updated to reference the new bind paths. Justfiles gain `init` (mkdir prerequisite of `up`), `backup` (with `down && up` quiesce — both apps use SQLite), and `restore` recipes — all delegating to the Phase 2 shared scripts.

**Tech Stack:** Docker named volumes, alpine container for cross-volume copy, BSD tar (already verified), the bind-mount + just-subsequent patterns established in Phase 2.

**Scope:** Phase 3 of 8. Depends on Phase 2 (uses the shared backup script + the just-subsequent quiesce pattern). After this phase, all four stacks share the same volume model; Phase 4 builds the backup-all aggregate on top.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC1: Data durability
- **stack-resilience.AC1.1 Success:** `stacks/freshrss/compose.yaml` uses `${HOME}/.volumes/freshrss/{data,extensions}` bind mounts; the top-level `volumes:` block is removed.
- **stack-resilience.AC1.2 Success:** `stacks/wallabag/compose.yaml` uses `${HOME}/.volumes/wallabag/{data,images}` bind mounts; the top-level `volumes:` block is removed.
- **stack-resilience.AC1.3 Success:** After freshrss migration, login as user `cxreiff` succeeds and feeds present pre-migration are still present (data preserved).
- **stack-resilience.AC1.4 Success:** After wallabag migration, login as `ADMIN_USERNAME` succeeds (data preserved).

(Extends AC1.5/AC1.11/AC1.12 from Phase 2 to cover freshrss + wallabag.)

---

## Operational Context (read before executing — IMPORTANT)

This is the **single highest-risk phase in the plan**. Migrating live SQLite-backed application data requires care.

**Live data this touches:**
- freshrss `data` volume — SQLite DB with subscribed feeds, read state, the `cxreiff` user account, OPML history.
- freshrss `extensions` volume — installed UI extensions.
- wallabag `data` volume — SQLite DB with saved articles, tags, user accounts including the actual admin.
- wallabag `images` volume — cached images for saved articles.

**Recovery path if the migration goes wrong:**
1. The pre-migration safety tarballs (Task 1) sit in `~/.volume-backups/daily/` and contain the original named-volume data captured BEFORE compose.yaml is touched.
2. The named volumes themselves remain in the Docker storage backend until you explicitly run `docker volume rm`. If the bind-mount data ends up empty or corrupt, restore by editing compose.yaml back to the named-volume form and `up` again — Docker re-attaches the original volumes.
3. The migration tasks below explicitly do **NOT** delete the named volumes. They become orphaned but recoverable until a future cleanup task.

**Pre-flight (verify before starting):**
- Phases 1 + 2 are complete. `dotfiles stacks doctor` is all-green for the infrastructure section.
- `~/.volume-backups/daily/` exists and contains adguard + homebridge tarballs from Phase 2.
- `~/.volumes/freshrss/` and `~/.volumes/wallabag/` do **NOT** yet exist.
- Both freshrss and wallabag compose files still use named volumes (verify with `grep -A2 '^volumes:' stacks/{freshrss,wallabag}/compose.yaml` — should show `data:` and `extensions:`/`images:`).
- The `cxreiff` user can currently log in to freshrss; the admin user can log in to wallabag. (You'll re-test these post-migration as the AC1.3/AC1.4 verification.)

**Do not start this phase late at night or right before traveling.** If something breaks, you want to be able to fix it.

---

<!-- START_TASK_1 -->
### Task 1: Pre-migration safety tarballs (named-volume snapshots)

**Verifies:** No AC directly — this is the safety net for AC1.3 + AC1.4 in case migration goes wrong.

**Files:** None modified. Output: tarballs in `~/.volume-backups/daily/`.

**Implementation:**

Tar each named volume into the same backup directory the Phase 2 scripts use, but with explicit pre-migration filenames so they can't be overwritten by Phase 4's launchd timer. The named volumes need a Docker container as a tar driver — they aren't accessible from the host filesystem directly. (This is the `docker --context colima-shared run --rm -v "$vol:/v" alpine tar ...` idiom that already appears in `stacks/README.md` lines 78-81.)

```bash
mkdir -p ~/.volume-backups/daily

# Confirm named volumes exist on the shared profile
docker --context colima-shared volume ls | grep -E '(freshrss|wallabag)_(data|extensions|images)'
# Expected: 4 lines — freshrss_data, freshrss_extensions, wallabag_data, wallabag_images

# Snapshot each volume into a uniquely-named pre-migration tarball
for vol in freshrss_data freshrss_extensions wallabag_data wallabag_images; do
    docker --context colima-shared run --rm \
        -v "${vol}:/src:ro" \
        -v ~/.volume-backups/daily:/dst \
        alpine \
        tar -C /src -czf "/dst/PRE-MIGRATION-${vol}-$(date +%Y-%m-%d).tgz" .
done

# Verify
ls -la ~/.volume-backups/daily/PRE-MIGRATION-*.tgz
# Expected: 4 tarballs, each non-empty
```

**Verification:**

```bash
# Inspect contents of each
for vol in freshrss_data freshrss_extensions wallabag_data wallabag_images; do
    echo "--- ${vol} ---"
    tar tzf ~/.volume-backups/daily/PRE-MIGRATION-${vol}-$(date +%Y-%m-%d).tgz | head -5
done
# Expected:
#   freshrss_data: ./users/, ./*.db files, etc.
#   freshrss_extensions: ./<extension dirs>/
#   wallabag_data: ./db/wallabag.sqlite, ./assets/
#   wallabag_images: ./<image dirs>/
```

**Commit:** None — these tarballs are gitignored runtime data.
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Migrate freshrss data into `~/.volumes/freshrss/`

**Verifies:** Sets up AC1.1 + AC1.3 (verified after Task 3).

**Files:** None modified yet (compose.yaml change is Task 3, after data is in place).

**Implementation:**

1. Stop freshrss cleanly so SQLite is consistent.
2. Create the host directories.
3. Use a one-shot alpine container that mounts both the source named volume and the destination host directory, then `cp -av` the contents over. This preserves permissions, ownership (numeric UIDs from inside the container), and timestamps.
4. Inspect the result on the host before touching compose.yaml.

```bash
# Stop freshrss cleanly (lets SQLite finalize)
dotfiles stacks freshrss down

# Verify it's down
docker --context colima-shared ps -a --filter name=freshrss
# Expected: empty or showing 'Exited' status

# Create host directories
mkdir -p ~/.volumes/freshrss/{data,extensions}

# Confirm they're empty (sanity)
ls -la ~/.volumes/freshrss/data ~/.volumes/freshrss/extensions
# Expected: both empty

# Copy named volume → host bind mount, preserving permissions
for pair in data:data extensions:extensions; do
    src_vol="freshrss_${pair%:*}"
    dst_dir="$HOME/.volumes/freshrss/${pair#*:}"
    docker --context colima-shared run --rm \
        -v "${src_vol}:/src:ro" \
        -v "${dst_dir}:/dst" \
        alpine \
        sh -c 'cp -av /src/. /dst/'
done

# Inspect the host-side result
ls -la ~/.volumes/freshrss/data | head -20
# Expected: ownership/permissions copied from the named volume
ls -la ~/.volumes/freshrss/extensions | head
# Expected: extension directories (or empty if none installed)
```

**Verification:**

```bash
# Compare sizes — should roughly match the original named volume
du -sh ~/.volumes/freshrss/data ~/.volumes/freshrss/extensions
docker --context colima-shared run --rm -v freshrss_data:/v alpine du -sh /v
docker --context colima-shared run --rm -v freshrss_extensions:/v alpine du -sh /v
# Expected: similar du output for each pair (permission/sparse-file diffs are OK; gross size mismatch is NOT)

# Confirm SQLite-looking files are present (you should see one or more *.db files, plus users/, fever/, favicons/, etc.)
ls ~/.volumes/freshrss/data
```

**STOP — pause for human verification:** if `~/.volumes/freshrss/data/` looks empty or doesn't contain expected directories (`users/`, db files), DO NOT continue to Task 3. The freshrss container is still down — re-edit compose.yaml only when the host data is confirmed correct. To recover: just `dotfiles stacks freshrss up` and the named volume is re-attached to the still-original compose.yaml (Task 3 hasn't happened yet).

**Commit:** None yet — compose.yaml change is bundled with the next task.
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Switch `stacks/freshrss/compose.yaml` to bind mounts; wire `init`, `backup`, `restore` recipes

**Verifies:** stack-resilience.AC1.1, stack-resilience.AC1.3

**Files:**
- Modify: `stacks/freshrss/compose.yaml` (lines 1-3, 21-23)
- Modify: `stacks/freshrss/justfile`

**Implementation:**

**`stacks/freshrss/compose.yaml`:** drop the top-level `volumes:` block (lines 1-3) and swap the service `volumes:` lines to bind-mount form. Mirror the adguard pattern (`${HOME}/.volumes/<stack>/<dir>:/<container-path>`).

Read the current file first, then apply the diff:
- Lines 1-3 (`volumes:\n  data:\n  extensions:\n`) → DELETE entirely.
- Lines 22-23 currently:
  ```yaml
        - data:/var/www/FreshRSS/data
        - extensions:/var/www/FreshRSS/extensions
  ```
  → become:
  ```yaml
        - ${HOME}/.volumes/freshrss/data:/var/www/FreshRSS/data
        - ${HOME}/.volumes/freshrss/extensions:/var/www/FreshRSS/extensions
  ```

After edit, the file starts at `services:` (no top-level `volumes:`) and lengths drops by 3 lines.

**`stacks/freshrss/justfile`:** add `init` recipe matching the adguard shape (lines 10-11 of `stacks/adguard/justfile`), make `up` depend on `init`, and add `backup`/`restore` mirroring Phase 2 homebridge (with `down && up` quiesce — freshrss is SQLite-backed). Add `volumes_dir` constant near the top alongside the existing `serve_port` etc. for parallelism with adguard/homebridge.

Currently the freshrss justfile is 31 lines starting with:
```just
context := "colima-shared"
tailscale := "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
serve_port := "8765"
internal_port := "18765"

default:
    @just --list

up:
    docker --context {{context}} compose up -d
```

Insert a `volumes_dir` line on line 3 (after `tailscale :=`):
```just
volumes_dir := join(env("HOME"), ".volumes", "freshrss")
```

Insert an `init` recipe before `up:`:
```just
init:
    mkdir -p {{volumes_dir}}/data {{volumes_dir}}/extensions
```

Change `up:` to `up: init`:
```just
up: init
    docker --context {{context}} compose up -d
```

Append at the end (after the existing `serve` recipe):
```just

backup: down && up
    @../scripts/backup.sh freshrss

restore tarball:
    @../scripts/restore.sh freshrss {{tarball}}
```

**Verification:**

```bash
# Compose syntax sanity (should print expanded compose YAML)
docker --context colima-shared compose -f stacks/freshrss/compose.yaml config | head -20
# Expected: shows bind-mount paths under ${HOME}/.volumes/freshrss/...

# Bring it up — uses bind mounts now
dotfiles stacks freshrss up
docker --context colima-shared ps --filter name=freshrss
# Expected: freshrss container Up

# Wait a few seconds for healthcheck
sleep 15
docker --context colima-shared ps --filter name=freshrss --format '{{.Status}}'
# Expected: "Up X seconds (healthy)" — confirming the migrated SQLite is intact

# AC1.3: log in via Tailscale
echo "Open https://${PUBLIC_HOST}:${PUBLIC_PORT} (from .env) in a browser and log in as cxreiff"
# Expected: login succeeds, feed list is your pre-migration feeds, articles read-state preserved
```

**STOP — human verification gate:** the user MUST confirm login succeeds and feeds are present BEFORE moving on to wallabag. If the migration data is bad:
1. `dotfiles stacks freshrss down`
2. `git checkout stacks/freshrss/compose.yaml stacks/freshrss/justfile` (revert to named volumes)
3. `rm -rf ~/.volumes/freshrss` (clear partial bind-mount state)
4. `dotfiles stacks freshrss up` (named volume re-attaches; you're back to pre-migration state)
5. Re-investigate the cp step before retrying.

**Commit (after human confirms login works):**
```bash
git add stacks/freshrss/compose.yaml stacks/freshrss/justfile
git commit -m "freshrss: migrate to host bind mounts under ~/.volumes/freshrss/"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Migrate wallabag data into `~/.volumes/wallabag/`

**Verifies:** Sets up AC1.2 + AC1.4 (verified after Task 5).

**Files:** None modified yet.

**Implementation:**

Same procedure as Task 2, for wallabag. Volumes: `wallabag_data` → `~/.volumes/wallabag/data`, `wallabag_images` → `~/.volumes/wallabag/images`. Container internal paths: `/var/www/wallabag/data` and `/var/www/wallabag/web/assets/images` (verified from `stacks/wallabag/compose.yaml:17-18`).

```bash
# Stop wallabag cleanly
dotfiles stacks wallabag down
docker --context colima-shared ps -a --filter name=wallabag
# Expected: empty or 'Exited'

# Create host dirs
mkdir -p ~/.volumes/wallabag/{data,images}
ls -la ~/.volumes/wallabag/data ~/.volumes/wallabag/images
# Expected: both empty

# Copy named volumes → host
for pair in data:data images:images; do
    src_vol="wallabag_${pair%:*}"
    dst_dir="$HOME/.volumes/wallabag/${pair#*:}"
    docker --context colima-shared run --rm \
        -v "${src_vol}:/src:ro" \
        -v "${dst_dir}:/dst" \
        alpine \
        sh -c 'cp -av /src/. /dst/'
done

# Inspect — should see db/wallabag.sqlite at minimum
ls -la ~/.volumes/wallabag/data
# Expected: db/ subdir, possibly assets/
ls ~/.volumes/wallabag/data/db
# Expected: wallabag.sqlite
```

**Verification:**

```bash
# Confirm SQLite file is non-zero
stat -f%z ~/.volumes/wallabag/data/db/wallabag.sqlite
# Expected: a positive integer (KB or MB depending on usage)

# Compare with named volume size
docker --context colima-shared run --rm -v wallabag_data:/v alpine du -sh /v
du -sh ~/.volumes/wallabag/data
# Expected: similar
```

**STOP — pause for human verification:** if `~/.volumes/wallabag/data/db/wallabag.sqlite` doesn't exist or is empty, DO NOT continue. The wallabag container is still down — recover by `dotfiles stacks wallabag up` (named volume re-attaches).

**Commit:** None yet (bundled with Task 5).
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Switch `stacks/wallabag/compose.yaml` to bind mounts; wire `init`, `backup`, `restore` recipes

**Verifies:** stack-resilience.AC1.2, stack-resilience.AC1.4

**Files:**
- Modify: `stacks/wallabag/compose.yaml`
- Modify: `stacks/wallabag/justfile`

**Implementation:**

**`stacks/wallabag/compose.yaml`:** drop top-level `volumes:` block (lines 1-3), swap service volumes (lines 17-18).
- Lines 1-3: DELETE.
- Line 17 (`- data:/var/www/wallabag/data`) → `- ${HOME}/.volumes/wallabag/data:/var/www/wallabag/data`
- Line 18 (`- images:/var/www/wallabag/web/assets/images`) → `- ${HOME}/.volumes/wallabag/images:/var/www/wallabag/web/assets/images`

**`stacks/wallabag/justfile`:** add `volumes_dir`, `init` recipe, make `up` depend on `init`, add `backup` (with `down && up`) and `restore`. Mirror exactly what Phase 3 Task 3 did for freshrss; the structures are identical.

Insert after `tailscale :=` line:
```just
volumes_dir := join(env("HOME"), ".volumes", "wallabag")
```

Insert before `up:`:
```just
init:
    mkdir -p {{volumes_dir}}/data {{volumes_dir}}/images
```

Change `up:` to `up: init`:
```just
up: init
    docker --context {{context}} compose up -d
```

Append at the end (after the existing `serve` recipe, line 58):
```just

backup: down && up
    @../scripts/backup.sh wallabag

restore tarball:
    @../scripts/restore.sh wallabag {{tarball}}
```

**Verification:**

```bash
# Compose syntax
docker --context colima-shared compose -f stacks/wallabag/compose.yaml config | head -20
# Expected: bind mounts shown

# Bring up
dotfiles stacks wallabag up
sleep 20  # wallabag healthcheck takes a bit on first start
docker --context colima-shared ps --filter name=wallabag --format '{{.Status}}'
# Expected: "Up X seconds (healthy)"

# AC1.4: log in via Tailscale
echo "Open https://${PUBLIC_HOST}:${PUBLIC_PORT} (from wallabag/.env) in a browser and log in as ADMIN_USERNAME"
# Expected: login succeeds, saved articles visible
```

**STOP — human verification gate:** confirm wallabag login + saved-article count matches pre-migration. If broken, recover via the same path as freshrss (revert files, rm bind dir, re-up).

**Commit (after human confirms login works):**
```bash
git add stacks/wallabag/compose.yaml stacks/wallabag/justfile
git commit -m "wallabag: migrate to host bind mounts under ~/.volumes/wallabag/"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Extend doctor to check `~/.volumes/<stack>/` populated for all four stacks

**Verifies:** Augments stack-resilience.AC5.1 (more checks); supports AC1.1/AC1.2 by giving doctor a way to detect regression.

**Files:**
- Modify: `stacks/scripts/doctor.sh`
- Modify: the `--- Backups ---` loop to iterate all 4 stacks now (was 2 in Phase 2).

**Implementation:**

Add a new `--- Stack volumes ---` section between `--- Infrastructure ---` and `--- Backups ---`. For each stack:
- `~/.volumes/<stack>/` exists.
- `~/.volumes/<stack>/` is non-empty.

Both checks `pass`/`fail` independently per stack.

Update the existing `--- Backups ---` loop to iterate `adguard freshrss homebridge wallabag` (all 4) instead of just `adguard homebridge`.

Insert after the infrastructure section (after the tailscale check, before the existing `--- Backups ---` block):

```bash
echo
echo "--- Stack volumes ---"
for stack in adguard freshrss homebridge wallabag; do
    dir="${HOME}/.volumes/${stack}"
    if [ ! -d "$dir" ]; then
        fail "${stack} host volume dir missing: ${dir}"
    elif [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        fail "${stack} host volume dir empty: ${dir}"
    else
        pass "${stack} host volume dir present and non-empty"
    fi
done
```

And modify the existing `for stack in adguard homebridge; do` line in the Backups section to:

```bash
for stack in adguard freshrss homebridge wallabag; do
```

**Verification:**

```bash
dotfiles stacks doctor
# Expected:
#   --- Stack volumes ---
#   [OK]   adguard host volume dir present and non-empty
#   [OK]   freshrss host volume dir present and non-empty
#   [OK]   homebridge host volume dir present and non-empty
#   [OK]   wallabag host volume dir present and non-empty
#   --- Backups ---
#   [OK] / [WARN] for each of 4 stacks
echo "exit=$?"
# Expected: 0 (all checks pass)

# Time check — should still be <5s
time dotfiles stacks doctor >/dev/null
```

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: check ~/.volumes/<stack>/ for all four stacks"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Take fresh post-migration backups via the new recipes

**Verifies:** stack-resilience.AC1.5 (extends to freshrss + wallabag).

**Files:** None modified. Output: tarballs in `~/.volume-backups/daily/`.

**Implementation:**

Now that the host bind mounts are in place, run the new `backup` recipes to produce tarballs that follow the standard naming and live alongside the adguard/homebridge backups.

```bash
# freshrss backup uses down && up (SQLite quiesce)
dotfiles stacks freshrss backup
# Expected: prints ~/.volume-backups/daily/freshrss-YYYY-MM-DD.tgz

# wallabag backup — same shape
dotfiles stacks wallabag backup
# Expected: prints ~/.volume-backups/daily/wallabag-YYYY-MM-DD.tgz

# Confirm both tarballs are present
ls -la ~/.volume-backups/daily/
# Expected: 4 same-day tarballs (adguard, freshrss, homebridge, wallabag) + the
# 4 PRE-MIGRATION-* safety tarballs from Task 1
```

**Verification:**

```bash
for stack in adguard freshrss homebridge wallabag; do
    echo "--- ${stack} ---"
    tar tzf ~/.volume-backups/daily/${stack}-$(date +%Y-%m-%d).tgz | head -3
done

dotfiles stacks doctor
# Expected: backups section now shows [OK] for all 4 stacks (all 0h old)
```

**Commit:** None — runtime data.
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Document the bind-mount paths in per-stack READMEs

**Verifies:** Supports AC7.5 (later phase audit) by making bind-mount layout explicit.

**Files:**
- Modify: `stacks/freshrss/README.md`
- Modify: `stacks/wallabag/README.md`

**Implementation:**

Each README currently says "single container with named Docker volumes for [data]; no host-side bind mounts" (freshrss line 4-5; wallabag line 4-5). Replace those statements with the new reality, and add a brief "Volumes" section enumerating the host paths. Mirror the level of detail the homebridge README gives for `~/.volumes/homebridge/`.

**`stacks/freshrss/README.md`** lines 4-5 currently:
```markdown
FreshRSS in the default Colima VM. Runs as a single container with named
Docker volumes for data and extensions; no host-side bind mounts.
```
Replace with:
```markdown
FreshRSS in the `shared` Colima VM. Runs as a single container with host
bind mounts under `~/.volumes/freshrss/`.
```

Add a new `## Volumes` section after the `## .env keys` table (before `## First-run automation`):
```markdown
## Volumes

| Host path | Container path | Contents |
|---|---|---|
| `~/.volumes/freshrss/data` | `/var/www/FreshRSS/data` | SQLite DB, user accounts, feed/article state |
| `~/.volumes/freshrss/extensions` | `/var/www/FreshRSS/extensions` | Installed UI extensions |

`init` (a `up` prerequisite) creates these directories. `backup` and `restore`
recipes target them via the shared `stacks/scripts/backup.sh` /
`restore.sh`. `restore` refuses to overwrite a non-empty destination unless
`--force` is passed.
```

**`stacks/wallabag/README.md`** lines 3-5 currently:
```markdown
[Wallabag](https://www.wallabag.org/) (read-it-later) in the default Colima
VM. Single container with named Docker volumes for the SQLite database and
asset images; no host-side bind mounts.
```
Replace with:
```markdown
[Wallabag](https://www.wallabag.org/) (read-it-later) in the `shared` Colima
VM. Single container with host bind mounts under `~/.volumes/wallabag/`.
```

Add the same shape `## Volumes` section after the `## .env keys` table (before `## First-run automation`):
```markdown
## Volumes

| Host path | Container path | Contents |
|---|---|---|
| `~/.volumes/wallabag/data` | `/var/www/wallabag/data` | SQLite DB (`db/wallabag.sqlite`), assets |
| `~/.volumes/wallabag/images` | `/var/www/wallabag/web/assets/images` | Cached article images |

`init` (a `up` prerequisite) creates these directories. `backup` and `restore`
recipes target them via the shared `stacks/scripts/backup.sh` /
`restore.sh`. `restore` refuses to overwrite a non-empty destination unless
`--force` is passed.
```

**Verification:**

Re-read each README and confirm the new sections render correctly. Tone matches the existing operational style (no marketing voice). Length is short.

**Commit:**
```bash
git add stacks/freshrss/README.md stacks/wallabag/README.md
git commit -m "freshrss/wallabag: document host bind-mount layout in READMEs"
```
<!-- END_TASK_8 -->

---

## Done When

- `stacks/freshrss/compose.yaml` has no top-level `volumes:` block; service volumes use `${HOME}/.volumes/freshrss/{data,extensions}` bind paths.
- `stacks/wallabag/compose.yaml` has no top-level `volumes:` block; service volumes use `${HOME}/.volumes/wallabag/{data,images}` bind paths.
- `~/.volumes/freshrss/{data,extensions}` and `~/.volumes/wallabag/{data,images}` exist and are populated with the migrated data.
- freshrss serves the `cxreiff` user successfully (login via Tailscale URL works; pre-migration feeds present) — AC1.3 verified by human.
- wallabag serves `ADMIN_USERNAME` successfully (login works; pre-migration saved articles present) — AC1.4 verified by human.
- `dotfiles stacks doctor` reports `[OK]` for all four `--- Stack volumes ---` checks and all four `--- Backups ---` checks; total runtime still <5s.
- `~/.volume-backups/daily/` contains 4 same-day tarballs from the new `backup` recipes plus 4 `PRE-MIGRATION-*` safety tarballs (these stay until you decide to clean them up; Phase 4's GFS prune doesn't touch the `PRE-MIGRATION-` prefix).
- Original named volumes (`freshrss_data`, `freshrss_extensions`, `wallabag_data`, `wallabag_images`) still exist in Docker — they're orphaned but recoverable. Do **not** `docker volume rm` them in this phase. Cleanup is a separate user-driven decision once the migration has been live for a few days.
- Five commits land: freshrss compose+justfile, wallabag compose+justfile, doctor extension, READMEs.
