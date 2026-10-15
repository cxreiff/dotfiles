#!/usr/bin/env bash
# stacks/onecli/scripts/init-env.sh
# Idempotently ensure stacks/onecli/.env holds the three onecli v2 secrets
# (SECRET_ENCRYPTION_KEY, BETTER_AUTH_SECRET, GATEWAY_INTERNAL_SECRET).
# Existing non-empty values are never changed. Values are never printed.
# Always leaves .env at mode 0600.
#
# Usage: init-env.sh            (operates on stacks/onecli/.env)
#        ONECLI_ENV_FILE=<path> init-env.sh   (alternate file; used by tests)
#
# Exit codes:
#   0 — .env complete (keys added or already present)
#   1 — existing SECRET_ENCRYPTION_KEY is malformed (not base64 of 32 bytes)
#   2 — missing prerequisite (openssl)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${ONECLI_ENV_FILE:-${SCRIPT_DIR}/../.env}"

command -v openssl >/dev/null || { echo "init-env: openssl not found" >&2; exit 2; }

umask 077
[ -f "$env_file" ] || : > "$env_file"
chmod 600 "$env_file"

# onecli base64-decodes SECRET_ENCRYPTION_KEY and requires exactly 32 bytes
# (packages/api/src/lib/crypto.ts loadKey; gateway crates/crypto KEY_LEN=32),
# so it is base64. The other two are opaque strings; hex is fine.
gen() {
    case "$1" in
        SECRET_ENCRYPTION_KEY) openssl rand -base64 32 ;;
        *) openssl rand -hex 32 ;;
    esac
}

added=()
for key in SECRET_ENCRYPTION_KEY BETTER_AUTH_SECRET GATEWAY_INTERNAL_SECRET POSTGRES_PASSWORD; do
    # For POSTGRES_PASSWORD, check if missing, empty, or equal to CHANGE_ME.
    if [ "$key" = POSTGRES_PASSWORD ]; then
        if grep -qE "^${key}=.+" "$env_file" && ! grep -qE "^${key}=\s*$|^${key}=CHANGE_ME" "$env_file"; then
            continue
        fi
    else
        if grep -qE "^${key}=.+" "$env_file"; then
            continue
        fi
    fi
    # Drop an empty `KEY=` line if present, then append a fresh value.
    tmp="$(mktemp "${env_file}.XXXXXX")"
    grep -vE "^${key}=" "$env_file" > "$tmp" || true
    printf '%s=%s\n' "$key" "$(gen "$key")" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$env_file"
    added+=("$key")
done

# Existing values are never rewritten — so refuse (don't silently keep) a
# SECRET_ENCRYPTION_KEY that does not decode to 32 bytes.
klen=$(grep -E '^SECRET_ENCRYPTION_KEY=' "$env_file" | head -1 | cut -d= -f2- | { base64 -d 2>/dev/null || true; } | wc -c | tr -d ' ')
if [ "$klen" != 32 ]; then
    echo "init-env: SECRET_ENCRYPTION_KEY in $(basename "$env_file") does not base64-decode to 32 bytes (got ${klen}); fix it by hand (never on a vault with data)" >&2
    exit 1
fi

if [ "${#added[@]}" -gt 0 ]; then
    echo "init-env: generated ${added[*]} in $(basename "$env_file") (values not shown)"
else
    echo "init-env: all onecli secrets already present; nothing changed"
fi
echo "init-env: REMINDER — escrow SECRET_ENCRYPTION_KEY from stacks/onecli/.env in your password manager." \
     "Without it, onecli backups cannot be decrypted."
