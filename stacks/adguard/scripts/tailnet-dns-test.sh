#!/bin/bash
# stacks/adguard/scripts/tailnet-dns-test.sh — fixture checks for the
# TAILNET_DNS_FALLBACK parser (lib/fallback.sh) and the TAILNET guard in
# tailnet-dns.sh. Makes no network calls and never reads stacks/adguard/.env:
# the parser runs on fixture files, the TAILNET guard runs against a fixture
# tailnet.conf (TAILSCALE_TAILNET_CONF) that lacks TAILNET (exits 2 before the
# first API call), and the fallback-scope fixtures run a scratch copy of the
# scripts with a stub api.sh and a fixture .env.
# Exit: 0 all fixtures pass; 1 any fixture failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fallback.sh
source "${SCRIPT_DIR}/lib/fallback.sh"
tailnet_dns="${SCRIPT_DIR}/tailnet-dns.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0
pass_fixture() { echo "PASS tailnet-dns-fixture $1"; }
fail_fixture() { echo "FAIL tailnet-dns-fixture $1: $2" >&2; failures=$((failures + 1)); }

# expect_value NAME CONTENT WANT: the parser prints WANT and returns 0.
expect_value() {
    local f="$tmp/$1.env" got rc
    printf '%s' "$2" > "$f"
    got="$(tailnet_dns_fallback "$f" 2>"$tmp/err")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fail_fixture "$1" "rc ${rc}, want 0"
    elif [ "$got" != "$3" ]; then
        fail_fixture "$1" "got '${got}', want '${3}'"
    else
        pass_fixture "$1"
    fi
}

# expect_reject NAME CONTENT VALUE: the parser returns 2, prints nothing on
# stdout, names the KEY on stderr, and never echoes VALUE.
expect_reject() {
    local f="$tmp/$1.env" got rc
    printf '%s' "$2" > "$f"
    got="$(tailnet_dns_fallback "$f" 2>"$tmp/err")"; rc=$?
    if [ "$rc" -ne 2 ]; then
        fail_fixture "$1" "rc ${rc}, want 2"
    elif [ -n "$got" ]; then
        fail_fixture "$1" "printed '${got}' on stdout"
    elif ! grep -qF 'TAILNET_DNS_FALLBACK' "$tmp/err"; then
        fail_fixture "$1" "stderr does not name TAILNET_DNS_FALLBACK"
    elif sed -e 's/^tailnet-dns: TAILNET_DNS_FALLBACK in stacks\/adguard\/\.env is not an IP address//' "$tmp/err" \
        | grep -qF -- "$3"; then
        # The fixed message is stripped first: it contains ':' and '.', so a
        # punctuation-only VALUE would otherwise match the message itself.
        fail_fixture "$1" "stderr echoes the value"
    else
        pass_fixture "$1"
    fi
}

K=TAILNET_DNS_FALLBACK
expect_value plain-ipv4        "$K=1.1.1.1"$'\n'                                  1.1.1.1
expect_value double-quoted     "$K=\"1.1.1.1\""$'\n'                              1.1.1.1
expect_value single-quoted     "$K='1.1.1.1'"$'\n'                                1.1.1.1
expect_value trailing-comment  "$K=1.1.1.1 # cloudflare"$'\n'                     1.1.1.1
expect_value quoted-comment    "$K=\"1.1.1.1\" # cloudflare"$'\n'                 1.1.1.1
expect_value crlf-terminated   "$K=\"1.1.1.1\""$'\r\n'                            1.1.1.1
expect_value crlf-trailing-sp  "$K=1.1.1.1 "$'\r\n'                               1.1.1.1
expect_value ipv6              "$K=\"2606:4700:4700::1111\""$'\n'                 2606:4700:4700::1111
expect_value ipv6-loopback     "$K=::1"$'\n'                                      ::1
expect_value ipv6-full-8       "$K=2001:db8:0:0:0:0:0:1"$'\n'                     2001:db8:0:0:0:0:0:1
expect_value absent-key        "TAILNET_DNS_OTHER=1.2.3.4"$'\n'                   ""
expect_value blank-key         "$K="$'\n'                                         ""
expect_value empty-quotes      "$K=\"\""$'\n'                                     ""
expect_value export-prefixed   "export $K=1.1.1.1"$'\n'                            1.1.1.1
expect_value export-tab-quoted "export"$'\t'"$K=\"1.1.1.1\""$'\n'                  1.1.1.1
expect_value indented-key      "  $K=1.1.1.1"$'\n'                                1.1.1.1

expect_reject bare-garbage     "$K=bogus-value"$'\n'                              bogus-value
expect_reject octet-range      "$K=1.1.1.999"$'\n'                                1.1.1.999
expect_reject unbalanced-quote "$K=\"1.1.1.1"$'\n'                                '"1.1.1.1'
expect_reject mismatched-quote "$K='1.1.1.1\""$'\n'                               "1.1.1.1\""
expect_reject json-injection   "$K=1.1.1.1\"],\"zzprobe"$'\n'                    zzprobe
expect_reject lone-quote       "$K=\""$'\n'                                       '"'
expect_reject ipv6-colon-only  "$K=:"$'\n'                                        :
expect_reject ipv6-triple      "$K=:::"$'\n'                                      :::
expect_reject ipv6-group-5hex  "$K=12345::1"$'\n'                                 12345::1
expect_reject ipv6-9-groups    "$K=1:2:3:4:5:6:7:8:9"$'\n'                        1:2:3:4:5:6:7:8:9

