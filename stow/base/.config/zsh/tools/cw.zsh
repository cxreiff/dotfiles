# cw [slug] — switch to a git worktree, creating the branch and worktree if needed.
#
#   cw          go to the repository's primary worktree
#   cw <slug>   go to the worktree for branch $USER/<slug> (or <slug>),
#               creating <root>/.worktrees/<dir> if it has none, where <dir>
#               is <slug> with each "/" replaced by "+". A leading $USER/ in
#               <slug> is ignored. A branch that exists only on a remote gets
#               a local tracking branch. If no branch matches, $USER/<slug> is
#               created from HEAD.
#
# cw stops with an error, without changing anything, if <dir> is already used
# by another worktree or file, if the worktree that has the branch checked out
# is missing from disk, or if the new local branch name is not valid or
# conflicts with an existing branch.
#
# Inside herdr, the worktree is opened as a workspace grouped under the
# repository's workspace and focused, instead of cd-ing the current shell.

cw() {
  emulate -L zsh
  setopt err_return no_unset pipe_fail

  if (( $# > 1 )); then
    print -u2 "usage: cw [slug]"
    return 2
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    print -u2 "cw: not inside a git repository"
    return 1
  fi

  local porcelain root
  porcelain=$(git worktree list --porcelain)
  root=${${(f)porcelain}[1]#worktree }

  local -a lines
  lines=(${(f)porcelain})

  # Prints the path of the worktree that has refs/heads/$1 checked out, if any.
  _cw_worktree_for_branch() {
    local line wt=
    for line in $lines; do
      case $line in
        worktree\ *) wt=${line#worktree } ;;
        "branch refs/heads/$1") print -r -- $wt; return 0 ;;
      esac
    done
    return 1
  }

  # Prints what the worktree registered at path $1 has checked out, if one is
  # registered there.
  _cw_worktree_at() {
    local line here=0
    for line in $lines; do
      case $line in
        worktree\ *)
          here=0
          if [[ ${${line#worktree }:A} == ${1:A} ]]; then
            here=1
          fi
          ;;
        branch\ refs/heads/*)
          if (( here )); then
            print -r -- "branch '${line#branch refs/heads/}'"
            return 0
          fi
          ;;
        detached)
          if (( here )); then
            print -r -- "a detached HEAD"
            return 0
          fi
          ;;
      esac
    done
    return 1
  }

  # Fails with a message if a new local branch named $1 cannot be created
  # because an existing branch is a prefix of it, or it is a prefix of one.
  _cw_check_new_branch() {
    local branch=$1 prefix=$1
    while [[ $prefix == */* ]]; do
      prefix=${prefix%/*}
      if git show-ref --verify --quiet "refs/heads/$prefix"; then
        print -u2 "cw: cannot create branch '$branch' because branch '$prefix' exists"
        return 1
      fi
    done
    if [[ -n $(git for-each-ref --count=1 --format='%(refname)' "refs/heads/$branch/") ]]; then
      print -u2 "cw: cannot create branch '$branch' because branches under '$branch/' exist"
      return 1
    fi
  }

  _cw_go() {
    local target=$1
    if [[ -n ${HERDR_ENV:-} ]] && (( $+commands[herdr] )); then
      if herdr worktree open --cwd $root --path $target --focus >/dev/null; then
        return 0
      fi
      print -u2 "cw: herdr could not open $target as a workspace; changing directory instead"
    fi
    cd -- $target
    if [[ -n ${ZELLIJ:-} ]]; then
      zellij action rename-tab ${target:t}
    fi
  }

  {
    if (( $# == 0 )); then
      _cw_go $root
      return
    fi

    local slug=${1#$USER/}
    if [[ -z $slug || $slug == -* ]] || ! git check-ref-format --branch "$USER/$slug" >/dev/null 2>&1; then
      print -u2 "cw: '$1' is not a valid branch name"
      return 2
    fi

    local branch= upstream= candidate remote wt what dest=$root/.worktrees/${slug//\//+}
    local -a remotes
    remotes=(${(f)"$(git remote)"})
    # Check origin before any other remote.
    remotes=(${(M)remotes:#origin} ${remotes:#origin})

    for candidate in "$USER/$slug" "$slug"; do
      if git show-ref --verify --quiet "refs/heads/$candidate"; then
        branch=$candidate
        break
      fi
      for remote in $remotes; do
        if git show-ref --verify --quiet "refs/remotes/$remote/$candidate"; then
          branch=$candidate upstream=$remote/$candidate
          break 2
        fi
      done
    done

    local create=0
    if [[ -z $branch ]]; then
      branch="$USER/$slug" create=1
    fi

    if [[ -z $upstream ]] && (( ! create )) && wt=$(_cw_worktree_for_branch $branch); then
      if [[ ! -d $wt ]]; then
        print -u2 "cw: branch '$branch' is checked out in $wt, which is missing; if it was deleted, run 'git worktree prune'"
        return 1
      fi
      _cw_go $wt
      return
    fi

    if what=$(_cw_worktree_at $dest); then
      if [[ -e $dest ]]; then
        print -u2 "cw: $dest is already the worktree for $what, not for branch '$branch'"
      else
        print -u2 "cw: $dest is registered as the worktree for $what, but is missing; if it was deleted, run 'git worktree prune'"
      fi
      return 1
    fi
    if [[ -e $dest || -L $dest ]]; then
      print -u2 "cw: $dest exists but is not a worktree; move or remove it first"
      return 1
    fi

    if [[ -n $upstream ]] || (( create )); then
      _cw_check_new_branch $branch || return 1
    fi

    if [[ -n $upstream ]]; then
      git worktree add --track -b $branch -- $dest $upstream
    elif (( create )); then
      git worktree add -b $branch -- $dest HEAD
    else
      git worktree add -- $dest $branch
    fi

    _cw_go $dest
  } always {
    unfunction _cw_worktree_for_branch _cw_worktree_at _cw_check_new_branch _cw_go 2>/dev/null
  }
}

# Completes local and remote branch names as cw slugs, without the remote
# name or the $USER/ prefix.
_cw() {
  local expl
  local -a refs slugs
  refs=(${(f)"$(git for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null)"})

  local ref name
  for ref in $refs; do
    case $ref in
      refs/heads/*) name=${ref#refs/heads/} ;;
      refs/remotes/*/HEAD) continue ;;
      refs/remotes/*) name=${${ref#refs/remotes/}#*/} ;;
    esac
    slugs+=(${name#$USER/})
  done

  slugs=(${(u)slugs})
  (( CURRENT == 2 )) && _wanted slugs expl slug compadd -a slugs
}
compdef _cw cw
