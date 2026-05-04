# Phase 1: Doctor recipe (verification foundation)

**Goal:** Establish the read-only `dotfiles stacks doctor` recipe so every later phase has a single command to verify expected state. Begins as a minimal infrastructure-checks skeleton; later phases extend it with their own concerns.

**Architecture:** A new `stacks/scripts/` directory with a small shared `lib/check.sh` exporting `pass()`/`warn()`/`fail()` and a top-level `doctor.sh` that executes the suite and exits non-zero if anything is `[FAIL]`. The justfile recipe is a one-line delegation to the script. `lib/check.sh` is sourced (not executed) so all later checks share its formatting and exit-tracking helpers.

**Tech Stack:** POSIX-compatible bash, `colima`, `docker`, macOS launchd vocabulary (`launchctl print`), `pgrep`. No external dependencies introduced beyond what's already on the host (`just 1.50.0`, `colima`, `docker`).

**Scope:** Phase 1 of 8 from the original design.

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

This phase implements and tests the infrastructure-check subset of `stack-resilience.AC5`. Later phases (2, 4, 5, 6, 7) extend the doctor with backup-age, DNS-state, IP-drift, and pairing-identity checks — each phase ships its own AC for its added check.

### stack-resilience.AC5: Sanity recipes — doctor + bootstrap fail-loudly
- **stack-resilience.AC5.1 Success:** `dotfiles stacks doctor` runs end-to-end and produces output for every defined check.
- **stack-resilience.AC5.2 Success:** Each check reports `[OK]`, `[WARN]`, or `[FAIL]` with a one-line message.
- **stack-resilience.AC5.3 Failure:** Intentionally breaking one check (e.g., `colima stop -p bridged`) makes `doctor` exit non-zero and clearly identifies the failing check.
- **stack-resilience.AC5.4 Success:** `doctor` never reads any `.env` value — only counts keys via `grep -c '^KEY='` and similar (auditable from script source). *(This phase establishes the contract; Phase 7 adds the first .env-related check that exercises it.)*
- **stack-resilience.AC5.5 Success:** `doctor` completes in <5s on a healthy environment.

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.1 Success:** Every justfile recipe is ≤1–2 lines; recipes that need more delegate to a script in `stacks/scripts/` or `stacks/<stack>/scripts/`. *(This phase establishes the `stacks/scripts/` directory and the one-line-delegation pattern that every subsequent phase honors.)*
- **stack-resilience.AC7.2 Success:** `stacks/scripts/` directory contains the stacks-shared scripts: `doctor.sh`, … `lib/check.sh`. *(This phase ships the foundational subset — `doctor.sh` and `lib/check.sh`. Phases 2/4/6 add the rest.)*

---

## Operational Context (read before executing)

This is a **homelab dotfiles repo with real environment side effects**. Every task in this plan must be safe to re-run, and any operation that modifies live VM state or shared infrastructure must announce itself. Phase 1 itself is **purely additive and read-only at runtime** — it adds new files but the new code only inspects state.

**Existing files this phase modifies:** `stacks/justfile` (adds one recipe). All other changes are new files under `stacks/scripts/`.

