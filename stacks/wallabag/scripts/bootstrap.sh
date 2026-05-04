#!/usr/bin/env bash
# stacks/wallabag/scripts/bootstrap.sh
# Replace the hardcoded default `wallabag:wallabag` admin with credentials
# from .env. Fail-loudly: structured exit codes + recovery hints.
#
# Exit codes:
#   0 — success (bootstrap done, or already done idempotently)
#   1 — unexpected state (script can't safely proceed without human input)
#   2 — missing prerequisite (.env, env keys, container)
#   3 — upstream CLI failure (FOSUserBundle errored during operation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"
context="colima-shared"

# --- Preflight: .env + required keys ---
if [ ! -f "$env_file" ]; then
    echo "wallabag bootstrap: ${env_file} missing" >&2
    echo "  recover: cp .env.example .env && chmod 600 .env && edit ADMIN_*" >&2
    exit 2
fi
set -a; source "$env_file"; set +a

for key in ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD; do
    if [ -z "${!key:-}" ]; then
        echo "wallabag bootstrap: ${key} not set in ${env_file}" >&2
        echo "  recover: edit .env, set ${key}=..." >&2
        exit 2
    fi
done

# --- Preflight: container running ---
if ! docker --context "$context" compose ps --status running 2>/dev/null \
        | grep -q wallabag; then
    echo "wallabag bootstrap: wallabag container not running on ${context}" >&2
    echo "  recover: dotfiles stacks wallabag up" >&2
    exit 2
fi

# --- Wait for HTTP API ---
echo "Waiting for wallabag to respond..."
deadline=$(($(date +%s) + 180))
until docker --context "$context" compose exec -T wallabag \
        curl -fs --user-agent healthcheck http://localhost/api/info >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "wallabag bootstrap: API did not become ready within 180s" >&2
        echo "  recover: check 'dotfiles stacks wallabag logs'" >&2
        exit 2
    fi
    sleep 2
done

# --- Unexpected-state check (AC5.10) ---
# List users. Parse by columns: $1=username, $3=enabled (yes/no), $4=admin (yes/no)
# Try wallabag:user:list first (newer versions), fall back to fos:user:list
user_list=$(docker --context "$context" compose exec -T wallabag \
    bin/console wallabag:user:list --env=prod 2>/dev/null || \
    docker --context "$context" compose exec -T wallabag \
    bin/console fos:user:list --env=prod 2>/dev/null || true)

# Parse the table by column: username is $1, enabled status is $3.
# Skip header rows (lines with "---" or "username") and the [OK] summary line.
# Note: wallabag:user:list outputs a Symfony-style whitespace table; fos:user:list
# is one user per line with optional "(disabled)" suffix. Both formats are parsed below.
default_present_row=$(echo "$user_list" | awk '$1 == "wallabag" && $3 != "is" {print}' | head -1)
# Check if the "is enabled?" column ($3) contains exactly "yes" (case-sensitive, as wallabag outputs lowercase)
default_active=$(echo "$default_present_row" | awk '$3 == "yes" {print}' | head -1)
admin_present_row=$(echo "$user_list" | awk -v u="$ADMIN_USERNAME" '$1 == u && $3 != "is" {print}' | head -1)

# AC5.10: default wallabag user exists but is deactivated AND configured admin missing → fatal
if [ -n "$default_present_row" ] && [ -z "$default_active" ] && [ -z "$admin_present_row" ]; then
    cat >&2 <<EOF
wallabag bootstrap: detected default 'wallabag' user is deactivated AND
                    configured admin '${ADMIN_USERNAME}' does not exist.
                    No active user will exist if we proceed.

  recover: log into the container and reactivate the default wallabag user:
           docker --context ${context} compose exec wallabag bash
           <in container>
           bin/console wallabag:user:enable wallabag --env=prod
           (or on older versions: bin/console fos:user:activate wallabag)

           Then re-run bootstrap, or set ADMIN_USERNAME=wallabag in .env.
EOF
    exit 1
fi

# --- Create admin (idempotent) ---
echo "Creating admin user '${ADMIN_USERNAME}'..."
create_rc=0
create_out=$(docker --context "$context" compose exec -T wallabag \
    bin/console fos:user:create "$ADMIN_USERNAME" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
        --super-admin --env=prod -n 2>&1) || create_rc=$?

if [ "$create_rc" -ne 0 ]; then
    if echo "$create_out" | grep -qiE '(already in use|already exists|unique constraint|email_canonical)'; then
        echo "  user '${ADMIN_USERNAME}' already exists — skipping create"
    else
        echo "wallabag bootstrap: fos:user:create failed (exit ${create_rc})" >&2
        echo "$create_out" >&2
        echo "  recover: investigate above stderr; this is an upstream CLI failure" >&2
        exit 3
    fi
fi

# --- Deactivate default (idempotent, only if ADMIN_USERNAME != wallabag) ---
if [ "$ADMIN_USERNAME" != "wallabag" ]; then
    echo "Deactivating default 'wallabag' user..."
    deact_rc=0
    deact_out=$(docker --context "$context" compose exec -T wallabag \
        bin/console fos:user:deactivate wallabag --env=prod -n 2>&1) || deact_rc=$?
    if [ "$deact_rc" -ne 0 ]; then
        if echo "$deact_out" | grep -qiE '(already.*disabled|not found|does not exist)'; then
            echo "  default 'wallabag' user already deactivated or removed — skipping"
        else
            echo "wallabag bootstrap: fos:user:deactivate failed (exit ${deact_rc})" >&2
            echo "$deact_out" >&2
            exit 3
        fi
    fi
fi

echo "Bootstrap complete. Log in at https://${PUBLIC_HOST}:${PUBLIC_PORT} as '${ADMIN_USERNAME}'."
exit 0
