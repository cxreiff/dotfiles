# Connectome Agent Implementation Plan — Phase 4 of 4 (design Phase 3: operations integration)

**Goal:** Make onecli v2 and connectome first-class stacks in the repo's operational tooling. That covers fault-tolerant `up-all`, ordered `down-all`/`backup-all`, connectome backup/restore, GFS rotation, `doctor` checks plus the static security-invariant lints (verified against broken fixtures), boot autostart, and the documentation rewrite.

**Architecture:** Extend the existing `just` module structure (`stacks/justfile` aggregates, per-stack justfiles) and the existing `stacks/scripts/doctor.sh` + `lib/check.sh` helpers (`pass`/`warn`/`fail`/`off`; exit 1 if any FAIL). The invariant lints are a standalone script `stacks/connectome/scripts/lint.sh` that `doctor` calls. A companion `lint-test.sh` generates single-violation fixtures on the fly from the tracked files.

**Tech Stack:** just 1.50, bash, jq, Docker Compose (`config --no-interpolate --format json` for static parsing; JSON is valid compose YAML, so fixtures can be JSON), macOS `stat -f`, launchd (existing startup daemon).

**Scope:** 4 phases from original design (design Phases 0–3). This file covers design Phase 3. Numbering: `phase_04` = design Phase 3.

**Codebase verified:** 2026-10-14

