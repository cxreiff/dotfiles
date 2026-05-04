# Phase 6: `bridged-ip-changed` orchestration + router-DNS investigation + migration recovery doc

**Goal:** A single recipe (`dotfiles stacks bridged-ip-changed`) that re-runs every automatable refresh after the bridged VM's IP changes, prints a checklist of human-must-do steps, and handles the rare cases (router replacement, subnet renumbering, DHCP-reservation lost) where the IP does drift. Plus: investigate the user's RT-AC68U DHCP-DNS-advertisement behavior, document the chosen final config, and extract the clean-slate recovery procedure into `docs/migration-recovery.md`. Replace the misleading "in-place migration" section in `stacks/README.md` with a clear "use clean-slate" pointer.

**Architecture:** A new `stacks/scripts/bridged-ip-changed.sh` orchestration script: resolves current bridged VM IP, patches `~/.volumes/adguard/conf/AdGuardHome.yaml` `bind_hosts:`, restarts AGH, drops + re-adds Tailscale serve mappings for `:8689` (adguard) and `:8767` (homebridge), re-runs `adguard advertise`, refreshes Tailscale Global NS via `tailnet-dns.sh on`, and prints a closing checklist with the live MAC + IP for manual router DHCP reservation + Tailscale admin route approval. Plus documentation reorg: the existing migration content in `stacks/README.md` lines 58-123 gets restructured into clean cross-references.

**Tech Stack:** Reuses `tailnet-dns.sh` from Phase 5; `colima ssh` for live MAC discovery; `sed -i ''` (BSD sed — confirmed macOS); `tailscale serve` CLI for serve-mapping refresh.

**Scope:** Phase 6 of 8. Depends on Phase 5 (`tailnet-dns-on` is invoked from `bridged-ip-changed`).

**Codebase verified:** 2026-05-03

---

## Acceptance Criteria Coverage

### stack-resilience.AC2: DNS resilience (router side)
- **stack-resilience.AC2.10 Success:** Router WAN DNS is configured to a non-AGH resolver; documented in `stacks/adguard/README.md`.
- **stack-resilience.AC2.11 Success:** ASUSWRT DHCP-DNS-advertisement behavior is investigated and the chosen final config is documented in `stacks/adguard/README.md`.

### stack-resilience.AC3: Recreation cheap and honest
- **stack-resilience.AC3.1 Success:** `dotfiles stacks bridged-ip-changed` patches AGH yaml `bind_hosts:`, restarts AGH, refreshes both `serve` mappings, re-runs `advertise`, and refreshes Tailscale Global NS via `tailnet-dns-on`.
- **stack-resilience.AC3.2 Success:** Prints a closing checklist with the live bridged-VM MAC (from `colima ssh ... ip link show col0`) and IP for manual router + Tailscale admin steps.
- **stack-resilience.AC3.3 Success:** `stacks/README.md` "Renaming a Colima profile" section explicitly warns against `limactl rename` and points to the clean-slate procedure in `docs/migration-recovery.md`.
- **stack-resilience.AC3.4 Success:** `stacks/README.md` has a single "When the bridged VM IP changes" section enumerating every coupling.
- **stack-resilience.AC3.5 Success:** `docs/migration-recovery.md` exists with the clean-slate procedure (extracted from the recovery walk-through).

### stack-resilience.AC4: Static-MAC research
- **stack-resilience.AC4.1 Success:** `stacks/README.md` (or `stacks/adguard/README.md`) documents that the bridged VM MAC is qemu-deterministic from the lima instance directory path, stable across `colima delete -p bridged && colima start -p bridged`, only changes on profile rename or move of `~/.colima/_lima/`.

### stack-resilience.AC5: Sanity recipes
- **stack-resilience.AC5.7 Success:** `doctor` warns/fails when AGH `bind_hosts:` doesn't match the current bridged-VM `col0` IP. (Plus extends the doctor with a serve-mapping check matching the current IP.)

