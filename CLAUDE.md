# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. Last updated: 2026-05-06.

## Repo shape

Three independent areas, intentionally not unified:

- `bare/` — legacy bare-repo dotfiles. **Unmanaged, untouched.** Do not edit unless the user explicitly asks; nothing in the active workflow reads from here.
- `stow/` — GNU Stow packages, symlinked into `$HOME` for tools that read fixed paths.
- `stacks/` — Docker Compose stacks. **Not stowed** — invoked in place via `just`.
- `stacks/scripts/` — shared shell helpers used by stack justfiles (`backup.sh`, `restore.sh`, `backup-rotate.sh`, `backup-install.sh`, `bridged-ip-changed.sh`, `doctor.sh`, `lib/check.sh`, plus the launchd plist template). Per-stack `scripts/` dirs hold stack-specific scripts (e.g., `adguard/scripts/tailnet-dns.sh`, `homebridge/scripts/{bootstrap,gen-pin}.sh`).
- `docs/` — operational references: `docs/migration-recovery.md` (clean-slate rebuild procedure), `docs/design-plans/` and `docs/implementation-plans/` (planning artifacts).

The `dotfiles` shell alias (defined in `stow/base/.zshrc`) is the entry point for everything:

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```

The root `justfile` only does `mod stacks` / `mod stow`; all real recipes live in `stacks/justfile`, `stow/justfile`, and per-stack `stacks/<name>/justfile`. Use `dotfiles` (or `just -f …`) rather than invoking `docker compose` / `stow` / `tailscale serve` by hand — the justfiles encode the right context, ports, and ordering.

## Setup is staged (universal → container → per-stack)

The top-level README is bifurcated; CLAUDE.md edits that touch setup must keep the same boundaries:

- **Stage 1 (`README.md`)** — universal: `brew install just stow neovim ...` + `dotfiles stow setup-base`. Every device.
- **Stage 2 (`stacks/README.md`)** — opt-in container support: brew Colima/Docker/socket_vmnet/tailscale-cli + `dotfiles stow setup-colima` + `dotfiles stacks vm-shared-up` + `dotfiles stacks vm-bridged-up`. Only on hosts that run stacks.
- **Stage 3** — per-stack first-run, documented in each `stacks/<name>/README.md`.

`docs/migration-recovery.md` is the canonical clean-slate / fresh-device rebuild procedure (covers `colima delete && colima start` preserving the qemu-deterministic MAC, restore-from-tarball, and the bridged-IP recovery checklist).

## Reproducible vs runtime

What's in the repo vs what's environment-specific:

| In repo (tracked) | Runtime / environment (gitignored or external) |
|---|---|
| `stacks/<stack>/{justfile, compose.yaml, README.md, .env.example}` | `stacks/<stack>/.env` (mode 0600) |
| `stacks/<stack>/scripts/*.sh` | Container state inside Colima VMs |
| `stacks/<stack>/conf/...` templates (e.g., `homebridge/config.json.template`) | Live files under `~/.volumes/<stack>/` |
| `stow/<package>/...` | Stowed symlinks under `$HOME` |
| `stow/colima/.colima/<profile>/colima.yaml` | Live VM disks under `~/.colima/_lima/`, qemu MAC, DHCP-leased IP |
| `stacks/scripts/{backup,restore,backup-rotate}.sh` | `~/.volume-backups/{daily,weekly,monthly}/` backup tarballs (gitignored runtime data) |
| `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` is per-machine | Installed by `dotfiles stacks backup-install` |

Things that look like "runtime drift" but are actually fine:
- Bridged VM IP changing rarely (router reservation pins it; `dotfiles
  stacks bridged-ip-changed` re-coordinates everything else).
- Tailscale Global Nameservers being toggled by `tailnet-dns-on/off` —
  not configuration drift, an intentional state machine.

## Colima first-start config mutations

When you first `colima start -p <profile>`, Colima rewrites the stowed
`colima.yaml` to add resolved fields (the `vmnet` socket path, the user's
home dir absolute path, etc.). This is a one-time lifecycle event, NOT
runtime churn:

- The mutated yaml IS committed to the repo when it changes (`stow
  restow` keeps the symlink pointing at the repo file, so `git diff` shows
  the new resolved fields after first start on a fresh device).
- Subsequent `colima start`/`stop`/`restart` do NOT mutate the yaml.
- If `colima.yaml` shows up in `git status` after a routine restart on
  an existing setup, that's a regression worth investigating — Colima is
  not supposed to rewrite the file outside of first-start.

## Common commands

```sh
dotfiles                          # list root recipes
dotfiles stow setup               # both packages (base + colima)
dotfiles stow setup-base          # editor + shell only (Stage 1)
dotfiles stow setup-colima        # container support only (Stage 2)
dotfiles stow restow              # re-link after adding files (also: restow-base, restow-colima)
dotfiles stow status              # dry-run (also: status-base, status-colima)

dotfiles stacks vm-shared-up      # start a VM (also: vm-shared-down, vm-bridged-{up,down}, vm-agents-{up,down})
dotfiles stacks up-all            # bring up all stacks
dotfiles stacks down-all          # DNS-aware shutdown order (apps before adguard)
dotfiles stacks ps-all            # status across stacks
dotfiles stacks doctor            # ~22 read-only checks across 6 sections (run after non-trivial changes)

dotfiles stacks backup-all        # per-stack backup + GFS rotation
dotfiles stacks backup-install    # install ~/Library/LaunchAgents nightly 4 AM timer
dotfiles stacks bridged-ip-changed  # re-coordinate every IP-coupled artifact

dotfiles stacks <stack> up|down|restart|logs|ps|pull|shell
dotfiles stacks <stack> serve     # publish via Tailscale serve
dotfiles stacks <stack> backup|restore <tarball>
dotfiles stacks adguard tailnet-dns-on|tailnet-dns-off|tailnet-dns-status
```

Per-stack details: `stacks/<name>/README.md`. The `adguard` README documents a non-obvious wizard gotcha (must bind DNS to `col0`, not `eth0` or "All interfaces") — preserve that if editing.

`doctor` is the first thing to run when investigating any operational issue — it covers Infrastructure, Stack volumes, Backups (fails if any tarball is >36h old), DNS failover, IP coupling, and Stack identity & env. It's read-only and AC5.4-compliant (does not read .env *values*; the one BRIDGE_USERNAME read is a public pairing identifier, not a secret — don't extend that pattern to other keys without thought).

## DNS failover state machine

`adguard up` and `adguard down` automatically toggle Tailscale Global Nameservers via `adguard/scripts/tailnet-dns.sh` (Tailscale REST API, requires `TAILSCALE_PAT` in `stacks/adguard/.env`). The `up` recipe wires `wait-healthy.sh && tailnet-dns.sh on` on a single shell line so a wait-healthy failure surfaces as the recipe's exit code (no half-state where AGH is unhealthy but tailnet NS already points at it). The `down` recipe flips off *before* `compose down` to keep the tailnet resolvable for the brief overlap.

`doctor`'s "DNS failover" section cross-checks AGH container state vs the tailnet NS list and **fails** if AGH is Down but the tailnet NS still points at it (the bricked-DNS scenario). Don't add manual `tailscale dns` invocations to other places — route through the `tailnet-dns-*` recipes.

## Colima architecture

Three Colima profiles, each tuned for the workloads it carries:

| Profile | VM type | Networking | Holds |
|---|---|---|---|
| `shared` | `vz` | vzNAT, Mac localhost forwards (Colima's `network.mode: shared`) | `freshrss`, `wallabag`, future Mac-localhost-only services |
| `bridged` | `qemu` | bridged via `socket_vmnet`, real LAN IP (Colima's `network.mode: bridged`) | `adguard` (DNS source IPs), `homebridge` (HomeKit/mDNS) |
| `agents` | `vz` | vzNAT (`network.mode: shared`) | container host for agent workloads |

Each VM is started and stopped individually via `vm-<name>-up` / `vm-<name>-down`. `shared` and `bridged` are the always-on home-services VMs; `agents` is started on demand so its CPU/RAM are only reserved while in use.

Why `bridged` exists separately from `shared`: only `qemu + socket_vmnet bridged` preserves source IPs and propagates multicast (mDNS/Bonjour) to the LAN on macOS Colima — `vz` doesn't support bridged networking. Putting everything bridged would force qemu emulation for all services and expose every port to the LAN. The split keeps native vz performance for everything that doesn't need real LAN visibility.

`adguard` and `homebridge` justfiles use `docker --context colima-bridged`; `freshrss` and `wallabag` use `docker --context colima-shared`. Don't homogenize them. Likewise, the bridged-VM `serve` recipes parse `colima list` for the live VM IP (because `network_mode: host` binds inside the VM, not on Mac localhost) — keep that pattern.

All three profiles set `autoActivate: false` so `colima start -p X` does not steal the active Docker context. The active context is held at `default` (the built-in `unix:///var/run/docker.sock` pointer, which is unbound on this machine — there's no Docker Desktop). Any ad-hoc `docker run` from a fresh shell therefore fails fast rather than silently dropping a stray container into a purpose-dedicated VM. Recipes that need a VM target it explicitly with `--context colima-<profile>`; if you genuinely want ad-hoc work to land somewhere, `docker context use colima-<profile>` is a deliberate, scoped switch.

## Stow package conventions

| Package | Folding | Why |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.zshrc` — folder symlinks fine |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/<profile>/` holds runtime state files; folder-level symlinking would suck them into the repo |

When adding a new package, edit `stow/justfile` to add the package to **every aggregate recipe** (`setup`, `restow`, `unstow`, `status`) AND add **per-package recipes** (`setup-<name>`, `restow-<name>`, `unstow-<name>`, `status-<name>`) mirroring the existing pattern — there's no loop, every recipe lists each package explicitly. Use `--no-folding` if the target dir holds runtime state.

## Port and `.env` conventions

- **`serve_port`** — Tailscale-side HTTPS port (the URL users hit).
- **`internal_port`** — local app/forward port. Convention: `1` prefixed to `serve_port` (`8765` → `18765`, `8689` → `18689`).
- The justfile is the source of truth for these. When changing a stack's port, the README usually lists the other places that must change in lockstep (e.g., for `adguard`: `internal_port` in justfile **and** `address:` in `~/.volumes/adguard/conf/AdGuardHome.yaml`; for `homebridge`: `internal_port` in justfile **and** `platforms[].port` in `~/.volumes/homebridge/config.json`).
- `.env` is gitignored and kept `0600`; `.env.example` is the tracked template. The `.gitignore` allowlists `*.env.example` after blocking `*.env*` — keep that pattern intact.
- `tailscale` is invoked via the absolute path `/Applications/Tailscale.app/Contents/MacOS/Tailscale` inside justfiles (the Homebrew CLI shim isn't assumed). The user's `.zshrc` aliases `tailscale` to the same path for interactive use.

## Backups

- Per-stack `backup` recipes tar `~/.volumes/<stack>/` into `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz`. Quiesce-needing stacks (`freshrss`, `wallabag`, `homebridge` — SQLite) wrap the tar in `down && up`; `adguard` stays up (its on-disk format is safe to read live).
- `backup-rotate.sh` GFS-promotes daily → weekly (Sundays, kept 4) → monthly (1st of month, kept 3). `daily/` is capped at 7 per stack.
- The launchd LaunchAgent installed by `dotfiles stacks backup-install` runs `dotfiles stacks backup-all` nightly at 04:00. Logs land in `~/.volume-backups/.log/{stdout,stderr}.log`. The plist Label is `com.cxreiff.dotfiles.backup`.
- `~/.volume-backups/` is gitignored runtime data; never commit a tarball.

## When editing

- Cross-cutting changes (ports, new stack, new package) usually touch a justfile **and** a README — keep them in sync; READMEs are operational, not decorative.
- Don't introduce manual `docker compose` / `tailscale serve` / `tailscale dns` invocations in docs or new recipes; route through the existing module structure.
- The `bare/` tree is frozen. If a config under `bare/.config/<tool>/` needs to become live, the move is into `stow/base/.config/<tool>/` plus a `restow` — not editing in place.
- After non-trivial changes, run `dotfiles stacks doctor` and fix any FAILs before declaring work complete. WARNs are informational (e.g., missing `.env` on a stack you don't run).
