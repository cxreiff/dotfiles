# Phase 8: New-device clean-setup audit + bifurcated docs

**Goal:** Make the new-device setup path coherent across **three independent stages** — Stage 1 (universal: brew base + clone + base dotfiles), Stage 2 (container-running devices only: brew container packages + colima dotfiles + vm-up), Stage 3 (per-stack opt-in). Per-package stow recipes (`setup-base`, `setup-colima`) replace single-shot `setup` for users who only want one. The top-level `README.md` covers Stage 1 only; `stacks/README.md` covers Stages 2+3 with the explicit `dotfiles stow setup-colima` prerequisite. After all rewrites, **statically audit** the entire new-device walkthrough end-to-end and fix every gap found in the same phase.

**Architecture:** `stow/justfile` gains 8 new per-package recipes (`setup-base`, `setup-colima`, `restow-base`, `restow-colima`, `unstow-base`, `unstow-colima`, `status-base`, `status-colima`). Aggregate recipes remain. Documentation reorganization: `README.md` becomes Stage-1-only; `stow/README.md` documents per-package commands; `stacks/README.md` declares the stow prerequisite explicitly and covers Stages 2+3. The audit is executed as a documented investigation: read every README in dependency order, every script, every justfile; produce a gap list; fix each gap; commit each fix.

**Tech Stack:** GNU Stow (already in use), the per-stack scripts and recipes shipped by Phases 1-7. No new external dependencies.

**Scope:** Phase 8 of 8 — the closing phase. Depends on all previous phases.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC7: Code organization + new-device clean-setup validation
- **stack-resilience.AC7.1 Success:** Every justfile recipe is ≤1–2 lines; recipes that need more delegate to a script in `stacks/scripts/` or `stacks/<stack>/scripts/`. *(Phase 8 audits this across the whole repo and fixes any violation.)*
- **stack-resilience.AC7.2 Success:** `stacks/scripts/` contains: `doctor.sh`, `tar-stack.sh` (named `backup.sh` in this implementation), `restore-stack.sh` (named `restore.sh`), `backup-rotate.sh`, `bridged-ip-changed.sh`, `backup-install.sh`, `lib/check.sh`. *(Naming notes: design plan says `tar-stack.sh`/`restore-stack.sh`; we use `backup.sh`/`restore.sh` for symmetry with the recipe verbs. This is documented in the audit task as an intentional naming choice.)*
- **stack-resilience.AC7.3 Success:** Per-stack `scripts/` directories exist for stacks needing them: `stacks/adguard/scripts/{tailnet-dns.sh, wait-healthy.sh}`, `stacks/wallabag/scripts/{bootstrap.sh}`, `stacks/homebridge/scripts/{bootstrap.sh, gen-pin.sh}`. No per-stack `backup.sh`/`restore.sh`.
- **stack-resilience.AC7.4 Success:** Top-level `README.md` documents Stage 1 (universal) without referencing container concepts. `stow/README.md` documents per-package setup. `stacks/README.md` documents Stages 2 + 3 with `dotfiles stow setup-colima` as an explicit prerequisite.
- **stack-resilience.AC7.5 Success:** Each stage's walkthrough references only earlier-step deliverables or documented manual actions; Stage 1 has no container dependencies; Stages 2 + 3 declare their stow-side prerequisites; no step depends on undocumented manual environment state.
- **stack-resilience.AC7.6 Success:** Phase 8 audit produces a documented gap list; every gap is fixed within the same plan execution.
- **stack-resilience.AC7.7 Success:** `dotfiles stow setup-base` stows only `base`; `dotfiles stow setup-colima` stows only `colima`; aggregate `setup` stows both.

---

## Operational Context (read before executing)

This phase is **mostly documentation + small justfile additions + a static audit pass**. It modifies one user-impacting recipe area (stow), but the existing aggregate recipes (`setup`, `restow`, `unstow`, `status`) remain unchanged — the new per-package recipes are additive, not replacing. Existing users typing `dotfiles stow setup` get exactly the same behavior they did before.

**Pre-flight (verify before starting):**
- All previous phases (1-7) complete. Final `dotfiles stacks doctor` is all-green.
- All commits from previous phases are landed on `main`.

