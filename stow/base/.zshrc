
# env

export COLORTERM=truecolor
export EDITOR=nvim
export VISUAL=nvim

## command line prompt
# PROMPT='%F{208}%n@mini%f %F{cyan}%~%f%(1V. %F{magenta}[%1v]%f.) %F{208}❯%f '
PROMPT=$'\n%F{cyan}%~%f%(1V. %F{magenta}[%1v]%f.)\n%F{208}%n@mini%f %F{208}❯%f '
precmd() { psvar=(); local b=$(git branch --show-current 2>/dev/null); [[ -n $b ]] && psvar[1]=$b; }

export PATH="$HOME/.local/bin:$PATH"

# aliases

alias ls='ls -a'

alias vi='nvim'
alias zrc='vi ~/.zshrc && source ~/.zshrc'
alias wrk='cd ~/Developer'
alias dotfiles="just -f ~/Developer/dotfiles/justfile"

alias zz='zellij'

alias cc='claude'
alias cx='claude --dangerously-skip-permissions'

alias suk='security unlock-keychain'
alias adg='sudo /Applications/AdGuardHome/AdGuardHome -s'
alias tailscale='/Applications/Tailscale.app/Contents/MacOS/Tailscale'

# completions
autoload -Uz compinit && compinit

# scripts
source "$HOME/.config/scripts/cw.zsh"

# tool setup

## fnm
eval "$(fnm env --use-on-cd --shell zsh)"

# pnpm
export PNPM_HOME="/Users/cxreiff/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

