#!/usr/bin/env bash
# stacks/connectome/scripts/init-env.sh
# Create/complete stacks/connectome/.env (mode 0600) without printing values:
#   - prompts (hidden input for the token) for Discord values if absent;
#   - generates WEBUI_PASS and SESSION_SERVER_TOKEN if absent;
#   - ALWAYS re-syncs HOST_ONECLI_TOKEN / SHELL_ONECLI_TOKEN from the onecli
#     API (agents connectome-host / connectome-shell), so a regenerated token
#     is picked up by re-running this.
# Env: CONNECTOME_ENV_FILE overrides the target (tests).
# Exit codes: 0 ok; 2 missing prereq; 3 onecli API failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../onecli/scripts/lib/api.sh
source "${SCRIPT_DIR}/../../onecli/scripts/lib/api.sh"
env_file="${CONNECTOME_ENV_FILE:-${SCRIPT_DIR}/../.env}"

umask 077
[ -f "$env_file" ] || : > "$env_file"
chmod 600 "$env_file"

has() { grep -qE "^$1=.+" "$env_file"; }
set_key() {  # set_key KEY VALUE — replaces any existing line; value never echoed
    local tmp; tmp=$(mktemp "${env_file}.XXXXXX")
    trap "rm -f '$tmp'" EXIT
    grep -vE "^$1=" "$env_file" > "$tmp" || true
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$env_file"
}
prompt() {  # prompt KEY "question" [hidden] [default]
    has "$1" && return 0
    local v
    if [ "${3:-}" = hidden ]; then read -r -s -p "$2: " v; echo; else read -r -p "$2${4:+ [$4]}: " v; fi
    v="${v:-${4:-}}"
    [ -n "$v" ] || { echo "init-env: $1 is required" >&2; exit 2; }
    set_key "$1" "$v"; echo "init-env: set $1"
}

prompt LLM_MODEL "Codex model id" "" "gpt-6-luna"
prompt DISCORD_TOKEN "Discord bot token (hidden)" hidden

# Validate and prompt for DISCORD_OPERATOR_ID with re-prompting on bad input
id_val() { grep -E "^$1=" "$env_file" | head -1 | cut -d= -f2-; }
validate_operator_id() {
    local pre_existing=! has DISCORD_OPERATOR_ID
    while true; do
        prompt DISCORD_OPERATOR_ID "Operator Discord user id (numeric: Developer Mode → Copy User ID; not your username)"
        if [[ "$(id_val DISCORD_OPERATOR_ID)" =~ ^[0-9]{17,20}$ ]]; then
            return 0
        fi
        if [ "$pre_existing" -eq 0 ]; then
            # Pre-existing bad value in .env; don't re-prompt, just error
            echo "init-env: DISCORD_OPERATOR_ID must be a numeric Discord user id, got '$(id_val DISCORD_OPERATOR_ID)'; fix it in .env" >&2
            exit 2
        fi
        # Re-prompt if the value came from this run's prompt
        echo "init-env: DISCORD_OPERATOR_ID must be a numeric Discord user id; please try again" >&2
        # Remove the bad value so prompt() will ask again
        grep -vE "^DISCORD_OPERATOR_ID=" "$env_file" > "$env_file.tmp"
        mv "$env_file.tmp" "$env_file"
    done
}

# Validate and prompt for DISCORD_GUILD_ID with re-prompting on bad input
validate_guild_id() {
    local pre_existing=! has DISCORD_GUILD_ID
    while true; do
        prompt DISCORD_GUILD_ID "Discord guild:channel whitelist (numeric ids, e.g. 1234…:5678…)"
        if [[ "$(id_val DISCORD_GUILD_ID)" =~ ^[0-9]{17,20}:[0-9]{17,20}(\+[0-9]{17,20})*$ ]]; then
            return 0
        fi
        if [ "$pre_existing" -eq 0 ]; then
            # Pre-existing bad value in .env; don't re-prompt, just error
            echo "init-env: DISCORD_GUILD_ID must be <guild id>:<channel id>[+<channel id>…], got '$(id_val DISCORD_GUILD_ID)'; fix it in .env" >&2
            exit 2
        fi
        # Re-prompt if the value came from this run's prompt
        echo "init-env: DISCORD_GUILD_ID must be <guild id>:<channel id>[+<channel id>…]; please try again" >&2
        # Remove the bad value so prompt() will ask again
        grep -vE "^DISCORD_GUILD_ID=" "$env_file" > "$env_file.tmp"
        mv "$env_file.tmp" "$env_file"
    done
}

validate_operator_id
validate_guild_id
has WEBUI_USER || { set_key WEBUI_USER operator; echo "init-env: set WEBUI_USER=operator"; }
has WEBUI_PASS || { set_key WEBUI_PASS "$(openssl rand -hex 32)"; echo "init-env: generated WEBUI_PASS"; }
has SESSION_SERVER_TOKEN || { set_key SESSION_SERVER_TOKEN "$(openssl rand -hex 32)"; echo "init-env: generated SESSION_SERVER_TOKEN"; }

for pair in HOST_ONECLI_TOKEN:connectome-host SHELL_ONECLI_TOKEN:connectome-shell; do
    key="${pair%%:*}"; ident="${pair#*:}"
    tok=$(agent_field "$ident" accessToken) || exit 3
    case "$tok" in aoc_*) ;; *) echo "init-env: no aoc_ token for agent ${ident} (run: dotfiles stacks onecli policy)" >&2; exit 3 ;; esac
    set_key "$key" "$tok"; unset tok
    echo "init-env: synced ${key} from onecli agent ${ident}"
done
echo "init-env: done ($(basename "$env_file") mode $(stat -f %Lp "$env_file"))"