---

<!-- START_TASK_1 -->
### Task 1: Add per-package stow recipes to `stow/justfile`

**Verifies:** stack-resilience.AC7.7

**Files:**
- Modify: `stow/justfile`

**Implementation:**

Current shape (verified — `stow/justfile` is 22 lines):
```just
default:
    @just --list

setup:
    stow -d {{source_directory()}} -t ~ base
    stow --no-folding -d {{source_directory()}} -t ~ colima

restow:
    stow -R -d {{source_directory()}} -t ~ base
    stow -R --no-folding -d {{source_directory()}} -t ~ colima

unstow:
    stow -D -d {{source_directory()}} -t ~ base
    stow -D --no-folding -d {{source_directory()}} -t ~ colima

status:
    stow --simulate -v -d {{source_directory()}} -t ~ base
    stow --simulate -v --no-folding -d {{source_directory()}} -t ~ colima
```

Add 8 per-package recipes. Pattern: each is exactly 1 line, mirrors a single line of the aggregate. Insert each per-package pair AFTER its corresponding aggregate (visual grouping):

```just
default:
    @just --list

# Stow all active packages onto a fresh device
setup:
    stow -d {{source_directory()}} -t ~ base
    stow --no-folding -d {{source_directory()}} -t ~ colima

setup-base:
    stow -d {{source_directory()}} -t ~ base

setup-colima:
    stow --no-folding -d {{source_directory()}} -t ~ colima

# Re-link everything (run after adding files to packages)
restow:
    stow -R -d {{source_directory()}} -t ~ base
    stow -R --no-folding -d {{source_directory()}} -t ~ colima

restow-base:
    stow -R -d {{source_directory()}} -t ~ base

restow-colima:
    stow -R --no-folding -d {{source_directory()}} -t ~ colima

# Remove all symlinks
unstow:
    stow -D -d {{source_directory()}} -t ~ base
    stow -D --no-folding -d {{source_directory()}} -t ~ colima

unstow-base:
    stow -D -d {{source_directory()}} -t ~ base

unstow-colima:
    stow -D --no-folding -d {{source_directory()}} -t ~ colima

# Dry-run: show what stow would do
status:
    stow --simulate -v -d {{source_directory()}} -t ~ base
    stow --simulate -v --no-folding -d {{source_directory()}} -t ~ colima

status-base:
    stow --simulate -v -d {{source_directory()}} -t ~ base

status-colima:
    stow --simulate -v --no-folding -d {{source_directory()}} -t ~ colima
```

**Verification:**

```bash
# All 12 recipes present (4 aggregate + 8 per-package)
dotfiles stow --list | grep -cE '^\s*(setup|restow|unstow|status)(-base|-colima)?\s'
# Expected: 12

# AC7.7: setup-base stows only base, setup-colima stows only colima.
# Verify by status (dry-run) — show what each per-package would do.
dotfiles stow status-base | head
# Expected: only references to base/* paths (no colima/*)
dotfiles stow status-colima | head
# Expected: only references to colima/* paths (no base/*)
```

Any actual stow op against the live `$HOME` is risky to reverse, so verify by status/dry-run, not by re-running setup itself.

**Commit:**
```bash
git add stow/justfile
git commit -m "stow: add per-package recipes (setup-base, setup-colima, etc.)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Rewrite `stow/README.md` for per-package usage and updated colima profile names

**Verifies:** stack-resilience.AC7.4

**Files:**
- Modify: `stow/README.md`

**Implementation:**

Current state has outdated profile names (line 11: `~/.colima/default/colima.yaml`, `~/.colima/adguard/colima.yaml` — those are the pre-rename names; current are `shared` and `bridged`).

Full rewrite (overwrite entirely):

```markdown
# stow

GNU Stow packages — config files that other tools read from fixed paths,
symlinked from the repo into `$HOME`.

## Packages

| Package | Folding | Targets |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.config/zsh/completions`, `~/.zshrc` |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/shared/colima.yaml`, `~/.colima/bridged/colima.yaml` |

`colima` uses `--no-folding` because the target directories
(`~/.colima/<profile>/`) hold runtime state files that mustn't end up
inside the dotfiles repo via folder symlinking.

