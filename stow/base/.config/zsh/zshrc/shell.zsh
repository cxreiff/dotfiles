
export LANG=en_US.UTF-8

export COLORTERM=truecolor
export EDITOR=nvim
export VISUAL=nvim


unsetopt beep
bindkey -e
bindkey "^[[1;2D" backward-word
bindkey "^[[1;2C" forward-word

# history

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory

# completions

fpath=("$HOME/.config/zsh/completions" $fpath)
autoload -Uz compinit && compinit
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

# path

[[ -d /opt/homebrew/bin ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
[[ -d /home/linuxbrew/.linuxbrew/bin ]] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
[[ -d /home/linuxbrew/bin ]] && eval "$(/home/linuxbrew/bin/brew shellenv)"

export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/.bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"

export LS_COLORS="$(vivid generate molokai)"

# tool setup

## fnm
eval "$(fnm env --use-on-cd --shell zsh)"

## pnpm
export PNPM_HOME="/Users/cxreiff/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

## bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

## aws
export AWS_DEFAULT_PROFILE=cxreiff

