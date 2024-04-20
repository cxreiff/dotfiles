### OPTIONS

unsetopt beep
bindkey -e

zstyle :compinstall filename "$HOME/.zshrc"
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory

export EDITOR=nvim
export LANG=en_US.UTF-8

if [ "$TERM" = xterm ]; then TERM=xterm-256color; fi

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    export PROMPT='%F{cyan}%n@cloud %f%1~ %# '
else
    export PROMPT='%F{magenta}%n@local %f%1~ %# '
fi

### ALIASES

alias vi='nvim'
alias zrl='nvim ~/.zshrc.local && ~/.zshrc.local'
alias zrc='nvim ~/.zshrc && source ~/.zshrc'
alias crc='nvim ~/.config/'
alias vrc='nvim ~/.vimrc'
alias nrc='nvim ~/.config/nvim/lua'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias init='chmod u+x ~/.config/init.sh && ~/.config/init.sh'

alias pnpx='pnpm exec'

alias dnew='doctl compute droplet create \
    --image debian-12-x64 \
    --size s-1vcpu-512mb-10gb \
    --region sfo3 \
    --vpc-uuid d69e3d9a-5190-4737-8488-c4d623e43ab1 \
    --ssh-keys 41711859\
    cloud'
alias dlist='doctl compute droplet list'
alias dssh='doctl compute ssh cloud --ssh-key-path ~/.ssh/id_ed25519'
alias dsshx='dssh --ssh-command'
alias dinit='dsshx "\
    curl -Lks https://raw.githubusercontent.com/cxreiff/dotfiles/main/.config/init.sh | /bin/bash\
    "'
alias dkill='doctl compute droplet delete cloud'

if [[ $(uname) = "Darwin" ]]; then
    alias wrk='cd ~/Developer'
fi

### PATH

[[ -d /opt/homebrew/bin ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
[[ -d /home/linuxbrew/.linuxbrew/bin ]] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
[[ -d /home/linuxbrew/bin ]] && eval "$(/home/linuxbrew/bin/brew shellenv)"

export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/.bin:$PATH"

export PNPM_HOME="$HOME/Library/pnpm"
export PATH="$PNPM_HOME:$PATH"

### LOCAL

[[ -f $HOME/.zshrc.local ]] && source $HOME/.zshrc.local 


# pnpm
export PNPM_HOME="/Users/cxreiff/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end
