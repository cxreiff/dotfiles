# dotfiles

```
dotfiles/
├── bare/        legacy bare-repo dotfiles (unmanaged, untouched)
├── stacks/      Docker compose stacks — invoked in place, not stowed
├── stow/        Stow packages — symlinked into $HOME for tools that read fixed paths
├── justfile     root justfile (mod stacks, mod stow)
└── .gitignore   secrets out, *.env.example in
```

Drive everything via the `dotfiles` shell alias (defined in
`stow/base/.zshrc`):

```sh
alias dotfiles="just -f ~/Developer/dotfiles/justfile"
```

## Recipe tree

```
dotfiles
├── stacks
│   ├── vm-default                   start default Colima VM
│   ├── vm-adguard                   start adguard Colima VM
│   ├── vm-up                        start both
│   ├── up-all                       bring up all stacks
│   ├── down-all                     bring down all (DNS-aware order)
│   ├── ps-all                       container status across stacks
│   ├── pull-all                     pull latest images for all stacks
│   ├── adguard
│   │   ├── init                     create ~/.volumes/adguard/{conf,work}
│   │   ├── up                       start container (depends on init)
│   │   ├── down, restart, logs, ps, pull, shell
│   │   ├── serve                    Tailscale serve at :8689 → AGH
│   │   └── advertise                Tailscale advertise VM IP as subnet route
│   └── freshrss
│       ├── up, down, restart, logs, ps, pull, shell
│       └── serve                    Tailscale serve at :8765 → FreshRSS
└── stow
    ├── setup                        stow base + colima
    ├── restow                       re-link after package changes
    ├── unstow                       remove all symlinks
    └── status                       dry-run, show what stow would do
```

## Fresh-device setup (high level)

```sh
git clone <this-repo> ~/Developer/dotfiles
cd ~/Developer/dotfiles

brew install colima socket_vmnet just stow
dotfiles stow setup
source ~/.zshrc                       # load `dotfiles` alias

dotfiles stacks vm-up                 # start both Colima VMs
dotfiles stacks up-all                # bring up all stacks
```

Per-area details:

- `stacks/README.md` — VM architecture and composite ops
- `stacks/adguard/README.md` — wizard, router, Tailscale steps
- `stacks/freshrss/README.md` — `.env` setup
- `stow/README.md` — package management

## Conventions

- **`serve_port`** — Tailscale-side HTTPS port (what users hit in browsers)
- **`internal_port`** — local app/forward port. Convention: `1` prefixed
  to `serve_port` (`8765` → `18765`, `8689` → `18689`)
- **`.env.example`** — committed template per stack; real `.env` is gitignored
  and `0600`
- **Justfile modules** drive everything; manual `docker compose` /
  `tailscale serve` calls should be rare