## Setup

| Audience | Command |
|---|---|
| Editor + shell only (most users) | `dotfiles stow setup-base` |
| Adding container support (a few devices) | `dotfiles stow setup-colima` |
| Both at once (legacy / opinionated) | `dotfiles stow setup` |

The `setup` aggregate is unchanged — it stows both packages. The
per-package variants are for cases where a device only wants one.

## Other ops

| Recipe (aggregate) | Per-package equivalents | Effect |
|---|---|---|
| `restow` | `restow-base`, `restow-colima` | re-link after adding files to a package |
| `unstow` | `unstow-base`, `unstow-colima` | remove symlinks |
| `status` | `status-base`, `status-colima` | dry-run; show what stow would do |

## Adding a new package

1. Create the package directory: `mkdir -p stow/<name>`
2. Place files inside, mirroring `$HOME`-relative paths
   (e.g., `stow/<name>/.config/foo/bar.toml` → `~/.config/foo/bar.toml`)
3. Edit `stow/justfile`: add the package to each aggregate recipe AND add
   per-package `<verb>-<name>` recipes (mirror the existing pattern). There
   is no loop — every recipe lists each package explicitly.
   Use `--no-folding` if target dirs hold runtime state.
4. `dotfiles stow setup-<name>` (or `setup` to stow everything).
```

**Verification:**

```bash
grep -c "shared.*colima\.yaml" stow/README.md
# Expected: 1 (new correct profile name)
grep -c "default/colima\.yaml" stow/README.md
# Expected: 0 (old name removed)
grep -c "setup-base\|setup-colima" stow/README.md
# Expected: at least 2
```

**Commit:**
```bash
git add stow/README.md
git commit -m "stow/README: bifurcate per-package vs aggregate; update profile names"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Rewrite top-level `README.md` for Stage 1 only (no container concepts)

**Verifies:** stack-resilience.AC7.4, stack-resilience.AC7.5

**Files:**
- Modify: `README.md`

**Implementation:**

Current `README.md` (verified — 77 lines) mixes Stage 1 (clone, brew, stow) with Stage 2 (container packages, vm-up, up-all) and references outdated profile names (`vm-default`, `vm-adguard`). Rewrite to be Stage-1-only.

The recipe-tree section (lines 19-45) currently spans both stow and stacks; cut it down to stow only and replace stacks references with a "see stacks/README.md" pointer.

Full rewrite:

```markdown
# dotfiles

```
dotfiles/
├── bare/        legacy bare-repo dotfiles (unmanaged, untouched)
├── stacks/     Docker compose stacks — opt-in (see stacks/README.md)
├── stow/       Stow packages — symlinked into $HOME for tools that read fixed paths
├── docs/       migration-recovery and other operational references
├── justfile    root justfile (mod stacks, mod stow)
└── .gitignore  secrets out, *.env.example in
```

Drive everything via the `dotfiles` shell alias (defined in
`stow/base/.zshrc`):

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```

## Stage 1 — universal setup (every device)

Editor + shell config. This is the only stage most devices need.

```sh
brew install just stow neovim zellij zsh-completions   # base tools
git clone <this-repo> ~/Developer/dotfiles
cd ~/Developer/dotfiles

dotfiles stow setup-base                               # stow base only
source ~/.zshrc                                        # load `dotfiles` alias
```

After Stage 1, your editor + shell config + the `dotfiles` alias are in
place. Most devices stop here.

## Stage 2 — opt-in container support (a few devices)

Only on devices where you want to run the Docker compose stacks (a Mac
mini that hosts AdGuard / FreshRSS / Homebridge / Wallabag, for example).

See **`stacks/README.md`** for:
- The container-side brew package set
- `dotfiles stow setup-colima` (the per-stack-VM stow piece)
- `dotfiles stacks vm-up` (start both Colima VMs)
- Per-stack first-run details

## Stage 3 — per-stack setup (only stacks you want)

For each stack you want to run on a Stage-2 device, follow that stack's
README:
- `stacks/adguard/README.md`
- `stacks/freshrss/README.md`
- `stacks/homebridge/README.md`
- `stacks/wallabag/README.md`

