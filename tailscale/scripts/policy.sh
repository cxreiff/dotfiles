#!/usr/bin/env bash
# tailscale/scripts/policy.sh — the tailnet policy as code.
#   policy.sh [--file F] pull [--force] | diff | push [--init] | status | same-policy G
# F defaults to tailscale/policy.hujson. push reads its confirmation from stdin.
# same-policy: offline; exit 0 iff F and G parse to the same policy (fails closed).
#
# push: lint -> API validate (runs the policy tests) -> fetch live + ETag -> diff
#       -> confirm -> POST with If-Match = that ETag. Plain push refuses unless
#       the live policy equals some committed version of F (git history); that
#       covers a new tailnet and an admin-console edit. --init skips that check
#       and the If-Match precondition (new tailnet, after showing the diff).
#       Tailscale reformats on store; if live then differs from F only in
#       formatting, push writes the stored (canonical) bytes back to F.
# status: in-sync / drift by repo SHA-256 vs live ETag (quotes stripped); byte
#       compare if the ETag is not 64 hex chars.
# Exit: 0 ok/in-sync/identical; 1 drift, diff, refusal, lint/validate failure,
#       abort; 2 credentials (api.sh); 3 API error.
# Test seam: TS_POLICY_TEST_STALE_ETAG=1 sends an all-zero If-Match (412 path).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/conf.sh
source "${SCRIPT_DIR}/lib/conf.sh"
api="${SCRIPT_DIR}/api.sh"

file="${SCRIPT_DIR}/../policy.hujson"
if [ "${1:-}" = --file ]; then file="$2"; shift 2; fi
cmd="${1:-}"; [ $# -gt 0 ] && shift

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch_live() {   # -> $tmp/live (exact bytes), $etag
    "$api" GET "/tailnet/${TAILNET}/acl" -H 'Accept: application/hujson' -D "$tmp/hdr" >"$tmp/live" || exit $?
    etag="$(sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' "$tmp/hdr" | tr -d '\r"' | tail -1)"
}
in_sync() {
    if [[ "$etag" =~ ^[0-9a-f]{64}$ ]]; then [ "$(sha "$file")" = "$etag" ]
    else cmp -s "$file" "$tmp/live"; fi
}
in_lineage() {   # live bytes equal a committed version of $file?
    local dir base want h
    dir="$(cd "$(dirname "$file")" && pwd)"; base="$(basename "$file")"; want="$(sha "$tmp/live")"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
    for h in $(git -C "$dir" log --format=%H -- "$base"); do
        [ "$(git -C "$dir" show "${h}:./${base}" | shasum -a 256 | cut -d' ' -f1)" = "$want" ] && return 0
    done
    return 1
}
# semantic FILE: canonical JSON of a HuJSON policy. Fails (no output, rc 1) unless
# the file parses to a JSON object; an empty conversion never reads as a policy.
semantic() {
    local json
    json="$(perl "${SCRIPT_DIR}/lib/hujson2json.pl" < "$1" | jq -S . 2>/dev/null)" || return 1
    [ -n "$json" ] || return 1
    jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1 || return 1
    printf '%s\n' "$json"
}
# same_policy A B: 0 iff both files parse to the same policy. Fails closed.
same_policy() {
    local a b
    a="$(semantic "$1")" || return 1
    b="$(semantic "$2")" || return 1
    [ "$a" = "$b" ]
}
need_file() { [ -f "$file" ] || { echo "policy: ${file} missing (dotfiles tailscale policy-pull)" >&2; exit 1; }; }

case "$cmd" in
pull)
    if [ -e "$file" ] && [ "${1:-}" != --force ]; then
        echo "policy: ${file} exists; refusing to overwrite (use --force)" >&2; exit 1
    fi
    fetch_live
    cp "$tmp/live" "${file}.tmp" && mv "${file}.tmp" "$file"
    echo "policy: wrote ${file} (sha256 $(sha "$file"))"
    ;;
diff)
    need_file; fetch_live
    diff -u --label "live (${TAILNET})" --label "repo ($(basename "$file"))" "$tmp/live" "$file"
    exit $?
    ;;
