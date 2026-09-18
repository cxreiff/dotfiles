
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

_set_prompt() {
  # Colored segments. The branch only renders when psvar[1] is set.
  local host="%F{$PROMPT_COLOR_HOST}${PROMPT_HOST_TEXT}%f "
  local branch="%(1V. %F{$PROMPT_COLOR_BRANCH}${PROMPT_BRANCH_OPEN}%1v${PROMPT_BRANCH_CLOSE}%f.)"
  local caret=" %F{$PROMPT_COLOR_HOST}${PROMPT_CARET}%f "

  # Visible widths, used to decide what fits alongside the directory.
  local hostname=${(%):-$PROMPT_HOST_TEXT}
  local -i host_width=$(( ${(m)#hostname} + 1 ))
  local -i branch_width=0 reserve=4
  if _prompt_narrow_p; then
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

  PROMPT="${host}${dir}${branch}${caret}"
  (( COLUMNS < 3 )) && PROMPT=${PROMPT% }
  (( COLUMNS < 2 )) && PROMPT=''
  return 0
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