## Common ops

```sh
dotfiles                        # list root recipes
dotfiles stow restow-base       # re-link after adding files to base
dotfiles stow status            # dry-run for both packages
dotfiles stow status-base       # dry-run for just base
```

## Conventions (Stage 1)

- Stow packages: `base` uses default folding (folder symlinks); other
  packages may need `--no-folding` if their target dir holds runtime
  state. See `stow/README.md`.
- The `bare/` tree is frozen legacy. Nothing in the active workflow reads
  from it.
```

**Verification:**

```bash
grep -c "vm-default\|vm-adguard\|up-all\|stacks vm-up" README.md
# Expected: 0 — Stage 1 has no container references
grep -c "stow setup-base" README.md
# Expected: at least 1
grep -c "stacks/README.md" README.md
# Expected: at least 1 (cross-reference for Stage 2/3)
```

**Commit:**
```bash
git add README.md
git commit -m "README: bifurcate to Stage 1 only (universal); cross-reference stacks/README"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Update `stacks/README.md` with Stage 2 brew prereqs + explicit stow prerequisite

**Verifies:** stack-resilience.AC7.4, stack-resilience.AC7.5

**Files:**
- Modify: `stacks/README.md`

**Implementation:**

Current `stacks/README.md` (after the Phase 4 + 6 edits) has:
- Architecture (intro)
- "Fresh-device setup" (line 23 onwards — currently abbreviated)
- Recipes
- Backups (added in Phase 4)
- When the bridged VM IP changes (added in Phase 6)
- Renaming a Colima profile (added in Phase 6)

The "Fresh-device setup" section is currently under-specified. Expand it to be the Stage-2-and-3 walkthrough with explicit prereqs.

Replace the "Fresh-device setup" section (currently a few lines) with a more thorough one. Insert this content where the old section was:

```markdown
## Stage 2 — fresh-device setup

Prerequisites:
- Stage 1 done (`dotfiles stow setup-base` already ran on this device).
- macOS host with admin/sudo (socket_vmnet needs sudo at install time).

```sh
brew install colima docker socket_vmnet gettext jq tailscale-cli
sudo brew services start socket_vmnet                  # bridged-VM networking

dotfiles stow setup-colima                             # symlink ~/.colima/<profile>/colima.yaml
dotfiles stacks vm-up                                  # start both Colima VMs
```

`brew install tailscale-cli` installs the CLI shim. The actual Tailscale
.app must be installed separately from <https://tailscale.com/download>
or via `brew install --cask tailscale` — every justfile invokes the .app
binary directly at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

After Stage 2, both Colima VMs are running and Docker contexts
`colima-shared` and `colima-bridged` exist.

## Stage 3 — per-stack setup (only stacks you want)

For each stack you want to run, follow that stack's README:

- `adguard/README.md` — DNS resolver (bridged VM, must complete the wizard
  pinning the listener to `col0`; Tailscale Global NS hookup via
  `dotfiles stacks adguard tailnet-dns-on`)
- `freshrss/README.md` — RSS reader (shared VM, fully declarative via .env)
- `homebridge/README.md` — HomeKit bridge (bridged VM, pair via the iOS
  Home app after `dotfiles stacks homebridge bootstrap`)
- `wallabag/README.md` — read-it-later (shared VM, run `dotfiles stacks
  wallabag bootstrap` after first up)

After all desired stacks are up, install the nightly backup timer:

```sh
dotfiles stacks backup-install                         # ~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist
dotfiles stacks doctor                                 # confirm everything's green
```

`doctor` runs read-only diagnostics (~12 checks across infrastructure,
per-stack state, Tailscale failover state, IP coupling, .env keys, and
homebridge pairing identity). Run it after any non-trivial change.
```

(The existing `## Architecture` table at the top stays unchanged.)

**Verification:**

```bash
grep -c "Stage 2" stacks/README.md
# Expected: at least 1
grep -c "stow setup-colima" stacks/README.md
# Expected: at least 1
grep -c "backup-install" stacks/README.md
# Expected: at least 1
grep -c "doctor" stacks/README.md
# Expected: at least 1
```