### stack-resilience.AC7: Code organization
- **stack-resilience.AC7.2 Success:** `stacks/scripts/bridged-ip-changed.sh` exists.

---

## Operational Context (read before executing)

This phase **mostly authors documentation and a single orchestration script that's safe to re-run**. The script itself is the high-impact one: it touches AGH config, restarts AGH, mutates Tailscale serve and Global NS state. But every operation it performs is exactly what `dotfiles stacks adguard up`/`serve`/`advertise` already do — it's a coordinator, not a new privilege.

**Router-DNS investigation step (Task 5)** requires the user to log into their RT-AC68U admin UI and check/change DHCP DNS settings. This is a manual step — the plan does NOT script router config changes (no API exposure, security boundary respected).

**Recovery if anything goes wrong:** `bridged-ip-changed` is idempotent. Re-running it after a partial failure picks up where it left off. AGH config patches use `sed -i .bak` so the original is preserved. If the script messes up AGH, restoring is `cp ~/.volumes/adguard/conf/AdGuardHome.yaml.bak ~/.volumes/adguard/conf/AdGuardHome.yaml && dotfiles stacks adguard restart`.

**Pre-flight (verify before starting):**
- Phases 1, 2, 3, 4, 5 are complete. `dotfiles stacks doctor` is all-green.
- `dotfiles stacks adguard tailnet-dns-status` works (PAT is valid).
- AGH is currently running and serving DNS.

---

<!-- START_TASK_1 -->
### Task 1: Create the bridged-ip-changed orchestration script (`stacks/scripts/bridged-ip-changed.sh`)

**Verifies:** stack-resilience.AC3.1, stack-resilience.AC3.2

**Files:**
- Create: `stacks/scripts/bridged-ip-changed.sh` (executable, mode 755)

**Implementation:**

Sequence:
1. Resolve current bridged VM IP via the colima awk idiom; bail if VM not running.
2. Resolve current bridged VM MAC via `colima ssh -p bridged -- ip link show col0` (parse the `link/ether` line).
3. Patch `~/.volumes/adguard/conf/AdGuardHome.yaml` `bind_hosts:` line. The current AGH yaml shape (verified) has:
   ```yaml
   dns:
     bind_hosts:
       - 192.168.1.78
   ```
   Use `sed -i .bak -E '/^[[:space:]]+bind_hosts:/,/^[^[:space:]-]/{s/^([[:space:]]+- )[0-9.]+$/\1<NEW_IP>/}'` carefully. **Simpler and more robust:** since `bind_hosts:` has exactly one entry on this user's host (verified from baseline investigation), use a two-line `sed` that replaces the IP on the line immediately following `bind_hosts:`. If the user later adds multi-bind, this script needs updating — accept the trade-off and document it.

   ```bash
   sed -i .bak -E '/^[[:space:]]+bind_hosts:/{n;s/^([[:space:]]+- )[0-9.]+$/\1'"$vm_ip"'/;}' \
       ~/.volumes/adguard/conf/AdGuardHome.yaml
   ```

4. `dotfiles stacks adguard restart` (so AGH picks up the new bind_hosts).
5. Refresh Tailscale serve mappings:
   - For each port `:8689` (adguard) and `:8767` (homebridge): drop the existing mapping, re-add pointing at the new VM IP.
   - The current `serve` recipes do `tailscale serve --bg --https=<port> http://<vm-ip>:<internal-port>`. To "drop", use `tailscale serve --https=<port> off`. Then re-run the existing `serve` recipes — they'll pick up the new VM IP from `colima list`.
6. `dotfiles stacks adguard advertise` (re-advertise the /32 subnet route with the new IP).
7. `dotfiles stacks adguard tailnet-dns-on` (refreshes Global NS to the new IP).
8. Print a closing checklist enumerating manual steps the user must do.

