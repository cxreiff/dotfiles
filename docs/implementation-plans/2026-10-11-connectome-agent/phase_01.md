# Connectome Agent Implementation Plan — Phase 1 of 4 (design Phase 0: decommission nanoclaw)

**Goal:** Remove nanoclaw (LaunchDaemon, agent image, local state) before the onecli v2 cutover, so nothing depends on the v1 vault.

**Architecture:** Purely operational on the Mac host and the `agents` Colima VM. No repo files change in this phase.

**Tech Stack:** macOS `launchctl`, Docker (`--context colima-agents`).

**Scope:** 4 phases from original design (design Phases 0–3). This file covers design Phase 0. File numbering: `phase_01` = design Phase 0, `phase_02` = design Phase 1, `phase_03` = design Phase 2, `phase_04` = design Phase 3.

**Codebase verified:** 2026-10-14

**State found at verification (2026-10-14):**
- `/Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist` is **present**.
- `pgrep -fl '[n]anoclaw'` returns nothing — no nanoclaw process is running (the pause step from the design was apparently already taken, but the daemon may still be registered).
- Image `nanoclaw-agent-v2-0aae9b3d:latest` (3.08 GB) is **present** in the `agents` VM.
- `~/Developer/nanoclaw/` is present (git checkout with `.env`, `data/`, `groups/`, `logs/`, `repo-tokens/`).
- `~/.volume-backups/archive/` does **not** exist yet (Phase 2 also creates it).

**Scope change (user, 2026-10-15):** nanoclaw stays *paused*, not decommissioned. Breaking it via the v1 vault cutover is accepted, but `~/Developer/nanoclaw`, the plist and the image are out of scope and left untouched. Executed state: the service is disabled in the `system` domain and no process runs (AC1.3 holds). AC1.1 and AC1.2 are **waived**. Tasks 1–2 below are kept for reference only and were not run.

**Operator-only steps.** Every task below needs `sudo` or a decision only the user can make. The executor must run read-only checks itself and hand the `sudo` commands to the user verbatim, then re-run the verification.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### connectome-agent.AC1: nanoclaw is decommissioned (Phase 0)
- **connectome-agent.AC1.1 Success:** `sudo launchctl print system/com.nanoclaw-v2-0aae9b3d` reports the service is not found, and `/Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist` does not exist.
- **connectome-agent.AC1.2 Success:** `docker --context colima-agents image ls` lists no `nanoclaw-agent-v2-0aae9b3d` image.
- **connectome-agent.AC1.3 Success:** no nanoclaw node process is running on the Mac.

---

<!-- START_TASK_1 -->
### Task 1: Disable and boot out the nanoclaw LaunchDaemon

**Verifies:** connectome-agent.AC1.3 (and the first half of AC1.1)

**Files:** none (system state only)

**Step 1: Inspect current registration (read-only, executor runs)**

```bash
ls -l /Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist
pgrep -fl '[n]anoclaw' || echo "no nanoclaw process"
launchctl print-disabled system | grep -i nanoclaw || echo "not in disabled list"
```

**Step 2: Operator runs (needs sudo)**

`bootout` exits non-zero ("No such process" / 3) when the service is already unloaded. That's expected and harmless.

```bash
sudo launchctl disable system/com.nanoclaw-v2-0aae9b3d
sudo launchctl bootout system/com.nanoclaw-v2-0aae9b3d || true
```

**Step 3: Verify**

```bash
pgrep -fl '[n]anoclaw' || echo "OK: no nanoclaw process"
sudo launchctl print system/com.nanoclaw-v2-0aae9b3d 2>&1 | head -1
```

Expected: `OK: no nanoclaw process`, and the `print` output says `Could not find service "com.nanoclaw-v2-0aae9b3d" in domain for system`.

**Commit:** none (no repo change).
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Remove the plist, the agent image, and archive nanoclaw state

**Verifies:** connectome-agent.AC1.1, connectome-agent.AC1.2

**Files:** none in the repo. Creates `~/.volume-backups/archive/nanoclaw-final.tgz` (runtime data, outside GFS rotation).

**Step 1: Archive `~/Developer/nanoclaw` state (operator decision)**

The design leaves archiving "as the user sees fit". Default proposed to the user: tar the whole checkout minus `node_modules/` and `dist/` into the archive directory, then leave the checkout in place. The tarball contains nanoclaw's `.env` and `repo-tokens/`, so it gets mode 0600. **Ask the user before running**; they may prefer to delete it or keep it as-is.

```bash
mkdir -p ~/.volume-backups/archive
chmod 700 ~/.volume-backups/archive
tar -C ~/Developer -czf ~/.volume-backups/archive/nanoclaw-final.tgz \
    --exclude='nanoclaw/node_modules' --exclude='nanoclaw/dist' nanoclaw
chmod 600 ~/.volume-backups/archive/nanoclaw-final.tgz
ls -l ~/.volume-backups/archive/nanoclaw-final.tgz
```

Expected: a non-empty tarball, mode `-rw-------`.

The v1 grants and `aoc_` tokens nanoclaw used die with the v1 vault in Phase 2. Nothing in onecli needs revoking now.

**Step 2: Operator removes the plist (needs sudo)**

```bash
sudo rm /Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist
```

**Step 3: Remove the agent image (executor may run)**

```bash
docker --context colima-agents image rm nanoclaw-agent-v2-0aae9b3d:latest
```

If this fails with "image is being used by stopped container", list the containers with `docker --context colima-agents ps -a --filter ancestor=nanoclaw-agent-v2-0aae9b3d`, remove them with `docker --context colima-agents rm <id>`, then retry.

**Step 4: Verify all of AC1**

```bash
test ! -e /Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist && echo "OK: plist gone"
sudo launchctl print system/com.nanoclaw-v2-0aae9b3d 2>&1 | grep -q 'Could not find service' && echo "OK: service not found"
docker --context colima-agents image ls --format '{{.Repository}}' | grep -q '^nanoclaw-agent-v2-0aae9b3d$' && echo "FAIL: image present" || echo "OK: image gone"
pgrep -fl '[n]anoclaw' && echo "FAIL: process running" || echo "OK: no process"
```

Expected: four `OK:` lines.

**Commit:** none (no repo change). The README section "Nanoclaw integration" in `stacks/onecli/README.md` is removed in Phase 4 (docs rewrite).
<!-- END_TASK_2 -->
