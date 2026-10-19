#!/bin/bash
# tailscale/scripts/doctor-test.sh — proves each tailnet doctor FAIL/WARN path.
# Each case runs tailscale/scripts/doctor.sh with fixture overrides and asserts
# on its output. Read-only against the live tailnet (GETs and token exchanges
# only; the live policy is never touched). Never prints a credential value: the
# admin secret is read into a variable only for an absence check, and reaches
# grep through a file, never argv.
# Exit: 0 all fixtures pass; 1 any fixture failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
doctor="${SCRIPT_DIR}/doctor.sh"
live_policy="${ts_root}/policy.hujson"
live_clients="${ts_root}/clients.conf"
live_env="${ts_root}/.env"
example_env="${ts_root}/.env.example"
tailscale_bin="/opt/homebrew/bin/tailscale"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0
pass_fixture() { echo "PASS doctor-fixture $1"; }
fail_fixture() { echo "FAIL doctor-fixture $1: $2" >&2; failures=$((failures + 1)); }

# run ARGS...: doctor with ARGS (VAR=value) as overrides, inherited overrides cleared.
# Output (stdout+stderr) lands in $out.
run() {
    out="$(env -u TAILSCALE_ENV_FILE -u TAILSCALE_POLICY_FILE -u TAILSCALE_CLIENTS_CONF \
        -u TAILSCALE_TAILNET_CONF -u TAILSCALE_STATUS_JSON -u TAILSCALE_LOCK_STATUS \
        -u DOCTOR_ENV_FILES env "$@" "$doctor" 2>&1)"
}

# Assertions accumulate into $reason; verdict LABEL reports and resets it.
reason=""
need() { grep -qF -- "$1" <<<"$out" || reason="${reason}; missing '$1'"; }
forbid_fail() {   # no [FAIL] line matches the extended regex $1
    if grep '^\[FAIL\]' <<<"$out" | grep -qE -- "$1"; then reason="${reason}; unexpected FAIL matching '$1'"; fi
    return 0
}
verdict() {
    if [ -z "$reason" ]; then
        pass_fixture "$1"
    else
        fail_fixture "$1" "${reason#; }"; sed 's/^/    /' <<<"$out" >&2
    fi
    reason=""
}

# make_env FILE MODE [OMIT_KEY]: fixture credentials file with the example's key
# names and dummy values (x); OMIT_KEY is left out.
make_env() {
    local f="$1" mode="$2" omit="${3:-}" k
    : > "$f"
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        [ "$k" = "$omit" ] && continue
        printf '%s=x\n' "$k" >> "$f"
    done < <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$example_env")
    chmod "$mode" "$f"
}

# status_fixture OUT JQ_FILTER: the live `tailscale status --json` with JQ_FILTER applied
live_status="$("$tailscale_bin" status --json 2>/dev/null)"
status_fixture() {
    if [ -n "$live_status" ]; then jq "$2" <<<"$live_status" > "$1" 2>/dev/null; fi
}

# baseline: the real declared state passes; the output is kept for no-values
run DOCTOR_TEST=baseline
printf '%s\n' "$out" > "$tmp/baseline.out"
need "[OK]   tailnet: policy in-sync"
need "[OK]   tailnet: client admin scopes match clients.conf"
need "[OK]   tailnet: client admin tags match clients.conf"
need "[OK]   tailnet: client authkeys tags match clients.conf"
need "[OK]   tailnet: this node is cxmini.faun-fir.ts.net"
need "[OK]   tailnet: policy hosts.cxmini matches this node"
forbid_fail '.'
verdict baseline

# policy-drift (AC4.2): repo bytes differ from live ETag
cp "$live_policy" "$tmp/drift.hujson"; printf '\n// drift\n' >> "$tmp/drift.hujson"
run TAILSCALE_POLICY_FILE="$tmp/drift.hujson"
need "[FAIL] tailnet: live policy differs from tailscale/policy.hujson"
verdict policy-drift

