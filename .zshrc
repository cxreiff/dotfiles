# Lines configured by zsh-newuser-install
unsetopt beep
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/jaxreiff/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

alias zrc='vim ~/.zshrc'
alias vrc='vim ~/.vimrc'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

alias vim-plug-init='curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'

# helps putty render 256 colors
if [ "$TERM" = xterm ]; then TERM=xterm-256color; fi

export FZF_DEFAULT_COMMAND='rg --files --hidden --smart-case --glob "!.git/*"'

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    export PROMPT='%F{cyan}%n@cloud %f%1~ %# '
else
    export PROMPT='%F{magenta}%n@local %f%1~ %# '
fi

