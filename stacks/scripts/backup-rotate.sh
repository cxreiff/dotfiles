#!/usr/bin/env bash
# stacks/scripts/backup-rotate.sh
# GFS rotation for ~/.volume-backups/. Promotes Sunday → weekly, 1st of month
# → monthly; prunes daily=7, weekly=4, monthly=3 per stack by mtime.
# Idempotent — safe to re-run same day.
#
# Exit codes:
#   0 — rotation and pruning successful
#   other — mkdir, cp, find, stat, or rm failed (set -euo pipefail)
set -euo pipefail

backups="${HOME}/.volume-backups"
mkdir -p "${backups}/daily" "${backups}/weekly" "${backups}/monthly"

stacks=(adguard freshrss homebridge wallabag)
today_iso="$(date +%Y-%m-%d)"
dow="$(date +%u)"   # 1..7, 7 = Sunday
dom="$(date +%d)"   # 01..31

# --- Promote ---
for stack in "${stacks[@]}"; do
    today_tgz="${backups}/daily/${stack}-${today_iso}.tgz"
    [ -f "$today_tgz" ] || continue   # nothing to promote

    if [ "$dow" = "7" ]; then
        # cp -n: no-clobber. Same-day re-run: weekly already exists, skip.
        cp -n "$today_tgz" "${backups}/weekly/${stack}-${today_iso}.tgz" || true
    fi

    if [ "$dom" = "01" ]; then
        cp -n "$today_tgz" "${backups}/monthly/${stack}-${today_iso}.tgz" || true
    fi
done

# --- Prune (per stack, per tier, by mtime, keep N newest) ---
prune_tier() {
    local tier="$1" keep="$2"
    for stack in "${stacks[@]}"; do
        # List <stack>-*.tgz (NOT PRE-MIGRATION-*) sorted oldest→newest by mtime
        find "${backups}/${tier}" -maxdepth 1 -type f -name "${stack}-*.tgz" \
            -print0 2>/dev/null \
            | xargs -0 stat -f "%m %N" 2>/dev/null \
            | sort -n \
            | awk -v keep="$keep" '
                { files[NR] = $0; total = NR }
                END {
                    drop = total - keep
                    for (i = 1; i <= drop; i++) {
                        # strip leading mtime, print path only
                        sub(/^[0-9]+ /, "", files[i]); print files[i]
                    }
                }' \
            | while IFS= read -r f; do
                rm -f "$f"
            done
    done
}

prune_tier daily 7
prune_tier weekly 4
prune_tier monthly 3