# env-missing (AC4.3): WARN, and no FAIL about the env, policy or clients
run TAILSCALE_ENV_FILE="$tmp/none"
need "[WARN] tailnet: tailscale/.env missing"
forbid_fail '\.env|policy|client'
verdict env-missing

# env-mode (AC4.3): a credentials file that is not 0600
make_env "$tmp/env-644.env" 644
run TAILSCALE_ENV_FILE="$tmp/env-644.env"
need "[FAIL] tailnet: tailscale/.env mode 644"
verdict env-mode

# env-keys (AC4.3): a key from .env.example is absent
make_env "$tmp/env-nosecret.env" 600 TS_ADMIN_CLIENT_SECRET
run TAILSCALE_ENV_FILE="$tmp/env-nosecret.env"
need "[FAIL] tailnet: tailscale/.env missing keys: TS_ADMIN_CLIENT_SECRET"
verdict env-keys

# api-unreachable (AC4.3): dummy credentials are rejected by the token endpoint
make_env "$tmp/env-dummy.env" 600
run TAILSCALE_ENV_FILE="$tmp/env-dummy.env"
need "[WARN] tailnet: policy status unavailable"
need "[WARN] tailnet: client admin: token exchange failed"
forbid_fail 'policy|client'
verdict api-unreachable

# scope-extra (AC2.6): granted set lacks a scope the declaration adds
grep -v '^#' "$live_clients" | sed 's/ -$/ users:read -/' > "$tmp/clients-extra.conf"
run TAILSCALE_CLIENTS_CONF="$tmp/clients-extra.conf"
need "[FAIL] tailnet: client admin scopes differ from clients.conf"
need "missing: users:read"
verdict scope-extra

# scope-missing (AC2.6): granted set has a scope the declaration omits
grep -v '^#' "$live_clients" | sed 's/ dns / /' > "$tmp/clients-nodns.conf"
run TAILSCALE_CLIENTS_CONF="$tmp/clients-nodns.conf"
need "[FAIL] tailnet: client admin scopes differ from clients.conf"
need "extra: dns"
verdict scope-missing

# scope-tabs: the same declaration with tab separators (runs of spaces become one
# tab) must still PASS the scope check; a tab before the tags column once put
# `-` into the scope set.
grep -v '^#' "$live_clients" | tr -s ' ' '\t' > "$tmp/clients-tabs.conf"
if ! grep -q "$(printf '\t')" "$tmp/clients-tabs.conf"; then
    fail_fixture scope-tabs "fixture has no tab separators"
fi
run TAILSCALE_CLIENTS_CONF="$tmp/clients-tabs.conf"
need "[OK]   tailnet: client admin scopes match clients.conf"
forbid_fail 'client'
verdict scope-tabs

# tags-mismatch (AC2.6): the declared tag differs from the client's live tag
grep -v '^#' "$live_clients" | sed 's/tag:cxagents$/tag:other/' > "$tmp/clients-tags.conf"
run TAILSCALE_CLIENTS_CONF="$tmp/clients-tags.conf"
need "[FAIL] tailnet: client authkeys tags differ from clients.conf"
forbid_fail 'scopes'
verdict tags-mismatch

# tags-extra (AC2.6): the row declares no tags (`-`) but the live client carries one
grep -v '^#' "$live_clients" | sed 's/tag:cxagents$/-/' > "$tmp/clients-tags-none.conf"
run TAILSCALE_CLIENTS_CONF="$tmp/clients-tags-none.conf"
need "[FAIL] tailnet: client authkeys tags differ from clients.conf (declared: -)"
verdict tags-extra

# tailnet-name, dns-suffix, magicdns-off (AC4.7): live status with one field changed
status_fixture "$tmp/status-name.json" '.CurrentTailnet.Name="other"'
run TAILSCALE_STATUS_JSON="$tmp/status-name.json"
need "[FAIL] tailnet: CurrentTailnet.Name is 'other'"
verdict tailnet-name

status_fixture "$tmp/status-suffix.json" '.CurrentTailnet.MagicDNSSuffix="x.ts.net"'
run TAILSCALE_STATUS_JSON="$tmp/status-suffix.json"
need "[FAIL] tailnet: CurrentTailnet.MagicDNSSuffix is 'x.ts.net'"
verdict dns-suffix

