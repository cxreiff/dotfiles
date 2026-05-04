# dotfiles

```
dotfiles/
├── bare/        legacy bare-repo dotfiles (unmanaged, untouched)
├── stacks/     Docker compose stacks — opt-in (see stacks/README.md)
├── stow/       Stow packages — symlinked into $HOME for tools that read fixed paths
├── docs/       migration-recovery and other operational references
├── justfile    root justfile (mod stacks, mod stow)
└── .gitignore  secrets out, *.env.example in
```

Drive everything via the `dotfiles` shell alias (defined in
`stow/base/.zshrc`):

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```

## Stage 1 — universal setup (every device)

Editor + shell config. This is the only stage most devices need.

```sh
brew install just stow neovim zellij zsh-completions   # base tools
git clone <this-repo> ~/Developer/dotfiles
cd ~/Developer/dotfiles

dotfiles stow setup-base                               # stow base only
source ~/.zshrc                                        # load `dotfiles` alias
```

After Stage 1, your editor + shell config + the `dotfiles` alias are in
place. Most devices stop here.

## Stage 2 — opt-in container support (a few devices)

Only on devices where you want to run the Docker compose stacks (a Mac
mini that hosts AdGuard / FreshRSS / Homebridge / Wallabag, for example).

See **`stacks/README.md`** for the complete Stage 2 walkthrough, including:
- The container-side brew package set
- `dotfiles stow setup-colima` (the per-stack-VM stow piece)
- Starting both Colima VMs
- Per-stack first-run details

## Stage 3 — per-stack setup (only stacks you want)

For each stack you want to run on a Stage-2 device, follow that stack's
README:
- `stacks/adguard/README.md`
- `stacks/freshrss/README.md`
- `stacks/homebridge/README.md`
- `stacks/wallabag/README.md`

## Common ops

```sh
dotfiles                        # list root recipes
dotfiles stow restow-base       # re-link after adding files to base
dotfiles stow status            # dry-run for both packages
dotfiles stow status-base       # dry-run for just base
```

## Conventions (Stage 1)

- Stow packages: `base` uses default folding (folder symlinks); other
  packages may need `--no-folding` if their target dir holds runtime
  state. See `stow/README.md`.
- The `bare/` tree is frozen legacy. Nothing in the active workflow reads
  from it.
