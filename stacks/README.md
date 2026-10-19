# stacks

Docker compose stacks. Not stowed — invoked from the repo via `just`.

## Architecture

Three Colima VMs, each tuned for the workloads it carries:

| Profile    | VM type | Networking | Holds |
|---|---|---|---|
| `shared`   | `vz`   | vzNAT — Mac localhost forwards (Colima's `network.mode: shared`) | freshrss, wallabag, future Mac-localhost-only services |
| `bridged`  | `qemu` | socket_vmnet bridged — real LAN IP (Colima's `network.mode: bridged`) | adguard, homebridge — services that need real LAN visibility (DNS source IPs, mDNS/Bonjour) |
| `agents`   | `vz`   | vzNAT (`network.mode: shared`) | onecli (credential vault v2), connectome (agent host + shell), cxagents (tailnet node) |

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
brew install colima docker socket_vmnet gettext jq tailscale socat

dotfiles stow setup-colima                             # symlink ~/.colima/<profile>/colima.yaml
dotfiles stacks vm-shared-up                           # start the shared VM
dotfiles stacks vm-bridged-up                          # start the bridged VM
```

Do **NOT** `sudo brew services start socket_vmnet` (despite the formula's
caveat suggesting it). Colima launches its own copy of the binary
(`/opt/colima/bin/socket_vmnet`, bridged mode on `en0`, via
`/etc/sudoers.d/colima`) on `vm-bridged-up`; the Homebrew service runs a
*shared*-mode instance nothing connects to, and its vmnet gateway drags in
InternetSharing/bootpd and puts mDNSResponder on wildcard `*:53` — which
collides with the dns-forward relay's `:53` bind and answers DNS probes
when the relay is down, masking real failures (bitten 2026-06-09 →
2026-07-26). `brew install socket_vmnet` (the binary) is still required.

`brew install tailscale` installs the open-source `tailscaled` daemon and
the `tailscale` CLI (not the Mac App Store / `.app` client — this host
runs headless, so there is no GUI to host the app). Start the daemon once
as a root LaunchDaemon and log in:

```sh
sudo brew services start tailscale
sudo tailscale up --hostname=cxmini
```

On a replacement Mac, first delete the stale `cxmini` device in the admin console, or this join takes the name `cxmini-1` — see `docs/migration-recovery.md`.

Every justfile and script invokes the CLI by absolute path at
`/opt/homebrew/bin/tailscale` (LaunchDaemons run with a minimal `PATH`).

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
- `onecli/README.md` — credential vault v2 (agents VM, required for connectome)
- `../tailscale/README.md` — not a stack (repo-root `tailscale/`): the tailnet policy and the OAuth clients in `tailscale/.env`. `adguard`'s tailnet DNS needs the admin client; `cxagents` needs both, with the policy declaring `tag:cxagents` pushed first.
- `cxagents/README.md` — tailnet node `cxagents` (agents VM; set up `tailscale/` first, see above; connectome's shell joins it as an optional overlay)
- `connectome/README.md` — AI agent **clara** over Discord (agents VM; requires onecli)
- `wallabag/README.md` — read-it-later (shared VM, run `dotfiles stacks
  wallabag bootstrap` after first up)

After all desired stacks are up, install the nightly backup timer and the
boot autostart daemon (so VMs + stacks come back after a reboot):

```sh
dotfiles stacks backup-install                         # /Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist (sudo)
dotfiles stacks startup-install                        # /Library/LaunchDaemons/com.cxreiff.dotfiles.startup.plist (sudo)
dotfiles stacks dns-forward-install                    # adguard only: tailnet DNS relay (sudo) — see adguard/README.md
dotfiles stacks doctor                                 # confirm everything's green
```

Both are **LaunchDaemons**, not LaunchAgents, because this host is headless
+ FileVault — there's no GUI login session for an agent to load into. The
`*-install` recipes use `sudo` for the install + `launchctl bootstrap
system`; run them as your normal user over SSH. See
[Autostart at boot](#autostart-at-boot).

`doctor` runs read-only diagnostics across 10 sections: Infrastructure (colima/docker/socket_vmnet/just),
Stack volumes, Backups, DNS forwarder (relay health), Tailnet (OAuth client scopes and tags, policy drift, MagicDNS, Tailnet Lock), DNS failover (tailnet Global NS), IP coupling,
Agents (onecli health, CA fingerprints, network attachment, shell grant, log sizes, invariant lints), cxagents (node identity and certificate, routes targets, lockdown lints), and Stack identity & env (incl. `.env` mode 0600). Run it after any non-trivial change.

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
| `up-all` | bring up adguard, freshrss, homebridge, onecli, cxagents, connectome, wallabag. Continues past failures (e.g., `tailscale/.env` missing or the Tailscale API unreachable) so agent stacks still start at boot; prints a summary naming any failures; exits non-zero if any failed. onecli precedes connectome (connectome joins the `onecli-agents` network); cxagents precedes connectome so the shell can join the `cxagents` network. |
| `down-all` | reverse order, DNS-aware: connectome, cxagents, onecli, wallabag, homebridge, freshrss, adguard last. connectome must come down before cxagents (its `down` refuses while the shell holds the `cxagents` network) and before onecli (onecli owns the `onecli-agents` network). |
| `ps-all` | container status across all stacks |
| `pull-all` | pull latest images for all stacks (connectome included) |
| `backup-all` | backup all stacks in order (adguard, freshrss, homebridge, connectome, onecli, wallabag), then run GFS rotation. Each stack uses its quiesce method (see Backups below). |
| `startup-install` | install the boot autostart daemon (all VMs + `up-all` at boot; sudo) |
| `backup-install` | install the nightly 4 AM backup daemon (sudo) |

### Per-stack

Modules: `dotfiles stacks adguard …`, `dotfiles stacks connectome …`,
`dotfiles stacks freshrss …`, `dotfiles stacks homebridge …`,
`dotfiles stacks onecli …`, `dotfiles stacks cxagents …`, `dotfiles stacks wallabag …`. See
respective READMEs for the full per-stack recipe set.

## Backups

Per-stack `backup` and `restore` recipes tar each stack's data (the
`~/.volumes/<stack>` bind mount, or the named volumes for onecli and
connectome) into `~/.volume-backups/{daily,weekly,monthly}/` (tarballs 0600
for onecli and connectome). The aggregate `backup-all`
recipe backs up adguard, freshrss, homebridge, connectome, onecli, wallabag (connectome before
onecli), then runs `backup-rotate.sh`:

| Tier | Retention | Promoted from |
|---|---|---|
| `daily/` | 7 per stack | `backup-all` itself |
| `weekly/` | 4 per stack | Sunday's daily tarball |
| `monthly/` | 3 per stack | The 1st of month's daily tarball |
| `archive/` (outside GFS) | permanent | `onecli-v1-final.tgz` (reference, not rotated) |

Backup quiesce and coverage:

- **adguard** (bind mount `~/.volumes/adguard/`): stays up (safe to tar live, no SQLite).
- **freshrss** (bind mount `~/.volumes/freshrss/`): `down && up` quiesce (SQLite-backed RSS feed DB).
- **homebridge** (bind mount `~/.volumes/homebridge/`): `down && up` quiesce (SQLite-backed HomeKit pairing).
- **wallabag** (bind mount `~/.volumes/wallabag/`): `down && up` quiesce.
- **connectome** (named volumes `state` and `workspace` only — NOT `outbox`): `compose stop && backup && compose start`. Prunes `llm-calls.*.jsonl` older than 14 days and truncates `headless.log` to 10 MiB when >50 MiB.
- **onecli** (named volumes `pgdata`, `app-data`): `compose stop && backup && compose start` (Postgres data is only consistent stopped).
- **cxagents**: not in `backup-all`. Its state volume (node keys, certificate cache) is disposable; see [`cxagents/README.md`](cxagents/README.md).

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
| `dns-forward` relay **target** (VM IP) | `com.cxreiff.dotfiles.dns-forward.plist` | `dotfiles stacks dns-forward-install` |
| Subnet route advertisement (optional — admin-UI-by-LAN-IP only) | Tailscale node config | `dotfiles stacks adguard advertise` |
| Tailscale Global Nameservers (points at node IP, *not* VM IP) | Tailscale tailnet config | `dotfiles stacks adguard tailnet-dns-on` |
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
