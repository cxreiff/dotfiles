mod stacks
mod stow
mod tailscale
mod tools

default:
    @just --list

# Bootstrap a new device's environment (packages, shell/editor config, tools; not Colima or stacks)
init: brew stow::setup-base tools::install

# Wrap brew bundle on the root Brewfile (e.g. `dotfiles brew check`, `dotfiles brew cleanup`)
brew *args:
    brew bundle {{args}} --file {{source_directory()}}/Brewfile