```bash
#!/usr/bin/env bash
# stacks/scripts/bridged-ip-changed.sh
# Re-run all the automatable refreshes after the bridged VM IP changes.
# Prints a checklist of remaining human-must-do steps at the end.
set -euo pipefail

TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# repo root is two levels up from stacks/scripts/ (matches Phase 4 backup-install.sh).
# Repo root's justfile has `mod stacks`, so `just -f <repo>/justfile stacks <recipe>`
# is the canonical invocation. Using `${SCRIPT_DIR}/..` here would resolve to
# stacks/, whose justfile has `mod adguard` etc. — the `stacks` target wouldn't
# resolve.
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "bridged-ip-changed: bridged VM not running (run: dotfiles stacks vm-bridged)" >&2
    exit 1
fi

vm_mac=$(colima ssh -p bridged -- ip link show col0 2>/dev/null \
    | awk '/link\/ether/ {print $2}')
if [ -z "$vm_mac" ]; then
    echo "bridged-ip-changed: could not read col0 MAC via colima ssh" >&2
    exit 1
fi

echo "bridged-ip-changed: bridged VM is at IP=${vm_ip} MAC=${vm_mac}"
echo

# 1. Patch AGH bind_hosts
agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
if [ ! -f "$agh_yaml" ]; then
    echo "bridged-ip-changed: ${agh_yaml} not found — has AGH ever started?" >&2
    exit 1
fi
echo "Patching ${agh_yaml} bind_hosts -> ${vm_ip} ..."
sed -i .bak -E '/^[[:space:]]+bind_hosts:/{n;s/^([[:space:]]+- )[0-9.]+$/\1'"$vm_ip"'/;}' \
    "$agh_yaml"
# Show diff against the .bak backup so the user sees what changed
diff -u "$agh_yaml.bak" "$agh_yaml" || true

# 2. Restart AGH so it re-binds
echo
echo "Restarting adguard ..."
just -f "${repo_root}/justfile" stacks adguard restart

# 3. Refresh both serve mappings (drop + re-add)
echo
echo "Refreshing Tailscale serve mappings ..."
for port in 8689 8767; do
    "$TAILSCALE" serve --https="$port" off || true
done
just -f "${repo_root}/justfile" stacks adguard serve
just -f "${repo_root}/justfile" stacks homebridge serve

# 4. Re-advertise subnet route
echo
echo "Re-advertising /32 subnet route ..."
just -f "${repo_root}/justfile" stacks adguard advertise

# 5. Refresh Global NS
echo
echo "Refreshing Tailscale Global Nameservers ..."
just -f "${repo_root}/justfile" stacks adguard tailnet-dns-on

# 6. Closing checklist
cat <<EOF

==========================================================
bridged-ip-changed complete. Manual steps remaining:
==========================================================

1. Router DHCP reservation: ensure the bridged VM gets the same IP after
   a router reboot. Set:
     MAC: ${vm_mac}
     IP:  ${vm_ip}
   On RT-AC68U: LAN -> DHCP Server -> Manual Assignment.

2. Tailscale subnet route approval: re-approval is required after any
   IP change. Visit:
     https://login.tailscale.com/admin/machines
   Find this host -> Edit route settings -> enable ${vm_ip}/32.

3. Confirm doctor is all-green:
     dotfiles stacks doctor
EOF
```

**Verification:**

```bash
chmod +x stacks/scripts/bridged-ip-changed.sh

# Dry-run path test: invoke against current state. Since IP hasn't actually
# changed, the sed patch is a no-op (replaces VM IP with itself), the AGH
# restart is a real restart, the serve mappings get dropped+re-added (live
# event but reversible), and the checklist prints with current MAC+IP.
./stacks/scripts/bridged-ip-changed.sh
echo "exit=$?"
# Expected: completes, prints checklist with the right MAC+IP, exit 0

# Verify AGH yaml is intact
diff ~/.volumes/adguard/conf/AdGuardHome.yaml.bak \
    ~/.volumes/adguard/conf/AdGuardHome.yaml
# Expected: no diff (IP unchanged)

# Verify doctor still green
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0
```

