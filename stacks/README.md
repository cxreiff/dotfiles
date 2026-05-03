# stacks

Docker compose stacks. Not stowed — invoked from the repo via `just`.

## Architecture

Two Colima VMs, each holding the stacks that match its networking model:

| Profile | VM type | Networking | Holds |
|---|---|---|---|
| `default` | `vz` | vzNAT (Mac localhost forwards) | freshrss, future general services |
| `adguard` | `qemu` | bridged via socket_vmnet (real LAN IP) | AGH only — bridged so DNS clients' source IPs reach the container |

Why split: only `qemu + socket_vmnet bridged` preserves source IPs on macOS
Colima (`vz` doesn't support bridged networking — Apple's
`com.apple.vm.networking` entitlement isn't granted to third-party tools).
Running everything bridged would mean putting all services under qemu
emulation and exposing every port to the LAN. The split keeps native vz
performance for everything that doesn't need source-IP visibility.

## Fresh-device setup

```sh
dotfiles stacks vm-up        # start both Colima profiles (reads stowed colima.yaml)
dotfiles stacks up-all       # bring up all stacks
```

Per-stack first-run details: `adguard/README.md`, `freshrss/README.md`.

## Recipes

### VM control

| Recipe | Effect |
|---|---|
| `vm-default` | `colima start -p default` |
| `vm-adguard` | `colima start -p adguard` |
| `vm-up` | both profiles |

### Composite (across stacks)

| Recipe | Effect |
|---|---|
| `up-all` | bring up adguard then freshrss |
| `down-all` | down freshrss first, then adguard (DNS-aware order) |
| `ps-all` | container status across all stacks |
| `pull-all` | pull latest images for all stacks |

### Per-stack

Modules: `dotfiles stacks adguard …`, `dotfiles stacks freshrss …`.
See respective READMEs for the full per-stack recipe set.
