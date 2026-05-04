# Phase 4: backup-all + GFS rotation + launchd nightly timer

**Goal:** Aggregate `backup-all` recipe across all four stacks, GFS rotation (Grandfather-Father-Son: daily/weekly/monthly retention with pruning), and a launchd `LaunchAgent` that runs `dotfiles stacks backup-all` at 4:00 AM nightly.

**Architecture:** A new `stacks/scripts/backup-rotate.sh` promotes Sundays' daily tarballs to `weekly/` and 1st-of-month dailies to `monthly/`, then prunes each tier (7 daily / 4 weekly / 3 monthly per stack). A `stacks/scripts/backup-install.sh` templates a `LaunchAgent` plist into `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` and bootstraps it via `launchctl bootstrap gui/$UID`. `backup-all` calls each per-stack `backup` recipe in turn, then `backup-rotate.sh` exactly once at the end. Phase 2/3 backup recipes are reused unchanged.

**Tech Stack:** macOS launchd 15.x (Sequoia), `launchctl bootstrap`/`bootout`/`kickstart`, `StartCalendarInterval` (fires-on-wake when Mac was asleep at the scheduled time, per Apple's documented behavior), envsubst for plist templating, BSD `stat` and `find` for file mtime.

**Scope:** Phase 4 of 8. Depends on Phases 2 + 3 (per-stack `backup` recipes exist for all four stacks). After this phase the system has unattended nightly protection.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC1: Data durability
- **stack-resilience.AC1.6 Success:** `dotfiles stacks backup-all` produces a fresh tarball for each of the four stacks AND runs `backup-rotate.sh` exactly once at the end.
- **stack-resilience.AC1.7 Success:** `backup-rotate.sh` promotes Sunday's daily tarball into `weekly/` (one per stack); promotes the 1st-of-month daily into `monthly/`. Idempotent — re-runs same day don't duplicate.
- **stack-resilience.AC1.8 Success:** `backup-rotate.sh` prunes `daily/` to last 7 per stack, `weekly/` to last 4 per stack, `monthly/` to last 3 per stack (by mtime).
- **stack-resilience.AC1.9 Success:** `dotfiles stacks backup-install` installs `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist`; `launchctl print` shows it scheduled for 4:00 daily.

### stack-resilience.AC5: Sanity recipes
- **stack-resilience.AC5.6 Success (promoted):** `doctor` warns/fails when the latest backup tarball for any stack is older than 36 hours. *(Phase 4 promotes the WARN from Phases 2-3 to FAIL — the timer is supposed to be running now.)*

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.2 Success:** `stacks/scripts/` now also contains `backup-rotate.sh`, `backup-install.sh`. Combined with Phase 1+2: `doctor.sh`, `lib/check.sh`, `backup.sh`, `restore.sh`, `backup-rotate.sh`, `backup-install.sh`. (Phase 6 adds `bridged-ip-changed.sh` to complete the set.)

---

## Operational Context (read before executing)

This phase **schedules a recurring background process** under the user's account. The blast radius is bounded — the LaunchAgent runs `dotfiles stacks backup-all`, which exercises the same recipes the user runs interactively, so any side effect they have on stacks (briefly stopping homebridge/freshrss/wallabag at 4 AM) is the only externally-visible behavior. AGH stays up throughout.

**Sleep/wake behavior** (verified per Apple launchd documentation): `StartCalendarInterval` will fire on the next wake if the Mac was asleep at the scheduled time. Multiple missed events coalesce into a single wake-time run. So if the Mac is asleep at 4 AM, the backup runs the next time you wake the Mac.

**Apple Silicon specifics confirmed:** the user's host is `arm64`, so Homebrew lives at `/opt/homebrew/bin/`. The plist's `EnvironmentVariables.PATH` and `ProgramArguments[0]` reflect this.

**Pre-flight (verify before starting):**
- Phases 1, 2, 3 are complete. `dotfiles stacks doctor` is all-green.
- All four stacks have `backup` recipes that work (verified by Phase 3 Task 7).
- `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` does NOT yet exist (`ls ~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist 2>&1` returns "No such file").
- `launchctl print gui/$(id -u)/com.cxreiff.dotfiles.backup` returns non-zero (no such service yet).

---

<!-- START_TASK_1 -->
### Task 1: Create the GFS rotation script (`stacks/scripts/backup-rotate.sh`)

**Verifies:** stack-resilience.AC1.7, stack-resilience.AC1.8

**Files:**
- Create: `stacks/scripts/backup-rotate.sh` (executable, mode 755)

**Implementation:**

Behavior:
1. For each stack in `adguard freshrss homebridge wallabag`:
   - **Weekly promotion:** if today is Sunday (`date +%u` returns `7`), copy today's daily tarball into `weekly/<stack>-YYYY-MM-DD.tgz`. Idempotent — `cp -n` (no-clobber) so a same-day re-run doesn't duplicate; if today's weekly already exists, the cp is a no-op.
   - **Monthly promotion:** if today is the 1st (`date +%d` returns `01`), same pattern into `monthly/`.
2. Then prune:
   - `daily/`: keep newest 7 per stack (by mtime).
   - `weekly/`: keep newest 4 per stack.
   - `monthly/`: keep newest 3 per stack.
3. Ignore `PRE-MIGRATION-*` tarballs entirely (Phase 3 safety snapshots — the user decides when to delete them).

Use `find ... -name '<stack>-*.tgz'` (which won't match `PRE-MIGRATION-<stack>-*.tgz`), sort by mtime via `stat -f "%m %N"` (BSD stat — confirmed macOS), keep the requested count.

```bash
#!/usr/bin/env bash
# stacks/scripts/backup-rotate.sh
# GFS rotation for ~/.volume-backups/. Promotes Sunday → weekly, 1st of month
# → monthly; prunes daily=7, weekly=4, monthly=3 per stack by mtime.
# Idempotent — safe to re-run same day.
set -euo pipefail

backups="${HOME}/.volume-backups"
mkdir -p "${backups}/daily" "${backups}/weekly" "${backups}/monthly"

stacks=(adguard freshrss homebridge wallabag)
today_iso="$(date +%Y-%m-%d)"
dow="$(date +%u)"   # 1..7, 7 = Sunday
dom="$(date +%d)"   # 01..31

# --- Promote ---
for stack in "${stacks[@]}"; do
    today_tgz="${backups}/daily/${stack}-${today_iso}.tgz"
    [ -f "$today_tgz" ] || continue   # nothing to promote

    if [ "$dow" = "7" ]; then
        # cp -n: no-clobber. Same-day re-run: weekly already exists, skip.
        cp -n "$today_tgz" "${backups}/weekly/${stack}-${today_iso}.tgz"
    fi

    if [ "$dom" = "01" ]; then
        cp -n "$today_tgz" "${backups}/monthly/${stack}-${today_iso}.tgz"
    fi
done

# --- Prune (per stack, per tier, by mtime, keep N newest) ---
prune_tier() {
    local tier="$1" keep="$2"
    for stack in "${stacks[@]}"; do
        # List <stack>-*.tgz (NOT PRE-MIGRATION-*) sorted oldest→newest by mtime
        find "${backups}/${tier}" -maxdepth 1 -type f -name "${stack}-*.tgz" \
            -print0 2>/dev/null \
            | xargs -0 stat -f "%m %N" 2>/dev/null \
            | sort -n \
            | awk -v keep="$keep" '
                { files[NR] = $0; total = NR }
                END {
                    drop = total - keep
                    for (i = 1; i <= drop; i++) {
                        # strip leading mtime, print path only
                        sub(/^[0-9]+ /, "", files[i]); print files[i]
                    }
                }' \
            | while IFS= read -r f; do
                rm -f "$f"
            done
    done
}

prune_tier daily 7
prune_tier weekly 4
prune_tier monthly 3
```

**Verification:**

```bash
chmod +x stacks/scripts/backup-rotate.sh

# Pure prune scenario — run on whatever today is. With 4 same-day tarballs
# from Phase 3 Task 7, nothing should be promoted (unless today is Sun/1st)
# and nothing should be pruned (only 1 daily per stack so far).
./stacks/scripts/backup-rotate.sh
echo "exit=$?"
ls -la ~/.volume-backups/daily/
# Expected: same files still there, nothing in weekly/ or monthly/ (unless today is Sun/1st)

# Idempotency
./stacks/scripts/backup-rotate.sh
ls -la ~/.volume-backups/daily/
# Expected: identical to previous listing

# Force-test the Sunday promotion: synthesize a fake daily, fake date via env
# Use TZ tricks or simply faketime if installed. Simplest reliable approach:
# create N fake daily tarballs, then test prune. Run the whole block in a
# subshell with a trap so artifacts are cleaned up even if the test aborts
# mid-flight.
(
    trap 'rm -rf ~/.volume-backups/.test-rotate' EXIT

    mkdir -p ~/.volume-backups/.test-rotate
    cp ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz ~/.volume-backups/.test-rotate/
    # Make 10 fake daily tarballs with backdated mtimes
    for i in 1 2 3 4 5 6 7 8 9 10; do
        cp ~/.volume-backups/.test-rotate/adguard-$(date +%Y-%m-%d).tgz \
           ~/.volume-backups/daily/adguard-$(date -v-${i}d +%Y-%m-%d).tgz
        touch -t $(date -v-${i}d +%Y%m%d0400) \
           ~/.volume-backups/daily/adguard-$(date -v-${i}d +%Y-%m-%d).tgz
    done
    ls ~/.volume-backups/daily/adguard-*.tgz | wc -l
    # Expected: 11 (today + 10 backdated)

    ./stacks/scripts/backup-rotate.sh
    ls ~/.volume-backups/daily/adguard-*.tgz | wc -l
    # Expected: 7 (oldest 4 pruned by mtime)
)
# trap auto-fires on subshell exit, removes ~/.volume-backups/.test-rotate

# Re-take a fresh adguard backup so doctor stays green (the rotate above
# may have pruned today's tarball if synthesis didn't honor it; safer to
# re-take after the test).
dotfiles stacks adguard backup
```

**Sunday promotion test (read-only audit, since today's `date +%u` may not be 7):**

Read the script source — confirm the cp -n line for Sunday is present and correct. The cp idempotency is exercised by the no-clobber semantic itself, not requiring a test run.

**Commit:**
```bash
git add stacks/scripts/backup-rotate.sh
git commit -m "stacks: add GFS rotation script (daily=7, weekly=4, monthly=3)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Add the `backup-all` recipe to `stacks/justfile`

**Verifies:** stack-resilience.AC1.6

**Files:**
- Modify: `stacks/justfile`

**Implementation:**

`backup-all` runs each per-stack `backup` recipe in turn, then `backup-rotate.sh` once at the end. Order: alphabetical (matches `up-all` style — `adguard, freshrss, homebridge, wallabag`).

**AC7.1 interpretation note (list-style aggregate exemption):** AC7.1 says every justfile recipe is ≤1–2 lines, intended to push orchestration logic into scripts. The pre-existing `up-all`/`down-all`/`ps-all`/`pull-all` recipes are 4 lines each (one per stack — pure list, no orchestration). `backup-all` follows the same pattern at 5 lines (one per stack + one rotate). These list-style aggregates are exempt from the ≤2-line rule because each line is a self-contained subcommand invocation with no inter-line state — the pattern is auditable at a glance and there's no reasonable script extraction that improves it. Phase 8's audit task explicitly carves out this exemption.

`up-all` is currently lines 9-13. Insert `backup-all` immediately after `pull-all` (line 31) and before `vm-shared` (line 33), so backup commands cluster with the composite recipes:

```just

backup-all:
    just adguard backup
    just freshrss backup
    just homebridge backup
    just wallabag backup
    @./scripts/backup-rotate.sh
```

The leading blank line preserves visual separation. `@` on the rotate line suppresses just's command echo (the script itself is silent on success — no output is correct behavior).

**Verification:**

```bash
dotfiles stacks backup-all
echo "exit=$?"
# Expected: 4 tarballs in ~/.volume-backups/daily/ (today's), exit 0,
# rotate ran exactly once (visible by checking weekly/monthly state didn't
# duplicate or re-promote on a same-day re-run).

# Confirm 4 tarballs and they're all today
ls -la ~/.volume-backups/daily/*-$(date +%Y-%m-%d).tgz | wc -l
# Expected: 4 (one per stack)

# AC1.6 — rotate runs exactly once: re-run backup-all, weekly count unchanged
weekly_before=$(ls ~/.volume-backups/weekly/ 2>/dev/null | wc -l)
dotfiles stacks backup-all
weekly_after=$(ls ~/.volume-backups/weekly/ 2>/dev/null | wc -l)
[ "$weekly_before" = "$weekly_after" ] && echo "rotate idempotent OK" || echo "rotate NOT idempotent"
```

**Commit:**
```bash
git add stacks/justfile
git commit -m "stacks: add backup-all recipe (per-stack backup + GFS rotate)"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create the launchd plist template

**Verifies:** Sets up AC1.9 (verified in Task 5).

**Files:**
- Create: `stacks/scripts/com.cxreiff.dotfiles.backup.plist.template`

**Implementation:**

A plist with `__HOME__`, `__JUST__`, `__JUSTFILE__`, `__BACKUPS__` placeholders that `backup-install.sh` substitutes via `envsubst`. Settings:

- `Label`: `com.cxreiff.dotfiles.backup` (must match the filename, by convention).
- `ProgramArguments`: `[just, -f, <justfile>, stacks, backup-all]`. Use absolute path to `just` so launchd's stripped PATH doesn't matter for resolving the binary.
- `EnvironmentVariables.PATH`: includes `/opt/homebrew/bin` (where `just`, `docker`, `colima`, `envsubst`, `gh` live on Apple Silicon) plus standard system paths. `docker` needs to be reachable from inside the just recipes.
- `EnvironmentVariables.HOME`: explicitly set so `${HOME}` expansions in compose files resolve correctly under launchd.
- `StartCalendarInterval`: `Hour=4 Minute=0` — daily 4 AM. (Per Apple docs and verified for macOS 15: omitted `Day`/`Month`/`Weekday` keys are wildcards. Will fire on next wake if Mac was asleep at the scheduled time.)
- `StandardOutPath` and `StandardErrorPath`: `~/.volume-backups/.log/{stdout,stderr}.log`. The `.log` subdir is created by `backup-install.sh`.
- `RunAtLoad`: false (default — don't immediately fire on `bootstrap`; we want it to wait for 4 AM).

Apple Silicon paths verified: `/opt/homebrew/bin/just`, `/opt/homebrew/bin/docker`, `/opt/homebrew/bin/colima`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cxreiff.dotfiles.backup</string>

  <key>ProgramArguments</key>
  <array>
    <string>__JUST__</string>
    <string>-f</string>
    <string>__JUSTFILE__</string>
    <string>stacks</string>
    <string>backup-all</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>__HOME__</string>
  </dict>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>__BACKUPS__/.log/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>__BACKUPS__/.log/stderr.log</string>

  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
```

**Verification:**

```bash
# Confirm well-formed XML (plutil should succeed)
plutil -lint stacks/scripts/com.cxreiff.dotfiles.backup.plist.template
# Expected: "OK" (placeholders are still valid XML strings)
```

**Commit:**
```bash
git add stacks/scripts/com.cxreiff.dotfiles.backup.plist.template
git commit -m "stacks: add launchd plist template for nightly backup"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Create the launchd installer script (`stacks/scripts/backup-install.sh`)

**Verifies:** stack-resilience.AC1.9

**Files:**
- Create: `stacks/scripts/backup-install.sh` (executable, mode 755)

**Implementation:**

Behavior:
1. Determine absolute paths: `JUST=$(which just)`, `JUSTFILE` resolved from `git rev-parse --show-toplevel` + `/justfile`, `HOME` from env, `BACKUPS=$HOME/.volume-backups`.
2. `mkdir -p $BACKUPS/.log $HOME/Library/LaunchAgents`.
3. `envsubst < template > $HOME/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` substituting the four placeholders.
4. If the agent is already loaded, `launchctl bootout` first (idempotency: re-running install replaces the existing plist).
5. `launchctl bootstrap gui/$(id -u) <plist>`.
6. `launchctl print gui/$(id -u)/com.cxreiff.dotfiles.backup` — print to stdout so the user sees the schedule confirmation.

Use `envsubst` with explicit variable names (it's installed at `/opt/homebrew/bin/envsubst` — confirmed). Pass the placeholder names explicitly so envsubst doesn't accidentally substitute `${HOME}` or other natural shell vars in the template.

```bash
#!/usr/bin/env bash
# stacks/scripts/backup-install.sh
# Install the nightly-backup LaunchAgent. Idempotent — bootouts existing
# instance before re-bootstrapping. Templates absolute paths into the plist
# so launchd doesn't depend on PATH lookup.
set -euo pipefail

just_bin="$(command -v just)"
[ -n "$just_bin" ] || { echo "just not found on PATH" >&2; exit 2; }

# Resolve repo root from the script location (this script lives at
# <repo>/stacks/scripts/backup-install.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
justfile="${repo_root}/justfile"
[ -f "$justfile" ] || { echo "justfile not found at ${justfile}" >&2; exit 2; }

backups="${HOME}/.volume-backups"
agents="${HOME}/Library/LaunchAgents"
plist="${agents}/com.cxreiff.dotfiles.backup.plist"
template="${SCRIPT_DIR}/com.cxreiff.dotfiles.backup.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

mkdir -p "${backups}/.log" "${agents}"

# Substitute placeholders. envsubst with an explicit list ensures we don't
# accidentally substitute other ${VAR}-looking strings in the template.
JUST="$just_bin" JUSTFILE="$justfile" HOME="$HOME" BACKUPS="$backups" \
    envsubst '$JUST $JUSTFILE $HOME $BACKUPS' < "$template" > "$plist"

# But the template uses __PLACEHOLDER__ form (envsubst only substitutes
# $VAR / ${VAR}). So fall back to sed for __PLACEHOLDER__ form.
sed -i '' \
    -e "s|__JUST__|${just_bin}|g" \
    -e "s|__JUSTFILE__|${justfile}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__BACKUPS__|${backups}|g" \
    "$plist"

# Validate the resulting plist
plutil -lint "$plist" >/dev/null

# Idempotent reload
uid="$(id -u)"
if launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}" "$plist"
fi
launchctl bootstrap "gui/${uid}" "$plist"

echo
echo "Installed: $plist"
echo
launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" | grep -E '(state|path|next start) ='
```

**Note on the envsubst+sed double-substitution:** `envsubst` only substitutes `$VAR` / `${VAR}` syntax. Our template uses `__VAR__` instead so the file remains a valid plist standalone (no shell-var-looking strings that could confuse XML readers). The script does a single `sed` pass to substitute the `__VAR__` placeholders. The earlier `envsubst` invocation in the script is a defensive no-op for the `__VAR__` form but would handle a future `${VAR}`-style template if we change the convention. To keep things simpler, you can drop the envsubst call and rely on sed alone — verify the script runs to completion either way.

**Simpler version (recommended — drop envsubst, sed alone):**

```bash
#!/usr/bin/env bash
# stacks/scripts/backup-install.sh
set -euo pipefail

just_bin="$(command -v just)"
[ -n "$just_bin" ] || { echo "just not found on PATH" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
justfile="${repo_root}/justfile"
[ -f "$justfile" ] || { echo "justfile not found at ${justfile}" >&2; exit 2; }

backups="${HOME}/.volume-backups"
agents="${HOME}/Library/LaunchAgents"
plist="${agents}/com.cxreiff.dotfiles.backup.plist"
template="${SCRIPT_DIR}/com.cxreiff.dotfiles.backup.plist.template"
[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }

mkdir -p "${backups}/.log" "${agents}"

sed \
    -e "s|__JUST__|${just_bin}|g" \
    -e "s|__JUSTFILE__|${justfile}|g" \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__BACKUPS__|${backups}|g" \
    "$template" > "$plist"

plutil -lint "$plist" >/dev/null

uid="$(id -u)"
if launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" >/dev/null 2>&1; then
    launchctl bootout "gui/${uid}" "$plist"
fi
launchctl bootstrap "gui/${uid}" "$plist"

echo
echo "Installed: $plist"
echo
launchctl print "gui/${uid}/com.cxreiff.dotfiles.backup" | grep -E '(state|path|next start) ='
```

Use the simpler version. (The envsubst invocation in the verbose draft was redundant once the convention is `__VAR__`-only.)

**Verification:** none yet — exercised in Task 5.

**Commit:**
```bash
git add stacks/scripts/backup-install.sh
git commit -m "stacks: add backup-install script for launchd LaunchAgent"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Wire `backup-install` recipe and exercise the launchd path end-to-end

**Verifies:** stack-resilience.AC1.9

**Files:**
- Modify: `stacks/justfile`

**Implementation:**

Add `backup-install` recipe immediately after `backup-all` (one-line delegation):

```just

backup-install:
    @./scripts/backup-install.sh
```

**Verification:**

```bash
dotfiles stacks backup-install
# Expected output (last lines):
#   Installed: /Users/cxreiff/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
#   state = waiting
#   path = /Users/cxreiff/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
#   next start = <some Sat/Sun/Mon at 04:00>

# Verify plist exists and is well-formed
ls -la ~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
plutil -lint ~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
# Expected: lists OK

# AC1.9: launchctl print shows it loaded and scheduled
launchctl print gui/$(id -u)/com.cxreiff.dotfiles.backup
# Expected: state = waiting, schedule = StartCalendarInterval { Hour = 4 Minute = 0 }, next start within next 24h at 04:00

# Idempotency — re-run, should bootout-then-bootstrap cleanly
dotfiles stacks backup-install
# Expected: same final output, no error

# Manually fire the agent NOW (don't wait for 4 AM); verify it produces tarballs
launchctl kickstart -k gui/$(id -u)/com.cxreiff.dotfiles.backup
# Wait ~30s for backup to run
sleep 30

# Tarballs should be fresh (mtime within last minute)
ls -la ~/.volume-backups/daily/*-$(date +%Y-%m-%d).tgz
# Expected: 4 tarballs, all very recent

# Logs should have content
ls -la ~/.volume-backups/.log/
cat ~/.volume-backups/.log/stdout.log | tail -20
# Expected: stdout.log shows the backup-all recipe output (script paths, no errors)
cat ~/.volume-backups/.log/stderr.log
# Expected: empty or only just/docker non-fatal warnings
```

**Commit:**
```bash
git add stacks/justfile
git commit -m "stacks: wire backup-install recipe (one-line delegation)"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Promote backup-age check from WARN to FAIL

**Verifies:** stack-resilience.AC5.6 (final form)

**Files:**
- Modify: `stacks/scripts/doctor.sh`

**Implementation:**

In the `--- Backups ---` section added in Phase 2 / extended in Phase 3, the "older than 36h" branch currently calls `warn`. Change it to `fail`. Also change the "no backups yet" branch from `warn` to `fail` — by Phase 4, every stack should have at least one tarball (the launchd timer runs nightly and the user just ran `backup-all` manually).

Locate the block in `stacks/scripts/doctor.sh`:

```bash
    if [ "$age_hours" -gt 36 ]; then
        warn "${stack} latest backup is ${age_hours}h old (>36h)"
    else
        pass "${stack} latest backup is ${age_hours}h old"
    fi
```

Change `warn` to `fail`. Same for the two "no backups yet" branches above.

After this change, `doctor` will hard-fail if the launchd timer hasn't been running. That's the intended Phase 4 contract.

**Verification:**

```bash
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0 (because we just ran backup-all twice in Tasks 2 and 5)

# Exercise the FAIL branch
touch -t $(date -v-2d +%Y%m%d0000) ~/.volume-backups/daily/adguard-$(date +%Y-%m-%d).tgz
dotfiles stacks doctor; echo "exit=$?"
# Expected: [FAIL] for adguard backup, exit 1

# Restore by re-taking the backup
dotfiles stacks adguard backup
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0
```

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: promote backup-age WARN to FAIL (timer is running now)"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Document the launchd timer in `stacks/README.md`

**Verifies:** Supports AC7.4/AC7.5 (Phase 8 audit) by making the install path discoverable.

**Files:**
- Modify: `stacks/README.md`

**Implementation:**

Add a new `## Backups` section after the existing `## Recipes` section (before "Migrating from the old…" section). Brief — the per-stack READMEs are operational; this is the index entry.

```markdown
## Backups

Per-stack `backup` and `restore` recipes tar `~/.volumes/<stack>/` into
`~/.volume-backups/{daily,weekly,monthly}/`. The aggregate `backup-all`
recipe runs all four stacks then `backup-rotate.sh`:

| Tier | Retention | Promoted from |
|---|---|---|
| `daily/` | 7 per stack | `backup-all` itself |
| `weekly/` | 4 per stack | Sunday's daily tarball |
| `monthly/` | 3 per stack | The 1st of month's daily tarball |

Schedule unattended nightly runs via launchd:

```sh
dotfiles stacks backup-install     # installs ~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
launchctl print gui/$(id -u)/com.cxreiff.dotfiles.backup    # confirm next start
```

Logs land in `~/.volume-backups/.log/{stdout,stderr}.log`. `dotfiles stacks
doctor` fails if the latest tarball for any stack is older than 36 hours.

(Phase 6 adds a cross-reference to `docs/migration-recovery.md` here once
that doc exists.)
```

**Verification:**

Read the rendered file, confirm the section sits cleanly between Recipes and the legacy migration section. The `docs/migration-recovery.md` cross-reference will be satisfied by Phase 6.

**Commit:**
```bash
git add stacks/README.md
git commit -m "stacks/README: document backup tiers + launchd install"
```
<!-- END_TASK_7 -->

---

## Done When

- `dotfiles stacks backup-all` writes 4 same-day tarballs to `~/.volume-backups/daily/` and runs `backup-rotate.sh` exactly once at the end (verified by re-run idempotency).
- `dotfiles stacks backup-install` installs `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist`, bootstraps it, and prints the schedule. `launchctl print gui/$(id -u)/com.cxreiff.dotfiles.backup` shows `state = waiting` with `next start` at 4:00 AM the next day.
- `launchctl kickstart -k gui/$(id -u)/com.cxreiff.dotfiles.backup` runs the backup successfully; tarballs appear; `~/.volume-backups/.log/stdout.log` contains the run output; `stderr.log` is empty.
- `backup-rotate.sh` prunes the daily tier to 7 newest per stack (verified with backdated mtimes); same-day re-runs don't duplicate weekly/monthly tarballs.
- `dotfiles stacks doctor` exits 1 with a clear `[FAIL]` line when any stack's latest backup is >36h old (verified by `touch -t`-backdating). Re-taking the backup restores all-green.
- Seven commits land: `backup-rotate.sh`, `backup-all` recipe, plist template, `backup-install.sh`, `backup-install` recipe, doctor promotion, README update.