**Pre-flight assumptions (verify before starting):**
- Both Colima profiles exist (`colima list` shows `shared` and `bridged`; status doesn't matter — doctor is the thing checking it).
- Docker contexts `colima-shared` and `colima-bridged` exist (`docker context ls`).
- `just 1.50.0` is on PATH at `/opt/homebrew/bin/just`.

If any pre-flight fails, **STOP** and report — Phase 1 doesn't fix broken infrastructure, it diagnoses it.

---

<!-- START_TASK_1 -->
### Task 1: Create the shared check helpers (`stacks/scripts/lib/check.sh`)

**Files:**
- Create: `stacks/scripts/lib/check.sh`

**Implementation:**

This is a sourceable bash library, not an executable script. It exports three functions and one tracking variable. Every later phase's doctor extension sources this file.

Contract:
- `pass "<msg>"` — prints `[OK]   <msg>` to stdout. Increments nothing; success is the default.
- `warn "<msg>"` — prints `[WARN] <msg>` to stdout. Sets `__check_warned=1` (visible to caller).
- `fail "<msg>"` — prints `[FAIL] <msg>` to stdout. Sets `__check_failed=1` (visible to caller).
- Final exit status is the caller's responsibility: doctor.sh inspects `$__check_failed` at the end and exits non-zero if any FAIL occurred. WARN does not affect exit status.
- Output is unbuffered-friendly (line-at-a-time) so ordering is stable when run from launchd or a CI environment.

Color is intentionally NOT included — doctor output may be captured to launchd logs (Phase 4) or piped, where ANSI codes are noise.

```bash
#!/usr/bin/env bash
# stacks/scripts/lib/check.sh
# Shared check helpers for `dotfiles stacks doctor`. Source-only — do not execute.
#
# Contract:
#   pass "msg"  -> "[OK]   msg"
#   warn "msg"  -> "[WARN] msg"  + sets __check_warned=1
#   fail "msg"  -> "[FAIL] msg"  + sets __check_failed=1
# Caller decides exit status by inspecting $__check_failed at end of run.

__check_failed=0
__check_warned=0

pass() { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; __check_warned=1; }
fail() { printf '[FAIL] %s\n' "$*"; __check_failed=1; }
```

**Verification:**

```bash
# From the repo root
bash -c 'source stacks/scripts/lib/check.sh; pass "p"; warn "w"; fail "f"; echo "warned=$__check_warned failed=$__check_failed"'
```

Expected output:
```
[OK]   p
[WARN] w
[FAIL] f
warned=1 failed=1
```

**Commit:**
```bash
git add stacks/scripts/lib/check.sh
git commit -m "stacks: add shared check helpers for doctor recipe"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Create the doctor script with infrastructure checks (`stacks/scripts/doctor.sh`)

**Verifies:** stack-resilience.AC5.1, stack-resilience.AC5.2, stack-resilience.AC5.3, stack-resilience.AC5.5

**Files:**
- Create: `stacks/scripts/doctor.sh` (executable, mode 755)

**Implementation:**

Five infrastructure checks, in order. The script sources `lib/check.sh`, runs each check, then exits 0 or 1 based on `$__check_failed` (WARN does not fail the run).

Checks (each one independent — a failure in one does not skip subsequent checks):

1. **Both Colima profiles exist and are Running.** Parse `colima list` (skip header). For each of `shared` and `bridged`, locate the row and check `$2 == "Running"`. Use the same awk idiom established in `stacks/adguard/justfile:37`.
2. **Both docker contexts exist and resolve.** `docker context ls --format '{{.Name}}'` includes both `colima-shared` and `colima-bridged`. Then `docker --context <name> info` succeeds (proves the context is connectable, not just defined).
3. **`socket_vmnet` daemon is running.** `pgrep -x socket_vmnet` returns at least one PID. (This daemon is required for the bridged profile; if it's down, bridged-profile networking will fail silently.)
4. **`just` is on PATH and is version ≥ 1.13** (the version that introduced `recipe: dep && post` subsequent dependencies, which Phase 2 onwards relies on). Check `just --version` and parse semver.
5. **Tailscale CLI is reachable at the absolute path used by all justfiles.** Just an `[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]` check (not invoking it — pure file probe).

Doctor MUST complete in <5s on a healthy environment; the slowest commands are `docker info` (cached when contexts are warm) and `colima list` (cheap). No network calls in this phase.

**Header convention** (every doctor extension follows this):
- A `--- <Section Title> ---` header line precedes each logical group.
- Phase 1 has only one section: `--- Infrastructure ---`.

```bash
#!/usr/bin/env bash
# stacks/scripts/doctor.sh
# Read-only diagnostic for the dotfiles stacks layer.
# Exits 0 if no FAILs, 1 otherwise. WARN never fails the run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/check.sh
source "${SCRIPT_DIR}/lib/check.sh"

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

echo "--- Infrastructure ---"

# 1. Colima profiles Running
for profile in shared bridged; do
    status=$(colima list 2>/dev/null \
        | awk -v p="$profile" '$1 == p {print $2}')
    if [ "$status" = "Running" ]; then
        pass "colima profile '$profile' is Running"
    elif [ -z "$status" ]; then
        fail "colima profile '$profile' not found (run: dotfiles stacks vm-$profile)"
    else
        fail "colima profile '$profile' status is '$status' (expected Running)"
    fi
done

# 2. Docker contexts present and connectable
contexts=$(docker context ls --format '{{.Name}}' 2>/dev/null || true)
for ctx in colima-shared colima-bridged; do
    if echo "$contexts" | grep -qx "$ctx"; then
        if docker --context "$ctx" info >/dev/null 2>&1; then
            pass "docker context '$ctx' connects"
        else
            fail "docker context '$ctx' present but not connectable"
        fi
    else
        fail "docker context '$ctx' missing"
    fi
done

# 3. socket_vmnet daemon
if pgrep -x socket_vmnet >/dev/null; then
    pass "socket_vmnet daemon running"
else
    fail "socket_vmnet daemon not running (bridged-profile networking will fail)"
fi

# 4. just version
if command -v just >/dev/null 2>&1; then
    just_version=$(just --version | awk '{print $2}')
    # Compare major.minor numerically against 1.13
    major=$(echo "$just_version" | cut -d. -f1)
    minor=$(echo "$just_version" | cut -d. -f2)
    if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 13 ]; }; then
        pass "just $just_version (>=1.13 supports subsequent deps)"
    else
        fail "just $just_version is too old; need >=1.13 for 'recipe: dep && post' syntax"
    fi
else
    fail "just not on PATH"
fi

# 5. Tailscale CLI reachable
if [ -x "$TAILSCALE" ]; then
    pass "tailscale CLI present at $TAILSCALE"
