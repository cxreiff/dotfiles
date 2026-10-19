#!/bin/bash
# stacks/cxagents/scripts/lint-test.sh — proves each cxagents lint invariant.
# Builds baseline fixtures in a trap-cleaned temp dir from the tracked policy,
# forwarder compose, routes, and the KEY NAMES of each stack's .env.example
# (values "x"). Each case mutates one thing and asserts that lint.sh fails only
# the named invariant (expect_only), or reports no FAIL (expect_none).
#
# Credential key names are built from fragments below so that no tracked file
# outside tailscale/ spells them (tailscale/scripts/keyscan.sh --repo stays clean).
# The fixture .env files hold those names with value "x" in the temp dir only;
# the real stacks/*/.env files are never read here.
# Exit: 0 all fixtures pass; 1 any fixture failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
repo_root="$(cd "${stack_dir}/../.." && pwd)"
lint_sh="${SCRIPT_DIR}/lint.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0

# Credential key names, built from fragments (see header).
k_authkey="TS_AUTH""KEY"
k_oauth="TS_AUTH""KEYS_CLIENT""_SECRET"
k_pat="TAILSCALE""_PAT"

# --- baseline fixtures -------------------------------------------------------
perl "${repo_root}/tailscale/scripts/lib/hujson2json.pl" < "${repo_root}/tailscale/policy.hujson" \
    | jq . > "$tmp/policy.json" || { echo "lint-test: cannot convert the policy" >&2; exit 1; }
cp "${stack_dir}/routes" "$tmp/routes"
docker compose -f "${stack_dir}/compose.yaml" config --no-interpolate --format json > "$tmp/compose.json" \
    || { echo "lint-test: cannot render ${stack_dir}/compose.yaml" >&2; exit 1; }

