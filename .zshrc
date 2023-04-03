# Lines configured by zsh-newuser-install
unsetopt beep
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/jaxreiff/.zshrc'

autoload -Uz compinit
compinit

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
# End of lines added by compinstall

alias zrc='nvim ~/.zshrc'
alias vrc='nvim ~/.vimrc'
alias nrc='nvim ~/.config/nvim/lua'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias init='chmod u+x ~/.config/init.sh && ~/.config/init.sh'

alias dev='ssh jaxreiff@143.244.208.149'

# helps putty render 256 colors
if [ "$TERM" = xterm ]; then TERM=xterm-256color; fi

export EDITOR=nvim
export LANG=en_US.UTF-8

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    export PROMPT='%F{cyan}%n@cloud %f%1~ %# '
else
    export PROMPT='%F{magenta}%n@local %f%1~ %# '
fi

if [[ $(uname) = "Darwin" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    alias wrk='cd ~/Documents'
    alias wcd='cd ~/Documents; cd'
elif [[ $(uname) = "Linux" ]]; then
    eval "$(/home/linuxbrew/bin/brew shellenv)"
fi

export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/.bin:$PATH"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# pnpm
export PNPM_HOME="/Users/jaxreiff/Library/pnpm"
export PATH="$PNPM_HOME:$PATH"
# pnpm end
#
