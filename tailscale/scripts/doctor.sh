#!/bin/bash
# tailscale/scripts/doctor.sh — read-only checks of the declared tailnet state.
# Called by stacks/scripts/doctor.sh (--- Tailnet ---), which re-emits its lines.
# Prints only [OK]/[FAIL]/[WARN]/[OFF] lines (stacks/scripts/lib/check.sh), each
# prefixed "tailnet: ". Never reads a .env value (key names only) and never
# writes the tailnet (GETs and token exchanges only).
# Exit: 0 no FAIL; 1 any FAIL. The caller treats the exit status as informational.
#
# Fixture overrides (tailscale/scripts/doctor-test.sh):
#   TAILSCALE_ENV_FILE       credentials file (default tailscale/.env; api.sh reads it too)
#   TAILSCALE_POLICY_FILE    policy file (default tailscale/policy.hujson)
#   TAILSCALE_CLIENTS_CONF   expected OAuth clients (default tailscale/clients.conf)
#   TAILSCALE_TAILNET_CONF   identity (lib/conf.sh)
#   TAILSCALE_STATUS_JSON    file used instead of `tailscale status --json`
#   TAILSCALE_LOCK_STATUS    file used instead of `tailscale lock status`
#   DOCTOR_ENV_FILES         space-separated list instead of tailscale/.env + stacks/*/.env
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${ts_root}/.." && pwd)"
# shellcheck source=../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"
# shellcheck source=lib/conf.sh
source "${SCRIPT_DIR}/lib/conf.sh"          # TAILNET, TAILNET_DNS_SUFFIX

TAILSCALE="/opt/homebrew/bin/tailscale"
api="${SCRIPT_DIR}/api.sh"
policy_sh="${SCRIPT_DIR}/policy.sh"
lint_sh="${SCRIPT_DIR}/lint.sh"
keyscan_sh="${SCRIPT_DIR}/keyscan.sh"
env_file="${TAILSCALE_ENV_FILE:-${ts_root}/.env}"
policy_file="${TAILSCALE_POLICY_FILE:-${ts_root}/policy.hujson}"
clients_conf="${TAILSCALE_CLIENTS_CONF:-${ts_root}/clients.conf}"
api_ok=1

# 1. Credentials file: presence, mode, git-ignored, key names
if [ ! -f "$env_file" ]; then
    warn "tailnet: tailscale/.env missing — API checks skipped (restore from escrow; tailscale/README.md)"
    api_ok=0
else
    mode="$(stat -L -f %Lp "$env_file" 2>/dev/null)"
    if [ "$mode" = 600 ]; then
        pass "tailnet: tailscale/.env mode 600"
    else
        fail "tailnet: tailscale/.env mode ${mode:-unknown} (chmod 600)"
    fi
    if git -C "$repo_root" check-ignore -q tailscale/.env; then
        pass "tailnet: tailscale/.env is git-ignored"
    else
        fail "tailnet: tailscale/.env is not git-ignored"
    fi
    missing=""
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        grep -qE "^${key}=" "$env_file" || missing="${missing} ${key}"
    done < <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "${ts_root}/.env.example")
    missing="${missing# }"
    if [ -n "$missing" ]; then
        fail "tailnet: tailscale/.env missing keys: ${missing}"
        api_ok=0
    else
        pass "tailnet: tailscale/.env has every key in .env.example"
    fi
    if grep -qE '^TS_OAUTH_CLIENT_' "$env_file"; then
        fail "tailnet: tailscale/.env has deprecated TS_OAUTH_CLIENT_* keys (rename; see api.sh)"
        api_ok=0
    fi
fi

