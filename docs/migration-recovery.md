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
dotfiles stacks vm-shared-up
dotfiles stacks vm-bridged-up
dotfiles stacks vm-agents-up

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

# 9. Re-install the boot autostart + nightly backup LaunchDaemons (sudo).
#    Required on a fresh device: this host is headless + FileVault, so
#    nothing comes back after a reboot without these. See stacks/README.md
#    "Autostart at boot".
dotfiles stacks startup-install
dotfiles stacks backup-install

# 10. Confirm
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