status)
    need_file; fetch_live
    if in_sync; then echo in-sync; else echo drift; exit 1; fi
    ;;
push)
    init=0; [ "${1:-}" = --init ] && init=1
    need_file
    if ! "${SCRIPT_DIR}/lint.sh" --file "$file" >"$tmp/lint" 2>&1; then
        cat "$tmp/lint" >&2; echo "policy: lint failed; not pushing" >&2; exit 1
    fi
    "$api" POST "/tailnet/${TAILNET}/acl/validate" -H 'Content-Type: application/hujson' \
        --data-binary "@${file}" >"$tmp/val" 2>"$tmp/valerr"
    rc=$?
    [ "$rc" -eq 2 ] && { cat "$tmp/valerr" >&2; exit 2; }
    if [ "$rc" -ne 0 ] || [ -n "$(jq -r '.message // empty' "$tmp/val" 2>/dev/null)" ]; then
        cat "$tmp/valerr" >&2; (jq . "$tmp/val" 2>/dev/null || cat "$tmp/val") >&2
        echo "policy: validate failed; not pushing" >&2; exit 1
    fi
    fetch_live
    if cmp -s "$tmp/live" "$file"; then echo "policy: live already matches $(basename "$file")"; exit 0; fi
    if [ "$init" -eq 0 ] && ! in_lineage; then
        echo "policy: live policy matches no committed version of $(basename "$file") (a new tailnet, or an admin-console edit)." >&2
        echo "policy: review \`dotfiles tailscale policy-diff\`; to replace live with the repo file run \`dotfiles tailscale policy-push --init\`." >&2
        exit 1
    fi
    diff -u --label "live (${TAILNET})" --label "repo ($(basename "$file"))" "$tmp/live" "$file"
    note=""; [ "$init" -eq 1 ] && note=" WITHOUT If-Match (--init)"
    printf 'Push %s to tailnet %s%s? [y/N] ' "$(basename "$file")" "$TAILNET" "$note" >&2
    read -r answer || answer=""
    case "$answer" in y|yes) ;; *) echo "policy: aborted; nothing pushed" >&2; exit 1 ;; esac
    hdrs=(-H 'Content-Type: application/hujson')
    if [ "$init" -eq 0 ]; then
        m="$etag"
        [ "${TS_POLICY_TEST_STALE_ETAG:-}" = 1 ] && m="$(printf '%064d' 0)"
        hdrs+=(-H "If-Match: \"${m}\"")
    fi
    if ! "$api" POST "/tailnet/${TAILNET}/acl" "${hdrs[@]}" --data-binary "@${file}" >"$tmp/post" 2>"$tmp/err"; then
        if grep -q 'HTTP 412' "$tmp/err"; then echo "policy: live policy changed; run policy-diff" >&2; exit 1; fi
        cat "$tmp/err" >&2; exit 3
    fi
    fetch_live
    # Tailscale stores the policy in canonical HuJSON formatting. When live
    # differs from F only in formatting, adopt the stored bytes so F stays
    # byte-identical to live (status, lineage).
    if ! in_sync && same_policy "$tmp/live" "$file"; then
        cp "$tmp/live" "${file}.tmp" && mv "${file}.tmp" "$file"
        echo "policy: Tailscale reformatted the policy on store; wrote its canonical form to $(basename "$file")" >&2
    fi
    if in_sync; then
        echo "policy: pushed; in-sync (sha256 $(sha "$file"))"
        git -C "$(dirname "$file")" diff --quiet HEAD -- "$(basename "$file")" 2>/dev/null \
            || echo "policy: commit $(basename "$file") now — the next plain push requires live to match a committed version" >&2
    else echo "policy: pushed, but live differs from $(basename "$file") (run policy-diff)" >&2; exit 1; fi
    ;;
same-policy)   # exit 0 iff F and G parse to the same policy (offline; no API)
    [ $# -eq 1 ] || { echo "usage: policy.sh [--file F] same-policy G" >&2; exit 2; }
    same_policy "$file" "$1"
    ;;
*)
    echo "usage: policy.sh [--file F] pull [--force] | diff | push [--init] | status | same-policy G" >&2; exit 2 ;;
esac
