#!/usr/bin/env bash
# tailscale/scripts/keyscan.sh — owns the list of Tailscale credential key
# names, so no file outside tailscale/ has to spell them.
#   keyscan.sh --names [--no-pat]  read KEY names on stdin; print the forbidden ones
#                        (exit 1 if any). --no-pat leaves out the retired PAT name
#                        (cxagents lint invariant 4: a leftover PAT line is doctor's
#                        tailnet WARN, not a lockdown failure).
#   keyscan.sh --repo    print tracked files outside tailscale/, archive/ and the
#                        planning docs (docs/{design,implementation,test}-plans/)
#                        that mention one, or a literal tskey- value (exit 1 if any;
#                        exit 2 if git grep itself fails, so an error is never "clean")
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   KEYSCAN_REPO_ROOT overrides the repo --repo scans (keyscan-test.sh's seam).
repo_root="${KEYSCAN_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
base='TS_(ADMIN|AUTHKEYS|OAUTH)_CLIENT_(ID|SECRET)|TS_AUTH_?KEY|TS_CLIENT_(ID|SECRET)|TS_API_KEY'
names="${base}|TAILSCALE_PAT"
case "${1:-}" in
--names)
    pat="$names"
    case "${2:-}" in
        --no-pat) pat="$base" ;;
        "") ;;
        *) echo "usage: keyscan.sh --names [--no-pat] | --repo" >&2; exit 2 ;;
    esac
    hits="$(grep -Ex "$pat" || true)"
    [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
--repo)
    # git grep reads every tracked file (-a: binary files too, so none is skipped).
    # Exit 0 = hits, 1 = no hits, anything else = git failed.
    # Left boundary on the names: CXAGENTS_AUTHKEY_CMD (a repo test seam) ends in
    # "TS_AUTHKEY" and must not match; a real TS_AUTHKEY starts a word. A name right
    # after a backslash escape (printf 'a\nTS_AUTHKEY=x') or a percent/octal/hex/unicode escape
    # (\012, \12, \x0a, \xa, \u000a, \U0000000a, %0A) starts a word too.
    left='(^|[^A-Za-z0-9_]|\\([abefnrtv]|[0-7]{1,3}|x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})|%[0-9A-Fa-f]{2})'
    pat="${left}(${names})|tskey-(api|auth|client)-[A-Za-z0-9]{6,}-[A-Za-z0-9]{10,}"
    hits="$(git -C "$repo_root" grep -laE "$pat" -- . ':!tailscale/' ':!archive/' \
        ':!docs/design-plans/' ':!docs/implementation-plans/' ':!docs/test-plans/')"
    rc=$?
    case "$rc" in
        0) ;;
        1) hits="" ;;
        *) echo "keyscan.sh: git grep failed (rc=${rc})" >&2; exit 2 ;;
    esac
    [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
*) echo "usage: keyscan.sh --names|--repo" >&2; exit 2 ;;
esac
