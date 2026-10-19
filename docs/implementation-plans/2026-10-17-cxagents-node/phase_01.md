# cxagents Node Implementation Plan — Phase 1 of 7: `tailscale/` module and policy as code

**Goal:** The tailnet's policy, identity and OAuth clients are declared in the repo; the policy is pullable, diffable, safely pushable and checkable for drift with the `dotfiles-admin` client.

**Architecture:** A new top-level just module `tailscale/` (beside `stacks` and `stow`). `tailscale/scripts/api.sh` is the only code that reads the OAuth client secrets (`tailscale/.env`); `policy.sh` implements `policy-pull|diff|push|status` on top of it; `lint.sh` checks static policy invariants after converting HuJSON to JSON with a small Perl filter (no HuJSON tool is installed); `smoke.sh` exercises everything against the live tailnet using fixtures and test seams so it never changes the live policy.

**Tech Stack:** bash, curl (8.7, macOS), jq 1.7, perl (macOS system perl), `just` 1.50, Tailscale API v2 (OAuth client credentials).

**Scope:** Phase 1 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`.

**Codebase verified:** 2026-10-17

**Conventions used in every phase file of this plan:**
- `wt=/Users/cxreiff/Developer/dotfiles/.worktrees/cxagents-node` (this worktree, branch `cxagents-node`), `main=/Users/cxreiff/Developer/dotfiles` (main checkout).
- **Never use the `dotfiles` alias while executing this plan** — it points at the *main* checkout's justfile (`stow/base/.config/zsh/zshrc/aliases.zsh:21`). Run recipes as `just -f "$wt/justfile" <module> <recipe>`; below this is abbreviated `J` (`J="just -f $wt/justfile"`).
- The live system (LaunchDaemons, boot autostart) runs from `main`. Anything changed here reaches the live system only after the branch is merged; post-merge steps are called out explicitly.
- Scripts follow the repo's patterns: `#!/usr/bin/env bash` (lints use `#!/bin/bash`), `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `stacks/scripts/lib/check.sh` `pass`/`fail`/`warn`/`off` helpers, lints are `set -uo pipefail` (no `-e`, so every check runs) and end `[ "$__check_failed" -eq 0 ] || exit 1`, lint-tests generate single-violation fixtures in a trap-cleaned temp dir and use `mk`/`expect_only`/`expect_none` (model: `stacks/connectome/scripts/lint-test.sh`), smoke scripts name each check `check_acN_M` and print `pass "cxagents-node.ACN.M ..."` / `fail ...` (model: `stacks/connectome/scripts/smoke.sh`).
- **Never read or print `.env` values.** Key names only (`sed 's/=.*//'`). No `grep -r` over directories that contain `.env` files without `--exclude='.env*'`.
- shellcheck and Go are not installed on the host; do not add steps that need them on the host.
- **Scripts run under macOS `/bin/bash` 3.2.** With `set -u`, expanding an empty array as `"${arr[@]}"` aborts ("unbound variable"): guard with `${arr[@]+"${arr[@]}"}` or a length check. No `mapfile`, no `${var,,}`, no associative arrays.
- **Credential key names stay inside `tailscale/`.** No tracked file outside `tailscale/` and the planning docs (`docs/design-plans/`, `docs/implementation-plans/`, `docs/test-plans/`) may spell a Tailscale credential env/key name (the OAuth client keys, `TS_AUTHKEY`/`TS_AUTH_KEY`, `TS_CLIENT_ID`/`_SECRET`, `TS_API_KEY`, and from Phase 2 `TAILSCALE_PAT`) or a literal `tskey-…` value — in code (Go included), comments, READMEs and CLAUDE.md alike. Where code must name one (e.g. to unset it), build it from fragments (`"TS_" + "AUTHKEY"`) with a comment pointing at `tailscale/scripts/keyscan.sh`. **Before every commit from Task 8 of this phase on, run `tailscale/scripts/keyscan.sh --repo` (must exit 0).**
- Commit messages: `<area>: <imperative, lower-case>` (e.g. `tailscale: ...`, `stacks/adguard: ...`, `docs: ...`).

**Tailscale API facts this phase relies on** (live-probed during design on 2026-10-17 unless marked): OAuth exchange at `POST /api/v2/oauth/token` returns `{access_token, token_type, expires_in, scope}` and `scope` is the space-separated granted set (`logs:configuration:read` added implicitly); `/tailnet/-/` and `/tailnet/cxreiff.github/` both work; `GET /tailnet/{t}/acl` with `Accept: application/hujson` returns the exact stored bytes and an `ETag` that is the quoted SHA-256 of those bytes; `POST /tailnet/{t}/acl` with `If-Match: "<etag>"` stores the bytes exactly, a stale `If-Match` returns `412 precondition failed, invalid old hash` and changes nothing; validate works with the admin client; `/tailnet/-/keys` returns 403 for the admin client. **Not yet probed** (Task 6 probes it before relying on it): the response shape of `POST /tailnet/{t}/acl/validate` when a policy `tests` entry fails (documented as either non-2xx or 200 with a non-empty `message`; the code treats both as failure).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC1: Tailnet policy is code (Phase 1, tests extended in Phase 3)
- **cxagents-node.AC1.1 Success:** with `tailscale/policy.hujson` absent, `dotfiles tailscale policy-pull` writes it byte-identical to the live policy; `policy-status` then prints `in-sync`.
- **cxagents-node.AC1.2 Failure:** `policy-pull` refuses (non-zero, file untouched) when `policy.hujson` exists and `--force` is not given.
- **cxagents-node.AC1.3 Success:** `policy-push` of an edited file validates via the API, shows the diff, asks for confirmation, and afterwards `policy-status` is `in-sync` and the live ETag (quotes stripped) equals `shasum -a 256 tailscale/policy.hujson`.
- **cxagents-node.AC1.4 Failure:** `policy-push` aborts with "live policy changed; run policy-diff" and changes nothing when the live policy changed after the diff (412).
- **cxagents-node.AC1.5 Failure:** `policy-push` of a file that the lint rejects, or that the API rejects at validate (including a failing policy `tests`/`sshTests` entry), never POSTs.
- **cxagents-node.AC1.6 Edge:** `policy-diff` exits 0 with no output when repo and live are identical, non-zero with a unified diff otherwise.
- **cxagents-node.AC1.7 Success:** `policy.hujson` carries policy `tests` asserting members reach cxmini on tcp:22 and tcp:53/udp:53 and the serve ports; members are denied `tag:cxagents` tcp:3100 and tcp:80; `tag:cxagents` reaches nothing on cxmini. A push that would break any of these is rejected by validate. *(Phase 1: the member→cxmini tests only; the `tag:cxagents` tests are added in Phase 3.)*
- **cxagents-node.AC1.8 Success:** on a tailnet whose live policy differs from the repo (new tailnet), `policy-push --init` shows the diff, confirms, and pushes the repo policy without the If-Match precondition; plain `policy-push` refuses there with a hint to use `--init`.