else
    fail "tailscale CLI missing at $TAILSCALE (install Tailscale.app)"
fi

# Exit status: 1 if any FAIL, 0 otherwise (WARN does not fail).
[ "$__check_failed" -eq 0 ] || exit 1
exit 0
```

**Verification:**

```bash
chmod +x stacks/scripts/doctor.sh
./stacks/scripts/doctor.sh
echo "exit=$?"
```

On a healthy host, expected: every line is `[OK]`, exit 0, total wall time <5s. Time it explicitly:

```bash
time ./stacks/scripts/doctor.sh >/dev/null
```

Expected: `real` < 5.0s.

**Failure-mode test (manual, ONE check at a time, restore after):**

```bash
# Test the bridged-profile check. SAFE — colima stop is fully reversible.
colima stop -p bridged
./stacks/scripts/doctor.sh; echo "exit=$?"   # should print [FAIL] for bridged + exit 1
colima start -p bridged                      # restore
./stacks/scripts/doctor.sh; echo "exit=$?"   # should print [OK] + exit 0
```

Do **not** test the docker-context, socket_vmnet, or just checks by intentionally breaking them — those are expensive to reverse on this user's host. Inspecting the script source proves the branches exist.

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "stacks: add doctor.sh with infrastructure checks"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Wire the doctor recipe into `stacks/justfile`

**Verifies:** stack-resilience.AC5.1, stack-resilience.AC7.1

**Files:**
- Modify: `stacks/justfile`

**Implementation:**

Add a one-line `doctor` recipe just below `vm-up` (line 39 currently). The recipe delegates to `./scripts/doctor.sh`. Per AC7.1 every recipe is ≤2 lines; this one is exactly 1.

just resolves recipe-relative paths against the directory containing the justfile, so `./scripts/doctor.sh` runs `stacks/scripts/doctor.sh` regardless of where the user's shell happens to be.

Insert after `vm-up: vm-shared vm-bridged` (currently the last line, line 39):

```just
doctor:
    @./scripts/doctor.sh
```

The `@` suppresses just's "Running echo" line so the doctor's own header is the first thing the user sees.

**Verification:**

```bash
dotfiles stacks doctor; echo "exit=$?"
```

Expected: identical output to the direct script run, exit 0.

```bash
dotfiles stacks --list | grep -E '^\s*doctor'
```

Expected: a `doctor` line appears in the recipe list.

**Commit:**
```bash
git add stacks/justfile
git commit -m "stacks: wire doctor recipe in justfile"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Verify end-to-end via the user-facing entrypoint

**Verifies:** stack-resilience.AC5.1, stack-resilience.AC5.2, stack-resilience.AC5.3, stack-resilience.AC5.5

**Files:** None modified — pure verification task.

**Implementation:**

Run the recipe via the `dotfiles` alias the user actually types day-to-day, on a healthy environment. Confirm each AC line-by-line.

```bash
dotfiles stacks doctor
```

**AC5.1 — Runs end-to-end:** every check from doctor.sh produces a line. Count: should be at least 7 (2 colima + 2 docker + 1 socket_vmnet + 1 just + 1 tailscale). Also a single `--- Infrastructure ---` header.

**AC5.2 — Format consistency:** every non-header line begins with `[OK]   `, `[WARN] `, or `[FAIL] `.

```bash
dotfiles stacks doctor 2>/dev/null \
    | grep -vE '^---' \
    | grep -vE '^\[(OK|WARN|FAIL)\] ' \
    | wc -l
```

Expected: `0` (no malformed lines).

**AC5.3 — FAIL exits non-zero:** already covered in Task 2 verification. Re-run via the recipe to confirm `dotfiles stacks doctor` (not just the bare script) honors the exit code:

```bash
colima stop -p bridged
dotfiles stacks doctor; echo "exit=$?"     # expect [FAIL] + exit 1
colima start -p bridged
dotfiles stacks doctor; echo "exit=$?"     # expect [OK] + exit 0
```

**AC5.5 — Under 5 seconds:**

```bash
time dotfiles stacks doctor >/dev/null
```

Expected: `real` < 5.0s.

**Commit:** None (no file changes).
<!-- END_TASK_4 -->

---

## Done When

- `dotfiles stacks doctor` runs end-to-end on this user's host, reports `[OK]` for all 7+ infrastructure checks, exits 0, completes in <5s.
- Intentionally breaking the bridged-profile check (`colima stop -p bridged`) makes doctor exit 1 with a clear `[FAIL]` line and a one-line hint; restoring the profile returns doctor to all-green exit 0.
- Three commits land: `stacks/scripts/lib/check.sh`, `stacks/scripts/doctor.sh`, `stacks/justfile` recipe wire-up.
- `stacks/scripts/lib/check.sh` and `stacks/scripts/doctor.sh` are the only files in `stacks/scripts/` (later phases add `tar-stack.sh`, `restore-stack.sh`, `backup-rotate.sh`, `bridged-ip-changed.sh`, `backup-install.sh`).
