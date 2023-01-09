# Lines configured by zsh-newuser-install
unsetopt beep
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/jaxreiff/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

alias zrc='nvim ~/.zshrc'
alias vrc='nvim ~/.vimrc'
alias nrc='nvim ~/.config/nvim/lua'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

alias dev='ssh jaxreiff@143.244.208.149'

# helps putty render 256 colors
if [ "$TERM" = xterm ]; then TERM=xterm-256color; fi

export EDITOR=/home/linuxbrew/.linuxbrew/bin/nvim

export PATH="$HOME/.cargo/bin:$PATH"

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    export PROMPT='%F{cyan}%n@cloud %f%1~ %# '
else
    export PROMPT='%F{magenta}%n@local %f%1~ %# '
fi

# add homebrew bin to PATH
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

