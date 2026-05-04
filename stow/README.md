# stow

GNU Stow packages — config files that other tools read from fixed paths,
symlinked from the repo into `$HOME`.

## Packages

| Package | Folding | Targets |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.config/zsh/completions`, `~/.zshrc` |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/shared/colima.yaml`, `~/.colima/bridged/colima.yaml` |

`colima` uses `--no-folding` because the target directories
(`~/.colima/<profile>/`) hold runtime state files that mustn't end up
inside the dotfiles repo via folder symlinking.

## Setup

| Audience | Command |
|---|---|
| Editor + shell only (most users) | `dotfiles stow setup-base` |
| Adding container support (a few devices) | `dotfiles stow setup-colima` |
| Both at once (legacy / opinionated) | `dotfiles stow setup` |

The `setup` aggregate is unchanged — it stows both packages. The
per-package variants are for cases where a device only wants one.

## Other ops

| Recipe (aggregate) | Per-package equivalents | Effect |
|---|---|---|
| `restow` | `restow-base`, `restow-colima` | re-link after adding files to a package |
| `unstow` | `unstow-base`, `unstow-colima` | remove symlinks |
| `status` | `status-base`, `status-colima` | dry-run; show what stow would do |

## Adding a new package

1. Create the package directory: `mkdir -p stow/<name>`
2. Place files inside, mirroring `$HOME`-relative paths
   (e.g., `stow/<name>/.config/foo/bar.toml` → `~/.config/foo/bar.toml`)
3. Edit `stow/justfile`: add the package to each aggregate recipe AND add
   per-package `<verb>-<name>` recipes (mirror the existing pattern). There
   is no loop — every recipe lists each package explicitly.
   Use `--no-folding` if target dirs hold runtime state.
4. `dotfiles stow setup-<name>` (or `setup` to stow everything).