**Commit:**
```bash
git add stacks/README.md
git commit -m "stacks/README: expand Stages 2+3 with brew prereqs and stow prerequisite"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Static audit — read every README + script in dependency order; produce gap list

**Verifies:** stack-resilience.AC7.5, stack-resilience.AC7.6

**Files:** None modified directly. Output: a gap list maintained in this task's verification record.

**Implementation:**

This is **a structured read-only audit pass**. Run it after Tasks 1-4 are committed (so the audit is against the final intended documentation state).

Audit procedure:

1. **Read every README in dependency order:**
   - `README.md` (top-level)
   - `stow/README.md`
   - `stacks/README.md`
   - `stacks/adguard/README.md`
   - `stacks/freshrss/README.md`
   - `stacks/homebridge/README.md`
   - `stacks/wallabag/README.md`
   - `docs/migration-recovery.md`

2. **Read every script:**
   - `stacks/scripts/{doctor.sh, backup.sh, restore.sh, backup-rotate.sh, backup-install.sh, bridged-ip-changed.sh, lib/check.sh}`
   - `stacks/adguard/scripts/{tailnet-dns.sh, wait-healthy.sh}`
   - `stacks/wallabag/scripts/bootstrap.sh`
   - `stacks/homebridge/scripts/{bootstrap.sh, gen-pin.sh}`

3. **Read every justfile:**
   - root `justfile`
   - `stacks/justfile`
   - `stow/justfile`
   - `stacks/<stack>/justfile` × 4

4. **For each step in each stage**, confirm:
   - (a) Each prerequisite is created by an earlier step in the same or a documented earlier stage, OR is documented as a manual action with explicit instructions.
   - (b) Stage 1 brew package set has no container packages.
   - (c) Stage 2 explicitly declares the Stage 1 prerequisite.
   - (d) Stage 3 per-stack walkthroughs explicitly declare the Stage 2 prerequisite.

5. **For each script**, confirm:
   - Preflight checks reference clear remediation (recovery hint when prereq is missing).
   - All env variables referenced in the script are present in the relevant `.env.example`.
   - Exit codes are documented at the top of the script (per Phase 7 contract).

6. **For each justfile recipe**, confirm:
   - ≤2 lines (per AC7.1). Anything longer delegates to a script.
     **Exemption:** list-style aggregate recipes (`up-all`, `down-all`,
     `ps-all`, `pull-all`, `backup-all`) are exempt — each line is a
     self-contained subcommand invocation with no inter-line state, so
     the recipe is itself the readable abstraction. Aggregate recipes
     pass the audit at any line count.
   - Uses the established context idiom (`docker --context colima-<profile>`).
   - Tailscale invocations use the absolute-path `tailscale` constant.

**Gap list template (maintained inline):**

```
## Audit gap list (Phase 8 Task 5)

[ ] gap-1: <description>          fixed by: <task-6 sub-task or follow-up commit>
[ ] gap-2: <description>          fixed by: ...
...
```

**Expected gaps based on the design + execution sequence:**

The audit is exploratory — gaps depend on what actually got committed. Likely candidates to check for:
- top-level `README.md` recipe-tree references that should now point to Phase 8's bifurcated docs.
- Per-stack READMEs that reference `dotfiles stacks vm-up` without mentioning the `stow setup-colima` prerequisite.
- Bootstrap scripts that source `.env` but don't mention `chmod 600 .env` in their preflight error messages.
- Any remaining "in-place migration" mention in stacks-related text (Phase 6 was supposed to clean this up).
- `stacks/freshrss/README.md` and `stacks/wallabag/README.md` may still reference "default Colima VM" (the pre-rename name) in their first paragraphs — Phase 3 Task 8 was supposed to fix this; verify.

Record each gap with a clear remediation pointer.

**Output of this task:** a gap list maintained as a scratch file at `/tmp/audit-stack-resilience.md` (NOT committed — this is a transient artifact for Task 6 to consume).

```bash
# Create the audit record in /tmp (not in the repo — it would be a churn commit)
cat > /tmp/audit-stack-resilience.md <<'EOF'
# Audit gap list — Phase 8

Each gap below is fixed in Task 6. This file is not committed.