**Execution context (applies to every command in this phase):**
- Work happens in the worktree `/Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent` (branch `connectome-agent`); relative paths are relative to it.
- The interactive `dotfiles` alias points at the **main** checkout (`~/Developer/dotfiles`, still on `main`), so it would run the old recipes. Wherever this plan writes `dotfiles …`, run it against the worktree. Shell state doesn't persist between commands, so define it in each command: `dotfiles() { just -f /Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent/justfile "$@"; }`.
- **`.env` files are gitignored and exist only in the main checkout.** Phase 2 Task 1 Step 0b copies them into the worktree (`install -m 600`, real copies; no symlinks, because `init-env` `mv`s over the path and doctor's `stat` would report the link). New secrets (onecli v2 keys, `stacks/connectome/.env`) are created in the worktree and copied back to main in Phase 4 Task 8 Step 0. Until then the worktree holds the only on-disk copy of the new secrets, so **never remove the worktree before that step**.
- The nightly backup LaunchDaemon is **paused** (`disable`d + booted out in Phase 2 Task 1) until the branch is merged at the end of Phase 4. It would otherwise run main's onecli v1 recipes against the v2 stack. When a doctor backup-age check needs fresh tarballs:
  - back up **onecli and connectome** with the worktree recipes;
  - back up the **unchanged stacks** (adguard, freshrss, homebridge, wallabag) with main's justfile, e.g. `just -f ~/Developer/dotfiles/justfile stacks freshrss backup`. Their recipes are identical, and main holds their `.env`.
- **Residual risk (accepted):** an *unplanned* reboot during execution makes the startup daemon run main's `up-all`, including main's v1 `onecli up`. If that happens, after the FileVault unlock immediately run `docker --context colima-agents rm -f onecli` (the v1 container name), then the worktree's `dotfiles stacks onecli up`, and confirm the backup daemon is still disabled (`sudo launchctl print-disabled system | grep com.cxreiff.dotfiles.backup`; it was `disable`d, which persists across reboots). Avoid planned reboots until Phase 4 Task 8.

**Verified state this phase relies on (after Phases 1–3 of this plan):**
- `stacks/justfile`, as verified pre-plan:
  - `mod` lines (Phase 3 inserts `mod connectome`).
  - `up-all`: `just adguard up` / `freshrss` / `homebridge` / `onecli` / `wallabag`, sequential, stops at the first failure.
  - `down-all`: onecli, wallabag, homebridge, freshrss, adguard.
  - `ps-all`, `pull-all` (same five), and `backup-all` (adguard, freshrss, homebridge, onecli, wallabag, then `@./scripts/backup-rotate.sh`).
  - `doctor: @./scripts/doctor.sh`. No loop variable; every recipe lists stacks explicitly.
- `stacks/scripts/backup-rotate.sh:15`: `stacks=(adguard freshrss homebridge onecli wallabag)`.
- `stacks/scripts/startup.sh` runs `vm-shared-up`, `vm-bridged-up`, `vm-agents-up` (any failure aborts), then `up-all` (a failure only logs a WARNING). No change needed: once `up-all` continues past failures, onecli and connectome come up even if adguard fails.
- `stacks/scripts/doctor.sh` (325 lines, `set -u`, sources `lib/check.sh`). Sections:
  - `--- Infrastructure ---` (~13).
  - `--- Stack volumes ---` (~98): a `~/.volumes` loop over adguard/freshrss/homebridge/wallabag, then an `onecli_pgdata`/`onecli_app-data` named-volume check inside `if docker --context colima-agents info`, `off` otherwise.
  - `--- Backups ---` (~128): loop `for stack in adguard freshrss homebridge onecli wallabag`, with onecli `off` when the agents VM is down and a >36 h FAIL.
  - `--- DNS forwarder ---` (~166), `--- DNS failover ---` (~202), `--- IP coupling ---` (~236).
  - `--- Stack identity & env ---` (~271): homebridge BRIDGE_USERNAME check, then a `for stack in adguard freshrss homebridge onecli wallabag` `.env`-keys-vs-`.env.example` loop, with no mode check.
  - Final `[ "$__check_failed" -eq 0 ] || exit 1`.
  - Line numbers are approximate (the quoted copy had wrapping artefacts), so anchor edits on the section header strings and loop lines.
- `stacks/onecli/justfile` (Phase 2): `down` is plain `compose down`, and `backup`/`restore` already quiesce with `stop`/`start`.
- `stacks/connectome/justfile` (Phase 3): `init-env build image-test provision-codex up down restart ps pull shell logs serve smoke force-failure set-heartbeat-rate ratelimit-check`. There is no `backup`/`restore` yet. `logs` already tails `headless.log` + `failures.log`.
- Volume names: `connectome_state`, `connectome_workspace`, `connectome_outbox`, `onecli_pgdata`, `onecli_app-data`.
- Docs to update: `CLAUDE.md` (Repo shape; Reproducible-vs-runtime table ~33-48 with the onecli named-volume row at ~44; Colima table ~119-123, agents row "`onecli` (credential vault), future agent-side services"; "Why keep FileVault" paragraph ~177-187 describing the onecli key; Common commands; "Last updated" line 3). `stacks/README.md` (stack lists, composite recipes ~1003 in the quote, Backups, Autostart). `stacks/onecli/README.md` (v1: Fresh-device setup, .env keys, Auth model, "Why we can't customise admin@localhost", Volumes, Nanoclaw integration, Migration from the upstream installer, Backup notes). `docs/migration-recovery.md` (99 lines: Why no in-place rename, Prerequisites mentions "four stacks", Clean-slate procedure with a restore loop over `adguard freshrss homebridge wallabag`, On a fresh device).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### connectome-agent.AC11: operations integration (Phase 3)
- **connectome-agent.AC11.1 Success:** `up-all` starts `onecli` before `connectome`. If one stack fails, it continues with the rest, prints a summary naming each failed stack, and exits non-zero if any failed.
- **connectome-agent.AC11.2 Success:** `down-all` stops `connectome` before `onecli`, and `ps-all`/`pull-all` include `connectome`.
- **connectome-agent.AC11.3 Failure:** `onecli down` refuses while connectome containers exist, and `connectome up` without the `onecli-agents` network fails with "run `dotfiles stacks onecli up` first".
- **connectome-agent.AC11.4 Success:** `connectome logs` shows `$DATA_DIR/headless.log` and `logs/failures.log`.
- **connectome-agent.AC11.5 Success:** `connectome backup` uses `compose stop`/`start`, never `down`/`up`, and writes `~/.volume-backups/daily/connectome-YYYY-MM-DD.tgz` containing `state` and `workspace`. It first prunes `llm-calls.*.jsonl` older than 14 days and truncates `headless.log` past its size cap.
- **connectome-agent.AC11.6 Success:** `backup-all` backs up `connectome` before `onecli`, and the onecli tarball contains ciphertext and the CA but not `SECRET_ENCRYPTION_KEY`.
- **connectome-agent.AC11.7 Failure:** `connectome restore <tarball>` refuses when the target volumes are non-empty. On empty volumes it restores a working stack.
- **connectome-agent.AC11.8 Success:** after a reboot (FileVault unlock), the startup daemon brings up the `agents` VM, onecli and connectome without intervention.

### connectome-agent.AC12: doctor and invariant lints (Phase 3)
- **connectome-agent.AC12.1 Success:** on the healthy live system, `doctor` reports PASS for each check:
  - onecli api, web and gateway healthy; migrations exited 0;
  - gateway CA owned by the gateway uid; image CA fingerprint = gateway CA;
  - `onecli-agents` exists with `connectome` and `shell` attached;
  - connectome volumes present; backup age;
  - `.env` mode 0600 for every stack;
  - the shell has no LLM grant;
  - all invariant lints.
- **connectome-agent.AC12.2 Failure:** each lint FAILs on a fixture that violates exactly its invariant (1, 2, 4, 6, 7, 8, 9).
- **connectome-agent.AC12.3 Failure:** `doctor` FAILs on a CA fingerprint mismatch, and on any stack `.env` with mode other than 0600.
- **connectome-agent.AC12.4 Success:** `llm-calls`/`headless.log` over their size thresholds produce a WARN, not a FAIL.
- **connectome-agent.AC12.5 Success:** lints read `.env` key names only, never values.

### connectome-agent.AC13: documentation (Phase 3)
- **connectome-agent.AC13.1 Success:** `stacks/onecli/README.md` describes v2 (auth, key location, threat model). `stacks/connectome/README.md` covers sources and patches, provisioning, calibration values and known exposures.
- **connectome-agent.AC13.2 Success:** CLAUDE.md no longer refers to nanoclaw or onecli v1. Its onecli key/FileVault paragraph, Reproducible-vs-runtime table, Colima table and stack lists include connectome.
- **connectome-agent.AC13.3 Success:** `docs/migration-recovery.md` covers rebuilding onecli v2 and connectome on a fresh device, including manual re-application of local patches.

---

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->
<!-- START_TASK_1 -->
### Task 1: Aggregate recipes in `stacks/justfile`

**Verifies:** connectome-agent.AC11.1, connectome-agent.AC11.2

**Files:**
- Modify: `stacks/justfile` (the `up-all`, `down-all`, `ps-all`, `pull-all` and `backup-all` recipes)

**Implementation:** replace those five recipes with:

```just
# Bring every stack up. Continues past an individual stack's failure (e.g. an
# expired Tailscale PAT failing `adguard up`) so onecli/connectome still start
# at boot; prints a summary and exits non-zero if any stack failed.
# onecli precedes connectome (connectome joins onecli's network).
up-all:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for s in adguard freshrss homebridge onecli connectome wallabag; do
        echo "=== ${s} up ==="
        # Module recipes run with cwd stacks/, so plain `just <stack> up`
        # resolves stacks/justfile (as the other aggregates do). Do NOT use
        # {{justfile()}} here: inside a module it is the ROOT justfile.
        just "$s" up || failed+=("$s")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "up-all: FAILED: ${failed[*]}" >&2
        exit 1
    fi
    echo "up-all: all stacks up"

# DNS-aware shutdown: apps before adguard; connectome before onecli (onecli
# owns the onecli-agents network and refuses to go down under connectome).
down-all:
    just connectome down
    just onecli down
    just wallabag down
    just homebridge down
    just freshrss down
    just adguard down

ps-all:
    just adguard ps
    just connectome ps
    just freshrss ps
    just homebridge ps
    just onecli ps
    just wallabag ps

pull-all:
    just adguard pull
    just connectome pull
    just freshrss pull
    just homebridge pull
    just onecli pull
    just wallabag pull

# connectome before onecli: connectome's tarball is taken while the gateway
# is up; connectome then briefly loses the gateway during onecli's stop/start
# (harmless at 04:00).
backup-all:
    just adguard backup
    just freshrss backup
    just homebridge backup
    just connectome backup
    just onecli backup
    just wallabag backup
    @./scripts/backup-rotate.sh
```

**Testing:**
- AC11.1 ordering and summary: make one stack's `up` fail harmlessly by making its compose file unreadable. compose can't load it, and no container is touched:

  ```bash
  bash -c '
  just_up_all() { just -f ~/Developer/dotfiles/.worktrees/connectome-agent/justfile stacks up-all; }
  mode=$(stat -f %Lp stacks/freshrss/compose.yaml)
  trap "chmod $mode stacks/freshrss/compose.yaml" EXIT
  chmod 000 stacks/freshrss/compose.yaml
  out=$(mktemp)
  just_up_all >"$out" 2>&1; echo "rc=$?"
  chmod "$mode" stacks/freshrss/compose.yaml; trap - EXIT
  grep -n "=== \(onecli\|connectome\|wallabag\) up ===\|up-all: FAILED" "$out"; rm -f "$out"'
  ```

  (Run from the worktree root. The `dotfiles` alias points at `~/Developer/dotfiles`, the main checkout, so the worktree's justfile is invoked explicitly. Use the same `just -f <worktree>/justfile` form everywhere in this phase until the branch is merged.)

  Expected: `=== onecli up ===` on an earlier line than `=== connectome up ===`, `=== wallabag up ===` still present (it continued after freshrss), `up-all: FAILED: freshrss`, and `rc=1`.
- Healthy run: `dotfiles stacks up-all; echo rc=$?` → `up-all: all stacks up`, `rc=0`.
- AC11.2 static: `just -f stacks/justfile --show down-all | grep -n 'connectome\|onecli'` shows connectome on an earlier line than onecli, and `--show ps-all`/`--show pull-all` each contain `connectome`.

**Commit:** `stacks: up-all continues past failures; connectome in aggregates`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: `onecli down` refuses under connectome; connectome `up` network guard check

**Verifies:** connectome-agent.AC11.3, connectome-agent.AC11.4

**Files:**
- Modify: `stacks/onecli/justfile` (the `down` recipe)

**Implementation — `down`:**

```just
# Refuses while connectome containers exist: compose down would try to remove
# the onecli-agents network they are attached to. `down-all` orders this.
down:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(docker --context {{context}} ps -aq --filter label=com.docker.compose.project=connectome)" ]; then
        echo "onecli: connectome containers exist — run \`dotfiles stacks connectome down\` first" >&2
        exit 1
    fi
    docker --context {{context}} compose down
```

The connectome `up` guard already exists (Phase 3 Task 10).

**Testing:**
- AC11.3 (a): with connectome running, `dotfiles stacks onecli down; echo rc=$?` → the refusal message, `rc=1`, and onecli still `Up`.
- AC11.3 (b): `dotfiles stacks connectome down && dotfiles stacks onecli down`, then `dotfiles stacks connectome up; echo rc=$?` → `network onecli-agents missing — run \`dotfiles stacks onecli up\` first`, `rc=1`. Then `dotfiles stacks onecli up && dotfiles stacks connectome up`.
- AC11.4: `logs` follows forever, and macOS has no `timeout(1)`, so run it in the background and kill it, along with the `tail -F` inside the container:

  ```bash
  bash -c '
  out=$(mktemp)
  just -f /Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent/justfile stacks connectome logs >"$out" 2>&1 & p=$!
  sleep 5; kill $p 2>/dev/null
  docker --context colima-agents exec connectome pkill -f "tail -n 50 -F" 2>/dev/null || true
  cat "$out"; rm -f "$out"'
  ```

  Expected: the `==> /agent/state/data/headless.log <==` and `==> /agent/state/logs/failures.log <==` headers, each followed by content (failures.log has the Phase 3 Task 12 entry). If `pkill` is absent in the image, `docker --context colima-agents restart connectome` is an acceptable cleanup.

**Commit:** `stacks/onecli: down refuses while connectome containers exist`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: connectome `backup`/`restore`; rotation

**Verifies:** connectome-agent.AC11.5, connectome-agent.AC11.6, connectome-agent.AC11.7

**Files:**
- Modify: `stacks/connectome/justfile` (add `backup`, `restore`, and the `backups_dir` variable)
- Modify: `stacks/scripts/backup-rotate.sh:15` (add `connectome` to the array)

**Implementation — justfile additions:**

```just
backups_dir := join(env("HOME"), ".volume-backups", "daily")

# Quiesce with stop/start (never down/up), prune llm-calls.*.jsonl older than
# 14 days, cap headless.log (keep the last 10 MiB once it passes 50 MiB),
# then tar the state + workspace volumes. No-op when the agents VM is down.
backup:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! docker --context {{context}} info >/dev/null 2>&1; then
        echo "connectome: agents VM not running, skipping backup"
        exit 0
    fi
    docker --context {{context}} compose stop
    trap 'docker --context {{context}} compose start' EXIT
    docker --context {{context}} run --rm -v connectome_state:/s alpine sh -c '
        find /s/data -maxdepth 1 -name "llm-calls.*.jsonl" -mtime +14 -print -delete
        log=/s/data/headless.log
        if [ -f "$log" ] && [ "$(stat -c %s "$log")" -gt 52428800 ]; then
            tail -c 10485760 "$log" > /s/data/.headless.tail && cat /s/data/.headless.tail > "$log" && rm -f /s/data/.headless.tail
            echo "truncated headless.log to last 10 MiB"
        fi'
    mkdir -p "{{backups_dir}}"
    dst="{{backups_dir}}/connectome-$(date +%Y-%m-%d).tgz"
    docker --context {{context}} run --rm \
        -v connectome_state:/src/state:ro \
        -v connectome_workspace:/src/workspace:ro \
        -v "{{backups_dir}}":/dst \
        alpine sh -c "cd /src && tar czf /dst/$(basename "$dst") state workspace"
    echo "$dst"

# Restore state + workspace from a tarball; refuses non-empty volumes.
restore tarball:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! docker --context {{context}} info >/dev/null 2>&1; then
        echo "connectome: agents VM not running (run dotfiles stacks vm-agents-up)" >&2
        exit 1
    fi
    [ -f "{{tarball}}" ] || { echo "connectome: tarball not found: {{tarball}}" >&2; exit 1; }
    docker --context {{context}} compose stop 2>/dev/null || true
    # On refusal/failure, bring the (untouched) stack back.
    trap 'docker --context {{context}} compose start 2>/dev/null || true' ERR
    abs="$(cd "$(dirname "{{tarball}}")" && pwd)/$(basename "{{tarball}}")"
    # Fresh device: create the volumes with compose's labels (adopted by
    # compose without warnings) and WITHOUT image copy-up — `compose create`
    # would pre-populate workspace with the shell image's outbox/ dir and the
    # emptiness check below would then refuse.
    for v in state workspace; do
        docker --context {{context}} volume inspect "connectome_${v}" >/dev/null 2>&1 \
            || docker --context {{context}} volume create \
                --label com.docker.compose.project=connectome \
                --label com.docker.compose.volume="${v}" "connectome_${v}" >/dev/null
    done
    docker --context {{context}} run --rm \
        -v connectome_state:/dst/state \
        -v connectome_workspace:/dst/workspace \
        -v "$(dirname "$abs")":/src:ro \
        alpine sh -c "
            # An existing-but-unused workspace may hold only an empty outbox/
            # mountpoint (copied up from the shell image); treat that as empty.
            if [ -n \"\$(ls -A /dst/state 2>/dev/null)\" ] \
               || [ -n \"\$(ls -A /dst/workspace 2>/dev/null | grep -vx outbox)\" ] \
               || [ -n \"\$(ls -A /dst/workspace/outbox 2>/dev/null)\" ]; then
                echo 'connectome: target volumes are non-empty; refusing to clobber. Manually clear and retry.' >&2
                exit 1
            fi
            cd /dst && tar xzpf /src/$(basename "{{tarball}}")"
    trap - ERR
    # cwd is stacks/connectome (this module's dir), so `just up` resolves the
    # connectome justfile; {{justfile()}} would be the ROOT justfile.
    just up
```

The volumes are created with compose's project/volume labels, because unlabelled volumes make compose warn "volume already exists but was not created by Docker Compose". `compose create` is avoided because its image copy-up pre-populates them.

**`backup-rotate.sh:15`:** `stacks=(adguard connectome freshrss homebridge onecli wallabag)`.

**Testing:**
- AC11.5: drop a fake old file: `docker --context colima-agents exec connectome sh -c ': > /agent/state/data/llm-calls.2000-01-01T00-00-00-000Z.jsonl && touch -d "2000-01-01" /agent/state/data/llm-calls.2000-01-01T00-00-00-000Z.jsonl'`. Then:
  - `dotfiles stacks connectome backup` prints the deleted path and `~/.volume-backups/daily/connectome-<today>.tgz`.
  - `tar -tzf <it> | awk -F/ '{print $1}' | sort -u` → `state workspace`.
  - `just -f stacks/connectome/justfile --show backup | grep -cE 'compose (down|up)'` → `0`.
  - The containers are `Up` afterwards.
  - The old llm-calls file is gone.
  - Truncation: create a 51 MiB headless.log only if the real one is small. Instead, verify with a fixture volume: `docker volume create cx-trunc-test`, write a 51 MiB `data/headless.log` into it, and run the same `sh -c` block against `-v cx-trunc-test:/s`. Assert size = 10485760, then remove the volume.
- AC11.6: `just -f stacks/justfile --show backup-all` lists connectome before onecli. Then `tar -tzf ~/.volume-backups/daily/onecli-<today>.tgz | grep -c 'app-data/gateway/ca.pem'` ≥ 1, and the key is absent: `bash -c 'tar -xzOf ~/.volume-backups/daily/onecli-$(date +%Y-%m-%d).tgz 2>/dev/null | grep -acF -f <(grep "^SECRET_ENCRYPTION_KEY=" stacks/onecli/.env | cut -d= -f2-)'` → `0`. The key reaches grep through a process-substitution file, never argv or the terminal.
- AC11.7 refusal: `dotfiles stacks connectome restore ~/.volume-backups/daily/connectome-<today>.tgz; echo rc=$?` on the live stack → `non-empty; refusing`, `rc=1`. Then `dotfiles stacks connectome up`, because restore stopped the stack.
- AC11.7 restore onto empty volumes (**destructive rehearsal; confirm with the user first**; a tarball from the step above must exist):

  ```bash
  t=~/.volume-backups/daily/connectome-$(date +%Y-%m-%d).tgz; test -s "$t"
  dotfiles stacks connectome down
  docker --context colima-agents volume rm connectome_state connectome_workspace
  dotfiles stacks connectome restore "$t"
  dotfiles stacks connectome smoke
  ```

  Expected: restore succeeds, the stack comes up, and `smoke` passes. The operator DMs the bot and gets a reply with prior conversation context intact.

**Commit:** `stacks/connectome: backup/restore (stop/start quiesce, log pruning); rotate connectome`
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 4-5) -->
<!-- START_TASK_4 -->
### Task 4: Invariant lint script

**Verifies:** connectome-agent.AC12.2 (via Task 5), connectome-agent.AC12.5

**Files:**
- Create: `stacks/connectome/scripts/lint.sh` (0755)

**Implementation:**

```bash
#!/usr/bin/env bash
# stacks/connectome/scripts/lint.sh
# Static lints for the connectome security invariants (design Phase 2,
# invariants 1, 2, 4, 6, 7, 8, 9). Reads the tracked recipe / compose files /
# Dockerfile and the KEY NAMES of .env files — never .env values.
# Used by `dotfiles stacks doctor`; fixture paths are overridable for tests.
#
# Usage: lint.sh [--recipe F] [--compose F] [--dockerfile F] [--env F]
#                [--onecli-compose F] [--onecli-env F]
# Exit: 0 all pass; 1 any FAIL; 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${stack_dir}/../.." && pwd)"
# shellcheck source=../../scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

recipe="${stack_dir}/recipes/agent.json"
compose="${stack_dir}/compose.yaml"
dockerfile="${stack_dir}/build/connectome.Dockerfile"
envf="${stack_dir}/.env"
oc_compose="${repo_root}/stacks/onecli/compose.yaml"
oc_env="${repo_root}/stacks/onecli/.env"
while [ $# -gt 0 ]; do
    case "$1" in
        --recipe) recipe="$2" ;; --compose) compose="$2" ;; --dockerfile) dockerfile="$2" ;;
        --env) envf="$2" ;; --onecli-compose) oc_compose="$2" ;; --onecli-env) oc_env="$2" ;;
        *) echo "lint: unknown argument $1" >&2; exit 2 ;;
    esac
    shift 2
done

# KEY NAMES only (AC12.5): never source or read values.
keys() { [ -f "$1" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1; true; }
cjson() { docker compose -f "$1" config --no-interpolate --format json 2>/dev/null; }
rj() { jq -e "$1" "$recipe" >/dev/null 2>&1; }

c=$(cjson "$compose") || c=""
oc=$(cjson "$oc_compose") || oc=""
[ -n "$c" ] || fail "lint: cannot parse ${compose}"
cj() { jq -e "$1" >/dev/null 2>&1 <<<"$c"; }
env_keys=$(keys "$envf")
svc_env_keys=$(jq -r '.services[]?.environment // {} | keys[]' <<<"$c" 2>/dev/null)

# 1 — host-code-execution features off; no in-process workspace
if rj '(.codeExecution == null or .codeExecution == false or .codeExecution.enabled == false)
       and ((.extensions // {}) | length == 0)
       and ((.modules.mcplAdmin // false) == false)
       and (.modules.workspace == false)'; then
    pass "invariant 1: codeExecution, mcplAdmin, extensions off; modules.workspace false"
else
    fail "invariant 1: codeExecution/mcplAdmin/extensions enabled or modules.workspace not false (${recipe})"
fi

# 2 — fleet never `true`; object form only, explicit children, allowedRecipes under /agent/recipes
if rj '(.modules.fleet == null)
       or ((.modules.fleet | type) == "object"
           and ((.modules.fleet.children // null) | type) == "array"
           and ((.modules.fleet.allowedRecipes // []) | length > 0 and all(startswith("/agent/recipes/"))))'; then
    pass "invariant 2: modules.fleet absent or explicit object form"
else
    fail "invariant 2: modules.fleet is true or lacks explicit children/allowedRecipes under /agent/recipes"
fi

# 4 — only `outbox` shared, read-only in connectome; connectome binds read-only; shell has no binds
if cj '([.services.connectome.volumes[]? | select(.type=="volume") | .source] as $a
        | [.services.shell.volumes[]? | select(.type=="volume") | .source] as $b
        | ($a - ($a - $b))) == ["outbox"]
       and ([.services.connectome.volumes[]? | select(.source=="outbox") | .read_only] == [true])
       and ([.services.connectome.volumes[]? | select(.type=="bind") | .read_only == true] | all)
       and ([.services.shell.volumes[]? | select(.type=="bind")] | length == 0)'; then
    pass "invariant 4: only outbox shared (ro in connectome); no writable binds"
else
    fail "invariant 4: volume sharing between connectome and shell violates the outbox-only rule"
fi

# 6 — no onecli user API key; private-destination allowance never covers 172.16/12; no host-gateway
bad_keys=$(printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -iE 'API_KEY|USER_KEY|ONECLI_KEY|^OC_' || true)
gw_private=$(jq -r '.services.gateway.environment.GATEWAY_ALLOW_PRIVATE_DESTINATIONS // ""' <<<"$oc" 2>/dev/null)
oc_env_has_private=$(keys "$oc_env" | grep -cx GATEWAY_ALLOW_PRIVATE_DESTINATIONS || true)
host_gw=$(printf '%s\n%s\n' "$c" "$oc" | jq -s '[.[] | .services[]? | (.extra_hosts // empty) | tostring | select(test("host-gateway"))] | length' 2>/dev/null || echo 1)
if [ -z "$bad_keys" ] && ! grep -qE '(^|,)172\.' <<<"$gw_private" && [ "$oc_env_has_private" = 0 ] && [ "$host_gw" = 0 ]; then
    pass "invariant 6: no onecli user API key; no 172.16/12 private allowance; no host-gateway"
else
    fail "invariant 6: ${bad_keys:+api-key-like keys [$(tr '\n' ' ' <<<"$bad_keys")] }${gw_private:+private allowance [$gw_private] }$([ "$oc_env_has_private" != 0 ] && echo 'GATEWAY_ALLOW_PRIVATE_DESTINATIONS set in onecli .env (value not inspected) ')$([ "$host_gw" != 0 ] && echo 'extra_hosts host-gateway')"
fi

# 7 — GATE_TELEMETRY unset everywhere
if ! printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -qx GATE_TELEMETRY && ! grep -q 'GATE_TELEMETRY' "$dockerfile"; then
    pass "invariant 7: GATE_TELEMETRY unset"
else
    fail "invariant 7: GATE_TELEMETRY is set (.env key, compose env, or Dockerfile)"
fi

# 8 — Discord filters fixed in the recipe; no filters file; dangerous tools disabled
if rj '(.mcpServers.discord.env | has("DISCORD_FILTERS_FILE") | not)
       and ((.mcpServers.discord.env.DISCORD_DM_USERS // "") | length > 0)
       and ((.mcpServers.discord.env.DISCORD_GUILD_ID // "") | length > 0)
       and ((.mcpServers.discord.disabledTools // []) as $d
            | ["filters_update","create_text_channel","delete_channel"] | all(. as $t | $d | index($t)))' \
   && ! printf '%s\n%s\n' "$env_keys" "$svc_env_keys" | grep -qx DISCORD_FILTERS_FILE; then
    pass "invariant 8: discord filters fixed, no filters file, filters_update/create/delete disabled"
else
    fail "invariant 8: discord filters file set, allowlist missing, or dangerous tools not disabled"
fi

# 9 — OBSERVERS_FILE on the read-only recipes mount, not overridden
if grep -q 'OBSERVERS_FILE=/agent/recipes/observers.json' "$dockerfile" \
   && cj '(.services.connectome.environment // {} | has("OBSERVERS_FILE") | not)
          and ([.services.connectome.volumes[]? | select(.target=="/agent/recipes") | .read_only] == [true])'; then
    pass "invariant 9: OBSERVERS_FILE points at the read-only /agent/recipes mount"
else
    fail "invariant 9: OBSERVERS_FILE overridden or /agent/recipes not mounted read-only"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
```

**Verification:**

```bash
./stacks/connectome/scripts/lint.sh; echo "rc=$?"
grep -nE '^\s*(source|\.)\s+.*\.env|\$\(cat .*\.env' stacks/connectome/scripts/lint.sh || echo "OK: lint never sources .env"
```

Expected: seven `[OK] invariant …` lines, `rc=0`, and `OK: lint never sources .env`.

**Commit:** `stacks/connectome: static security-invariant lints`
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Lint fixture tests

**Verifies:** connectome-agent.AC12.2, connectome-agent.AC12.5

**Files:**
- Create: `stacks/connectome/scripts/lint-test.sh` (0755)
- Modify: `stacks/connectome/justfile` (add `lint` and `lint-test`)

**Implementation:** `lint-test.sh` builds, in a `mktemp -d` dir (trap-removed), a **baseline** fixture set:
- `recipe.json` = the tracked `recipes/agent.json`;
- `compose.json` = `docker compose -f stacks/connectome/compose.yaml config --no-interpolate --format json` (JSON is valid compose YAML);
- `env` = the key lines of `stacks/connectome/.env.example` (values empty);
- `onecli-compose.json` from the onecli compose, the same way;
- `onecli-env` = the keys of `stacks/onecli/.env.example`;
- `Dockerfile` = a copy of `build/connectome.Dockerfile`.

It asserts the baseline yields zero FAILs. Then, for each mutation below, it copies the baseline, applies **one** change, runs `lint.sh` with all six `--…` overrides, and asserts that the output contains `[FAIL] invariant N` for exactly that N and **no other** `[FAIL]` line:

| N | Mutation |
|---|---|
| 1 | `jq '.codeExecution = {"enabled": true}' recipe.json` |
| 2 | `jq '.modules.fleet = true' recipe.json` |
| 4 | `jq '.services.shell.volumes += [{"type":"volume","source":"state","target":"/agent/state"}]' compose.json` |
| 6 | append `ONECLI_API_KEY=` to `env` |
| 7 | append `GATE_TELEMETRY=` to `env` |
| 8 | `jq '.mcpServers.discord.env.DISCORD_FILTERS_FILE = "/agent/state/discord/filters.json"' recipe.json` |
| 9 | `jq '.services.connectome.environment.OBSERVERS_FILE = "/agent/state/observers.json"' compose.json` |
| AC12.5 | append `NOTE=GATE_TELEMETRY ONECLI_API_KEY DISCORD_FILTERS_FILE` to `env` (names only appear in a **value**) → expect **zero** FAILs |

Each case prints `PASS lint-fixture <N>` or `FAIL lint-fixture <N>: <lint output>`. The script exits 1 on any FAIL.

**justfile** — add:

```just
# Static security-invariant lints (also run by `dotfiles stacks doctor`).
lint:
    @./scripts/lint.sh

# Prove each lint fails on a fixture violating exactly its invariant.
lint-test:
    @./scripts/lint-test.sh
```

**Verification:**

```bash
dotfiles stacks connectome lint-test; echo "rc=$?"
```

Expected: eight `PASS lint-fixture …` lines (1, 2, 4, 6, 7, 8, 9, AC12.5), `rc=0`.

**Commit:** `stacks/connectome: lint fixture tests`
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_6 -->
### Task 6: `doctor` — onecli v2, connectome, env modes, lints

**Verifies:** connectome-agent.AC12.1, connectome-agent.AC12.3, connectome-agent.AC12.4

**Files:**
- Modify: `stacks/scripts/doctor.sh`. The edits are at four anchors: the end of `--- Stack volumes ---`, the `--- Backups ---` loop, a **new section** inserted immediately before `echo "--- Stack identity & env ---"`, and the `.env` loop in that section.

**Edits:**

1. **Stack volumes** — directly after the onecli named-volume `for vol in onecli_pgdata onecli_app-data` loop (inside the same `if docker --context colima-agents info` block), add:

```bash
    for vol in connectome_state connectome_workspace connectome_outbox; do
        if echo "$onecli_volumes" | grep -qx "$vol"; then
            pass "connectome named volume '$vol' present in colima-agents"
        else
            fail "connectome named volume '$vol' missing in colima-agents (run: dotfiles stacks connectome up)"
        fi
    done
```

2. **Backups** — change `for stack in adguard freshrss homebridge onecli wallabag; do` to `for stack in adguard connectome freshrss homebridge onecli wallabag; do`, and the agents-down skip condition from `[ "$stack" = "onecli" ]` to `{ [ "$stack" = "onecli" ] || [ "$stack" = "connectome" ]; }`.

3. **New section** (insert before `echo` / `echo "--- Stack identity & env ---"`):

```bash
echo
echo "--- Agents (onecli + connectome) ---"

# Image CA files to compare with the gateway CA; overridable for the
# AC12.3 fixture test (DOCTOR_CONNECTOME_IMAGES="img1 img2").
connectome_images="${DOCTOR_CONNECTOME_IMAGES:-connectome-host:local connectome-shell:local}"
llm_warn_mb="${DOCTOR_LLM_CALLS_WARN_MB:-500}"
hlog_warn_mb="${DOCTOR_HEADLESS_LOG_WARN_MB:-50}"
A="docker --context colima-agents"
if ! $A info >/dev/null 2>&1; then
    off "agents checks skipped (colima-agents not running)"
else
    for n in onecli-api onecli-web onecli-gateway; do
        h=$($A inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$n" 2>/dev/null || echo missing)
        [ "$h" = healthy ] && pass "$n healthy" || fail "$n is ${h} (run: dotfiles stacks onecli up)"
    done
    m=$($A inspect -f '{{.State.Status}} {{.State.ExitCode}}' onecli-migrations 2>/dev/null || echo "missing -")
    [ "$m" = "exited 0" ] && pass "onecli-migrations exited 0" || fail "onecli-migrations: ${m}"

    gw_uid=$($A exec onecli-gateway id -u 2>/dev/null || echo "?")
    ca_uid=$($A exec onecli-gateway stat -c %u /app/data/gateway/ca.pem 2>/dev/null || echo "??")
    [ "$gw_uid" = "$ca_uid" ] && pass "gateway CA owned by gateway uid (${gw_uid})" \
        || fail "gateway CA owner uid ${ca_uid} != gateway uid ${gw_uid}"

    gw_ca=$($A exec onecli-gateway cat /app/data/gateway/ca.pem 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    for img in $connectome_images; do
        if ! $A image inspect "$img" >/dev/null 2>&1; then
            fail "image ${img} missing (run: dotfiles stacks connectome build)"; continue
        fi
        img_ca=$($A run --rm --network none --entrypoint cat "$img" /usr/local/share/ca-certificates/onecli-gateway.crt 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
        [ "$img_ca" = "$gw_ca" ] && pass "${img} CA fingerprint matches gateway CA" \
            || fail "${img} CA fingerprint differs from onecli-gateway CA (fresh vault? run: dotfiles stacks connectome build)"
    done

    attached=$($A network inspect onecli-agents -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    if [ -z "$attached" ]; then
        fail "network onecli-agents missing (run: dotfiles stacks onecli up)"
    else
        for n in connectome connectome-shell; do
            grep -qE "(^| )${n}( |$)" <<<"$attached" && pass "${n} attached to onecli-agents" \
                || fail "${n} not attached to onecli-agents (run: dotfiles stacks connectome up)"
        done
    fi

    # Shell must hold no LLM grant (needs the operator key in the host CLI).
    # shellcheck source=../onecli/scripts/lib/api.sh
    source "${SCRIPT_DIR}/../onecli/scripts/lib/api.sh"
    if operator_key >/dev/null 2>&1; then
        shell_id=$(agent_field connectome-shell id 2>/dev/null || true)
        # The shell is granted nothing at all (design: connectome-shell ← nothing),
        # so count every secret grant rather than relying on a type field.
        llm=$(api GET "/v1/agents/${shell_id}/grants" 2>/dev/null | jq '[.secrets[]?] | length' 2>/dev/null || echo "?")
        [ "$llm" = 0 ] && pass "connectome-shell has no LLM grant" \
            || fail "connectome-shell LLM grants: ${llm} (run: dotfiles stacks onecli policy)"
    else
        warn "connectome-shell grant check skipped (host onecli CLI not authenticated)"
    fi

    if $A inspect connectome >/dev/null 2>&1; then
        llm_kb=$($A exec connectome sh -c 'du -ck /agent/state/data/llm-calls.*.jsonl 2>/dev/null | tail -1 | cut -f1' 2>/dev/null || echo 0)
        hlog_kb=$($A exec connectome sh -c 'du -k /agent/state/data/headless.log 2>/dev/null | cut -f1' 2>/dev/null || echo 0)
        [ "${llm_kb:-0}" -gt $(( llm_warn_mb * 1024 )) ] && warn "connectome llm-calls total $(( llm_kb / 1024 )) MiB > ${llm_warn_mb} MiB (pruned >14d by backup)" \
            || pass "connectome llm-calls total $(( ${llm_kb:-0} / 1024 )) MiB"
        [ "${hlog_kb:-0}" -gt $(( hlog_warn_mb * 1024 )) ] && warn "connectome headless.log $(( hlog_kb / 1024 )) MiB > ${hlog_warn_mb} MiB (capped by backup)" \
            || pass "connectome headless.log $(( ${hlog_kb:-0} / 1024 )) MiB"
    fi
fi

# Static security-invariant lints (key names only; never .env values).
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "${line#\[FAIL\] }" ;;
        *)         [ -n "$line" ] && warn "lint: ${line}" ;;
    esac
done < <("${SCRIPT_DIR}/../connectome/scripts/lint.sh" 2>&1)
```

`lib/api.sh` sets no shell options, so sourcing it is safe under doctor's `set -u`. It defines `ONECLI_API`/`ONECLI_BIN` with defaults.

4. **Stack identity & env** — change the env loop header to `for stack in adguard connectome freshrss homebridge onecli wallabag; do`. Inside the loop, right after the `if [ ! -f "$actual" ]; then … continue; fi` block, add:

```bash
    mode=$(stat -f %Lp "$actual")
    if [ "$mode" = 600 ]; then
        pass "${stack}/.env mode 0600"
    else
        fail "${stack}/.env mode ${mode} (run: chmod 600 stacks/${stack}/.env)"
    fi
```

**Testing:**
- AC12.1: `dotfiles stacks doctor; echo rc=$?` on the healthy system. Every item in AC12.1 appears as `[OK]` (the onecli trio, migrations, CA owner, both image fingerprints, both attachments, the three connectome volumes, connectome and onecli backup age, all six `.env mode 0600` lines, the shell grant, seven `invariant` lines), and `rc=0`.
- AC12.3 (mode): `bash -c 'chmod 644 stacks/freshrss/.env; ./stacks/scripts/doctor.sh | grep "freshrss/.env mode"; echo rc=${PIPESTATUS[0]}; chmod 600 stacks/freshrss/.env'` → `[FAIL] freshrss/.env mode 644`, `rc=1`. The snippets in this task use `bash -c` because `PIPESTATUS` is bash-only; the interactive shell is zsh.
- AC12.3 (CA mismatch): build a fixture image whose CA file differs, run doctor against it, then remove it:

  ```bash
  d=$(mktemp -d); openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/k" -out "$d/onecli-gateway.crt" -subj /CN=doctor-fixture -days 1 2>/dev/null
  printf 'FROM connectome-shell:local\nUSER root\nCOPY onecli-gateway.crt /usr/local/share/ca-certificates/onecli-gateway.crt\n' > "$d/Dockerfile"
  docker --context colima-agents build -q -t connectome-doctor-fixture:local "$d"
  bash -c 'DOCTOR_CONNECTOME_IMAGES=connectome-doctor-fixture:local ./stacks/scripts/doctor.sh | grep "CA fingerprint"; echo "rc=${PIPESTATUS[0]}"'
  docker --context colima-agents image rm connectome-doctor-fixture:local; rm -rf "$d"
  ```

  Expected: `[FAIL] connectome-doctor-fixture:local CA fingerprint differs …`, `rc=1`.
- AC12.4: `bash -c 'DOCTOR_LLM_CALLS_WARN_MB=0 DOCTOR_HEADLESS_LOG_WARN_MB=0 ./stacks/scripts/doctor.sh | grep -E "llm-calls|headless.log"; echo rc=${PIPESTATUS[0]}'`. Expected: both lines `[WARN]` (provided the files are non-empty, which they are after Phase 3) and `rc=0` (no FAIL introduced).

**Commit:** `stacks/doctor: onecli v2 + connectome checks, .env modes, invariant lints`
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Documentation

**Verifies:** connectome-agent.AC13.1, connectome-agent.AC13.2, connectome-agent.AC13.3

**Files:**
- Modify: `stacks/onecli/README.md` (rewrite)
- Modify: `stacks/connectome/README.md` (complete)
- Modify: `CLAUDE.md`
- Modify: `stacks/README.md`
- Modify: `docs/migration-recovery.md`

**Content requirements:**

`stacks/onecli/README.md` — keep the operational tone of the existing per-stack READMEs and **drop** the v1 sections (`Auth model` local/oauth, `Why we can't customise admin@localhost`, `Nanoclaw integration`, `Migration from the upstream installer`). New headings:
- `## Fresh-device setup`: `init-env` (escrow reminder) → `up` → `bootstrap` (immediately: registration is open) → `import-openai` → `policy`, plus the CLI upgrade.
- `## .env keys`: the three secrets, the postgres vars, ports.
- `## Auth (v2)`: account login; API key in the host CLI only; agent `aoc_` tokens select the identity; no default identity (407); dashboard via `ssh -L 10254:127.0.0.1:10254 -L 10256:127.0.0.1:10256 cxmini`.
- `## Key location and FileVault`: `SECRET_ENCRYPTION_KEY` lives in `.env` (0600) with an escrow copy in the password manager. Tarballs hold ciphertext and the CA only.
- `## Identities and policy`: the rules table, grants, auto-attach caveat, `policy <n>`, `probe`.
- `## Threat model`: path rules are defense-in-depth only (dot-segment bypass, to report upstream); the private-destination refusal covers proxied traffic only; the agent can't reach the vault API.
- `## Volumes`: keep the named-volume rationale.
- `## Backup notes`: stop/start, never down/up; `down` refuses under connectome; the v1 archive at `~/.volume-backups/archive/onecli-v1-final.tgz`.

`stacks/connectome/README.md` — keep the Phase 3 sections and add:
- `## Architecture`: the two containers, the filesystem layout `/agent/{cwd,recipes,state,outbox}`, networks.
- `## Provisioning`: `provision-codex`, and never use the WebUI "log in again".
- `## Security invariants`: the 10 invariants, with how each is checked (`lint`, `image-test`, `smoke`).
- `## Known exposures (accepted)`: copied in substance from the design.
- `## Future: persona fleet children`: the seams.
- `## Operations`: logs, backup/restore, `serve`, the model-swap rule (new `DATA_DIR`).

`CLAUDE.md`:
- Update `Last updated:` to the execution date.
- Repo shape / stack mentions: add `connectome`.
- Reproducible-vs-runtime table: change the onecli row to v2 (the named volumes hold ciphertext + gateway CA; the key is in `stacks/onecli/.env` + password manager). Add a row for the `connectome_state`/`connectome_workspace`/`connectome_outbox` named volumes, one for `stacks/connectome/sources.lock` (tracked) vs `~/Developer/connectome/` clones + `local` branches (external), and one for `~/.volume-backups/archive/` (gitignored runtime, outside GFS).
- Colima table, agents row: "`onecli` (credential vault v2), `connectome` (agent host + shell)".
- The `onecli` named-volume paragraph under the Colima section: v2.
- "Why keep FileVault" paragraph: the key now lives in `stacks/onecli/.env` (escrowed in the password manager), so vault tarballs are ciphertext-only. FileVault still protects `.env`, the live VM disk (decrypted runtime state, the connectome `state` volume with chronicle and `llm-calls` full prompts) and the backup tarballs of connectome. Keep the `fdesetup authrestart` guidance.
- Common commands: add `dotfiles stacks connectome build|provision-codex|smoke|lint`.
- Backups section: list connectome as stop/start quiesce.
- Remove every `nanoclaw` mention and any v1 phrasing (`local mode`, `admin@localhost`, `onecli:latest`).

`stacks/README.md`: add connectome to every stack list and to Stage 3. Describe `up-all`'s continue-and-summarize behaviour and the `down-all`/`backup-all` ordering, and add connectome to the Backups tiers.

`docs/migration-recovery.md`:
- Prerequisites: "four stacks" → the actual set including onecli and connectome. The password-manager copy of `SECRET_ENCRYPTION_KEY` is a prerequisite for restoring onecli.
- Clean-slate restore loop: add onecli and connectome. onecli restore needs `.env` with the escrowed key **before** `up`.
- New subsection `### onecli v2 and connectome on a fresh device`:
  - re-clone the four sources at the SHAs in `sources.lock`;
  - re-apply each `patch <clone> <subject>` by hand on a `local` branch (the patches aren't stored anywhere else — known gap, decision 22);
  - `connectome build` (the CA is per-vault: build **after** onecli is restored/up);
  - restore the tarballs, or provision from scratch (`bootstrap → import-openai → policy → connectome init-env → provision-codex`).

**Verification:**

```bash
grep -rniE 'nanoclaw|admin@localhost|local mode|onecli:latest' CLAUDE.md stacks/README.md stacks/onecli/README.md docs/migration-recovery.md || echo "OK: no v1/nanoclaw references"
grep -c connectome CLAUDE.md stacks/README.md docs/migration-recovery.md
grep -nE '^## ' stacks/onecli/README.md stacks/connectome/README.md
grep -n 'patch' docs/migration-recovery.md | head
```

Expected: `OK: no v1/nanoclaw references`, every file has a non-zero connectome count, and the headings listed above are present. migration-recovery mentions the manual patch re-application.

**Commit:** `docs: onecli v2 + connectome (READMEs, CLAUDE.md, migration-recovery)`
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Reboot autostart and final doctor gate

**Verifies:** connectome-agent.AC11.8, connectome-agent.AC12.1 (final)

**Files:** none.

**Step 0: Merge locally and resume the backup daemon (user decision 2026-10-14: daemons paused until merged)**

The startup and backup daemons run recipes from `~/Developer/dotfiles` (main). Before any reboot or nightly run, main must contain this branch. **Ask the user to confirm the merge** (local only, no push; the finishing-a-development-branch step offers PR/merge options, and if the user chooses a PR instead, merge it and `git -C ~/Developer/dotfiles pull` before continuing):

First, on the branch (worktree), commit anything still uncommitted from planning: the design revision (`docs/design-plans/2026-10-11-connectome-agent.md`, modified at plan time) and the plan directory, if they aren't committed yet.

```bash
git -C /Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent status --short   # must be empty after that commit
# The main checkout may carry unrelated local edits (at plan time: 4 stow/base files
# + untracked .claude/). --ff-only still succeeds as long as the branch does not
# touch those paths; it refuses (safely) otherwise — then ask the user.
git -C ~/Developer/dotfiles status --short
git -C ~/Developer/dotfiles merge --ff-only connectome-agent
git -C ~/Developer/dotfiles log --oneline -1
sudo launchctl enable system/com.cxreiff.dotfiles.backup
sudo launchctl bootstrap system /Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist
sudo launchctl print system/com.cxreiff.dotfiles.backup | head -3

# Copy the secrets created/changed on the branch back to main (values never printed).
wt=/Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent
for s in onecli connectome; do install -m 600 "$wt/stacks/$s/.env" ~/Developer/dotfiles/stacks/$s/.env; done
for s in adguard connectome freshrss homebridge onecli wallabag; do printf '%s %s\n' "$s" "$(stat -f %Lp ~/Developer/dotfiles/stacks/$s/.env 2>/dev/null || echo missing)"; done
cmp -s "$wt/stacks/onecli/.env" ~/Developer/dotfiles/stacks/onecli/.env && cmp -s "$wt/stacks/connectome/.env" ~/Developer/dotfiles/stacks/connectome/.env && echo "OK: secrets copied"

# Re-home the running containers on main's paths (connectome bind-mounts ./recipes;
# compose labels record the project dir), so removing the worktree later is safe.
just -f ~/Developer/dotfiles/justfile stacks onecli up
just -f ~/Developer/dotfiles/justfile stacks connectome up
docker --context colima-agents inspect connectome -f '{{range .Mounts}}{{if eq .Destination "/agent/recipes"}}{{.Source}}{{end}}{{end}}'

just -f ~/Developer/dotfiles/justfile stacks backup-all    # fresh tarballs for doctor
```

Expected: every stack's `.env` shows `600`, `OK: secrets copied`, and the `/agent/recipes` mount source is under `/Users/cxreiff/Developer/dotfiles/stacks/connectome/recipes`, not `.worktrees/…`. The worktree may be removed only after this step.

Expected: the fast-forward succeeds, the backup daemon is loaded again, and `backup-all` writes tarballs for every stack, connectome before onecli. From here on the plain `dotfiles` alias is correct.

**Step 1: Planned reboot (operator; needs sudo)**

The startup daemon already runs `vm-agents-up` and then `up-all`, which now includes onecli → connectome and continues past failures. Unlock the next boot remotely:

```bash
sudo fdesetup authrestart
```

**Step 2: After the host is back (SSH in)**

```bash
tail -n 30 ~/Library/Logs/com.cxreiff.dotfiles.startup.out.log
docker --context colima-agents ps --format '{{.Names}}\t{{.Status}}'
dotfiles stacks doctor; echo "rc=$?"
```

Expected: the startup log shows `starting Colima VMs` and then the `up-all` sections with `=== onecli up ===` before `=== connectome up ===`. The containers `onecli-api/web/gateway`, `onecli-postgres-1`, `connectome-shell` and `connectome` are `Up`. **doctor reports no FAIL and `rc=0`.** Any WARN is informational. The operator DMs the bot and gets a reply.

**Commit:** none.
<!-- END_TASK_8 -->