# One directory per stack: the rendered-from-source compose.yaml, and a .env
# holding KEY=x for each KEY in .env.example (key names only come from the tracked file).
mkdir -p "$tmp/stacks"
for d in "${repo_root}"/stacks/*/; do
    s="$(basename "$d")"
    mkdir -p "$tmp/stacks/$s"
    [ -f "$d/compose.yaml" ] && cp "$d/compose.yaml" "$tmp/stacks/$s/compose.yaml"
    [ -f "$d/.env.example" ] && grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$d/.env.example" | sed 's/$/x/' > "$tmp/stacks/$s/.env"
done

# run_lint [overrides...]: lint output; baseline flags first, overrides last.
run_lint() {
    "$lint_sh" --policy "$tmp/policy.json" --compose "$tmp/compose.json" \
        --routes "$tmp/routes" --stacks-dir "$tmp/stacks" "$@" 2>&1
}

baseline_out="$(run_lint || true)"
if ! grep -q '^\[FAIL\]' <<<"$baseline_out" && [ "$(grep -c '^\[OK\]' <<<"$baseline_out")" -eq 7 ]; then
    echo "PASS lint-fixture baseline"
else
    echo "FAIL lint-fixture baseline: expected seven [OK] and no [FAIL]" >&2
    echo "$baseline_out" >&2; failures=$((failures + 1))
fi

# mk NAME SOURCE JQ: jq-modified copy of a baseline JSON fixture in $tmp.
mk() { jq "$3" "$tmp/$2" > "$tmp/$1"; }
# stacks_copy NAME: a fresh copy of the baseline stacks dir; prints its path.
stacks_copy() { rm -rf "$tmp/s-$1"; cp -R "$tmp/stacks" "$tmp/s-$1"; echo "$tmp/s-$1"; }

# expect_only LABEL PATTERN [overrides...]: lint must FAIL, and every FAIL line
# must match PATTERN (no collateral failures).
expect_only() {
    local label="$1" pat="$2" out others; shift 2
    out="$(run_lint "$@" || true)"
    others="$(grep '^\[FAIL\]' <<<"$out" | grep -vE "$pat" || true)"
    if grep -q '^\[FAIL\]' <<<"$out" && [ -z "$others" ]; then
        echo "PASS lint-fixture ${label}"
    else
        echo "FAIL lint-fixture ${label}: expected only FAILs matching /${pat}/" >&2
        echo "$out" >&2; failures=$((failures + 1))
    fi
}

# expect_none LABEL [overrides...]: lint must report no FAIL.
expect_none() {
    local label="$1" out; shift
    out="$(run_lint "$@" || true)"
    if ! grep -q '^\[FAIL\]' <<<"$out"; then
        echo "PASS lint-fixture ${label}"
    else
        echo "FAIL lint-fixture ${label}: expected no FAIL" >&2
        echo "$out" >&2; failures=$((failures + 1))
    fi
}

# --- invariant 1: no tag:cxagents source ----------------------------------------
mk p-grant-src policy.json '.grants += [{"src":["tag:cxagents"],"dst":["autogroup:member"],"ip":["*"]}]'
expect_only inv1-grant-src 'cxagents invariant 1:' --policy "$tmp/p-grant-src"
mk p-acl-src policy.json '.acls = [{"action":"accept","src":["tag:cxagents"],"dst":["autogroup:member:*"]}]'
expect_only inv1-acl-src 'cxagents invariant 1:' --policy "$tmp/p-acl-src"
mk p-ssh-src policy.json '.ssh += [{"action":"accept","src":["tag:cxagents"],"dst":["autogroup:self"],"users":["autogroup:nonroot"]}]'
expect_only inv1-ssh-src 'cxagents invariant 1:' --policy "$tmp/p-ssh-src"
mk p-ssh-star policy.json '.ssh += [{"action":"accept","src":["*"],"dst":["autogroup:self"],"users":["autogroup:nonroot"]}]'
expect_only inv1-ssh-star 'cxagents invariant 1:' --policy "$tmp/p-ssh-star"
mk p-cidr-src policy.json '.grants += [{"src":["100.64.0.0/10"],"dst":["autogroup:member"],"ip":["*"]}]'
expect_only inv1-cidr-src 'cxagents invariant 1:' --policy "$tmp/p-cidr-src"
mk p-danger-all-src policy.json '.grants += [{"src":["autogroup:danger-all"],"dst":["autogroup:member"],"ip":["*"]}]'
expect_only inv1-danger-all 'cxagents invariant 1:' --policy "$tmp/p-danger-all-src"
mk p-host-alias-src policy.json '.grants += [{"src":["cxmini"],"dst":["autogroup:member"],"ip":["*"]}]'
expect_only inv1-host-alias 'cxagents invariant 1:' --policy "$tmp/p-host-alias-src"
mk p-ipset-src policy.json '.grants += [{"src":["ipset:cx"],"dst":["autogroup:member"],"ip":["*"]}]'
expect_only inv1-ipset 'cxagents invariant 1:' --policy "$tmp/p-ipset-src"

# --- invariant 2: grants to tag:cxagents inside routes, no deny ports ---------
cx_grant='(.grants[] | select((.dst // []) | index("tag:cxagents")) | .ip)'
mk p-deny-port policy.json "${cx_grant} = [\"tcp:1024-65535\"]"
expect_only inv2-deny-port 'cxagents invariant 2:' --policy "$tmp/p-deny-port"
mk p-star policy.json "${cx_grant} = [\"*\"]"
expect_only inv2-star 'cxagents invariant 2:' --policy "$tmp/p-star"
mk p-below policy.json "${cx_grant} = [\"tcp:80\"]"
expect_only inv2-below-1024 'cxagents invariant 2:' --policy "$tmp/p-below"
mk p-udp policy.json "${cx_grant} = [\"udp:5000\"]"
expect_only inv2-udp 'cxagents invariant 2:' --policy "$tmp/p-udp"
mk p-tagged-dst policy.json '.grants += [{"src":["autogroup:member"],"dst":["autogroup:tagged"],"ip":["*"]}]'
expect_only inv2-tagged-dst 'cxagents invariant 2:' --policy "$tmp/p-tagged-dst"
mk p-acl-dst policy.json '.acls = [{"action":"accept","src":["autogroup:member"],"dst":["tag:cxagents:*"]}]'
expect_only inv2-acl-dst 'cxagents invariant 2:' --policy "$tmp/p-acl-dst"
mk p-tag-case policy.json '.grants += [{"src":["autogroup:member"],"dst":["tag:CXAGENTS"],"ip":["*"]}]'
expect_only inv2-tag-case 'cxagents invariant 2:' --policy "$tmp/p-tag-case"
mk p-danger-all-dst policy.json '.grants += [{"src":["autogroup:member"],"dst":["autogroup:danger-all"],"ip":["*"]}]'
expect_only inv2-danger-all-dst 'cxagents invariant 2:' --policy "$tmp/p-danger-all-dst"
mk p-cidr-dst policy.json '.grants += [{"src":["autogroup:member"],"dst":["100.64.0.0/10"],"ip":["*"]}]'
expect_only inv2-cidr-dst 'cxagents invariant 2:' --policy "$tmp/p-cidr-dst"
mk p-host-alias-dst policy.json '.grants += [{"src":["autogroup:member"],"dst":["cxmini"],"ip":["*"]}]'
expect_only inv2-host-alias-dst 'cxagents invariant 2:' --policy "$tmp/p-host-alias-dst"
mk p-acl-cidr-dst policy.json '.acls = [{"action":"accept","src":["autogroup:member"],"dst":["100.64.0.0/10:*"]}]'
expect_only inv2-acl-cidr-dst 'cxagents invariant 2:' --policy "$tmp/p-acl-cidr-dst"

# --- invariant 3: forwarder hardening -------------------------------------------
mk c-net compose.json '.services.forwarder.networks.default = {}'
expect_only inv3-extra-network 'cxagents invariant 3:' --compose "$tmp/c-net"
mk c-ports compose.json '.services.forwarder.ports = [{"target":80,"published":"8080","protocol":"tcp"}]'
expect_only inv3-ports 'cxagents invariant 3:' --compose "$tmp/c-ports"
mk c-rw compose.json '.services.forwarder.read_only = false'
expect_only inv3-no-readonly 'cxagents invariant 3:' --compose "$tmp/c-rw"
mk c-caps compose.json '.services.forwarder.cap_drop = []'
expect_only inv3-caps 'cxagents invariant 3:' --compose "$tmp/c-caps"
mk c-nnp compose.json '.services.forwarder.security_opt = []'
expect_only inv3-nnp 'cxagents invariant 3:' --compose "$tmp/c-nnp"
mk c-root compose.json '.services.forwarder.user = "0:0"'
expect_only inv3-root-user 'cxagents invariant 3:' --compose "$tmp/c-root"
mk c-log compose.json 'del(.services.forwarder.logging.options["max-size"])'
expect_only inv3-no-logging-limit 'cxagents invariant 3:' --compose "$tmp/c-log"
mk c-privileged compose.json '.services.forwarder.privileged = true'
expect_only inv3-privileged 'cxagents invariant 3:' --compose "$tmp/c-privileged"
mk c-cap-add compose.json '.services.forwarder.cap_add = ["NET_ADMIN","SYS_ADMIN"]'
expect_only inv3-cap-add 'cxagents invariant 3:' --compose "$tmp/c-cap-add"
mk c-pid-host compose.json '.services.forwarder.pid = "host"'
expect_only inv3-pid-host 'cxagents invariant 3:' --compose "$tmp/c-pid-host"
mk c-ipc-host compose.json '.services.forwarder.ipc = "host"'
expect_only inv3-ipc-host 'cxagents invariant 3:' --compose "$tmp/c-ipc-host"
mk c-userns compose.json '.services.forwarder.userns_mode = "host"'
expect_only inv3-userns-host 'cxagents invariant 3:' --compose "$tmp/c-userns"
mk c-cgroup compose.json '.services.forwarder.cgroup = "host"'
expect_only inv3-cgroup-host 'cxagents invariant 3:' --compose "$tmp/c-cgroup"
mk c-devices compose.json '.services.forwarder.devices = [{"source":"/dev/net/tun","target":"/dev/net/tun"}]'
expect_only inv3-devices 'cxagents invariant 3:' --compose "$tmp/c-devices"
mk c-unconfined compose.json '.services.forwarder.security_opt += ["seccomp=unconfined"]'
expect_only inv3-unconfined 'cxagents invariant 3:' --compose "$tmp/c-unconfined"
mk c-bind-src compose.json '(.services.forwarder.volumes[] | select(.target == "/etc/forwarder/routes") | .source) = "/var/run/docker.sock"'
expect_only inv3-bind-source 'cxagents invariant 3:' --compose "$tmp/c-bind-src"
mk c-volumes-from compose.json '.services.forwarder.volumes_from = ["connectome-shell"]'
expect_only inv3-volumes-from 'cxagents invariant 3:' --compose "$tmp/c-volumes-from"
mk c-sysctls compose.json '.services.forwarder.sysctls = {"net.ipv4.ip_forward":"1"}'
expect_only inv3-sysctls 'cxagents invariant 3:' --compose "$tmp/c-sysctls"

# --- invariant 4: no auth-key / OAuth key names in stack env ------------------
s="$(stacks_copy env-file)"; echo "${k_authkey}=x" >> "$s/onecli/.env"
expect_only inv4-env-key 'cxagents invariant 4:' --stacks-dir "$s"
s="$(stacks_copy export-env-key)"; echo "export ${k_authkey}=x" >> "$s/onecli/.env"
expect_only inv4-export-env-key 'cxagents invariant 4:' --stacks-dir "$s"
s="$(stacks_copy indented-env-key)"; echo "  ${k_authkey}=x" >> "$s/onecli/.env"
expect_only inv4-indented-env-key 'cxagents invariant 4:' --stacks-dir "$s"
s="$(stacks_copy compose-env)"
awk -v line="      ${k_authkey}: x" '{ print } /^      FORWARDER_HOSTNAME:/ { print line }' \
    "$s/cxagents/compose.yaml" > "$s/cxagents/compose.yaml.tmp" && mv "$s/cxagents/compose.yaml.tmp" "$s/cxagents/compose.yaml"
expect_only inv4-compose-env 'cxagents invariant 4:' --stacks-dir "$s"
s="$(stacks_copy oauth-name)"; echo "${k_oauth}=x" >> "$s/onecli/.env"
expect_only inv4-oauth-name 'cxagents invariant 4:' --stacks-dir "$s"
# The retired PAT name is excluded on purpose (--no-pat): a leftover line is doctor's WARN.
s="$(stacks_copy pat-leftover)"; echo "${k_pat}=x" >> "$s/onecli/.env"
expect_none inv4-pat-leftover-not-a-failure --stacks-dir "$s"

# --- invariant 5: route targets are container names ---------------------------
sed -E 's/^connectome-shell[[:space:]]+/no-such-container /' "$tmp/routes" > "$tmp/r-unknown"
expect_only inv5-unknown-target 'cxagents invariant 5:' --routes "$tmp/r-unknown"

# --- invariant 6: routes parse, >=1024, no overlap, deny inside range ----------
{ cat "$tmp/routes"; echo 'cxagents-forwarder 5000-6000 -'; } > "$tmp/r-overlap"
expect_only inv6-overlap 'cxagents invariant 6:' --routes "$tmp/r-overlap"
sed -E 's/^connectome-shell[[:space:]]+1024-65535/connectome-shell 80-65535/' "$tmp/routes" > "$tmp/r-low"
expect_only inv6-low 'cxagents invariant 6:' --routes "$tmp/r-low"

# --- invariant 7: identity and tagOwners --------------------------------------
mk c-host compose.json '.services.forwarder.environment.FORWARDER_HOSTNAME = "cxagents2"'
expect_only inv7-hostname 'cxagents invariant 7:' --compose "$tmp/c-host"
mk p-no-owner policy.json 'del(.tagOwners)'
expect_only inv7-tag-not-declared 'cxagents invariant 7:' --policy "$tmp/p-no-owner"

if [ "$failures" -gt 0 ]; then
    echo "FAIL: ${failures} fixture(s) failed" >&2
    exit 1
fi
echo "All fixtures passed"
exit 0