**Real-IP-change test (OPTIONAL — skip unless you want to exercise it):**

Briefly remove the router's DHCP reservation for the bridged VM, then `colima restart -p bridged`. The VM may pick up a different IP. Run `bridged-ip-changed.sh`, watch it patch + restart everything. Then re-add the reservation to restore the original IP and run again. **Only do this if you can be at the router for the next 10 minutes** to fix it if anything goes sideways.

**Commit:**
```bash
git add stacks/scripts/bridged-ip-changed.sh
git commit -m "stacks: add bridged-ip-changed orchestration script"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Wire `bridged-ip-changed` recipe into `stacks/justfile`

**Verifies:** stack-resilience.AC3.1

**Files:**
- Modify: `stacks/justfile`

**Implementation:**

One-line delegation, placed alongside other composite recipes (after `vm-up`):

```just

bridged-ip-changed:
    @./scripts/bridged-ip-changed.sh
```

**Verification:**

```bash
dotfiles stacks bridged-ip-changed
# Expected: same end-state as direct script invocation; exit 0; checklist printed
```

**Commit:**
```bash
git add stacks/justfile
git commit -m "stacks: wire bridged-ip-changed recipe"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Create `docs/migration-recovery.md` (clean-slate procedure)

**Verifies:** stack-resilience.AC3.5

**Files:**
- Create: `docs/migration-recovery.md`

**Implementation:**

Extract the clean-slate procedure currently in `stacks/README.md` lines 67-100 into a standalone reference. Update for the new bind-mount reality (post-Phase 3, freshrss/wallabag also have host-bind data, so the named-volume backup loop is gone — the standard `dotfiles stacks backup-all` is the source of safety tarballs now). Add the bridged-ip-changed step.

```markdown
# Migration & recovery

How to clean-slate-rebuild the stacks layer of this repo on a new Mac, or
recover from a Colima VM that won't start.

## Why no in-place rename

`limactl rename` (and manual `mv ~/.colima/<old> ~/.colima/<new>`) does
**NOT** rewrite the hardcoded paths inside the lima instance configuration
(`<instance>/lima.yaml`, `<instance>/qcow2-backed-disk.qcow2`'s metadata,
the qemu-deterministic MAC derivation seed). Lima is left in a confused
state — sometimes it boots, sometimes it doesn't, and recovery is harder
than just rebuilding.

**Use clean-slate. Always.** The bridged VM's MAC is qemu-deterministic
from the lima instance directory path, so `colima delete -p bridged &&
colima start -p bridged` actually preserves the MAC (and therefore the
DHCP reservation, and therefore the IP) — the only thing this loses is
non-volumes container state, which we don't care about.

## Prerequisites

- Recent `~/.volume-backups/daily/` tarballs for all four stacks (run
  `dotfiles stacks backup-all` before destroying anything). The launchd
  timer should already be giving you nightly snapshots.
- The user's `stacks/<stack>/.env` files captured separately. They're
  gitignored so they're not in the repo; copy them off before wiping a
  device.

## Clean-slate procedure

```sh
# 1. Take a fresh full backup just before destroying state
dotfiles stacks backup-all
ls -la ~/.volume-backups/daily/                  # confirm 4 same-day tarballs

# 2. Bring everything down
dotfiles stacks down-all

# 3. Destroy both VMs (host bind mounts under ~/.volumes/ are unaffected)
colima delete -p shared
colima delete -p bridged

# 4. Re-stow if this is a new device
dotfiles stow setup    # or stow setup-base + stow setup-colima per Phase 8

# 5. Re-create VMs from the stowed colima.yaml profiles
dotfiles stacks vm-up

# 6. Restore named-volume backups if you're recovering from a backup
#    (otherwise skip — host bind mounts are already populated):
for stack in adguard freshrss homebridge wallabag; do
    dotfiles stacks $stack restore \
        ~/.volume-backups/daily/${stack}-$(date +%Y-%m-%d).tgz --force
