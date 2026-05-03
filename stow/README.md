# stow

GNU Stow packages — config files that other tools read from fixed paths,
symlinked from the repo into `$HOME`.

## Packages

| Package | Folding | Targets |
|---|---|---|
| `base` | default (folder symlinks) | `~/.config/nvim`, `~/.config/zellij`, `~/.zshrc` |
| `colima` | `--no-folding` (file-level symlinks) | `~/.colima/default/colima.yaml`, `~/.colima/adguard/colima.yaml` |

`colima` uses `--no-folding` because the target directories
(`~/.colima/<profile>/`) hold runtime state files that mustn't end up
inside the dotfiles repo via folder symlinking.

## Fresh-device setup

```sh
dotfiles stow setup
```

Stows both packages into `$HOME` with the appropriate folding flags.

## After adding new files to a package

```sh
dotfiles stow restow
```

Idempotent — `stow -R` removes existing symlinks for the package, then
re-creates them based on current package contents. Run after dropping new
files into `stow/<package>/`.

## Adding a new package

1. Create the package directory: `mkdir -p stow/<name>`
2. Place files inside, mirroring `$HOME`-relative paths
   (e.g., `stow/<name>/.config/foo/bar.toml` → `~/.config/foo/bar.toml`)
3. Edit `stow/justfile` and add the package to each recipe's stow lines
   (use `--no-folding` if target dirs hold runtime state)
4. `dotfiles stow setup` (or `restow`)

## Other ops

| Recipe | Effect |
|---|---|
| `status` | dry-run: show what stow would do, no changes |
| `unstow` | remove all symlinks for both packages |