# 2. Policy drift: repo bytes vs live ETag (read-only GET)
if [ "$api_ok" -eq 1 ]; then
    out="$("$policy_sh" --file "$policy_file" status 2>/dev/null)"; rc=$?
    case "$rc" in
        0)
            if [ "$out" = in-sync ]; then
                pass "tailnet: policy in-sync (sha256 = live ETag)"
            else
                warn "tailnet: policy status unexpected output (rc 0)"
            fi ;;
        1)
            if [ "$out" = drift ]; then
                fail "tailnet: live policy differs from tailscale/policy.hujson (admin-console edit? run: dotfiles tailscale policy-diff)"
            else
                warn "tailnet: policy status unavailable (rc 1, unexpected output)"
            fi ;;
        2|3) warn "tailnet: policy status unavailable (API unreachable or credentials invalid)" ;;
        *)   warn "tailnet: policy status unavailable (rc ${rc})" ;;
    esac
fi

# 3. OAuth clients: granted scopes and tags (exact sets, one fresh token exchange each)
if [ "$api_ok" -eq 1 ]; then
    if [ ! -f "$clients_conf" ]; then
        fail "tailnet: clients.conf missing (tailscale/clients.conf declares the expected clients)"
    else
        nclients=0
        while read -r name rest; do
            case "$name" in ""|\#*) continue ;; esac
            nclients=$((nclients + 1))
            # scopes = every field but the last; the last field is the tags column.
            # Split on any whitespace (spaces or tabs). Length checks only: under
            # set -u, bash 3.2 rejects expanding an empty array.
            fields=()
            read -r -a fields <<<"$rest" || true
            nfields=${#fields[@]}
            scopes=""
            i=0
            while [ "$i" -lt $((nfields - 1)) ]; do
                scopes="${scopes} ${fields[$i]}"
                i=$((i + 1))
            done
            want="$(tr -s ' \t' '\n' <<<"$scopes" | sed '/^$/d' | sort -u)"
            if [ -z "$want" ]; then
                fail "tailnet: client ${name}: clients.conf row declares no scopes"
                continue
            fi
            # one exchange: `scope<TAB>tags` (api.sh --granted). The tags column
            # is the declared tags as the tailnet reports them; `-` = none.
            granted="$("$api" --client "$name" --granted 2>/dev/null </dev/null)"; rc=$?
            case "$rc" in
                0) ;;
                2) fail "tailnet: client ${name}: credentials missing in tailscale/.env"; continue ;;
                3) warn "tailnet: client ${name}: token exchange failed (API unreachable?)"; continue ;;
                *) warn "tailnet: client ${name}: scope check unavailable (rc ${rc})"; continue ;;
            esac
            case "$granted" in
                *$'\t'*) ;;
                *) warn "tailnet: client ${name}: token exchange output unrecognised"; continue ;;
            esac
            granted_scopes="${granted%%$'\t'*}"
            granted_tags="${granted#*$'\t'}"
            got="$(tr -s ' \t' '\n' <<<"$granted_scopes" | sed '/^$/d' | sort -u)"
            if [ -z "$got" ]; then
                warn "tailnet: client ${name}: token exchange returned no scopes"
                continue
            fi
            extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ' | sed 's/ *$//')"
            missing_scopes="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | tr '\n' ' ' | sed 's/ *$//')"
            if [ -z "$extra" ] && [ -z "$missing_scopes" ]; then
                pass "tailnet: client ${name} scopes match clients.conf"
            else
                fail "tailnet: client ${name} scopes differ from clients.conf (extra: ${extra:-none}; missing: ${missing_scopes:-none})"
            fi
            # tags: exact set comparison; the declared `-` means no tags at all
            decl_tags="${fields[$((nfields - 1))]}"
            decl_set="$decl_tags"; [ "$decl_set" = "-" ] && decl_set=""
            want_tags="$(tr -s ' \t' '\n' <<<"$decl_set" | sed '/^$/d' | sort -u)"
            got_tags="$(tr -s ' \t' '\n' <<<"$granted_tags" | sed '/^$/d' | sort -u)"
            tags_diff="$(comm -3 <(printf '%s\n' "$want_tags" | sed '/^$/d') <(printf '%s\n' "$got_tags" | sed '/^$/d'))"
            if [ -z "$tags_diff" ]; then
                pass "tailnet: client ${name} tags match clients.conf"
            else
                fail "tailnet: client ${name} tags differ from clients.conf (declared: ${decl_tags})"
            fi
        done < <(grep -vE '^[[:space:]]*(#|$)' "$clients_conf")
        if [ "$nclients" -eq 0 ]; then
            warn "tailnet: clients.conf declares no clients"
        fi
    fi
