
## command line prompt
#
# Layout:  <host> <directory> [<branch>] <caret>
# Below PROMPT_NARROW_COLS the caret moves to its own line and a blank line
# is printed before each prompt.

# --- colors -----------------------------------------------------------------
# Any %F{...} value works: a name (cyan), a 256-color index (208), or a
# truecolor hex (#800020, degraded to the nearest palette color if needed).
PROMPT_COLOR_HOST_LOCAL='#800020'   # hostname + caret on a local shell
PROMPT_COLOR_HOST_SSH='magenta'     # hostname + caret over ssh
PROMPT_COLOR_DIR='cyan'
PROMPT_COLOR_BRANCH='green'

# --- segment shapes ---------------------------------------------------------
PROMPT_HOST_TEXT='%m'               # zsh prompt escape for the hostname
PROMPT_DIR_TEXT='%~'                # zsh prompt escape for the directory
PROMPT_BRANCH_OPEN='['
PROMPT_BRANCH_CLOSE=']'
PROMPT_CARET='❯'
PROMPT_TRUNCATE='…'                 # shown where a long directory is cut
PROMPT_NARROW_COLS=80               # switch to the two-line layout below this
PROMPT_MIN_DIR_COLS=12              # drop branch/host to keep this much for the dir

# Pick the hostname/caret color once, based on how this shell was reached.
if [[ -n $SSH_CONNECTION || -n $SSH_TTY || -n $SSH_CLIENT ]]; then
  PROMPT_COLOR_HOST=$PROMPT_COLOR_HOST_SSH
else
  PROMPT_COLOR_HOST=$PROMPT_COLOR_HOST_LOCAL
fi

# --- layout -----------------------------------------------------------------
_prompt_narrow_p() { (( COLUMNS < PROMPT_NARROW_COLS )) }

# Build one layout into REPLY: $1 is 1 for the two-line (narrow) layout.
_prompt_layout() {
  # Colored segments. The branch only renders when psvar[1] is set.
  local host="%F{$PROMPT_COLOR_HOST}${PROMPT_HOST_TEXT}%f "
  local branch="%(1V. %F{$PROMPT_COLOR_BRANCH}${PROMPT_BRANCH_OPEN}%1v${PROMPT_BRANCH_CLOSE}%f.)"
  local caret=" %F{$PROMPT_COLOR_HOST}${PROMPT_CARET}%f "

  # Visible widths, used to decide what fits alongside the directory.
  local hostname=${(%):-$PROMPT_HOST_TEXT}
  local -i host_width=$(( ${(m)#hostname} + 1 ))
  local -i branch_width=0 reserve=4
  if (( $1 )); then
    caret=$'\n'"%F{$PROMPT_COLOR_HOST}${PROMPT_CARET}%f "
    reserve=1
  fi
  [[ -n ${psvar[1]} ]] && branch_width=$(( ${(m)#psvar[1]} + ${#PROMPT_BRANCH_OPEN} + ${#PROMPT_BRANCH_CLOSE} + 1 ))

  # Prioritize the directory when other details leave too few columns.
  if (( COLUMNS - host_width - branch_width - reserve < PROMPT_MIN_DIR_COLS )); then
    branch='' branch_width=0
  fi
  if (( COLUMNS - host_width - reserve < PROMPT_MIN_DIR_COLS )); then
    host=''
  fi
  (( reserve += branch_width ))

  # Reserve room for the first-line suffix and avoid wrapping at the margin.
  # %<< ends truncation so only the beginning of the directory is removed.
  local dir="%F{$PROMPT_COLOR_DIR}%-${reserve}<${PROMPT_TRUNCATE}<${PROMPT_DIR_TEXT}%<<%f"

  REPLY="${host}${dir}${branch}${caret}"
  (( COLUMNS < 3 )) && REPLY=${REPLY% }
  (( COLUMNS < 2 )) && REPLY=''
  return 0
}

# Build both layouts; PROMPT picks one each time it is expanded. zsh re-expands
# PROMPT itself on SIGWINCH before TRAPWINCH runs, so the line/two-line choice
# tracks COLUMNS even when a resize (e.g. herdr refitting a tab on focus) races
# the trap.
setopt prompt_subst
typeset -ga _prompt_layouts
PROMPT='${_prompt_layouts[COLUMNS < PROMPT_NARROW_COLS ? 2 : 1]}'

_set_prompt() {
  local REPLY
  _prompt_layout 0; _prompt_layouts[1]=$REPLY
  _prompt_layout 1; _prompt_layouts[2]=$REPLY
}

precmd() {
  psvar=()
  local b=$(git branch --show-current 2>/dev/null)
  [[ -n $b ]] && psvar[1]=$b
  _set_prompt
  _prompt_narrow_p && print
}

# Recompute the available directory width when the window is resized.
TRAPWINCH() { _set_prompt; zle && zle reset-prompt }
