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

To restore on a fresh device, see
[`docs/migration-recovery.md`](../docs/migration-recovery.md).

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
