#!/bin/bash
# tailscale/scripts/keyscan-test.sh — proves `keyscan.sh --repo` flags every form
# a credential key name can take in a tracked file, and ignores lookalikes.
# Runs against a temp git repo (KEYSCAN_REPO_ROOT seam), never the real tree.
# Credential names are built from fragments so this file does not spell them.
# Exit: 0 all cases pass; 1 any case failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
keyscan="${SCRIPT_DIR}/keyscan.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0
pass_case() { echo "PASS keyscan-fixture $1"; }
fail_case() { echo "FAIL keyscan-fixture $1: $2" >&2; failures=$((failures + 1)); }

# Credential key names (fragments; see header).
names=(
    "TS_AUTH""KEY"
    "TS_AUTH""KEYS_CLIENT""_SECRET"
    "TS_OAUTH""_CLIENT""_ID"
    "TS_ADMIN""_CLIENT""_SECRET"
    "TS_API""_KEY"
    "TAILSCALE""_PAT"
)

# Each form is one line with @N@ standing for a name. Labels are parallel.
forms=(
    'export @N@=x'
    '@N@=x'
    '  @N@=x'
    '"@N@"'
    "'@N@'"
    '${@N@}'
    '$@N@'
    '-e @N@=x'
    '@N@: x'
    '  @N@: x'
    'os.Getenv("@N@")'
    '[@N@]'
    'a.@N@'
    'a-@N@'
    "printf 'a\\n@N@=x'"
    "printf 'a\\t@N@=x'"
    "printf 'a\\r@N@=x'"
    "printf 'a\\f@N@=x'"
    "printf 'a\\v@N@=x'"
    "printf 'a\\e@N@=x'"
    "printf 'a\\0@N@=x'"
    "printf 'a\\x0a@N@=x'"
    "printf 'a\\u000a@N@=x'"
    "printf 'a%0A@N@=x'"
    "printf 'a\\012@N@=x'"
    "printf 'a\\12@N@=x'"
    "printf 'a\\xa@N@=x'"
    "printf 'a\\U0000000a@N@=x'"
)
labels=(
    'export NAME=' 'bare NAME=' 'indented NAME=' 'double-quoted "NAME"'
    "single-quoted 'NAME'" '${NAME}' '$NAME' '-e NAME=' 'YAML NAME: (unindented)'
    'YAML NAME: (indented)' 'os.Getenv("NAME")' '[NAME]' 'a.NAME' 'a-NAME'
    'escaped newline \n NAME=' 'escaped tab \t NAME=' 'escaped return \r NAME='
    'escaped form feed \f NAME=' 'escaped vertical tab \v NAME=' 'escaped escape \e NAME='
    'escaped NUL \0 NAME=' 'hex escape \x0a NAME=' 'unicode escape \u000a NAME='
    'percent-encoded newline %0A NAME='
    'octal newline \012 NAME=' 'short octal newline \12 NAME='
    'short hex newline \xa NAME=' 'long unicode newline \U0000000a NAME='
)

# Lookalikes and clean text: must not be flagged.
negatives=(
    'export CXAGENTS_AUTHKEY_CMD=/usr/bin/true'
    'CXAGENTS_AUTHKEY_CMD'
    "printf 'a\\nCXAGENTS_AUTHKEY_CMD=x'"
    "printf 'a\\x0aCXAGENTS_AUTHKEY_CMD=x'"
    'nothing sensitive here'
)

# Positive repo: every form x name, one file per form and name.
pos="$tmp/pos-repo"; mkdir -p "$pos"; git -C "$pos" init -q
f=0
for i in "${!forms[@]}"; do
    for name in "${names[@]}"; do
        line="${forms[$i]//@N@/$name}"
        printf '%s\n' "$line" > "$pos/form-${i}-${f}.txt"
        f=$((f + 1))
    done
done
# A literal tskey value (no name at all) is also a hit.
printf 'value tskey-%s-%s-%s\n' auth abcdef ABCDEFGHIJKL > "$pos/literal-tskey.txt"
git -C "$pos" add -A

pos_out="$(KEYSCAN_REPO_ROOT="$pos" "$keyscan" --repo)"; pos_rc=$?
if [ "$pos_rc" -ne 1 ]; then
    fail_case positive-rc "keyscan --repo rc=${pos_rc} on a repo full of key names, want 1"
fi
f=0
for i in "${!forms[@]}"; do
    missed=0
    for name in "${names[@]}"; do
        grep -qxF "form-${i}-${f}.txt" <<<"$pos_out" || missed=$((missed + 1))
        f=$((f + 1))
    done
    if [ "$missed" -eq 0 ]; then pass_case "detects ${labels[$i]} (${#names[@]} names)"
    else fail_case "detects ${labels[$i]}" "${missed} of ${#names[@]} names not flagged"; fi
done
if grep -qxF 'literal-tskey.txt' <<<"$pos_out"; then pass_case "detects a literal tskey- value"
else fail_case "detects a literal tskey- value" "not flagged"; fi

# Negative repo: lookalikes and clean text only -> rc 0, no hits.
neg="$tmp/neg-repo"; mkdir -p "$neg"; git -C "$neg" init -q
for i in "${!negatives[@]}"; do printf '%s\n' "${negatives[$i]}" > "$neg/neg-${i}.txt"; done
git -C "$neg" add -A
neg_out="$(KEYSCAN_REPO_ROOT="$neg" "$keyscan" --repo)"; neg_rc=$?
if [ "$neg_rc" -eq 0 ] && [ -z "$neg_out" ]; then pass_case "ignores CXAGENTS_AUTHKEY_CMD and clean text"
else fail_case "ignores CXAGENTS_AUTHKEY_CMD and clean text" "rc=${neg_rc}: ${neg_out}"; fi

if [ "$failures" -gt 0 ]; then
    echo "FAIL: ${failures} keyscan fixture(s) failed" >&2
    exit 1
fi
echo "All keyscan fixtures passed"
exit 0
