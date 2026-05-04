#!/usr/bin/env bash
# stacks/scripts/backup.sh
# Tar ~/.volumes/<stack>/ into ~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz.
# Quiesce, if needed, is the caller's responsibility (declared at justfile level).
#
# Usage: backup.sh <stack-name>
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: backup.sh <stack-name>" >&2
    exit 2
fi
stack="$1"

src="${HOME}/.volumes/${stack}"
if [ ! -d "$src" ] || [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    echo "backup.sh: ${src} missing or empty — nothing to back up" >&2
    exit 2
fi

dst_dir="${HOME}/.volume-backups/daily"
mkdir -p "$dst_dir"
dst="${dst_dir}/${stack}-$(date +%Y-%m-%d).tgz"

tar -C "${HOME}/.volumes" -czf "$dst" "$stack"
echo "$dst"
