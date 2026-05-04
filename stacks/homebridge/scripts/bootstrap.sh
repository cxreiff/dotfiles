#!/usr/bin/env bash
# stacks/homebridge/scripts/bootstrap.sh
# Complete the Config UI X setup wizard non-interactively, creating the
# admin user from ADMIN_* in .env. Fail-loudly: structured exit codes +
# recovery hints.
#
# Exit codes:
#   0 — success (bootstrap done, or wizard already complete idempotently)
#   1 — unexpected state (script can't safely proceed without human input)
#   2 — missing prerequisite (.env, env keys, jq, container, API)
#   3 — upstream API failure (Config UI X HTTP error)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${SCRIPT_DIR}/../.env"

# --- Preflight ---
if [ ! -f "$env_file" ]; then
    echo "homebridge bootstrap: ${env_file} missing" >&2
    echo "  recover: cp .env.example .env && chmod 600 .env && edit ADMIN_*" >&2
    exit 2
fi
set -a; source "$env_file"; set +a

for key in ADMIN_USERNAME ADMIN_PASSWORD INTERNAL_PORT PUBLIC_HOST PUBLIC_PORT; do
    if [ -z "${!key:-}" ]; then
        echo "homebridge bootstrap: ${key} not set in ${env_file}" >&2
        exit 2
    fi
done

if ! command -v jq >/dev/null 2>&1; then
    echo "homebridge bootstrap: jq not on PATH (brew install jq)" >&2
    exit 2
fi

vm_ip=$(colima list | awk '/^bridged[[:space:]]/ && $2 == "Running" {print $NF}')
if [ -z "$vm_ip" ]; then
    echo "homebridge bootstrap: bridged VM not running" >&2
    echo "  recover: dotfiles stacks vm-bridged" >&2
    exit 2
fi

base="http://${vm_ip}:${INTERNAL_PORT}"

# --- Wait for API ---
echo "Waiting for Homebridge UI at ${base} ..."
deadline=$(($(date +%s) + 180))
until curl -fs "${base}/api/auth/settings" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "homebridge bootstrap: UI did not become ready within 180s" >&2
        echo "  recover: dotfiles stacks homebridge logs" >&2
        exit 2
    fi
    sleep 2
done

# --- Read wizard state ---
settings=$(curl -fs "${base}/api/auth/settings")
wizard_done=$(echo "$settings" | jq -r '.env.setupWizardComplete')

# --- Idempotent already-bootstrapped path ---
if [ "$wizard_done" = "true" ]; then
    # AC5.9: but check that auth.json contains ADMIN_USERNAME — otherwise
    # we're in the partial-completion case where wizard ran but the user
    # we expected isn't there.
    auth_json="${HOME}/.volumes/homebridge/auth.json"
    if [ ! -f "$auth_json" ]; then
        cat >&2 <<EOF
homebridge bootstrap: detected setupWizardComplete=true but auth.json is
                      missing at ${auth_json}.
  recover: stop homebridge, restore from backup, or remove
           ~/.volumes/homebridge/auth.json + ~/.volumes/homebridge/.uix-secrets
           and re-run bootstrap (will re-trigger setup wizard).
EOF
        exit 1
    fi
    if ! jq -e --arg u "$ADMIN_USERNAME" 'any(.username == $u)' \
            "$auth_json" >/dev/null; then
        cat >&2 <<EOF
homebridge bootstrap: detected setupWizardComplete=true but auth.json
                      lacks user '${ADMIN_USERNAME}'.
  Existing users in auth.json:
$(jq -r 'map("    " + .username) | .[]' "$auth_json")
  recover: log in as one of the above and create '${ADMIN_USERNAME}' via
           the UI, OR remove ~/.volumes/homebridge/auth.json and
           ~/.volumes/homebridge/.uix-secrets and re-run bootstrap.
EOF
        exit 1
    fi
    echo "Setup wizard already complete and ${ADMIN_USERNAME} present — nothing to do."
    exit 0
fi

# --- Run the wizard ---
echo "Running setup wizard for user '${ADMIN_USERNAME}'..."
token_resp=$(curl -fsS "${base}/api/setup-wizard/get-setup-wizard-token" 2>&1) || {
    echo "homebridge bootstrap: setup-wizard token endpoint failed: ${token_resp}" >&2
    echo "  recover: investigate; check homebridge logs" >&2
    exit 3
}
token=$(echo "$token_resp" | jq -r '.access_token')
if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "homebridge bootstrap: empty access_token from setup-wizard endpoint" >&2
    echo "$token_resp" >&2
    exit 3
fi

create_resp=$(curl -fsS -X POST "${base}/api/setup-wizard/create-first-user" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" \
            '{username:$u, password:$p, name:$u, admin:true}')" 2>&1) || {
    echo "homebridge bootstrap: create-first-user endpoint failed: ${create_resp}" >&2
    exit 3
}

echo "Bootstrap complete. Log in at https://${PUBLIC_HOST}:${PUBLIC_PORT} as '${ADMIN_USERNAME}'."
exit 0
