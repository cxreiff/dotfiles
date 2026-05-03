# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo shape

Three independent areas, intentionally not unified:

- `bare/` — legacy bare-repo dotfiles. **Unmanaged, untouched.** Do not edit unless the user explicitly asks; nothing in the active workflow reads from here.
- `stow/` — GNU Stow packages, symlinked into `$HOME` for tools that read fixed paths.
- `stacks/` — Docker Compose stacks. **Not stowed** — invoked in place via `just`.

The `dotfiles` shell alias (defined in `stow/base/.zshrc`) is the entry point for everything:

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```

The root `justfile` only does `mod stacks` / `mod stow`; all real recipes live in `stacks/justfile`, `stow/justfile`, and per-stack `stacks/<name>/justfile`. Use `dotfiles` (or `just -f …`) rather than invoking `docker compose` / `stow` / `tailscale serve` by hand — the justfiles encode the right context, ports, and ordering.

## Common commands

```sh
dotfiles                          # list root recipes
dotfiles stow setup               # fresh-device: stow base + colima
dotfiles stow restow              # re-link after adding files to a package
dotfiles stow status              # dry-run; show what stow would do

dotfiles stacks vm-up             # start both Colima VMs (default + adguard)
dotfiles stacks up-all            # bring up all stacks
dotfiles stacks down-all          # DNS-aware shutdown order (apps before adguard)
dotfiles stacks ps-all            # status across stacks

dotfiles stacks <stack> up|down|restart|logs|ps|pull|shell
dotfiles stacks <stack> serve     # publish via Tailscale serve
```

Per-stack details: `stacks/<name>/README.md`. The `adguard` README documents a non-obvious wizard gotcha (must bind DNS to `col0`, not `eth0` or "All interfaces") — preserve that if editing.

## Two-VM Colima architecture

`stacks/` splits services across two Colima profiles:

| Profile | VM type | Networking | Holds |
|---|---|---|---|
| `default` | `vz` | vzNAT, Mac localhost forwards | `freshrss`, `wallabag`, future general services |
| `adguard` | `qemu` | bridged via `socket_vmnet`, real LAN IP | `adguardhome` only |

Why split: only `qemu + socket_vmnet bridged` preserves DNS source IPs on macOS Colima (`vz` doesn't support bridged networking). Putting everything bridged would force qemu emulation for all services and expose every port to the LAN. The split keeps native vz performance for everything that doesn't need source-IP visibility.

`adguard`'s justfile uses `docker --context colima-adguard`; `freshrss`'s and `wallabag`'s use `docker --context colima` (the default profile). Don't homogenize them.

## Stow package conventions

| Package | Folding | Why |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.zshrc` — folder symlinks fine |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/<profile>/` holds runtime state files; folder-level symlinking would suck them into the repo |

When adding a new package, edit every recipe in `stow/justfile` (`setup`, `restow`, `unstow`, `status`) — there's no loop. Use `--no-folding` if the target dir holds runtime state.

## Port and `.env` conventions

- **`serve_port`** — Tailscale-side HTTPS port (the URL users hit).
- **`internal_port`** — local app/forward port. Convention: `1` prefixed to `serve_port` (`8765` → `18765`, `8689` → `18689`).
- The justfile is the source of truth for these. When changing a stack's port, the README usually lists the other places that must change in lockstep (e.g., for `adguard`: `internal_port` in justfile **and** `address:` in `~/.volumes/adguard/conf/AdGuardHome.yaml`).
- `.env` is gitignored and kept `0600`; `.env.example` is the tracked template. The `.gitignore` allowlists `*.env.example` after blocking `*.env*` — keep that pattern intact.
- `tailscale` is invoked via the absolute path `/Applications/Tailscale.app/Contents/MacOS/Tailscale` inside justfiles (the Homebrew CLI shim isn't assumed). The user's `.zshrc` aliases `tailscale` to the same path for interactive use.

## When editing

- Cross-cutting changes (ports, new stack, new package) usually touch a justfile **and** a README — keep them in sync; READMEs are operational, not decorative.
- Don't introduce manual `docker compose` / `tailscale serve` invocations in docs or new recipes; route through the existing module structure.
- The `bare/` tree is frozen. If a config under `bare/.config/<tool>/` needs to become live, the move is into `stow/base/.config/<tool>/` plus a `restow` — not editing in place.
