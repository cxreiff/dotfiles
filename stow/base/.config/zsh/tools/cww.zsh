# cww [repo] — switch to a repository in $CX_WORKSPACE, cloning it if needed.
#
#   cww         go to $CX_WORKSPACE
#   cww <repo>  go to $CX_WORKSPACE/<repo>. The directory counts as a match
#               only if one of its remotes is also named <repo>, or if it has
#               no remotes (a local-only repository, named by its directory).
#               With no local match, HeartFlow/<repo> is cloned from GitHub
#               into $CX_WORKSPACE/<repo>.
#
# Inside herdr, the repository is opened as a workspace on its primary
# worktree and focused, or its open workspace is focused, instead of cd-ing
# the current shell.

cww() {
  emulate -L zsh
  setopt err_return no_unset pipe_fail

  local base=$CX_WORKSPACE org=HeartFlow

  if (( $# > 1 )); then
    print -u2 "usage: cww [repo]"
    return 2
  fi

  if (( $# == 0 )); then
    cd -- $base
    return
  fi

  local name=$1 dir=$base/$1
  if [[ $name == */* || $name == .* ]]; then
    print -u2 "cww: '$name' is not a repository name"
    return 2
  fi

  # Succeeds if a remote of the repository at $1 is named $2, or if it has no
  # remotes, since a local-only repository has no other name to check.
  _cww_remote_matches() {
    local remote url
    local -a remotes=(${(f)"$(git -C $1 remote)"})
    (( $#remotes )) || return 0
    for remote in $remotes; do
      url=$(git -C $1 remote get-url $remote) || continue
      url=${${url%/}%.git}
      [[ ${url##*[/:]} == $2 ]] && return 0
    done
    return 1
  }

  _cww_go() {
    local target=$1 id
    if [[ -n ${HERDR_ENV:-} ]] && (( $+commands[herdr] )); then
      id=$(herdr worktree list --cwd $target 2>/dev/null |
        jq -r '.result.worktrees[] | select(.is_linked_worktree | not) | .open_workspace_id // empty') || id=
      if [[ -n $id ]] && herdr workspace focus $id >/dev/null; then
        return 0
      fi
      if herdr worktree open --cwd $target --path $target --focus >/dev/null; then
        return 0
      fi
      print -u2 "cww: herdr could not open $target as a workspace; changing directory instead"
    fi
    cd -- $target
    if [[ -n ${ZELLIJ:-} ]]; then
      zellij action rename-tab ${target:t}
    fi
  }

  {
    if [[ -e $dir ]]; then
      if [[ ! -d $dir ]] || ! git -C $dir rev-parse --git-dir >/dev/null 2>&1; then
        print -u2 "cww: $dir exists but is not a git repository"
        return 1
      fi
      if [[ $(git -C $dir rev-parse --path-format=absolute --git-common-dir) != ${dir:A}/.git ]]; then
        print -u2 "cww: $dir is not a primary worktree"
        return 1
      fi
      if ! _cww_remote_matches $dir $name; then
        print -u2 "cww: $dir exists, but none of its remotes is named '$name':"
        git -C $dir remote -v | sed 's/^/  /' >&2
        return 1
      fi
      _cww_go $dir
      return
    fi

    local found
    if ! found=$(gh repo view $org/$name --json name --jq .name 2>/dev/null); then
      print -u2 "cww: no repository '$name' in $base, and $org/$name was not found on GitHub (or gh is not authenticated)"
      return 1
    fi
    if [[ $found != $name ]]; then
      print -u2 "cww: $org/$name resolves to $org/$found; run 'cww $found'"
      return 1
    fi

    gh repo clone $org/$name $dir
    _cww_go $dir
  } always {
    unfunction _cww_remote_matches _cww_go 2>/dev/null
  }
}

# Completes the git repositories in $CX_WORKSPACE.
_cww() {
  local expl
  local -a repos
  repos=($CX_WORKSPACE/*/.git(N:h:t))
  (( CURRENT == 2 )) && _wanted repos expl repo compadd -a repos
}
compdef _cww cww