# guard (AC): TAILNET missing from tailnet.conf exits 2 before any API call.
conf="$tmp/tailnet-missing.conf"
printf 'TAILNET_DNS_SUFFIX=example.ts.net\n' > "$conf"
out="$(TAILSCALE_TAILNET_CONF="$conf" /bin/bash "$tailnet_dns" status 2>&1)"; rc=$?
if [ "$rc" -ne 2 ]; then
    fail_fixture tailnet-missing "rc ${rc}, want 2"
elif ! grep -qF 'tailnet-dns: TAILNET missing in tailscale/tailnet.conf' <<<"$out"; then
    fail_fixture tailnet-missing "message missing: ${out}"
else
    pass_fixture tailnet-missing
fi

# fallback-scope (AC3.1): an INVALID TAILNET_DNS_FALLBACK must block only `off`.
# Runs a scratch copy of the scripts (never the real tree) with a stub api.sh
# that logs its argv and answers GET/POST without network, and a stub colima
# whose `list` is empty, so `on` stops at the VM check after its GET.
fb="$tmp/fb"
mkdir -p "$fb/stacks/adguard/scripts/lib" "$fb/tailscale/scripts/lib" "$fb/bin"
cp "$tailnet_dns" "$fb/stacks/adguard/scripts/tailnet-dns.sh"
cp "${SCRIPT_DIR}/lib/fallback.sh" "$fb/stacks/adguard/scripts/lib/fallback.sh"
cp "${SCRIPT_DIR}/../../../tailscale/scripts/lib/conf.sh" "$fb/tailscale/scripts/lib/conf.sh"
printf 'TAILNET=example.com\n' > "$fb/tailnet.conf"
printf 'TAILNET_DNS_FALLBACK=bogus-value\n' > "$fb/stacks/adguard/.env"
api_log="$fb/api.log"
cat > "$fb/tailscale/scripts/api.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$api_log"
case "\$*" in
    *" GET "*) echo '{"dns":["100.64.0.1"]}' ;;
    *) echo '{"dns":["1.1.1.1"]}' ;;
esac
EOF
chmod +x "$fb/tailscale/scripts/api.sh"
printf '#!/bin/sh\nexit 0\n' > "$fb/bin/colima"; chmod +x "$fb/bin/colima"

# fb_run SUBCMD: runs the scratch tailnet-dns.sh; sets fb_out and fb_rc.
fb_run() {
    : > "$api_log"
    fb_out="$(TAILSCALE_TAILNET_CONF="$fb/tailnet.conf" PATH="$fb/bin:$PATH" \
        /bin/bash "$fb/stacks/adguard/scripts/tailnet-dns.sh" "$1" 2>&1)"; fb_rc=$?
}

fb_run status
if [ "$fb_rc" -ne 0 ]; then
    fail_fixture fallback-scope-status "rc ${fb_rc}, want 0: ${fb_out}"
elif grep -qF 'TAILNET_DNS_FALLBACK' <<<"$fb_out"; then
    fail_fixture fallback-scope-status "fallback message surfaced on status"
elif ! grep -qF ' GET ' "$api_log"; then
    fail_fixture fallback-scope-status "stub api.sh never reached"
else
    pass_fixture fallback-scope-status
fi

fb_run on
if [ "$fb_rc" -ne 2 ] || ! grep -qF 'bridged VM not running' <<<"$fb_out"; then
    fail_fixture fallback-scope-on "rc ${fb_rc} or wrong stop point: ${fb_out}"
elif grep -qF 'TAILNET_DNS_FALLBACK' <<<"$fb_out"; then
    fail_fixture fallback-scope-on "fallback message surfaced on on"
elif ! grep -qF ' GET ' "$api_log"; then
    fail_fixture fallback-scope-on "stub api.sh never reached"
else
    pass_fixture fallback-scope-on
fi

fb_run off
if [ "$fb_rc" -ne 2 ]; then
    fail_fixture fallback-scope-off "rc ${fb_rc}, want 2"
elif ! grep -qF 'TAILNET_DNS_FALLBACK in stacks/adguard/.env is not an IP address' <<<"$fb_out"; then
    fail_fixture fallback-scope-off "key-only message missing: ${fb_out}"
elif grep -qF 'bogus-value' <<<"$fb_out"; then
    fail_fixture fallback-scope-off "stderr echoes the value"
elif grep -qF ' POST ' "$api_log"; then
    fail_fixture fallback-scope-off "POST sent despite invalid fallback"
else
    pass_fixture fallback-scope-off
fi

if [ "$failures" -eq 0 ]; then
    echo "All fixtures passed"
    exit 0
fi
echo "${failures} fixture(s) failed" >&2
exit 1
