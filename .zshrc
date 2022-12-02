# Lines configured by zsh-newuser-install
unsetopt beep
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/jaxreiff/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