[ ] gap-1: <fill in during audit>
[ ] gap-2: <fill in during audit>
EOF
```

**Verification:**

```bash
ls /tmp/audit-stack-resilience.md
# Expected: file present, populated with audit findings

git status
# Expected: no new tracked files (the audit scratchpad lives in /tmp)
```

**Commit:** None — the audit scratchpad is intentionally not in git.
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Fix every gap from the audit; final doctor-green check; remove the audit scratchpad

**Verifies:** stack-resilience.AC7.6

**Files:** Variable — depends on what gaps the audit produced. Common targets: `README.md`, `stacks/<stack>/README.md`, scripts under `stacks/scripts/` or `stacks/<stack>/scripts/`.

**Implementation:**

For each gap in `/tmp/audit-stack-resilience.md`:
1. Make the fix (smallest possible diff).
2. Mark the gap done in the scratchpad (`[x]`).
3. Commit with a focused message: `audit fix: <gap-N>: <one-line description>`.

After all gaps are fixed:
1. Run `dotfiles stacks doctor` — expect all-green, exit 0.
2. Re-read the top-level `README.md` from a "fresh-eyes" perspective: imagine you've never seen this repo. Does Stage 1 actually work without the reader needing to guess? If anything is unclear, fix it (one more focused commit).
3. Confirm: `git status` shows no uncommitted changes.
4. Remove the scratchpad (it was a temp artifact for this task, not a long-lived doc):

```bash
rm /tmp/audit-stack-resilience.md
```

**Verification (the canonical "all-green new device" simulation):**

```bash
# 1. Doctor green
dotfiles stacks doctor
echo "doctor exit: $?"
# Expected: all-green, exit 0

# 2. Stage 1 walkthrough sanity:
#    Re-read README.md and confirm the stage 1 commands (brew install,
#    git clone, stow setup-base, source .zshrc) are sufficient for a
#    new-device user. They should be — this is a static audit, not a
#    live re-run.

# 3. Stage 2 walkthrough sanity:
#    Re-read stacks/README.md "Stage 2" section. The brew install line,
#    socket_vmnet sudo line, stow setup-colima line, and vm-up line
#    should be sufficient.

# 4. No orphaned references:
grep -rn "vm-default\|vm-adguard" README.md stacks/ stow/ docs/ \
    | grep -v ".git/"
# Expected: no matches (old profile names fully scrubbed)
```

**Commit:** Done as part of the audit-fix loop above. This task ends with `/tmp/audit-stack-resilience.md` removed (no commit — it never entered git).
<!-- END_TASK_6 -->

---

## Done When

- `stow/justfile` has 12 recipes total: 4 aggregate + 8 per-package; AC7.7 verified by dry-runs.
- `stow/README.md` documents per-package vs aggregate setup; references current profile names (`shared`, `bridged`).
- Top-level `README.md` is Stage-1-only — no container references; cross-references `stacks/README.md` for Stage 2+3.
- `stacks/README.md` has Stage 2 (brew prereqs + `stow setup-colima`) and Stage 3 (per-stack pointers) sections.
- The audit gap list (in `/tmp/audit-stack-resilience.md`) was produced, every gap was fixed via a focused commit, and the scratchpad was removed (no commit churn for the scratchpad itself).
- `dotfiles stacks doctor` exits 0 on the user's host with all checks `[OK]`. The full check set across all phases is now exercised:
  - Infrastructure (5 checks: 2 colima profiles, 2 docker contexts, socket_vmnet, just-version, tailscale)
  - Stack volumes (4 checks: one per stack)
  - Backups (4 checks: one per stack — FAIL on >36h or missing)
  - DNS failover (1 check: AGH state vs Global NS)
  - IP coupling (3 checks: AGH bind_hosts, 2 serve mappings)
  - Stack identity & env (5 checks: 4 .env-key counts + 1 BRIDGE_USERNAME match)
  Total: ~22 checks across 6 sections, ≤5s wall time.
- `git log --oneline | head -<phase-commit-count>` shows a tidy commit history per the plan; the user can read it linearly to understand what changed.
- The user has a documented, audited path to bootstrap a new Mac end-to-end without consulting their personal memory or asking me.