done

# 7. Bring everything up
dotfiles stacks up-all

# 8. If the bridged VM IP changed (rare — qemu-deterministic MAC keeps
#    the DHCP lease), re-coordinate:
dotfiles stacks bridged-ip-changed   # follow the printed checklist

# 9. Confirm
dotfiles stacks doctor
```

## On a fresh device (new Mac, no prior state)

Same as the procedure above starting from step 4 (the device has no
backups to restore). After step 7, step through each stack's first-run
wizard / `bootstrap` per the per-stack README:

- `adguard/README.md` (DNS wizard, must bind to `col0`)
- `homebridge/README.md` (Pair via Home app)
- `wallabag/README.md` (`dotfiles stacks wallabag bootstrap`)
- `freshrss/README.md` (auto-installs from `.env`)

## When the bridged VM IP changes

The bridged VM gets its IP from the LAN router's DHCP. With a DHCP
reservation in place, the IP is stable across `colima stop`/`start` and
`colima delete`/`start`. It changes when:

- The router is replaced or factory-reset.
- The DHCP reservation is removed.
- The VM is moved to a new MAC (only happens with `mv ~/.colima/_lima/`,
  which we explicitly don't do).

When the IP changes, run:

```sh
dotfiles stacks bridged-ip-changed
```

Then follow the printed checklist (manual steps: router DHCP reservation,
Tailscale admin route approval). See the "When the bridged VM IP
changes" section in `stacks/README.md` for the full coupling diagram.
```

**Verification:**

```bash
ls -la docs/migration-recovery.md
# Expected: file present
```

Read it through. Confirm: tone matches existing READMEs (operational, not chatty); cross-references to per-stack READMEs are correct.

**Commit:**
```bash
git add docs/migration-recovery.md
git commit -m "docs: add migration-recovery.md (clean-slate procedure)"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Replace misleading "in-place migration" content in `stacks/README.md`; add coupling diagram + static-MAC note

**Verifies:** stack-resilience.AC3.3, stack-resilience.AC3.4, stack-resilience.AC4.1

**Files:**
- Modify: `stacks/README.md`

**Implementation:**

Current state of `stacks/README.md`:
- Lines 58-100: "Migrating from the old `default`/`adguard` profile names → Clean-slate migration" — relevant historical content but now belongs in the migration-recovery doc.
- Lines 102-123: "In-place migration (current device only, riskier)" — the AC3.3 misleading section. Replace with warning + pointer.

Replacement strategy:
1. **Delete** the entire "Migrating from the old `default`/`adguard` profile names" section (lines 58-123).
2. **Add** in its place a new section titled "When the bridged VM IP changes" that enumerates the coupling diagram (AC3.4).
3. **Add** a separate section "Renaming a Colima profile" with the AC3.3 warning + cross-reference to `docs/migration-recovery.md`.
4. **Add** a brief note about the static-MAC research outcome inside the new "When the bridged VM IP changes" section (AC4.1).

Replacement text (insert where lines 58-123 used to be, after the `## Recipes` section + the `## Backups` section added in Phase 4):

