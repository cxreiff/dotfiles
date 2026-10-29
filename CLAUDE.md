# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. Last updated: 2026-10-18.

## Repo shape

Four independent areas, intentionally not unified:

- `archive/` — legacy bare-repo dotfiles from before the move to Stow. **Frozen, unmanaged.** Do not edit unless the user explicitly asks; nothing in the active workflow reads from here.
- `stow/` — GNU Stow packages, symlinked into `$HOME` for tools that read fixed paths.
- `stacks/` — Docker Compose stacks. **Not stowed** — invoked in place via `just`. Per-stack: `adguard/`, `connectome/`, `cxagents/`, `freshrss/`, `homebridge/`, `onecli/`, `wallabag/`. `cxagents/` is the tailnet node (`forwarder/` is a tsnet Go program; see its README).
- `stacks/scripts/` — shared shell helpers used by stack justfiles (`backup.sh`, `restore.sh`, `backup-rotate.sh`, `backup-install.sh`, `startup.sh`, `startup-install.sh`, `dns-forward.sh`, `dns-forward-install.sh`, `bridged-ip-changed.sh`, `doctor.sh`, `lib/check.sh`, plus the launchd plist templates for the backup timer, the boot autostart daemon, and the dns-forward relay daemon). Per-stack `scripts/` dirs hold stack-specific scripts (e.g., `adguard/scripts/tailnet-dns.sh`, `connectome/scripts/{build,compose,image-test,lint,smoke}.sh`, `cxagents/scripts/{build,login,lint,smoke,doctor}.sh`, `homebridge/scripts/{bootstrap,gen-pin}.sh`).
- `tailscale/` — the tailnet, declared: `policy.hujson` (the access policy, with its `tests`; source of truth), `tailnet.conf` (tailnet name, DNS suffix and this node's device name), `clients.conf` (the expected OAuth clients), `.env` (both OAuth client credentials, 0600, escrowed; only `scripts/api.sh` reads its values). Tailnet-global, and the dependency runs one way: stacks call into it (`scripts/api.sh`, `scripts/authkey.sh`, `scripts/lib/conf.sh`), and nothing in it calls into a stack. It does declare the tailnet-level facts stacks rely on (`tag:cxagents`, its grant and policy tests, the `authkeys` client's tag), reuses `stacks/scripts/lib/check.sh` for its [OK]/[FAIL] output, and its doctor scans `stacks/*/.env` key names (never values) for retired or misplaced Tailscale credentials. Recipes: `dotfiles tailscale policy-pull|policy-diff|policy-push [--init]|policy-status|authkey tag:<name>|lint|lint-test|doctor-test|smoke`. Not stowed, and no containers.
- `tools/` — small programs built from source and installed to `~/.local/bin` (`dotfiles tools install`, or `install-<tool>`). Not stowed: the build output is a binary, not a config file. `herdr-keys/` is a Rust crate that the herdr `[[keys.command]]` bindings in `stow/base/.config/herdr/config.toml` call. It handles directional nav that crosses panes, tabs and workspaces in sidebar order, plus directional new pane, tab and workspace. See its README for the semantics and the latency constraints (the binary runs once per keypress). Install by rename, never `cp` over the old binary (`scripts/install.sh` explains why).
- `docs/` — operational references: `docs/migration-recovery.md` (clean-slate rebuild procedure), `docs/design-plans/` and `docs/implementation-plans/` (planning artifacts).

The `dotfiles` shell alias (defined in `stow/base/.config/zsh/zshrc/aliases.zsh`; `CX_WORKSPACE` is set in `params.zsh`) is the entry point for everything:

```sh
alias dotfiles="just -f $CX_WORKSPACE/dotfiles/justfile"
```

The root `justfile` only does `mod stacks` / `mod stow` / `mod tailscale`; all real recipes live in `stacks/justfile`, `stow/justfile`, `tailscale/justfile`, and per-stack `stacks/<name>/justfile`. Use `dotfiles` (or `just -f …`) rather than invoking `docker compose` / `stow` / `tailscale serve` by hand — the justfiles encode the right context, ports, and ordering.

