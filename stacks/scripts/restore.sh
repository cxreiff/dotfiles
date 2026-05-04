#!/usr/bin/env bash
# stacks/scripts/restore.sh
# Extract a backup tarball back into ~/.volumes/<stack>/.
# Refuses non-empty destination unless --force is passed.
# Caller stops the stack first; this script does not touch container state.
#
# Usage: restore.sh <stack-name> <tarball-path> [--force]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: restore.sh <stack-name> <tarball-path> [--force]" >&2
    exit 2
fi
stack="$1"
tarball="$2"
force=""
if [ "${3:-}" = "--force" ]; then
    force=1
fi

if [ ! -f "$tarball" ]; then
    echo "restore.sh: tarball not found: ${tarball}" >&2
    exit 2
fi

dst="${HOME}/.volumes/${stack}"
if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ] && [ -z "$force" ]; then
    echo "restore.sh: ${dst} is not empty; pass --force to overwrite" >&2
    exit 1
fi

mkdir -p "${HOME}/.volumes"
tar -C "${HOME}/.volumes" -xzf "$tarball"
echo "Restored ${stack} from ${tarball}"