fi

# 4. Tailnet identity and MagicDNS (local `tailscale status`, or the fixture)
if [ -n "${TAILSCALE_STATUS_JSON:-}" ]; then
    st="$(cat "$TAILSCALE_STATUS_JSON" 2>/dev/null)"
else
    st="$("$TAILSCALE" status --json 2>/dev/null)"
fi
if [ -z "$st" ]; then
    warn "tailnet: tailscale status unavailable"
elif ! jq -e 'type == "object"' <<<"$st" >/dev/null 2>&1; then
    warn "tailnet: tailscale status unparseable"
else
    ts_name="$(jq -r '.CurrentTailnet.Name // ""' <<<"$st")"
    ts_suffix="$(jq -r '.CurrentTailnet.MagicDNSSuffix // ""' <<<"$st")"
    ts_magic="$(jq -r '.CurrentTailnet.MagicDNSEnabled | tostring' <<<"$st")"
    id_ok=1
    if [ "$ts_name" != "$TAILNET" ]; then
        fail "tailnet: CurrentTailnet.Name is '${ts_name}' (tailnet.conf TAILNET=${TAILNET})"; id_ok=0
    fi
    if [ "$ts_suffix" != "$TAILNET_DNS_SUFFIX" ]; then
        fail "tailnet: CurrentTailnet.MagicDNSSuffix is '${ts_suffix}' (tailnet.conf TAILNET_DNS_SUFFIX=${TAILNET_DNS_SUFFIX})"; id_ok=0
    fi
    if [ "$ts_magic" != true ]; then
        fail "tailnet: MagicDNS is off (tailscale/README.md settings checklist)"; id_ok=0
    fi
    # This node's own name. Tailscale renames a node that takes a taken name (cxmini-1),
    # silently breaking WebUI origins, serve URLs and saved logins.
    ts_self="$(jq -r '.Self.DNSName // ""' <<<"$st")"
    ts_self="${ts_self%.}"
    if [ -z "$NODE_HOSTNAME" ]; then
        fail "tailnet: tailnet.conf has no NODE_HOSTNAME"; id_ok=0
    elif [ "$ts_self" != "${NODE_HOSTNAME}.${TAILNET_DNS_SUFFIX}" ]; then
        fail "tailnet: this node is named ${ts_self:-none}, not ${NODE_HOSTNAME} (stale device? see docs/migration-recovery.md)"; id_ok=0
    else
        pass "tailnet: this node is ${ts_self}"
    fi
    if [ "$id_ok" -eq 1 ]; then
        pass "tailnet: identity matches tailnet.conf (${TAILNET}, ${TAILNET_DNS_SUFFIX}, MagicDNS on)"
    fi
    # The policy's hosts.<NODE_HOSTNAME> entry must hold this node's IPv4: a node-IP
    # change (new daemon, re-joined device) is otherwise invisible until it bites.
    # Read-only: the status JSON above and the repo policy file.
    node_v4="$(jq -r '[(.Self.TailscaleIPs // [])[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[0] // ""' <<<"$st")"
    if [ -z "$NODE_HOSTNAME" ]; then
        : # reported by the identity check above
    else
        policy_json="$(perl "${SCRIPT_DIR}/lib/hujson2json.pl" < "$policy_file" 2>/dev/null | jq -c . 2>/dev/null)"
        if [ -z "$policy_json" ]; then
            fail "tailnet: policy unreadable or unparseable; cannot check hosts.${NODE_HOSTNAME}"
        else
            policy_v4="$(jq -r --arg n "$NODE_HOSTNAME" '.hosts[$n] // ""' <<<"$policy_json")"
            if [ -z "$policy_v4" ]; then
                fail "tailnet: policy has no hosts.${NODE_HOSTNAME} entry (edit tailscale/policy.hujson, policy-push; see CLAUDE.md node-IP artifacts)"
            elif [ -z "$node_v4" ]; then
                warn "tailnet: this node has no IPv4 in status; hosts.${NODE_HOSTNAME} not checked"
            elif [ "$policy_v4" != "$node_v4" ]; then
                fail "tailnet: policy hosts.${NODE_HOSTNAME} is ${policy_v4} but this node is ${node_v4} (edit tailscale/policy.hujson, policy-push; see CLAUDE.md node-IP artifacts)"
            else
                pass "tailnet: policy hosts.${NODE_HOSTNAME} matches this node (${node_v4})"
            fi
        fi
    fi
