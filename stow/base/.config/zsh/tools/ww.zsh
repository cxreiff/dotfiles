# ww
#
# call with `ww [path]` to cd into $CX_WORKSPACE, or a path inside it.
# e.g. `ww dotfiles/stow` goes to $CX_WORKSPACE/dotfiles/stow.
#
ww() { cd "$CX_WORKSPACE${1:+/$1}" }

_ww() { _path_files -W "$CX_WORKSPACE" -/ }
compdef _ww ww