## Setup is staged (universal → container → per-stack)

The top-level README is bifurcated; CLAUDE.md edits that touch setup must keep the same boundaries:

- **Stage 1 (`README.md`)** — universal: `brew install just stow neovim ...` + `dotfiles stow setup-base`. Every device.
- **Stage 2 (`stacks/README.md`)** — opt-in container support: brew Colima/Docker/socket_vmnet/tailscale + `dotfiles stow setup-colima` + `dotfiles stacks vm-shared-up` + `dotfiles stacks vm-bridged-up`. Only on hosts that run stacks.
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
| `stacks/connectome/sources.lock` | `~/Developer/connectome/{connectome-host,discord-mcpl,heartbeat-mcpl,voice-kit}/` clones at pinned SHAs (base commit in `base=` field), with `local` branches holding patches (subjects listed) |
| `stacks/onecli/compose.yaml` | `onecli_pgdata` / `onecli_app-data` Docker named volumes inside the `agents` VM (encrypted ciphertext store + gateway CA; encryption key in `stacks/onecli/.env` + password manager escrow) |
| `stacks/connectome/compose.yaml` | `connectome_state` / `connectome_workspace` / `connectome_outbox` Docker named volumes inside the `agents` VM (plaintext agent state, the shell workspace, and the transient outbox; recipes are a read-only bind of `stacks/connectome/recipes`) |
| `tailscale/policy.hujson` | The live tailnet policy. `policy-push` is the only writer; doctor FAILs on drift (repo SHA-256 vs live ETag) |
| `tailscale/clients.conf`, `tailscale/tailnet.conf` | OAuth clients `dotfiles-admin` / `dotfiles-authkeys` and tailnet settings in the admin console (doctor checks scopes, tags, identity, MagicDNS, this node's name, Tailnet Lock) |
| `tailscale/.env.example` | `tailscale/.env` (0600, gitignored, escrowed as a whole file) |
| `stacks/cxagents/{compose.yaml,routes,forwarder/,build.lock}` | Image `tailnet-forwarder:local` and Docker named volume `cxagents_state` inside the `agents` VM (node keys and cert cache; disposable, not backed up), and the `cxagents` tailnet device |
| `stacks/scripts/{backup,restore,backup-rotate}.sh` | `~/.volume-backups/{daily,weekly,monthly}/` backup tarballs (gitignored runtime data) |
| `/Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist` is per-machine | Installed by `dotfiles stacks backup-install` (sudo) |
| `/Library/LaunchDaemons/com.cxreiff.dotfiles.startup.plist` is per-machine | Installed by `dotfiles stacks startup-install` (sudo) |
| `/Library/LaunchDaemons/com.cxreiff.dotfiles.dns-forward.plist` is per-machine (bakes in node Tailscale IP + bridged VM IP) | Installed by `dotfiles stacks dns-forward-install` (sudo) |

Things that look like "runtime drift" but are actually fine:
- Bridged VM IP changing rarely (router reservation pins it; `dotfiles
  stacks bridged-ip-changed` re-coordinates everything else).
- Tailscale Global Nameservers being toggled by `tailnet-dns-on/off` —
  not configuration drift, an intentional state machine.
- Whitespace and layout changes to `tailscale/policy.hujson` after a `policy-push`: Tailscale stores the policy in canonical HuJSON, and the push writes those stored bytes back. Commit the result.

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
dotfiles init                     # bootstrap the environment: brew bundle + stow setup-base + tools install (no Colima/stacks)
dotfiles brew [args]              # brew bundle on the root Brewfile (e.g. check, cleanup)
dotfiles stow setup               # both packages (base + colima)
dotfiles stow setup-base          # editor + shell only (Stage 1)
dotfiles stow setup-colima        # container support only (Stage 2)
dotfiles stow restow              # re-link after adding files (also: restow-base, restow-colima)
dotfiles stow status              # dry-run (also: status-base, status-colima)

dotfiles tools install            # build + install every tool to ~/.local/bin (also: install-herdr-keys)
dotfiles tools test               # every tool's tests (also: test-herdr-keys)

dotfiles stacks vm-shared-up      # start a VM (also: vm-shared-down, vm-bridged-{up,down}, vm-agents-{up,down})
dotfiles stacks up-all            # bring up all stacks (continues past failures; onecli and cxagents before connectome)
dotfiles stacks down-all          # DNS-aware shutdown order (connectome before cxagents and onecli; apps before adguard last)
dotfiles stacks ps-all            # status across stacks
dotfiles stacks doctor            # read-only checks across 10 sections: Infrastructure, Stack volumes, Backups, DNS forwarder, Tailnet, DNS failover, IP coupling, Agents (onecli + connectome), cxagents, Stack identity & env

dotfiles stacks backup-all        # per-stack backup + GFS rotation (adguard, freshrss, homebridge, connectome, onecli, wallabag)
dotfiles stacks backup-install    # install nightly 4 AM backup LaunchDaemon (sudo)
dotfiles stacks startup-install   # install boot autostart LaunchDaemon — all VMs + up-all (sudo)
dotfiles stacks dns-forward-install # install tailnet DNS relay LaunchDaemon — node-IP:53 -> AGH VM (adguard; sudo)
dotfiles stacks bridged-ip-changed  # re-coordinate every IP-coupled artifact

dotfiles stacks <stack> up|down|restart|logs|ps|pull|shell
dotfiles stacks <stack> serve     # publish via Tailscale serve
dotfiles stacks <stack> backup|restore <tarball>
dotfiles stacks connectome build|provision-codex|smoke|lint  # agent-specific recipes
dotfiles stacks cxagents build|image-test|test|login|up|down|restart|ps|logs|pull|smoke|smoke-test|lint|lint-test|login-test|doctor-test  # tailnet node (smoke takes --long; no shell, serve or backup recipes: its state is disposable)
dotfiles tailscale policy-pull|policy-diff|policy-push [--init]|policy-status|authkey tag:<name>|lint|lint-test|doctor-test|smoke  # tailnet policy and clients
dotfiles stacks adguard tailnet-dns-on|tailnet-dns-off|tailnet-dns-status|tailnet-dns-test
```

Per-stack details: `stacks/<name>/README.md`. The `adguard` README documents a non-obvious wizard gotcha (must bind DNS to `col0`, not `eth0` or "All interfaces") — preserve that if editing.

`doctor` is the first thing to run when investigating any operational issue — it covers Infrastructure, Stack volumes, Backups (fails if any tarball is >36h old), DNS forwarder, Tailnet (OAuth client scopes and tags, policy drift, MagicDNS, this node's name, Tailnet Lock), DNS failover, IP coupling, Agents (onecli + connectome health, CA fingerprints, shell grant, invariant lints), cxagents (node identity and certificate, routes targets, lockdown lints) and Stack identity & env (incl. `.env` mode 0600). It's read-only and AC5.4-compliant (does not read .env *values*; the one BRIDGE_USERNAME read is a public pairing identifier, not a secret — don't extend that pattern to other keys without thought).

## DNS failover state machine

`adguard up` and `adguard down` automatically toggle Tailscale Global Nameservers via `adguard/scripts/tailnet-dns.sh` (Tailscale REST API via `tailscale/scripts/api.sh` — the shared OAuth admin client in `tailscale/.env`). The `up` recipe wires `wait-healthy.sh && tailnet-dns.sh on` on a single shell line so a wait-healthy failure surfaces as the recipe's exit code (no half-state where AGH is unhealthy but tailnet NS already points at it). The `down` recipe flips off *before* `compose down` to keep the tailnet resolvable for the brief overlap.

**Global NS "on" points at this node's Tailscale IP (`tailscale ip -4`), NOT the bridged VM's LAN IP.** AGH listens on the VM's LAN IP, which is only tailnet-reachable behind an approved subnet route — fragile: it breaks if a client doesn't accept routes, or if the remote network reuses `192.168.1.x`. The `dns-forward` LaunchDaemon (`stacks/scripts/dns-forward.sh`, installed by `dns-forward-install`) relays `node-IP:53` → `VM-IP:53` (socat UDP+TCP, runs as **root** to bind `:53` — the only stacks daemon that runs as root), so Global NS can point at a native `100.x` address every client always carries. `tailnet-dns.sh on` preflights the relay (`dig @node-ip`) and refuses to set Global NS if it's not answering — a dead relay must never become the tailnet's only resolver. The relay is therefore a hard dependency of the failover "on" state; `doctor`'s `--- DNS forwarder ---` section checks it. The `advertise` recipe / subnet-route dance is now **optional** (only for reaching the AGH admin UI by LAN IP over Tailscale) — DNS no longer needs it.

Credentials are the non-expiring `dotfiles-admin` OAuth client in `tailscale/.env` (0600, escrowed). If tailnet DNS is not using AGH after a reboot, check `dotfiles stacks adguard tailnet-dns-status` and `doctor`'s `--- Tailnet ---` section; a missing `tailscale/.env` makes `adguard up` fail with a restore hint. `stacks/adguard/.env` is now optional and holds no credential: `tailnet-dns.sh` reads only `TAILNET_DNS_FALLBACK` from it (validated as an IP, read only by `off`; default `1.1.1.1`).

The router's LAN DHCP advertises **two** DNS servers: AGH (`192.168.1.78`) first and the router (`192.168.1.1`) second as an unfiltered outage fallback — a deliberate 2026-08-24 trade-off (see `stacks/adguard/README.md` "Router-side configuration"). Some LAN traffic bypassing AGH is expected, not a bug.

`doctor`'s "DNS failover" section cross-checks AGH container state vs the tailnet NS list and **fails** if AGH is Down but the tailnet NS still points at it (the bricked-DNS scenario). Don't add manual `tailscale dns` invocations to other places — route through the `tailnet-dns-*` recipes.

## Colima architecture

Three Colima profiles, each tuned for the workloads it carries:

| Profile | VM type | Networking | Holds |
|---|---|---|---|
| `shared` | `vz` | vzNAT, Mac localhost forwards (Colima's `network.mode: shared`) | `freshrss`, `wallabag`, future Mac-localhost-only services |
| `bridged` | `qemu` | bridged via `socket_vmnet`, real LAN IP (Colima's `network.mode: bridged`) | `adguard` (DNS source IPs), `homebridge` (HomeKit/mDNS) |
| `agents` | `vz` | vzNAT (`network.mode: shared`) | `onecli` (credential vault v2), `connectome` (agent host + shell), `cxagents` (tailnet node) |

Each VM is started and stopped individually via `vm-<name>-up` / `vm-<name>-down`. All three are brought up automatically at boot by the autostart LaunchDaemon (see "Boot autostart" below); `down` them individually when you want to reclaim a VM's CPU/RAM.

Why `bridged` exists separately from `shared`: only `qemu + socket_vmnet bridged` preserves source IPs and propagates multicast (mDNS/Bonjour) to the LAN on macOS Colima — `vz` doesn't support bridged networking. Putting everything bridged would force qemu emulation for all services and expose every port to the LAN. The split keeps native vz performance for everything that doesn't need real LAN visibility.

`adguard` and `homebridge` justfiles use `docker --context colima-bridged`; `freshrss` and `wallabag` use `docker --context colima-shared`. Don't homogenize them. Likewise, the bridged-VM `serve` recipes parse `colima list` for the live VM IP (because `network_mode: host` binds inside the VM, not on Mac localhost) — keep that pattern.

`onecli`, `connectome` and `cxagents` use `docker --context colima-agents`. **Unlike every other stack, their volumes live inside the VM as Docker named volumes, not under `~/.volumes/`** — see `stacks/onecli/README.md` for the threat-model rationale. The `connectome` stack also bind-mounts local recipes (`./recipes` in the stack directory, read-only into `/agent/recipes`).

`cxagents` is a tsnet tailnet node (container `cxagents-forwarder`, tagged `tag:cxagents`) that owns the Docker network `cxagents`. A target joins that network as external to be reachable. connectome's `shell` does so through the optional `compose.cxagents.yaml` overlay, which `stacks/connectome/scripts/compose.sh` adds only when the network exists; the `connectome` container never joins. The node reaches nothing on `cxmini` except what the policy allows, and it relays each agent server to `https://cxagents.faun-fir.ts.net:<port>` (see `stacks/cxagents/README.md`). Its identity is a tailnet device: `login` feeds a single-use auth key on stdin, and no key is stored.

All three profiles set `autoActivate: false` so `colima start -p X` does not steal the active Docker context. The active context is held at `default` (the built-in `unix:///var/run/docker.sock` pointer, which is unbound on this machine — there's no Docker Desktop). Any ad-hoc `docker run` from a fresh shell therefore fails fast rather than silently dropping a stray container into a purpose-dedicated VM. Recipes that need a VM target it explicitly with `--context colima-<profile>`; if you genuinely want ad-hoc work to land somewhere, `docker context use colima-<profile>` is a deliberate, scoped switch.

## Stow package conventions

| Package | Folding | Why |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.zshrc` — folder symlinks fine. Exception: `~/.config/herdr/` holds herdr's sockets, logs and session state, so the base recipes `mkdir -p ~/.config/herdr` first and stow links only `config.toml`. herdr's own config writes go through the symlink (`fs::write`), so settings changed in its UI show up in `git diff` |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/<profile>/` holds runtime state files; folder-level symlinking would suck them into the repo |

When adding a new package, edit `stow/justfile` to add the package to **every aggregate recipe** (`setup`, `restow`, `unstow`, `status`) AND add **per-package recipes** (`setup-<name>`, `restow-<name>`, `unstow-<name>`, `status-<name>`) mirroring the existing pattern — there's no loop, every recipe lists each package explicitly. Use `--no-folding` if the target dir holds runtime state.

## Port and `.env` conventions

- **`serve_port`** — Tailscale-side HTTPS port (the URL users hit).
- **`internal_port`** — local app/forward port. Convention: `1` prefixed to `serve_port` (`8765` → `18765`, `8689` → `18689`).
- The justfile is the source of truth for these. When changing a stack's port, the README usually lists the other places that must change in lockstep (e.g., for `adguard`: `internal_port` in justfile **and** `address:` in `~/.volumes/adguard/conf/AdGuardHome.yaml`; for `homebridge`: `internal_port` in justfile **and** `platforms[].port` in `~/.volumes/homebridge/config.json`).
- `.env` is gitignored and kept `0600`; `.env.example` is the tracked template. The `.gitignore` allowlists `*.env.example` after blocking `*.env*` — keep that pattern intact.
- Tailscale is the Homebrew `tailscale` formula (open-source `tailscaled` as a root LaunchDaemon via `brew services`), **not** Tailscale.app — the host is headless, so the GUI client was dropped (2026-09-14). `tailscale` is invoked via the absolute path `/opt/homebrew/bin/tailscale` inside justfiles and scripts because LaunchDaemons run with a minimal `PATH`. The node's Tailscale hostname is `cxmini` (MagicDNS `cxmini.faun-fir.ts.net`); the old node was `cxreiff-mini`. Switching daemons issued a **new node IP**, so anything that bakes in `tailscale ip -4` (the dns-forward plist, tailnet Global NS, and the `hosts.cxmini` entry in `tailscale/policy.hujson`) must be reinstalled, re-pointed, or edited and pushed (`dotfiles tailscale policy-push`) after such a switch. `doctor`'s Tailnet section FAILs while `hosts.cxmini` differs from this node's IPv4. The cxagents node needs nothing, since everything reaches it by its MagicDNS name.

## Backups

- Per-stack `backup` recipes tar into `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz`. Quiesce behavior per stack:
  - **freshrss**, **homebridge**, **wallabag**: `down && up` quiesce (clean snapshots).
  - **connectome**: `compose stop && snapshot && compose start`. Also prunes `llm-calls.*.jsonl` older than 14 days and truncates `headless.log` to last 10 MiB when >50 MiB.
  - **onecli**: `compose stop && snapshot && compose start` (Postgres data is only consistent stopped).
  - connectome and onecli skip when their volumes are missing, start the stack again only if it was running (an intentionally stopped stack stays stopped), and never fail on the restart, so `backup-all` always reaches the later stacks and the rotation.
  - **adguard**: stays up (safe to tar live, no SQLite).
  - **cxagents**: not in `backup-all`. Its state volume (node keys, certificate cache) is disposable; losing it costs a re-login and a new certificate.
- `backup-rotate.sh` GFS-promotes daily → weekly (Sundays, kept 4) → monthly (1st of month, kept 3). `daily/` is capped at 7 per stack.
- The launchd **LaunchDaemon** installed by `dotfiles stacks backup-install` runs `dotfiles stacks backup-all` nightly at 04:00. It's a daemon, not an agent (see "Boot autostart" — this host has no GUI session for an agent to load into). Logs land in `~/.volume-backups/.log/{stdout,stderr}.log`. The plist Label is `com.cxreiff.dotfiles.backup`.
- `~/.volume-backups/` is gitignored runtime data; never commit a tarball. `~/.volume-backups/archive/` (outside GFS rotation, never pruned) holds one-off reference tarballs, e.g. `onecli-v1-final.tgz`.

## Boot autostart — why LaunchDaemons, not LaunchAgents

**This host is headless (administered over SSH) with FileVault on, so no
Aqua GUI login session ever exists.** That single fact drives the whole
autostart/backup design and is the #1 gotcha when something "doesn't start
after a reboot":

- **LaunchAgents (`~/Library/LaunchAgents`, `gui/$(id -u)` domain) never
  load here** — they only load when a user logs into the desktop GUI, which
  never happens. `launchctl bootstrap gui/$(id -u) …` fails with `125:
  Domain does not support specified action` even from your own SSH shell.
  (An earlier version of the backup timer was a LaunchAgent; it silently
  stopped firing the first time the box rebooted without a GUI login.)
- FileVault rules out the usual workaround (enable auto-login → GUI session
  → agents load): auto-login is unavailable while FileVault is on.
- Colima's `vz` VMs **do** start fine from a non-GUI context (they're
  started over SSH all the time), so a daemon-as-user works.

**Why keep FileVault (and not just disable it + auto-login, which is the
more common headless recipe):** the `onecli` credential vault stores its
`SECRET_ENCRYPTION_KEY` in `stacks/onecli/.env` on the Mac (0600, gitignored; the whole file
is escrowed in the password manager, since a restored vault also needs its `POSTGRES_PASSWORD`),
while the vault's ciphertext lives in the `onecli_pgdata` volume inside the `agents` VM disk
image. Both sit on this Mac's disk, as do the plaintext connectome state (chronicle, full-prompt
`llm-calls` logs) and its backup tarballs, and `tailscale/.env` (the non-expiring `dotfiles-admin`
OAuth client, which can rewrite the tailnet policy and DNS), so FileVault is the only at-rest
protection against a stolen or imaged disk. This is a deliberate choice (2026-06-02; with onecli v2, 2026-10-16,
the key moved from the vault's app-data volume to `.env`, which changes where it lives on the
disk, not the reliance on FileVault). Consequence: a reboot halts at the
FileVault unlock gate before any daemon runs. For planned remote reboots, unlock the next
boot over SSH first: `sudo fdesetup authrestart`. Only unplanned power loss needs a
physical/console unlock; after the unlock, the startup daemon fires normally.

