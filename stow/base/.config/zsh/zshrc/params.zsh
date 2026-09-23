
## per-OS parameters
#
# Env vars (prefixed CX_) that the rest of the zshrc scripts reference.
# Sourced first so everything after it can rely on them.

case $OSTYPE in
  darwin*)
    export CX_WORKSPACE="$HOME/Developer"
    ;;
  linux*)
    export CX_WORKSPACE="$HOME/code"
    ;;
esac
