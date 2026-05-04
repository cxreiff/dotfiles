# stacks

Docker compose stacks. Not stowed — invoked from the repo via `just`.

## Architecture

Two Colima VMs, each holding the stacks that match its networking model.
Profile names describe networking, not their first tenant:

| Profile   | VM type | Networking | Holds |
|---|---|---|---|
| `shared`  | `vz`   | vzNAT — Mac localhost forwards (Colima's `network.mode: shared`) | freshrss, wallabag, future Mac-localhost-only services |
| `bridged` | `qemu` | socket_vmnet bridged — real LAN IP (Colima's `network.mode: bridged`) | adguard, homebridge — services that need real LAN visibility (DNS source IPs, mDNS/Bonjour) |

Why split: only `qemu + socket_vmnet bridged` preserves source IPs and
propagates multicast (mDNS/Bonjour) to the LAN on macOS Colima — `vz`
doesn't support bridged networking (Apple's `com.apple.vm.networking`
entitlement isn't granted to third-party tools). Putting everything bridged
would mean qemu emulation for all services and exposing every port on the
LAN. The split keeps native vz performance for everything that doesn't need
real LAN visibility.

## Fresh-device setup

```sh
dotfiles stacks vm-up        # start both Colima profiles (reads stowed colima.yaml)
dotfiles stacks up-all       # bring up all stacks
```

Per-stack first-run details: `adguard/README.md`, `freshrss/README.md`,
`homebridge/README.md`, `wallabag/README.md`.

## Recipes

### VM control

| Recipe | Effect |
|---|---|
| `vm-shared`  | `colima start -p shared`  |
| `vm-bridged` | `colima start -p bridged` |
| `vm-up`      | both profiles             |

### Composite (across stacks)

| Recipe | Effect |
|---|---|
| `up-all` | bring up adguard, freshrss, homebridge, wallabag |
| `down-all` | reverse order: wallabag, homebridge, freshrss, adguard last (DNS-aware) |
| `ps-all` | container status across all stacks |
| `pull-all` | pull latest images for all stacks |

### Per-stack

Modules: `dotfiles stacks adguard …`, `dotfiles stacks freshrss …`,
`dotfiles stacks homebridge …`, `dotfiles stacks wallabag …`. See
respective READMEs for the full per-stack recipe set.

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

## Migrating from the old `default`/`adguard` profile names

Earlier versions of this repo used profile names `default` (vz) and
`adguard` (bridged). Those have been renamed to `shared` and `bridged`
(after Colima's own `network.mode` terms). On the current device, the
live `~/.colima/default/` and `~/.colima/adguard/` directories are
orphaned after `dotfiles stow restow`; pick one of the paths below to
bring the device back in sync.

### Clean-slate migration (also: new device)

Recreates the VMs from scratch. AGH state survives because it lives in
`~/.volumes/adguard/`; freshrss and wallabag use named docker volumes
inside the VM and **must be backed up first** or their data is lost.

```sh
dotfiles stacks down-all

# Back up named volumes (skip if you don't care about the data)
mkdir -p ~/stack-backups
for vol in freshrss_data freshrss_extensions wallabag_data wallabag_images; do
    docker --context colima run --rm -v "$vol:/v" -v ~/stack-backups:/b alpine \
        tar czf "/b/$vol.tgz" -C /v .
done

colima delete -p default
colima delete -p adguard

dotfiles stow restow
dotfiles stacks vm-up
dotfiles stacks up-all

# Restore named volumes
for vol in freshrss_data freshrss_extensions wallabag_data wallabag_images; do
    docker --context colima-shared run --rm -v "$vol:/v" -v ~/stack-backups:/b alpine \
        tar xzf "/b/$vol.tgz" -C /v
done
dotfiles stacks freshrss restart
dotfiles stacks wallabag restart

# If the bridged VM IP changed, re-advertise + re-approve in Tailscale
dotfiles stacks adguard advertise
```

### In-place migration (current device only, riskier)

Preserves existing VM disks by renaming Colima/Lima dirs. Verify the Lima
instance path with `colima list -j` first — Colima ≥0.6 uses
`~/.lima/colima-<profile>` (with the bare `colima` instance for the default
profile); older versions stored Lima instances under `~/.colima/_lima/`. If
the in-place rename leaves Lima confused, fall back to clean-slate.

```sh
dotfiles stacks down-all
colima stop -p default
colima stop -p adguard

mv ~/.colima/default ~/.colima/shared
mv ~/.colima/adguard ~/.colima/bridged
mv ~/.lima/colima ~/.lima/colima-shared
mv ~/.lima/colima-adguard ~/.lima/colima-bridged

dotfiles stow restow
dotfiles stacks vm-up
dotfiles stacks up-all
```