So both autostart and backups are **LaunchDaemons** in the `system` domain
(`/Library/LaunchDaemons/`), loaded at system boot regardless of GUI login,
installed and managed entirely over SSH with `sudo launchctl`. Each sets
`UserName cxreiff` / `GroupName staff` so the process runs as the user
(uses `~/.colima`, the user's docker contexts, `~/.volumes`), not as root.

`dotfiles stacks startup-install` installs
`/Library/LaunchDaemons/com.cxreiff.dotfiles.startup.plist` (Label
`com.cxreiff.dotfiles.startup`, `RunAtLoad`). At boot it runs
`scripts/startup.sh`, which brings up all three VMs (`vm-shared-up`,
`vm-bridged-up`, `vm-agents-up`) then `up-all` — routed through the recipes,
not raw `colima`/`docker`. Logs:
`~/Library/Logs/com.cxreiff.dotfiles.startup.{out,err}.log`.

- `colima start -p bridged` is non-interactive because `/etc/sudoers.d/colima`
  grants `%staff` passwordless `socket_vmnet` (cxreiff is in `staff`).
- VM-start failures abort the script; an `up-all` failure only warns (e.g.
  `adguard up`'s tailnet-DNS hookup can race Tailscale at boot — re-run
  `up-all` or check `doctor`).
- The `*-install` recipes use `sudo` for the `/Library/LaunchDaemons` write
  and `launchctl bootstrap system`. Run them as your normal user over SSH;
  sudo prompts as needed.
- If autostart/backups stop after a reboot, check the daemon is loaded:
  `sudo launchctl print system/com.cxreiff.dotfiles.{startup,backup}`.
  Manually re-trigger without rebooting:
  `sudo launchctl kickstart -k system/com.cxreiff.dotfiles.startup`.
- The orphan `homebrew.mxcl.colima` LaunchAgent that `brew install colima`
  drops is deliberately **not** used — it runs `colima start -f` with no
  `-p`, spinning up an unmanaged `default` profile (and stealing the active
  Docker context, defeating `autoActivate: false`). It's renamed aside to
  `homebrew.mxcl.colima.plist.orphan-disabled`; keep it disabled/removed.
- The `homebrew.mxcl.socket_vmnet` LaunchDaemon is likewise deliberately
  **stopped** (2026-07-26). Colima launches its own socket_vmnet
  (`/opt/colima/bin`, bridged mode, via `/etc/sudoers.d/colima`); the brew
  service ran an unused *shared*-mode instance whose vmnet gateway pulled in
  InternetSharing/bootpd and bound mDNSResponder to wildcard `*:53`,
  colliding with the dns-forward relay's bind and answering DNS probes as an
  imposter whenever the relay was down (masked a dead relay for 7 weeks).
  `brew install socket_vmnet` (the binary) is still required — only the
  service must stay stopped. Do not `sudo brew services start socket_vmnet`.

## When editing

- Cross-cutting changes (ports, new stack, new package) usually touch a justfile **and** a README — keep them in sync; READMEs are operational, not decorative.
- Don't introduce manual `docker compose` / `tailscale serve` / `tailscale dns` invocations in docs or new recipes; route through the existing module structure.
- The `archive/` tree is frozen. If a config under `archive/.config/<tool>/` needs to become live, the move is into `stow/base/.config/<tool>/` plus a `restow` — not editing in place.
- After non-trivial changes, run `dotfiles stacks doctor` and fix any FAILs before declaring work complete. WARNs are informational (e.g., missing `.env` on a stack you don't run).
- Tailnet changes go through `tailscale/policy.hujson` and `dotfiles tailscale policy-push`, never the admin console (doctor flags console edits as drift).
- Tailscale credential key names are spelled only inside `tailscale/` (`tailscale/scripts/keyscan.sh` owns the list); every other script, doc and `.env.example` refers to `tailscale/.env` and calls `tailscale/scripts/api.sh` instead. Run `tailscale/scripts/keyscan.sh --repo` before committing; it must exit 0 (planning docs and `archive/` are exempt).
