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

# if [ "$TERM" = xterm ]; then TERM=xterm-256color; fi

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    export PROMPT='%F{cyan}%n@cloud %f%1~ %# '
else
    export PROMPT='%F{magenta}%n@local %f%1~ %# '
fi

### ALIASES

alias ls='ls -F'
alias vi='nvim'
alias ze='zellij'
alias zeh='zellij --layout default'
alias zrl='nvim ~/.zshrc.local && ~/.zshrc.local'
alias zrc='nvim ~/.zshrc && source ~/.zshrc'
alias grc='nvim ~/.config/ghostty/config'
alias arc='nvim ~/.config/alacritty/alacritty.toml'
alias src='nvim ~/.config/sway'
alias crc='nvim ~/.config/'
alias vrc='nvim ~/.vimrc'
alias jrc='nvim ~/.config/zellij/config.kdl'
alias nrc='nvim ~/.config/nvim/lua'
alias init='chmod u+x ~/.config/init.sh && ~/.config/init.sh'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias reset='tput reset'

alias sshag='eval `ssh-agent -s` && ssh-add ~/.ssh/github'

# alias we='watchexec --wrap-process=session --no-process-group --restart'
alias we='watchexec --clear --no-process-group --restart'
alias wer='we -e rs,toml,ron,wgsl'
alias kw='killall watchexec'

alias pnpx='pnpm exec'

alias note='nvim note_$(date +'%Y_%m_%d').txt'

alias dnew='doctl compute droplet create \
    --image debian-12-x64 \
    --size s-1vcpu-1gb-35gb-intel \
    --region sfo3 \
    --vpc-uuid d69e3d9a-5190-4737-8488-c4d623e43ab1 \
    --ssh-keys 41711859\
    --user-data-file ~/.config/dropletconfig.yaml \
    cloud'
alias dlist='doctl compute droplet list'
alias dsshr='doctl compute ssh cloud --ssh-key-path ~/.ssh/id_ed25519'
alias dinit='dsshr --ssh-command "cp -rf ~/.ssh/authorized_keys /home/cxreiff/.ssh/authorized_keys"'
alias dssh='doctl compute ssh cloud --ssh-key-path ~/.ssh/id_ed25519 --ssh-user cxreiff'
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


# ttysvr
#
# call with `svr [variant] [seconds]`
# e.g. `svr maze 1000` for maze screensaver after 1000 seconds.
#
svr() { TMOUT=$2; trap "ttysvr $1; zle reset-prompt" ALRM }
svr_off() { TMOUT=0 }
# ttysvr end

