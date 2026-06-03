# stacks

Docker compose stacks. Not stowed — invoked from the repo via `just`.

## Architecture

Three Colima VMs, each tuned for the workloads it carries:

| Profile    | VM type | Networking | Holds |
|---|---|---|---|
| `shared`   | `vz`   | vzNAT — Mac localhost forwards (Colima's `network.mode: shared`) | freshrss, wallabag, future Mac-localhost-only services |
| `bridged`  | `qemu` | socket_vmnet bridged — real LAN IP (Colima's `network.mode: bridged`) | adguard, homebridge — services that need real LAN visibility (DNS source IPs, mDNS/Bonjour) |
| `agents`   | `vz`   | vzNAT (`network.mode: shared`) | container host for agent workloads |

Each VM is started and stopped individually via `vm-<name>-up` /
`vm-<name>-down`. All three are brought up automatically at boot once you
install the autostart daemon (`dotfiles stacks startup-install`, see
[Autostart at boot](#autostart-at-boot)); `down` a VM by hand when you want
to reclaim its CPU/RAM.

Why `bridged` is a separate VM from `shared`: only `qemu + socket_vmnet
bridged` preserves source IPs and propagates multicast (mDNS/Bonjour) to
the LAN on macOS Colima — `vz` doesn't support bridged networking
(Apple's `com.apple.vm.networking` entitlement isn't granted to
third-party tools). Putting everything bridged would mean qemu emulation
for all services and exposing every port on the LAN. The split keeps
native vz performance for everything that doesn't need real LAN
visibility.

## Stage 2 — fresh-device setup

Prerequisites:
- Stage 1 done (`dotfiles stow setup-base` already ran on this device).
- macOS host with admin/sudo (socket_vmnet needs sudo at install time).

```sh
brew install colima docker socket_vmnet gettext jq tailscale-cli
sudo brew services start socket_vmnet                  # bridged-VM networking

dotfiles stow setup-colima                             # symlink ~/.colima/<profile>/colima.yaml
dotfiles stacks vm-shared-up                           # start the shared VM
dotfiles stacks vm-bridged-up                          # start the bridged VM
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

After all desired stacks are up, install the nightly backup timer and the
boot autostart daemon (so VMs + stacks come back after a reboot):

```sh
dotfiles stacks backup-install                         # /Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist (sudo)
dotfiles stacks startup-install                        # /Library/LaunchDaemons/com.cxreiff.dotfiles.startup.plist (sudo)
dotfiles stacks doctor                                 # confirm everything's green
```

Both are **LaunchDaemons**, not LaunchAgents, because this host is headless
+ FileVault — there's no GUI login session for an agent to load into. The
`*-install` recipes use `sudo` for the install + `launchctl bootstrap
system`; run them as your normal user over SSH. See
[Autostart at boot](#autostart-at-boot).

`doctor` runs read-only diagnostics (~12 checks across infrastructure,
per-stack state, Tailscale failover state, IP coupling, .env keys, and
homebridge pairing identity). Run it after any non-trivial change.

## Recipes

### VM control

| Recipe | Effect |
|---|---|
| `vm-shared-up`    | `colima start -p shared`  |
| `vm-shared-down`  | `colima stop -p shared`   |
| `vm-bridged-up`   | `colima start -p bridged` |
| `vm-bridged-down` | `colima stop -p bridged`  |
| `vm-agents-up`    | `colima start -p agents`  |
| `vm-agents-down`  | `colima stop -p agents`   |

### Composite (across stacks)

| Recipe | Effect |
|---|---|
| `up-all` | bring up adguard, freshrss, homebridge, onecli, wallabag |
| `down-all` | reverse order: onecli, wallabag, homebridge, freshrss, adguard last (DNS-aware) |
| `ps-all` | container status across all stacks |
| `pull-all` | pull latest images for all stacks |
| `startup-install` | install the boot autostart daemon (all VMs + `up-all` at boot; sudo) |
| `backup-install` | install the nightly 4 AM backup daemon (sudo) |

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
dotfiles stacks backup-install     # installs /Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist (sudo)
sudo launchctl print system/com.cxreiff.dotfiles.backup     # confirm next start
```

It's a LaunchDaemon (not a LaunchAgent) for the same reason as the autostart
daemon — see [Autostart at boot](#autostart-at-boot).

Logs land in `~/.volume-backups/.log/{stdout,stderr}.log`. `dotfiles stacks
doctor` fails if the latest tarball for any stack is older than 36 hours.

To restore on a fresh device, see
[`docs/migration-recovery.md`](../docs/migration-recovery.md).

## Autostart at boot

Colima VMs don't survive a reboot on their own. **This host is headless
(administered over SSH) with FileVault on, so there is no Aqua GUI login
session** — which means a LaunchAgent would never load (agents only load on
GUI login), and auto-login isn't available with FileVault. So autostart is a
**LaunchDaemon** in the `system` domain instead: it loads at system boot
regardless of GUI login and is managed entirely over SSH.

`dotfiles stacks startup-install` installs a `RunAtLoad` LaunchDaemon
(`/Library/LaunchDaemons/com.cxreiff.dotfiles.startup.plist`, Label
`com.cxreiff.dotfiles.startup`) that runs as your user and executes
`scripts/startup.sh` at boot: start all three VMs (`vm-shared-up`,
`vm-bridged-up`, `vm-agents-up`) then `up-all`.

```sh
dotfiles stacks startup-install     # installs the daemon (sudo)
sudo launchctl print system/com.cxreiff.dotfiles.startup    # confirm it's loaded
```

- **Rebooting remotely:** FileVault halts boot at the unlock gate before
  any daemon runs (kept on because it's the only at-rest protection for the
  `onecli` vault). For a planned remote reboot, unlock the next boot over
  SSH first: `sudo fdesetup authrestart`. Only unplanned power loss needs a
  physical/console unlock; the daemon fires normally once unlocked.
- Logs land in `~/Library/Logs/com.cxreiff.dotfiles.startup.{out,err}.log`.
- The daemon sets `UserName cxreiff` / `GroupName staff`, so it uses
  `~/.colima` and the user's docker contexts (not root's).
  `colima start -p bridged` is non-interactive because
  `/etc/sudoers.d/colima` grants `%staff` passwordless `socket_vmnet`.
- A VM that fails to start aborts the script; an `up-all` failure only
  warns (most likely `adguard up`'s Tailscale-DNS hookup racing Tailscale
  coming up at boot — re-run `dotfiles stacks up-all` or check `dotfiles
  stacks doctor`).
- Test it without rebooting (`-k` restarts the job):
  ```sh
  dotfiles stacks vm-agents-down                                  # least-disruptive VM to cycle
  sudo launchctl kickstart -k system/com.cxreiff.dotfiles.startup # re-run the daemon
  dotfiles stacks doctor                                          # agents VM + onecli back up?
  ```
- The orphan `homebrew.mxcl.colima` LaunchAgent that `brew install colima`
  drops is **not** used here — it starts an unmanaged `default` profile
  (and would steal the active docker context). It's renamed aside to
  `homebrew.mxcl.colima.plist.orphan-disabled`; leave it disabled/removed.

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
