typeset -g _CW_PREV_WORKTREE=""

cw() {
  local create_branch=false
  if [[ "$1" == "-b" ]]; then
    create_branch=true
    shift
  fi

  # No argument: cd to root of current worktree
  if [[ -z "$1" ]]; then
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "cw: not in a git repo" >&2; return 1; }
    cd "$root"
    if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
      zellij action rename-tab "$(git branch --show-current 2>/dev/null || basename "$root")"
    fi
    return
  fi

  git rev-parse --git-common-dir &>/dev/null || { echo "cw: not in a git repo" >&2; return 1; }

  # "~": cd to main repo root
  if [[ "$1" == "~" ]]; then
    local git_common_dir main_root
    git_common_dir="$(git rev-parse --git-common-dir)"
    main_root="$(cd "$git_common_dir/.." && pwd)"
    _CW_PREV_WORKTREE="$(git rev-parse --show-toplevel)"
    cd "$main_root"
    if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
      zellij action rename-tab "$(git -C "$main_root" branch --show-current 2>/dev/null || basename "$main_root")"
    fi
    return
  fi

  # "-": switch to previous worktree
  if [[ "$1" == "-" ]]; then
    if [[ -z "$_CW_PREV_WORKTREE" ]]; then
      echo "cw: no previous worktree" >&2
      return 1
    fi
    local prev="$_CW_PREV_WORKTREE"
    _CW_PREV_WORKTREE="$(git rev-parse --show-toplevel)"
    cd "$prev"
    if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
      zellij action rename-tab "$(git branch --show-current 2>/dev/null || basename "$prev")"
    fi
    return
  fi

  local branch="$1"

  # Check if worktree already exists for this branch
  local target
  target=$(git worktree list --porcelain | awk -v b="$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch /   { ref = substr($0, 8); sub("refs/heads/", "", ref); if (ref == b) print path }
  ')

  # Create worktree if it doesn't exist
  if [[ -z "$target" ]]; then
    local git_common_dir main_root dir_name
    git_common_dir="$(git rev-parse --git-common-dir)"
    main_root="$(cd "$git_common_dir/.." && pwd)"
    dir_name="${branch//\//_}"
    target="$main_root/.worktrees/$dir_name"

    if $create_branch; then
      git worktree add -b "$branch" "$target" || return 1
    else
      git worktree add "$target" "$branch" || return 1
    fi
  fi

  _CW_PREV_WORKTREE="$(git rev-parse --show-toplevel)"
  cd "$target"
  if [[ -n "$ZELLIJ_SESSION_NAME" ]]; then
    zellij action rename-tab "$branch"
  fi
}

_cw() {
  git rev-parse --git-common-dir &>/dev/null || return
  local branches
  branches=(${(f)"$(git branch --format='%(refname:short)' 2>/dev/null)"})
  _describe 'branch' branches
}
compdef _cw cw