```markdown
## When the bridged VM IP changes

The bridged VM's IP is **pinned via router DHCP reservation** as a setup
step. It changes only on rare events: router replacement, subnet
renumbering, or the DHCP reservation getting lost.

Couplings that all reference the bridged VM IP:

| Coupling | Source of truth | Refreshed by |
|---|---|---|
| AGH `bind_hosts:` | `~/.volumes/adguard/conf/AdGuardHome.yaml` | `bridged-ip-changed.sh` patches via sed |
| AGH `serve` mapping `:8689` | `tailscale serve` state | `dotfiles stacks adguard serve` |
| Homebridge `serve` mapping `:8767` | `tailscale serve` state | `dotfiles stacks homebridge serve` |
| Subnet route advertisement | Tailscale node config | `dotfiles stacks adguard advertise` |
| Tailscale Global Nameservers | Tailscale tailnet config | `dotfiles stacks adguard tailnet-dns-on` |
| Router DHCP reservation | Router admin UI | **Manual** |
| Tailscale admin route approval | Tailscale admin UI | **Manual** |

Run `dotfiles stacks bridged-ip-changed` to re-do every automatable step
in one command; the script prints a closing checklist with the live MAC +
IP for the manual steps.

### Static-MAC behavior

The bridged VM's MAC is qemu-deterministic from the lima instance
directory path (`~/.colima/_lima/colima-bridged/`). This means:

- **Stable across** `colima stop`/`start`/`restart`.
- **Stable across** `colima delete -p bridged && colima start -p bridged`
  (the lima dir gets recreated at the same path → same MAC seed).
- **Changes only** if you rename the Colima profile or move the
  `~/.colima/_lima/` directory. Don't do either — use clean-slate
  (below) instead of in-place renames.

The DHCP reservation will continue to work across `colima delete` cycles
because the MAC is preserved.

## Renaming a Colima profile

**`limactl rename` is not viable in place.** It doesn't rewrite hardcoded
paths in `lima.yaml` or the qemu MAC derivation, leaving lima in an
inconsistent state. Same applies to manual `mv ~/.colima/<old>
~/.colima/<new>` and `mv ~/.lima/colima-<old> ~/.lima/colima-<new>` —
some things work, some don't, and recovery is harder than rebuilding.

For renames or fresh-device setup, use the clean-slate procedure in
[`docs/migration-recovery.md`](../docs/migration-recovery.md).
```

Also, in the `## Backups` section that Phase 4 Task 7 added, replace the placeholder line:

```markdown
(Phase 6 adds a cross-reference to `docs/migration-recovery.md` here once
that doc exists.)
```

with:

```markdown
To restore on a fresh device, see
[`docs/migration-recovery.md`](../docs/migration-recovery.md).
```

This couples the cross-reference creation to the file's existence (Phase 6 Task 3 created the file in this same phase).

**Verification:**

Read the rendered file. Confirm:
- The old "Migrating from the old `default`/`adguard` profile names" section is gone.
- The new "When the bridged VM IP changes" section has the coupling table and the static-MAC note.
- The new "Renaming a Colima profile" section warns and cross-references the migration-recovery doc.

```bash
grep -c "default.*adguard.*profile names" stacks/README.md
# Expected: 0 (old section gone)
grep -c "When the bridged VM IP changes" stacks/README.md
# Expected: 1
grep -c "limactl rename" stacks/README.md
# Expected: 1
grep -c "migration-recovery.md" stacks/README.md
# Expected: 1
```