### cxagents-node.AC2: Credentials are shared, declared and least-privilege (Phases 1, 3)
- **cxagents-node.AC2.1 Success:** `api.sh --client admin GET /tailnet/-/dns/nameservers` returns 200 using only `tailscale/.env`.
- **cxagents-node.AC2.2 Failure:** `api.sh` exits 2 with a hint naming `tailscale/.env.example` when credentials are missing or still placeholders, and exits 2 naming the replacement keys when it finds the deprecated `TS_OAUTH_CLIENT_*` keys; it never prints a secret or token.
- **cxagents-node.AC2.3 Failure:** the admin client is refused (403) on `/tailnet/-/keys`.
- **cxagents-node.AC2.5:** `tailscale/.env` is mode 0600 and gitignored; no file outside `tailscale/` contains a Tailscale client secret, PAT or auth key key name. *(Phase 1: OAuth-client and auth-key key names; the `TAILSCALE_PAT` name joins the scan in Phase 2, when the PAT is removed.)*

---

## Decisions recorded at planning time (deviations from / interpretations of the design)

1. **The `*`→`*` grant is replaced with `autogroup:member`→`autogroup:member` in Phase 1**, not Phase 3. The design's Phase 1 lint forbids a `*` grant source, which the pulled live policy has; the design's verified findings state the swap breaks nothing that exists today (all four nodes user-owned, no tags/routes/shared-in nodes). The Phase 1 policy `tests` guard against lockout. Phase 3 still adds everything cxagents-specific.
2. **What "a tailnet whose live policy differs from the repo (new tailnet)" means to plain `policy-push`:** plain push refuses unless the *live* policy is byte-identical to some committed version of `policy.hujson` in git history ("lineage"). That covers the new-tailnet case (live is Tailscale's default, never committed) and also refuses to silently overwrite an admin-console edit (drift); the refusal message points at `policy-diff` and `--init`. Normal adoption works: `policy-pull` → commit (live now matches a commit) → edit → plain `policy-push`.
3. **Test seams** (env vars, documented in script headers, used only by `smoke.sh`): `TAILSCALE_ENV_FILE` (api.sh credentials file), `--file F` (policy.sh/lint.sh target file; lineage uses F's git repo), `TS_POLICY_TEST_STALE_ETAG=1` (policy.sh sends an all-zero `If-Match` so the 412 path is exercised without touching live).
4. **`tailscale/scripts/keyscan.sh` owns the list of forbidden credential key names**, so that no file outside `tailscale/` has to spell them (AC2.5). Later lints/doctor call it. **AC2.5 is narrowed in one respect:** the repo scan excludes `tailscale/`, `archive/` (frozen) and the planning docs `docs/design-plans/`, `docs/implementation-plans/`, `docs/test-plans/` (they necessarily name the keys); operational docs such as `docs/migration-recovery.md` stay scanned.
5. The live `tailscale/.env` exists only in the main checkout (`$main/tailscale/.env`, mode 0600, keys `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`). The worktree gets **symlinks** to the main checkout's `.env` files (gitignored, never committed); every mode check uses `stat -L`.

---

<!-- START_TASK_1 -->
### Task 1: Worktree runtime links and symlink-safe `.env` mode check

**Verifies:** None (infrastructure).

**Files:**
- Create (untracked, gitignored symlinks): `$wt/tailscale/.env`, `$wt/stacks/{adguard,connectome,freshrss,homebridge,onecli,wallabag}/.env` → the main checkout's files.
- Modify: `stacks/scripts/doctor.sh:404` — `mode=$(stat -f %Lp "$actual")` → `mode=$(stat -L -f %Lp "$actual")`.

**Step 1: Create the links (executor runs; links only, no reads)**

```bash
wt=/Users/cxreiff/Developer/dotfiles/.worktrees/cxagents-node
main=/Users/cxreiff/Developer/dotfiles
mkdir -p "$wt/tailscale"
ln -sfn "$main/tailscale/.env" "$wt/tailscale/.env"
for s in adguard connectome freshrss homebridge onecli wallabag; do
    [ -f "$main/stacks/$s/.env" ] && ln -sfn "$main/stacks/$s/.env" "$wt/stacks/$s/.env"
done
cd "$wt" && git status --short   # must show nothing new: .env is gitignored
git check-ignore -q tailscale/.env && echo "OK: tailscale/.env ignored"
```
Expected: `git status --short` lists no `.env` paths; `OK: tailscale/.env ignored`.

**Step 2: Make doctor's Check B follow symlinks**

In `stacks/scripts/doctor.sh` Check B (currently line 404), change `stat -f %Lp "$actual"` to `stat -L -f %Lp "$actual"` (on macOS, `-L` reports the target's mode; without it a symlink reports 755).

**Step 3: Verify**

```bash
cd "$wt" && ./stacks/scripts/doctor.sh 2>&1 | grep -E '\.env (mode|has)'
```
Expected: one `[OK]   <stack>/.env mode 0600` line per stack with a `.env`, no FAIL among them.

**Step 4: Commit**

```bash
git add stacks/scripts/doctor.sh
git commit -m "stacks/doctor: .env mode check follows symlinks (stat -L)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Rename the live admin-client keys (operator-approved write)

**Verifies:** None (operator step; enables AC2.1).

**Files:** `$main/tailscale/.env` (untracked secret file; key *names* only are changed).

The design (Phase 1 components) renames the probe-era keys `TS_OAUTH_CLIENT_ID/SECRET` to `TS_ADMIN_CLIENT_ID/SECRET`. This writes to a secret file outside the worktree: **ask the user before running Step 1**, and tell them they must update the password-manager escrow copy of `tailscale/.env` the same way.

**Step 1: Rename (executor runs only after the user agrees; values are never read or printed)**

```bash
f=/Users/cxreiff/Developer/dotfiles/tailscale/.env
sed -i '' -e 's/^TS_OAUTH_CLIENT_ID=/TS_ADMIN_CLIENT_ID=/' -e 's/^TS_OAUTH_CLIENT_SECRET=/TS_ADMIN_CLIENT_SECRET=/' "$f"
chmod 600 "$f"
sed 's/=.*//' "$f"; stat -f %Lp "$f"
```
Expected: key names `TS_ADMIN_CLIENT_ID`, `TS_ADMIN_CLIENT_SECRET`; mode `600`.

**Step 2: Operator** updates the escrow copy (password manager) with the renamed keys.

**Commit:** none (no repo change).
<!-- END_TASK_2 -->

<!-- START_SUBCOMPONENT_A (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: Module skeleton — root `mod tailscale`, declarations, `.env.example`, conf helper

**Verifies:** None (infrastructure).

**Files:**
- Modify: `justfile` (root, currently `mod stacks` / `mod stow` / `default`) — add `mod tailscale` after `mod stow`.
- Create: `tailscale/justfile`, `tailscale/tailnet.conf`, `tailscale/clients.conf`, `tailscale/.env.example`, `tailscale/scripts/lib/conf.sh`.

**Step 1: Root justfile** becomes:
```just
mod stacks
mod stow
mod tailscale

default:
    @just --list
```

**Step 2: `tailscale/tailnet.conf`**
```
# Non-secret tailnet identity. Read by every script that needs it; never hardcode these.
TAILNET=cxreiff.github          # API name (tailscale status --json .CurrentTailnet.Name)
TAILNET_DNS_SUFFIX=faun-fir.ts.net
```

**Step 3: `tailscale/clients.conf`** (the authkeys row is added in Phase 3, when that client is created)
```
# Expected OAuth clients, compared by `dotfiles stacks doctor` against each
# token exchange's granted `scope` (exact set, extra scopes included) and tags.
# Create each client in the admin console exactly as declared (tailscale/README.md "Clients").
# client     scopes (exact set granted at exchange)                                              tags
admin        devices:core:read devices:posture_attributes dns logs:configuration:read policy_file   -
```

**Step 4: `tailscale/.env.example`**
```
# tailscale/.env — OAuth client credentials (tailnet-owned, scoped, non-expiring).
# cp .env.example .env && chmod 600 .env; fill in from the admin console
# (https://login.tailscale.com/admin/settings/oauth). Escrow the whole file in
# the password manager. Only tailscale/scripts/api.sh reads these values.

# dotfiles-admin: scopes as in clients.conf (policy, DNS, device reads)
TS_ADMIN_CLIENT_ID=CHANGE_ME
TS_ADMIN_CLIENT_SECRET=CHANGE_ME
```

**Step 5: `tailscale/scripts/lib/conf.sh`** (source-only)
```bash
#!/usr/bin/env bash
# tailscale/scripts/lib/conf.sh — source-only. Sets TAILNET, TAILNET_DNS_SUFFIX
# from tailscale/tailnet.conf (KEY=VALUE, `#` comments). TAILSCALE_TAILNET_CONF
# overrides the file (tests).
ts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ts_conf="${TAILSCALE_TAILNET_CONF:-${ts_root}/tailnet.conf}"
conf_get() { sed -n "s/^$1=\([^[:space:]#]*\).*/\1/p" "$ts_conf" | tail -1; }
TAILNET="$(conf_get TAILNET)"
TAILNET_DNS_SUFFIX="$(conf_get TAILNET_DNS_SUFFIX)"
```

**Step 6: `tailscale/justfile`** (recipes refer to scripts created in Tasks 4–8; just does not check that scripts exist at parse time)
```just
default:
    @just --list

# Write the live tailnet policy to policy.hujson (refuses if it exists, unless --force)
policy-pull *args:
    @./scripts/policy.sh pull {{args}}

# Unified diff live -> repo; exit 0 and no output when identical
policy-diff:
    @./scripts/policy.sh diff

# Lint -> API validate (runs policy tests) -> diff -> confirm -> push with If-Match (--init: new tailnet)
policy-push *args:
    @./scripts/policy.sh push {{args}}

# in-sync / drift (repo SHA-256 vs live ETag)
policy-status:
    @./scripts/policy.sh status

# Static invariants on policy.hujson (also run by `dotfiles stacks doctor`)
lint:
    @./scripts/lint.sh

# Prove each lint fails on a fixture violating exactly its invariant
lint-test:
    @./scripts/lint-test.sh

# Live checks against the tailnet (never changes the live policy)
smoke:
    @./scripts/smoke.sh
```

**Step 7: Verify**
```bash
cd "$wt" && just -f "$wt/justfile" --list --list-submodules 2>/dev/null | grep -A9 'tailscale:' || just -f "$wt/justfile" tailscale --list
bash -c 'source tailscale/scripts/lib/conf.sh; echo "$TAILNET $TAILNET_DNS_SUFFIX"'
```
Expected: the tailscale recipes are listed; `cxreiff.github faun-fir.ts.net`.

**Step 8: Commit**
```bash
git add justfile tailscale/justfile tailscale/tailnet.conf tailscale/clients.conf tailscale/.env.example tailscale/scripts/lib/conf.sh
git commit -m "tailscale: module skeleton (tailnet.conf, clients.conf, .env.example)"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: `api.sh` — the only reader of the OAuth secrets

**Verifies:** cxagents-node.AC2.1, cxagents-node.AC2.2, cxagents-node.AC2.3 (operationally here; re-checked by `smoke.sh` in Task 8).

**Files:**
- Create: `tailscale/scripts/api.sh` (mode 755).

**Implementation:** exactly this contract (design "`tailscale/` — the tailnet, declared"): per-invocation token exchange (nothing cached on disk), the secret is fed to curl on **stdin** (`--data-urlencode client_secret@-`), never on argv; the bearer token goes in a header read from a process-substitution file (`-H @<(...)`), never on argv; exit 2 for credential problems (nothing sent), exit 3 for HTTP/API errors.

```bash
#!/usr/bin/env bash
# tailscale/scripts/api.sh — authenticated Tailscale API calls. The ONLY code
# that reads the OAuth client secrets (tailscale/.env).
#
#   api.sh [--client admin|authkeys] [--tags "tag:a tag:b"] METHOD PATH [curl args...]
#       PATH is relative to https://api.tailscale.com/api/v2 (e.g. /tailnet/-/acl).
#       stdout: response body (also on an HTTP error, for callers that parse it).
#   api.sh [--client NAME] [--tags T] --granted-scopes
#       stdout: the space-separated `scope` of a fresh token exchange.
#
# Exit: 0 on 2xx; 2 missing/placeholder/deprecated credentials (nothing sent);
#       3 HTTP/API error ("<what> -> HTTP <code>: <message>" on stderr).
# Never prints a secret or token: the secret reaches curl on stdin, the token
# in a header file. TAILSCALE_ENV_FILE overrides tailscale/.env (tests).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${TAILSCALE_ENV_FILE:-${SCRIPT_DIR}/../.env}"
base="https://api.tailscale.com/api/v2"

client=admin tags="" mode=call
while [ $# -gt 0 ]; do
    case "$1" in
        --client) client="${2:-}"; shift 2 ;;
        --tags) tags="${2:-}"; shift 2 ;;
        --granted-scopes) mode=scopes; shift ;;
        *) break ;;
    esac
done
case "$client" in
    admin|authkeys) ;;
    *) echo "api.sh: unknown client '${client}' (admin|authkeys)" >&2; exit 2 ;;
esac
if [ "$mode" = call ] && [ $# -lt 2 ]; then
    echo "usage: api.sh [--client admin|authkeys] [--tags T] METHOD PATH [curl args...]" >&2
    exit 2
fi

hint="see tailscale/.env.example and tailscale/README.md (Clients)"
if [ ! -f "$env_file" ]; then
    echo "api.sh: ${env_file} missing — ${hint}" >&2; exit 2
fi
if grep -qE '^TS_OAUTH_CLIENT_(ID|SECRET)=' "$env_file"; then
    echo "api.sh: ${env_file} has deprecated TS_OAUTH_CLIENT_ID/TS_OAUTH_CLIENT_SECRET — rename them to TS_ADMIN_CLIENT_ID/TS_ADMIN_CLIENT_SECRET (and the escrow copy)" >&2
    exit 2
fi
prefix="TS_$(printf '%s' "$client" | tr '[:lower:]' '[:upper:]')_CLIENT"
val() { sed -n "s/^$1=//p" "$env_file" | tail -1; }
id="$(val "${prefix}_ID")"
secret="$(val "${prefix}_SECRET")"
if [ -z "$id" ] || [ -z "$secret" ] || [[ "${id}${secret}" == *CHANGE_ME* ]]; then
    echo "api.sh: ${prefix}_ID / ${prefix}_SECRET missing or placeholder in ${env_file} — ${hint}" >&2
    exit 2
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

ex=(-sS -o "$tmp/tok" -w '%{http_code}'
    --data-urlencode "grant_type=client_credentials"
    --data-urlencode "client_id=${id}"
    --data-urlencode "client_secret@-")
[ -n "$tags" ] && ex+=(--data-urlencode "tags=${tags}")
code="$(printf '%s' "$secret" | curl "${ex[@]}" "${base}/oauth/token")" || {
    echo "api.sh: token exchange failed (network)" >&2; exit 3; }
unset secret
case "$code" in
    2??) ;;
    *) echo "api.sh: token exchange (${client}) -> HTTP ${code}: $(jq -r '.message // .error_description // .error // empty' "$tmp/tok" 2>/dev/null)" >&2
       exit 3 ;;
esac
if [ "$mode" = scopes ]; then
    jq -r '.scope // empty' "$tmp/tok"; exit 0
fi
token="$(jq -r '.access_token // empty' "$tmp/tok")"
rm -f "$tmp/tok"
[ -n "$token" ] || { echo "api.sh: token exchange returned no access_token" >&2; exit 3; }

method="$1" path="$2"; shift 2
code="$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$method" \
    -H @<(printf 'Authorization: Bearer %s\n' "$token") "$@" "${base}${path}")" || {
    echo "api.sh: ${method} ${path}: request failed (network)" >&2; exit 3; }
cat "$tmp/body"
case "$code" in
    2??) exit 0 ;;
    *) echo "api.sh: ${method} ${path} -> HTTP ${code}: $(jq -r '.message // empty' "$tmp/body" 2>/dev/null)" >&2
       exit 3 ;;
esac
```

**Step 1:** Create the file as above; `chmod 755 tailscale/scripts/api.sh`.

**Step 2: Verify operationally (live; read-only API calls)**
```bash
cd "$wt/tailscale/scripts"
./api.sh --client admin GET /tailnet/-/dns/nameservers | jq -c .; echo "rc=$?"     # AC2.1
./api.sh --client admin --granted-scopes                                            # matches clients.conf admin row
./api.sh --client admin GET /tailnet/-/keys >/dev/null; echo "rc=$?"                # AC2.3
TAILSCALE_ENV_FILE=/nonexistent ./api.sh GET /tailnet/-/devices; echo "rc=$?"       # AC2.2
```
Expected: JSON with `.dns` and `rc=0`; a scope string equal (as a set) to `devices:core:read devices:posture_attributes dns logs:configuration:read policy_file`; stderr `... /tailnet/-/keys -> HTTP 403: ...` and `rc=3`; stderr naming `tailscale/.env.example` and `rc=2`. If the token exchange fails with an error mentioning `grant_type`, remove that one `--data-urlencode "grant_type=client_credentials"` line (the design probe exchanged successfully; this is the only parameter not taken from the probe) and re-run.

Argv safety is by construction (review the diff): the secret reaches curl only through `printf` (a builtin, never on a process's argv) into `--data-urlencode client_secret@-`, and the token only through the `-H @<(…)` file. **Never run `api.sh` under `bash -x`**: xtrace prints the secret and token.

**Step 3: Commit**
```bash
git add tailscale/scripts/api.sh
git commit -m "tailscale: api.sh (OAuth exchange per call; secret on stdin, token in header file)"
```
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 5-6) -->
<!-- START_TASK_5 -->
### Task 5: HuJSON→JSON filter, policy lint and lint-test

**Verifies:** cxagents-node.AC1.5 (lint half: a lint-rejected file never reaches validate/POST is enforced in Task 6; this task makes the lint).

**Files:**
- Create: `tailscale/scripts/lib/hujson2json.pl`, `tailscale/scripts/lint.sh` (755), `tailscale/scripts/lint-test.sh` (755).

**Implementation — `lib/hujson2json.pl`** (string-aware; two passes: strip comments, then drop trailing commas):
```perl
#!/usr/bin/perl
# tailscale/scripts/lib/hujson2json.pl — HuJSON (JSON + // and /* */ comments
# + trailing commas) on stdin -> JSON on stdout. String-aware. Exit 1 on an
# unterminated string or comment. Used by lint.sh (no HuJSON tool is installed).
use strict; use warnings;
local $/; my $s = <STDIN>; $s = '' unless defined $s;

sub scan {   # calls $cb->($char, $index) outside strings; copies strings verbatim
    my ($in, $cb) = @_; my $out = ''; my $n = length $in;
    for (my $i = 0; $i < $n; $i++) {
        my $c = substr($in, $i, 1);
        if ($c eq '"') {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($in, $j, 1);
                if ($d eq '\\') { $j += 2; next }
                last if $d eq '"';
                $j++;
            }
            die "hujson2json: unterminated string\n" if $j >= $n;
            $out .= substr($in, $i, $j - $i + 1); $i = $j; next;
        }
        my ($emit, $skip) = $cb->($c, $i, $in);
        $out .= $emit; $i += $skip;
    }
    return $out;
}

my $t = scan($s, sub {
    my ($c, $i, $in) = @_;
    my $nx = substr($in, $i + 1, 1);
    if ($c eq '/' && $nx eq '/') {
        my $j = index($in, "\n", $i); $j = length($in) if $j < 0;
        return ('', $j - $i - 1);
    }
    if ($c eq '/' && $nx eq '*') {
        my $j = index($in, '*/', $i + 2); die "hujson2json: unterminated comment\n" if $j < 0;
        return (' ', $j + 1 - $i);
    }
    return ($c, 0);
});
my $u = scan($t, sub {
    my ($c, $i, $in) = @_;
    if ($c eq ',') {
        my $rest = substr($in, $i + 1);
        return ('', 0) if $rest =~ /\A\s*[\]}]/;
    }
    return ($c, 0);
});
print $u;
```

**Implementation — `lint.sh`** (model: `stacks/connectome/scripts/lint.sh` header, arg loop, fail-closed parse, numbered invariants):
```bash
#!/bin/bash
# tailscale/scripts/lint.sh — static invariants on the tailnet policy.
# Usage: lint.sh [--file F]   (default tailscale/policy.hujson)
# Exit: 0 all pass; 1 any FAIL; 2 usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../stacks/scripts/lib/check.sh
source "${repo_root}/stacks/scripts/lib/check.sh"

file="${SCRIPT_DIR}/../policy.hujson"
while [ $# -gt 0 ]; do
    case "$1" in
        --file) file="$2" ;;
        *) echo "lint: unknown argument $1" >&2; exit 2 ;;
    esac
    shift 2
done

j="$(perl "${SCRIPT_DIR}/lib/hujson2json.pl" < "$file" 2>/dev/null | jq -c . 2>/dev/null)"
if [ -z "$j" ]; then
    fail "policy invariant 0: ${file} does not parse as HuJSON"
    exit 1
fi
pass "policy invariant 0: parses"
pj() { jq -e "$1" <<<"$j" >/dev/null 2>&1; }

# 1 — no grant or ACL source is "*", a tag, or autogroup:tagged
if pj '[(.grants[]?.src[]?), (.acls[]?.src[]?)]
       | all(. != "*" and . != "autogroup:tagged" and (startswith("tag:") | not))'; then
    pass "policy invariant 1: no *, tag or autogroup:tagged grant/ACL source"
else
    fail "policy invariant 1: a grant/ACL source is *, a tag, or autogroup:tagged"
fi

# 2 — every tag referenced anywhere is declared in tagOwners
undeclared="$(jq -r '((.tagOwners // {}) | keys) as $own
    | [.. | strings | select(test("^tag:[A-Za-z0-9-]+")) | capture("^(?<t>tag:[A-Za-z0-9-]+)").t]
    | unique - $own | join(" ")' <<<"$j")"
if [ -z "$undeclared" ]; then
    pass "policy invariant 2: every used tag is in tagOwners"
else
    fail "policy invariant 2: tags not in tagOwners: ${undeclared}"
fi

# 3 — policy tests present (they guard against lockout at validate time)
if pj '(.tests | type == "array" and length > 0)'; then
    pass "policy invariant 3: tests present"
else
    fail "policy invariant 3: no policy tests"
fi

[ "$__check_failed" -eq 0 ] || exit 1
exit 0
```

**Implementation — `lint-test.sh`** (model: `stacks/connectome/scripts/lint-test.sh` `mk`/`expect_only`/`expect_none` helpers and final summary). Baseline: `perl lib/hujson2json.pl < tailscale/policy.hujson > $tmpdir/base.json` (JSON is valid HuJSON, so jq-mutated fixtures feed straight into `lint.sh --file`). Fixtures, each must FAIL exactly the named invariant (`expect_only LABEL 'policy invariant N:' --file F`) or no invariant (`expect_none`):
- `baseline` → `expect_none` on the real `tailscale/policy.hujson`.
- `inv0-unparseable` → file containing `{ "grants": [ ` → only `policy invariant 0:`.
- `inv1-star-src` → `.grants += [{"src":["*"],"dst":["*"],"ip":["*"]}]`.
- `inv1-tag-src` → `.tagOwners["tag:x"] = ["autogroup:admin"] | .grants += [{"src":["tag:x"],"dst":["autogroup:member"],"ip":["*"]}]` (declared, so only invariant 1 fails).
- `inv1-tagged-src` → src `autogroup:tagged`.
- `inv1-acl-star` → `.acls = [{"action":"accept","src":["*"],"dst":["*:*"]}]`.
- `inv2-undeclared` → `.grants += [{"src":["autogroup:member"],"dst":["tag:nope"],"ip":["*"]}]`.
- `inv3-no-tests` → `del(.tests)`.
- `hujson-features` (`expect_none`) → the real file with a line comment containing quotes and a comma, and a block comment, inserted after its first `{` (`perl -0pe 's/\{/{\n\t\/\/ a "quoted", comment,\n\t\/* block *\/\n/' tailscale/policy.hujson > "$tmpdir/hj.hujson"`).
- `hujson-strings` (direct filter check, not via lint) → `printf '{"a": ["http://x",],}' | perl lib/hujson2json.pl | jq -e '.a == ["http://x"]'` must succeed → `PASS lint-fixture hujson-strings`.

The baseline fixtures need `tailscale/policy.hujson`, which Task 7 creates; **run lint/lint-test in Task 7 Step 5**, not here.

**Step 1:** Create the three files; `chmod 755 tailscale/scripts/lint.sh tailscale/scripts/lint-test.sh`.

**Step 2: Verify the filter in isolation**
```bash
cd "$wt/tailscale/scripts"
printf '{ // c\n "a": "x//y", /* b */ "b": [1,2,], }\n' | perl lib/hujson2json.pl | jq -c .
printf '{"a": "unterminated' | perl lib/hujson2json.pl; echo "rc=$?"
```
Expected: `{"a":"x//y","b":[1,2]}`; an `unterminated string` message and `rc=255` (non-zero).

**Step 3: Commit**
```bash
git add tailscale/scripts/lib/hujson2json.pl tailscale/scripts/lint.sh tailscale/scripts/lint-test.sh
git commit -m "tailscale: policy lint (no */tag source, tags declared, tests present) + lint-test"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: `policy.sh` — pull, diff, status, push

**Verifies:** cxagents-node.AC1.1, AC1.2, AC1.3, AC1.4, AC1.5, AC1.6, AC1.8 (behaviour; exercised in Tasks 7–8).

**Files:**
- Create: `tailscale/scripts/policy.sh` (755).

**Step 1: Probe the validate failure shape (live, read-only — validate never stores)**
```bash
cd "$wt/tailscale/scripts"
printf '{"grants":[{"src":["autogroup:member"],"dst":["autogroup:member"],"ip":["*"]}],"tests":[{"src":"cxreiff@github","deny":["100.70.208.32:22"]}]}' >/tmp/claude-probe-policy.json
./api.sh POST /tailnet/cxreiff.github/acl/validate -H 'Content-Type: application/hujson' --data-binary @/tmp/claude-probe-policy.json; echo "rc=$?"
rm -f /tmp/claude-probe-policy.json
```
Expected: either `rc=3` (non-2xx) or `rc=0` with a body whose `.message` is non-empty (e.g. `test(s) failed`). Record which in the commit message body. The `push` code below treats **both** as a validate failure, so no code change is needed either way; if the response is `rc=0` with an **empty** `.message`, STOP — validate does not run tests the way the design assumes; ask the user.

**Step 2: Create `policy.sh`:**
```bash
#!/usr/bin/env bash
# tailscale/scripts/policy.sh — the tailnet policy as code.
#   policy.sh [--file F] pull [--force] | diff | push [--init] | status
# F defaults to tailscale/policy.hujson. push reads its confirmation from stdin.
#
# push: lint -> API validate (runs the policy tests) -> fetch live + ETag -> diff
#       -> confirm -> POST with If-Match = that ETag. Plain push refuses unless
#       the live policy equals some committed version of F (git history); that
#       covers a new tailnet and an admin-console edit. --init skips that check
#       and the If-Match precondition (new tailnet, after showing the diff).
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
    if in_sync; then
        echo "policy: pushed; in-sync (sha256 $(sha "$file"))"
        git -C "$(dirname "$file")" diff --quiet HEAD -- "$(basename "$file")" 2>/dev/null \
            || echo "policy: commit $(basename "$file") now — the next plain push requires live to match a committed version" >&2
    else echo "policy: pushed, but live differs from $(basename "$file") (run policy-diff)" >&2; exit 1; fi
    ;;
*)
    echo "usage: policy.sh [--file F] pull [--force] | diff | push [--init] | status" >&2; exit 2 ;;
esac
```

**Step 3: Commit**
```bash
chmod 755 tailscale/scripts/policy.sh
git add tailscale/scripts/policy.sh
git commit -m "tailscale: policy.sh pull/diff/push/status (validate, If-Match, git-lineage guard, --init)"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_7 -->
### Task 7: Adopt the live policy, add `hosts`, member tests, member→member grant; push

**Verifies:** cxagents-node.AC1.1, AC1.3, AC1.6, AC1.7 (member half).

**Files:**
- Create: `tailscale/policy.hujson` (pulled), then modify it.

**Step 1: Pull and check (AC1.1, AC1.6)**
```bash
cd "$wt"
J="just -f $wt/justfile"
$J tailscale policy-pull
$J tailscale policy-status          # expect: in-sync
$J tailscale policy-diff; echo "rc=$?"   # expect: no output, rc=0
git add tailscale/policy.hujson
git commit -m "tailscale: adopt live tailnet policy (policy-pull, byte-identical)"
```
Expected: `in-sync`; `rc=0` with no diff output. Inspect the file: it should match the design's verified findings (a `*`→`*` grant, a Taildrive grant `autogroup:member`→`autogroup:self`, two SSH rules, one `nodeAttrs`). If it does not, STOP and tell the user what differs.

**Step 2: Edit `tailscale/policy.hujson`** (keep every existing comment; HuJSON style matches the file — tabs, trailing commas):
1. Insert at the top, inside the first `{`: `// Source of truth: tailscale/policy.hujson in the dotfiles repo. Edit there and` / `// push with \`dotfiles tailscale policy-push\`; admin-console edits show as drift in doctor.`
2. Add `"hosts": { "cxmini": "100.70.208.32" },` with the comment `// cxmini's node IP; update after a node-IP change (see CLAUDE.md).`
3. Replace the grant `{"src": ["*"], "dst": ["*"], "ip": ["*"]}` with `{"src": ["autogroup:member"], "dst": ["autogroup:member"], "ip": ["*"]}` and the comment `// Members reach each other on all ports (today's behaviour). No grant has *, a tag or autogroup:tagged as source (lint).`
4. Add (replacing the default's commented-out `tests` example if present):
```hujson
	// Lockout guards: validate rejects any push that breaks these.
	"tests": [
		{
			"src":    "cxreiff@github",
			"proto":  "tcp",
			"accept": ["cxmini:22", "cxmini:53", "cxmini:8189", "cxmini:8689", "cxmini:8765", "cxmini:8766", "cxmini:8767", "cxmini:8768"],
		},
		{
			"src":    "cxreiff@github",
			"proto":  "udp",
			"accept": ["cxmini:53"],
		},
	],
```
(`cxreiff@github` is the tailnet's only user, from `tailscale status --json .User[].LoginName`; serve ports from `CLAUDE.md`/design: AdGuard 8689 and 8189, FreshRSS 8765, Wallabag 8766, Homebridge 8767, connectome WebUI 8768.)

**Step 3: Lint**
```bash
$J tailscale lint
```
Expected: four `[OK]` lines (`policy invariant 0`–`3`).

**Step 4: Push (live write — ask the user before answering `y`)**

Show the user the diff that `policy-push` prints and get explicit approval before answering. Then:
```bash
$J tailscale policy-push            # answer y at the prompt only after user approval
$J tailscale policy-status          # expect: in-sync
h=$(mktemp); tailscale/scripts/api.sh GET /tailnet/cxreiff.github/acl -H 'Accept: application/hujson' -D "$h" >/dev/null
live_etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' "$h" | tr -d '\r"'); rm -f "$h"
[ "$live_etag" = "$(shasum -a 256 tailscale/policy.hujson | cut -d' ' -f1)" ] && echo "OK: ETag == sha256"
```
Expected (AC1.3): the diff is shown, the prompt appears, then `policy: pushed; in-sync (sha256 …)`, `in-sync`, `OK: ETag == sha256`.

Then ask the user to confirm connectivity is unchanged from one other device (open `https://cxmini.faun-fir.ts.net:8765` from cxmacbook or cxphone).

**Step 5: Lint-test (needs the committed policy)**
```bash
$J tailscale lint-test
```
Expected: `PASS lint-fixture ...` for every fixture and `All fixtures passed`.

**Step 6: Commit**
```bash
git add tailscale/policy.hujson
git commit -m "tailscale: policy hosts + member lockout tests; member->member replaces *->*"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: `keyscan.sh` and the tailscale `smoke.sh`

**Verifies:** cxagents-node.AC1.1, AC1.2, AC1.4, AC1.5, AC1.6, AC1.7 (member half), AC1.8, AC2.1, AC2.2, AC2.3, AC2.5 (Phase 1 scope).

**Files:**
- Create: `tailscale/scripts/keyscan.sh` (755), `tailscale/scripts/smoke.sh` (755).

**Implementation — `keyscan.sh`:**
```bash
#!/usr/bin/env bash
# tailscale/scripts/keyscan.sh — owns the list of Tailscale credential key
# names, so no file outside tailscale/ has to spell them.
#   keyscan.sh --names   read KEY names on stdin; print the forbidden ones (exit 1 if any)
#   keyscan.sh --repo    print tracked files outside tailscale/, archive/ and the
#                        planning docs (docs/{design,implementation,test}-plans/)
#                        that mention one, or a literal tskey- value (exit 1 if any)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
names='TS_(ADMIN|AUTHKEYS|OAUTH)_CLIENT_(ID|SECRET)|TS_AUTH_?KEY|TS_CLIENT_(ID|SECRET)|TS_API_KEY'
case "${1:-}" in
--names)
    hits="$(grep -Ex "$names" || true)"
    [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
--repo)
    hits="$(git -C "$repo_root" ls-files | grep -Ev '^(tailscale|archive|docs/(design|implementation|test)-plans)/' \
        | (cd "$repo_root" && xargs grep -lE "${names}|tskey-(api|auth|client)-[A-Za-z0-9]{6,}-[A-Za-z0-9]{10,}" 2>/dev/null) || true)"
    [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
*) echo "usage: keyscan.sh --names|--repo" >&2; exit 2 ;;
esac
```

**Implementation — `smoke.sh`** (model: `stacks/connectome/scripts/smoke.sh`: `set -euo pipefail`, sources `stacks/scripts/lib/check.sh`, one `check_acN_M` function per AC, a run list, `[ "$__check_failed" -eq 0 ] || exit 1`). It must never change the live policy: every push it performs is either declined, stopped by lint/validate, or sent with a stale `If-Match`. Temp dir trap-cleaned. Check list:
- `check_ac2_1` — `api.sh --client admin GET /tailnet/-/dns/nameservers` exits 0 and `jq -e '.dns|type=="array"'`.
- `check_ac2_2` — three fixture env files in the temp dir: (a) path that doesn't exist, (b) `TS_ADMIN_CLIENT_ID=CHANGE_ME` / `TS_ADMIN_CLIENT_SECRET=CHANGE_ME`, (c) `TS_OAUTH_CLIENT_ID=x` / `TS_OAUTH_CLIENT_SECRET=y`. For each, `TAILSCALE_ENV_FILE=... api.sh GET /tailnet/-/devices` must exit 2; (a) and (b) stderr contains `tailscale/.env.example`; (c) stderr contains `TS_ADMIN_CLIENT_ID`. Then, for the real `.env`, capture stdout+stderr of a successful call and of `--granted-scopes` and assert neither contains the value of `TS_ADMIN_CLIENT_SECRET` (read into a variable with `sed -n 's/^TS_ADMIN_CLIENT_SECRET=//p'`, never echoed) nor the substring `tskey-`. *(This is the one place the smoke reads a secret value, only to prove it is absent from output; it never prints it.)*
- `check_ac2_3` — `api.sh --client admin GET /tailnet/-/keys` exits 3 and stderr contains `HTTP 403`.
- `check_ac2_5` — `stat -L -f %Lp tailscale/.env` is `600`; `git check-ignore -q tailscale/.env`; `keyscan.sh --repo` exits 0.
- `check_ac1_6` — `policy.sh diff` exits 0 with empty stdout (repo and live identical after Task 7); and on a temp copy of `policy.hujson` with `// smoke diff` appended, `policy.sh --file "$tmp/d.hujson" diff` exits non-zero and its output starts with the unified-diff headers (`--- live (cxreiff.github)` / `+++ repo (d.hujson)`) and contains `+// smoke diff`.
- `check_ac1_1` — in a temp dir, `policy.sh --file "$tmp/p.hujson" pull` → file exists; `cmp` with a fresh `api.sh GET .../acl -H 'Accept: application/hujson'`; `policy.sh --file "$tmp/p.hujson" status` prints `in-sync`.
- `check_ac1_2` — `policy.sh --file "$tmp/p.hujson" pull` again (no `--force`) exits non-zero; sha256 of the file unchanged.
- `check_ac1_3` — live ETag (quotes stripped) equals `shasum -a 256 tailscale/policy.hujson`, and `policy.sh status` is `in-sync` (post-condition of the Task 7 push).
- `check_ac1_5_lint` — temp git repo (`git init -q`), commit a copy of live as `policy.hujson`, then rewrite it to add a `*`-source grant; `printf 'y\n' | policy.sh --file … push` exits 1, output contains `lint failed; not pushing`; live ETag unchanged.
- `check_ac1_5_validate` (also AC1.7) — same temp repo; restore the copy and remove the member→member grant (jq on `hujson2json.pl` output, written as JSON): lint passes, validate fails because the member→cxmini tests fail; output contains `validate failed; not pushing`; live ETag unchanged.
- `check_ac1_4` — same temp repo with live committed; append the line `// smoke` (lint and validate pass, bytes differ); `printf 'y\n' | TS_POLICY_TEST_STALE_ETAG=1 policy.sh --file … push` exits 1 with `live policy changed; run policy-diff`; live ETag unchanged.
- `check_ac1_8_refuse` — new temp git repo whose only commit is a policy that is *not* live (live + `// other lineage` line, committed); edit again; plain `push` (stdin `y`) exits 1 and stderr contains `--init`; live ETag unchanged.
- `check_ac1_8_init` — same repo; `printf 'n\n' | policy.sh --file … push --init` shows a diff, prompt contains `WITHOUT If-Match (--init)`, exits 1 with `aborted; nothing pushed`; live ETag unchanged. *(The actual `--init` push is exercised only on a new tailnet; the design's Phase 1 "Done when" requires running it up to the prompt and declining.)*

Every check that touches the live tailnet ends by asserting the live ETag equals the value captured at smoke start; a mismatch is a FAIL with the message `live policy changed during smoke — run policy-diff`.

Add the recipe line already present in `tailscale/justfile` (`smoke`).

**Step 1:** Create both files; `chmod 755`. (The `tskey-` value pattern requires a real key shape — `tskey-<kind>-<id>-<secret>` — so the `tskey-api-CHANGE_ME` placeholders still present in `stacks/adguard/` until Phase 2 do not match; the PAT *name* joins the list in Phase 2.)

**Step 2: Verify**
```bash
cd "$wt"; J="just -f $wt/justfile"
tailscale/scripts/keyscan.sh --repo; echo "rc=$?"     # rc=0, no output
$J tailscale smoke
```
Expected: one `[OK]` per check (AC ids in the text), no `[FAIL]`, exit 0.

**Step 3: Commit**
```bash
git add tailscale/scripts/keyscan.sh tailscale/scripts/smoke.sh
git commit -m "tailscale: keyscan (owns credential key names) + live smoke (AC1, AC2.1-2.3, AC2.5)"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: `tailscale/README.md`

**Verifies:** None (documentation; AC10.2 is completed in Phase 7).

**Files:**
- Create: `tailscale/README.md`.

**Content** (operational, not decorative; match the tone of `stacks/onecli/README.md`):
1. `# tailscale` — what the module owns (policy, tailnet identity, OAuth clients; tailnet-global; stacks read it, it never references a stack) and the recipe list (`policy-pull|diff|push|status`, `lint`, `lint-test`, `smoke`).
2. `## Files` — table: `policy.hujson` (source of truth, incl. `tests`), `tailnet.conf`, `clients.conf`, `.env` / `.env.example` (0600, gitignored, escrowed; only `scripts/api.sh` reads it), `scripts/`.
3. `## Bootstrap paths` — **(a) adopting an existing tailnet**: create `dotfiles-admin`, fill `.env`, `policy-pull`, commit, edit, `policy-push`. **(b) a new tailnet**: create `dotfiles-admin`, fill `.env`, `policy-push --init` (shows the diff against the default policy, confirms, pushes without `If-Match`). Explain the lineage rule (commit `policy.hujson` right after every successful push — `policy-push` reminds you): plain `policy-push` refuses when live matches no committed version (new tailnet, or an admin-console edit — resolve with `policy-diff`, then either `policy-pull --force` + commit to adopt the console edit, or `policy-push --init` to overwrite it).
4. `## Clients` — creation order (admin first; authkeys only after the policy declaring `tag:cxagents` is pushed — Phase 3 fills in its row), exact scopes from `clients.conf`, where to create (https://login.tailscale.com/admin/settings/oauth), that the client secret is shown once, copy into `.env` and the escrow.
5. `## Tailnet settings checklist` — numbered, for what the API cannot set: 1. MagicDNS on; 2. HTTPS certificates on; 3. Tailnet Lock off; 4. Device approval off. Say which doctor checks (Phase 2 adds them) and that HTTPS is proven by the forwarder's cert (Phase 7).
6. `## Credentials` — `api.sh` contract (exit 0/2/3, secret on stdin, token in a header file, `TAILSCALE_ENV_FILE` test override). A `### PAT revocation` placeholder heading with one line: "Filled in by the adguard migration (Phase 2)." — Phase 2 replaces it.

**Step 1:** Write the file.

**Step 2: Verify** that every recipe named in the README exists: `just -f "$wt/justfile" tailscale --list`.

**Step 3: Commit**
```bash
git add tailscale/README.md
git commit -m "tailscale: README (bootstrap paths, clients, settings checklist)"
```
<!-- END_TASK_9 -->

---

**Phase 1 done when:** `policy-status` is `in-sync` after the pull/commit and after the push of the hosts/tests/grant change; `tailscale lint`, `lint-test` and `smoke` pass; the smoke shows the stale-`If-Match` push refused (412), the lint- and validate-rejected pushes never POSTing, `policy-push --init` running to its prompt and being declined, and plain `policy-push` refusing a non-lineage fixture with the `--init` hint; `dotfiles stacks doctor` (run as `$wt/stacks/scripts/doctor.sh`) shows no new FAIL.
