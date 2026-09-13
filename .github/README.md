# dotfiles

Personal dotfiles and self-hosted service stacks for macOS, managed with
GNU Stow, `just`, and Docker Compose on Colima.

```
dotfiles/
├── archive/    legacy bare-repo dotfiles (frozen, unmanaged)
├── stacks/     Docker compose stacks — opt-in (see stacks/README.md)
├── stow/       Stow packages — symlinked into $HOME for tools that read fixed paths
├── docs/       migration-recovery and other operational references
└── justfile    root justfile (mod stacks, mod stow)
```

Setup is staged. Most devices only need Stage 1.

1. **Stage 1 — universal** ([`README.md`](../README.md)): editor + shell
   config via `dotfiles stow setup-base`.
2. **Stage 2 — container support** ([`stacks/README.md`](../stacks/README.md)):
   Colima VMs and the shared stack tooling, only on hosts that run stacks.
3. **Stage 3 — per-stack** (`stacks/<name>/README.md`): first-run steps for
   each stack you want.

Everything is driven through the `dotfiles` shell alias:

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```