fi

# 5. Tailnet Lock must be off (local `tailscale lock status`, or the fixture)
if [ -n "${TAILSCALE_LOCK_STATUS:-}" ]; then
    ls_out="$(cat "$TAILSCALE_LOCK_STATUS" 2>/dev/null)"
else
    ls_out="$("$TAILSCALE" lock status 2>/dev/null)"
fi
case "$ls_out" in
    "") warn "tailnet: tailscale lock status unavailable" ;;
    *"Tailnet Lock is NOT enabled"*) pass "tailnet: Tailnet Lock is off" ;;
    *"ENABLED"*|*"enabled"*) fail "tailnet: Tailnet Lock is on (must be off; tailscale/README.md settings checklist)" ;;
    *) fail "tailnet: Tailnet Lock status unrecognised (expected 'Tailnet Lock is NOT enabled')" ;;
esac

# 6. Policy lint (static invariants on the repo file), re-emitted with the prefix
lint_out="$("$lint_sh" --file "$policy_file" 2>&1)"
if [ -z "$lint_out" ]; then
    warn "tailnet: policy lint produced no output"
fi
while IFS= read -r line; do
    case "$line" in
        "[OK]"*)   pass "tailnet: ${line#\[OK\]   }" ;;
        "[FAIL]"*) fail "tailnet: ${line#\[FAIL\] }" ;;
        "[WARN]"*) warn "tailnet: ${line#\[WARN\] }" ;;
        "[OFF]"*)  off  "tailnet: ${line#\[OFF\]  }" ;;
        *)         [ -n "$line" ] && warn "tailnet: ${line}" ;;
    esac
done <<<"$lint_out"

# 7. Retired TAILSCALE_PAT key in any .env this repo keeps (key name only, never values)
if [ -n "${DOCTOR_ENV_FILES:-}" ]; then
    envfiles="$DOCTOR_ENV_FILES"
else
    envfiles="${repo_root}/tailscale/.env ${repo_root}/stacks/*/.env"
fi
pat_hits=""
for f in $envfiles; do
    [ -f "$f" ] || continue
    if grep -qE '^TAILSCALE_PAT=' "$f"; then
        pat_hits="${pat_hits} ${f#"${repo_root}"/}"
    fi
done
pat_hits="${pat_hits# }"
if [ -n "$pat_hits" ]; then
    for h in $pat_hits; do
        warn "tailnet: ${h} still has a TAILSCALE_PAT key (retired; see tailscale/README.md PAT revocation)"
    done
else
    pass "tailnet: no retired TAILSCALE_PAT key in tailscale/.env or stacks/*/.env"
fi

# 8. Tailscale credential key names outside tailscale/ (keyscan exit 0 = clean)
hits="$("$keyscan_sh" --repo 2>/dev/null)"; rc=$?
case "$rc" in
    0) pass "tailnet: no Tailscale credential key names outside tailscale/" ;;
    1) fail "tailnet: Tailscale credential key names outside tailscale/: $(tr '\n' ' ' <<<"$hits" | sed 's/ *$//')" ;;
    *) fail "tailnet: keyscan failed (rc ${rc}); cannot prove no credential key names outside tailscale/" ;;
esac

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
