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

- Recent `~/.volume-backups/daily/` tarballs for all stacks — adguard, connectome,
  freshrss, homebridge, onecli, wallabag (run `dotfiles stacks backup-all` before
  destroying anything). The launchd timer should already be giving you nightly snapshots.
- The user's `stacks/<stack>/.env` files captured separately. They're gitignored
  so they're not in the repo; copy them off before wiping a device. **For onecli v2,
  escrow the whole `stacks/onecli/.env` in the password manager:** a restored vault
  needs the same `SECRET_ENCRYPTION_KEY` (to decrypt its secrets) and the same
  `POSTGRES_PASSWORD` (Postgres keeps the password it was initialised with).
- A copy of the `~/Developer/connectome/` clones if possible: their `local` branches
  hold the patch commits, which are not pushed anywhere. Without it, the patches are
  re-applied by hand from the subjects in `stacks/connectome/sources.lock` before
  `connectome build`.
- The clean-slate procedure deletes the agents VM, and with it the locally built
  connectome images, so `connectome build` always runs again after onecli is back.

## Clean-slate procedure

```sh
# 1. Take a fresh full backup just before destroying state
dotfiles stacks backup-all
ls -la ~/.volume-backups/daily/                  # confirm same-day tarballs for all stacks

# 2. Bring everything down
dotfiles stacks down-all

# 3. Destroy all VMs (host bind mounts under ~/.volumes/ are unaffected)
colima delete -p shared
colima delete -p bridged
colima delete -p agents

# 4. Re-stow if this is a new device
dotfiles stow setup    # or stow setup-base + stow setup-colima per Phase 8

# 5. Re-create VMs from the stowed colima.yaml profiles
dotfiles stacks vm-shared-up
dotfiles stacks vm-bridged-up
dotfiles stacks vm-agents-up

# 6. onecli: recreate stacks/onecli/.env (0600) from the ESCROWED copy (the
#    whole file: SECRET_ENCRYPTION_KEY decrypts the secrets, and pgdata only
#    accepts the POSTGRES_PASSWORD it was initialised with). Never use init-env
#    here: it would generate new values that cannot open the backup. Then
#    restore. Do NOT run `onecli up` first: restore refuses non-empty volumes
#    and brings the stack up itself.
install -m 600 /dev/null stacks/onecli/.env
$EDITOR stacks/onecli/.env  # paste the escrowed onecli .env
dotfiles stacks onecli restore "$HOME/.volume-backups/daily/onecli-$(date +%Y-%m-%d).tgz"

# 7. connectome: sources, patches, .env, build, then restore.
#    sources.lock (tracked) records, per clone: sha= (the built commit, i.e. the
#    tip of the `local` branch, which exists only in the old clone) and base=
#    (the upstream commit it branched from), plus one `patch` line per local
#    commit. Check out base=, then re-apply the patches on a `local` branch:
#    cherry-pick from a copy of the old clones if you have one, else
#    re-implement each from its subject (see stacks/connectome/README.md).
mkdir -p ~/Developer/connectome && cd ~/Developer/connectome
for repo in connectome-host discord-mcpl heartbeat-mcpl voice-kit; do
    git clone "https://github.com/anima-research/${repo}.git"
    base=$(awk -v r="$repo" '$1=="source" && $2==r {for (i=3;i<=NF;i++) if ($i ~ /^base=/) {sub("base=","",$i); print $i}}' \
        ~/Developer/dotfiles/stacks/connectome/sources.lock)
    git -C "$repo" checkout -b local "$base"
done
grep '^patch ' ~/Developer/dotfiles/stacks/connectome/sources.lock   # re-apply these, commit each on `local`
cd ~/Developer/dotfiles
# connectome .env: restore it from your copy, or re-create with init-env (it
# prompts for the model, Discord token, guild:channel and operator id, and syncs
# the onecli agent tokens from the restored vault).
dotfiles stacks connectome init-env
# Build after onecli is up: the images bake in the restored vault's gateway CA.
dotfiles stacks connectome build
dotfiles stacks connectome image-test
# Restore onto the (still empty) volumes; restore brings the stack up. Do not
# run `connectome up` or `provision-codex` before it (the codex stub is in the
# backup).
dotfiles stacks connectome restore "$HOME/.volume-backups/daily/connectome-$(date +%Y-%m-%d).tgz"
dotfiles stacks connectome smoke

# 8. Restore other stacks from backup (optional; skip if you have no backups)
for stack in adguard freshrss homebridge wallabag; do
    if [ -f ~/.volume-backups/daily/${stack}-$(date +%Y-%m-%d).tgz ]; then
        dotfiles stacks $stack restore ~/.volume-backups/daily/${stack}-$(date +%Y-%m-%d).tgz --force
    fi
done

# 9. Bring everything up
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
backups to restore, and you skip step 6). After step 7, step through each
stack's first-run wizard / `bootstrap` per the per-stack README. See the new
subsection below for **onecli v2 and connectome on a fresh device**.

### onecli v2 and connectome on a fresh device

Both paths need the clones, the hand-applied patches and `connectome build`
(the images bake in the vault's gateway CA, so build after onecli is up).
They differ in where the vault and the agent state come from.

1. **Clone and patch the connectome sources** at the commits in the tracked
   `stacks/connectome/sources.lock`: check out each `base=` (the upstream
   commit), create a `local` branch, and re-apply the commits listed in the
   `patch` lines (cherry-pick from a copy of the old clones, or re-implement
   from the subjects). `voice-kit` has no patches. The loop in the clean-slate
   procedure above does the clone and checkout. `build` refuses dirty clones
   and rewrites `sources.lock` with the new SHAs.

2. **onecli v2**

   With a backup: recreate `stacks/onecli/.env` from the escrowed copy, then
   `dotfiles stacks onecli restore "$HOME/.volume-backups/daily/onecli-<date>.tgz"`
   (no `up` first), then `dotfiles stacks onecli bootstrap` to sign the host
   CLI in to the restored account.

   From scratch:

   ```sh
   dotfiles stacks onecli init-env      # generates the four secrets; escrow the whole .env
   dotfiles stacks onecli up
   dotfiles stacks onecli bootstrap     # register the operator account, point the host CLI at it
   dotfiles stacks onecli import-openai # dedicated ChatGPT device login (also reconciles grants)
   dotfiles stacks onecli policy        # agents, org rules (rule 1 limit: see connectome README)
   ```

3. **connectome**

   ```sh
   dotfiles stacks connectome init-env  # prompts; syncs the aoc_ tokens from onecli
   dotfiles stacks connectome build
   dotfiles stacks connectome image-test
   ```

   With a backup: `dotfiles stacks connectome restore "$HOME/.volume-backups/daily/connectome-<date>.tgz"`
   onto the empty volumes (restore brings the stack up; skip `provision-codex`
   and `up`).

   From scratch:

   ```sh
   dotfiles stacks connectome provision-codex   # onecli Codex stub + config into the state volume
   dotfiles stacks connectome up
   dotfiles stacks connectome serve
   ```

   Either way, finish with `dotfiles stacks connectome smoke`.

Tarball paths passed to `restore` must be absolute (relative paths resolve
against `stacks/<stack>/`).

Then proceed with the other stacks:
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