**Commit:**
```bash
git add stacks/README.md
git commit -m "stacks/README: replace in-place-migration with coupling diagram + clean-slate pointer"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: Router-DNS investigation — manual + document outcome in `stacks/adguard/README.md`

**Verifies:** stack-resilience.AC2.10, stack-resilience.AC2.11

**Files:**
- Modify: `stacks/adguard/README.md`

**Implementation:**

This is **a manual investigation task**: the user logs into the RT-AC68U admin UI and tests the DHCP-DNS-advertisement behavior, then records the outcome in the README. The plan tells the user what to test; the user runs the test on their own router.

**STOP — pause for the user to perform the investigation.** The plan executor cannot do this step; it requires the user's router admin credentials and physical-network access.

**What the user does (instructions to convey verbatim):**

1. Log into the router at `http://router.local` (or the router's LAN IP).
2. Navigate to **LAN → DHCP Server**.
3. Note current values for: "DNS Server 1", "DNS Server 2", and "Advertise router's IP in addition to user-specified DNS".
4. Test scenario: with AGH down (`dotfiles stacks adguard down`), can a freshly-DHCP-leased LAN device (Mac on Wi-Fi off-tailnet, or another phone with Wi-Fi cycled) resolve `example.com`? If yes, the router's DHCP DNS advertisement is working as fallback. If no, the LAN is currently relying on AGH being up — risky.
5. Set "DNS Server 1" to AGH VM IP, "DNS Server 2" to `1.1.1.1` (or another non-AGH resolver), and "Advertise the router's IP in addition to user-specified DNS" to **No** (so clients see the explicit DNS list, not the router's recursive resolver).
6. Test again — confirm both `dig @<router-ip> example.com` and clients receiving `1.1.1.1` as secondary actually fail over when AGH is down.
7. Configure WAN DNS (WAN → Internet Setup → DNS Server 1/2) to a non-AGH resolver (e.g., `1.1.1.1` and `1.0.0.1`). This protects the **router itself** from being DNS-dependent on AGH (otherwise the router's own outbound queries — DDNS, NTP, firmware update checks — would fail when AGH is down).

**After the investigation, the user records findings.** Add a new section to `stacks/adguard/README.md` after the existing `## DNS failover` section (added in Phase 5):

```markdown
## Router-side configuration (RT-AC68U specifics)

WAN DNS:
- **DNS Server 1**: 1.1.1.1
- **DNS Server 2**: 1.0.0.1
This is **non-AGH on purpose** — the router itself queries WAN DNS for its
own outbound traffic (DDNS, NTP, firmware checks). If WAN DNS pointed at
AGH and AGH were down, the router would lose its own internet identity.

LAN DHCP DNS advertisement:
- **DNS Server 1**: <bridged VM IP — pin via DHCP reservation, see "When the
  bridged VM IP changes" in stacks/README.md>
- **DNS Server 2**: 1.1.1.1
- **Advertise the router's IP in addition to user-specified DNS**: No.
  Clients see the explicit list (AGH first, then 1.1.1.1) and fail over
  on their own per OS-level resolver behavior. Most clients are sticky
  to the first responder, so AGH-down means a brief delay before clients
  retry on 1.1.1.1.

Together: cellular and off-LAN tailnet devices fall back via Tailscale
Global Nameservers (toggled by `tailnet-dns-on/off`); on-LAN devices fall
back via the router-advertised secondary DNS.
```

If the user's investigation reveals different optimal settings (e.g., RT-AC68U's "Advertise..." setting behaves differently than expected), update the README to match. The recorded values must reflect **what the user actually configured**, not what we hypothesized.

**Verification:**

After the user has both performed the router config AND updated the README:

```bash
grep -c "WAN DNS" stacks/adguard/README.md
# Expected: 1
grep -c "1.1.1.1" stacks/adguard/README.md
# Expected: at least 2 (WAN + LAN secondary)

# Operational test: bring AGH down briefly, confirm a phone or another
# device on the LAN can still resolve. Then bring AGH back up.
dotfiles stacks adguard down
sleep 5
echo "From a different LAN device (not the Mac): try resolving example.com"
sleep 30                                    # leave it down briefly
dotfiles stacks adguard up
```

**Commit (after user-verified):**
```bash
git add stacks/adguard/README.md
git commit -m "adguard/README: document router DNS config (WAN + LAN DHCP)"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Extend doctor with bind_hosts + serve-mapping IP-drift checks

**Verifies:** stack-resilience.AC5.7

**Files:**
- Modify: `stacks/scripts/doctor.sh`

**Implementation:**

Add a new `--- IP coupling ---` section after `--- DNS failover ---`. Three checks:

1. AGH `bind_hosts:` (in `~/.volumes/adguard/conf/AdGuardHome.yaml`) equals current bridged VM IP.
2. Tailscale serve mapping for `:8689` includes the current bridged VM IP.
3. Tailscale serve mapping for `:8767` includes the current bridged VM IP.

For (2)/(3): use `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status`. The output format includes lines like `https://<host>:8689 (tcp) → http://<vm-ip>:18689` — grep for the port + check the VM IP appears in the same line.

```bash
echo
echo "--- IP coupling ---"

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')

# 1. AGH bind_hosts vs current VM IP
agh_yaml="${HOME}/.volumes/adguard/conf/AdGuardHome.yaml"
if [ -f "$agh_yaml" ]; then
    bind=$(awk '
        /^[[:space:]]+bind_hosts:/ { in_bh=1; next }
        in_bh && /^[[:space:]]+- / { gsub(/^[[:space:]]+- /, ""); print; exit }
    ' "$agh_yaml")
    if [ "$bind" = "$vm_ip" ]; then
        pass "AGH bind_hosts matches bridged VM IP (${vm_ip})"
    else
        fail "AGH bind_hosts is ${bind} but VM IP is ${vm_ip} (run: dotfiles stacks bridged-ip-changed)"
    fi
else
    warn "AGH yaml not found at ${agh_yaml} (AGH never started?)"
fi

# 2/3. Tailscale serve mappings
TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
serve_status=$("$TAILSCALE" serve status 2>/dev/null || true)
for port in 8689 8767; do
    line=$(echo "$serve_status" | grep -E ":${port}[^0-9]" || true)
    if [ -z "$line" ]; then
        warn "tailscale serve has no mapping for :${port} (run: dotfiles stacks <stack> serve)"
    elif echo "$line" | grep -qF "${vm_ip}"; then
        pass "tailscale serve :${port} points at ${vm_ip}"
    else
        fail "tailscale serve :${port} not pointing at ${vm_ip} (run: dotfiles stacks bridged-ip-changed)"
    fi
done
```

**Verification:**

```bash
dotfiles stacks doctor
# Expected: --- IP coupling --- section, all [OK]
echo "exit=$?"
# Expected: 0

# Exercise the FAIL branch by manually breaking AGH bind_hosts
sudo sed -i .bak2 's/192\.168\.[0-9]*\.[0-9]*/192.168.99.99/' \
    ~/.volumes/adguard/conf/AdGuardHome.yaml
dotfiles stacks doctor; echo "exit=$?"
# Expected: [FAIL] AGH bind_hosts mismatch, exit 1

# RESTORE
cp ~/.volumes/adguard/conf/AdGuardHome.yaml.bak2 ~/.volumes/adguard/conf/AdGuardHome.yaml
dotfiles stacks adguard restart
dotfiles stacks doctor; echo "exit=$?"
# Expected: all-green, exit 0
```

**Commit:**
```bash
git add stacks/scripts/doctor.sh
git commit -m "doctor: check AGH bind_hosts + tailscale serve mappings vs current VM IP"
```
<!-- END_TASK_6 -->

---

## Done When

- `dotfiles stacks bridged-ip-changed` runs end-to-end, prints the closing checklist with the live MAC + IP, exits 0. AGH yaml gets a `.bak`; Tailscale serve mappings refreshed; subnet route re-advertised; Global NS refreshed.
- `docs/migration-recovery.md` exists with the clean-slate procedure (steps 1-9), references `bridged-ip-changed`, and explicitly warns against `limactl rename`.
- `stacks/README.md` no longer has the "Migrating from the old default/adguard" section. It now has:
  - "When the bridged VM IP changes" with the coupling table.
  - "Renaming a Colima profile" with the warning + cross-reference.
  - The static-MAC research outcome inline.
- `stacks/adguard/README.md` documents the router-side DNS config the user actually applied (WAN DNS non-AGH; LAN DHCP DNS = AGH primary + non-AGH secondary).
- `dotfiles stacks doctor` adds an `--- IP coupling ---` section with three checks; all `[OK]` on healthy state; intentional bind_hosts mismatch produces `[FAIL]` + exit 1.
- Six commits land: bridged-ip-changed.sh, justfile recipe, migration-recovery.md, stacks/README rewrite, adguard/README router section, doctor extension.
- Two human gates passed: (a) the user has set the router's WAN DNS to non-AGH; (b) the user has performed the LAN DHCP-DNS investigation on their RT-AC68U and recorded the chosen final config in adguard/README.md.