status_fixture "$tmp/status-magic.json" '.CurrentTailnet.MagicDNSEnabled=false'
run TAILSCALE_STATUS_JSON="$tmp/status-magic.json"
need "[FAIL] tailnet: MagicDNS is off"
verdict magicdns-off

# self-renamed: this node joined under a taken name (Tailscale appends -1), so its
# MagicDNS name is no longer NODE_HOSTNAME.<suffix> (stale device; see migration-recovery)
status_fixture "$tmp/status-self.json" '.Self.DNSName="cxmini-1.faun-fir.ts.net."'
run TAILSCALE_STATUS_JSON="$tmp/status-self.json"
need "[FAIL] tailnet: this node is named cxmini-1.faun-fir.ts.net, not cxmini"
need "stale device? see docs/migration-recovery.md"
verdict self-renamed

# hosts-stale: the policy's hosts.cxmini names an IP this node no longer has (a node-IP
# change that was not edited into policy.hujson and pushed; see CLAUDE.md node-IP artifacts)
sed -E 's/("cxmini": *")[0-9.]+(")/\1100.64.0.1\2/' "$live_policy" > "$tmp/hosts-stale.hujson"
if ! grep -q '100.64.0.1' "$tmp/hosts-stale.hujson"; then
    fail_fixture hosts-stale "fixture did not rewrite hosts.cxmini"
fi
run TAILSCALE_POLICY_FILE="$tmp/hosts-stale.hujson"
need "[FAIL] tailnet: policy hosts.cxmini is 100.64.0.1 but this node is"
need "edit tailscale/policy.hujson, policy-push; see CLAUDE.md node-IP artifacts"
verdict hosts-stale

# hosts-missing: the policy declares no hosts.cxmini entry at all
sed -E 's/"cxmini": *"[0-9.]+"//' "$live_policy" > "$tmp/hosts-missing.hujson"
run TAILSCALE_POLICY_FILE="$tmp/hosts-missing.hujson"
need "[FAIL] tailnet: policy has no hosts.cxmini entry"
verdict hosts-missing

# lock-on (AC4.7): Tailnet Lock enabled
printf 'Tailnet Lock is ENABLED.\n' > "$tmp/lock-on.txt"
run TAILSCALE_LOCK_STATUS="$tmp/lock-on.txt"
need "[FAIL] tailnet: Tailnet Lock is on"
verdict lock-on

# pat-key (AC4.7): a retired TAILSCALE_PAT key in an env file
printf 'TAILSCALE_PAT=x\n' > "$tmp/adguard.env"
run DOCTOR_ENV_FILES="$tmp/adguard.env"
need "[WARN] tailnet: $tmp/adguard.env still has a TAILSCALE_PAT key"
verdict pat-key

# no-values (AC4.6): the baseline output holds neither the admin secret nor a tskey- value
secret="$(sed -n 's/^TS_ADMIN_CLIENT_SECRET=//p' "$live_env" 2>/dev/null | tail -1)"
if [ -z "$secret" ]; then
    fail_fixture no-values "TS_ADMIN_CLIENT_SECRET not readable from tailscale/.env; absence cannot be checked"
elif grep -qF -f <(printf '%s\n' "$secret") "$tmp/baseline.out"; then
    fail_fixture no-values "baseline output contains the admin client secret"
elif grep -qF 'tskey-' "$tmp/baseline.out"; then
    fail_fixture no-values "baseline output contains a tskey- value"
else
    pass_fixture no-values
fi
unset secret

# no-values (static): doctor.sh never sources a .env file
if grep -nE '^[[:space:]]*(source|\.)[[:space:]][^#]*\.env' "$doctor"; then
    fail_fixture no-values "doctor.sh sources a .env file (see matches above)"
else
    pass_fixture no-values-static
fi

if [ "$failures" -eq 0 ]; then
    echo "All fixtures passed"
    exit 0
fi
echo "${failures} fixture(s) failed" >&2
exit 1
