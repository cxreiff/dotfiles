# tailscale

Tailnet-global configuration: the access policy, the tailnet identity, and the
OAuth clients that scripts use to talk to the Tailscale API. This module owns
tailnet state only. Stacks call into it (`scripts/api.sh`, `scripts/authkey.sh`, `scripts/lib/conf.sh`); nothing here calls into a stack. The policy does name the tags stacks use (`tag:cxagents`), the check scripts reuse `stacks/scripts/lib/check.sh`, and doctor scans `stacks/*/.env` key names (never values) for Tailscale credentials that belong in `tailscale/.env`.

Recipes (run as `dotfiles tailscale <recipe>`):

| Recipe | What it does |
|---|---|
| `policy-pull [--force]` | Write the live policy to `policy.hujson` (refuses to overwrite unless `--force`) |
| `policy-diff` | Unified diff live -> repo; exit 0 and no output when identical |
| `policy-push [--init]` | Lint, API validate (runs the policy tests), diff, confirm, push with `If-Match` (`--init`: new tailnet, no `If-Match`) |
| `policy-status` | `in-sync` or `drift` (repo SHA-256 vs live ETag) |
| `lint` | Static invariants on `policy.hujson` (also run by `dotfiles stacks doctor`) |
| `lint-test` | Prove each lint fails on a fixture that violates exactly its invariant |
| `doctor-test` | Prove each tailnet doctor FAIL/WARN path with fixtures (read-only against live) |
| `smoke` | Live checks against the tailnet; never changes the live policy |
| `authkey tag:<name>` | Mint one single-use, pre-authorized, non-ephemeral auth key tagged `tag:<name>`, valid 10 minutes; prints only the key |

## Files

| Path | Role |
|---|---|
| `policy.hujson` | Source of truth for the tailnet policy, including its `tests`. Committed. |
| `tailnet.conf` | Non-secret tailnet identity (`TAILNET`, `TAILNET_DNS_SUFFIX`) and this node's device name (`NODE_HOSTNAME`, `cxmini`). Read by every script that needs it. |
| `clients.conf` | Expected OAuth clients: exact scope set and tags. `dotfiles stacks doctor` compares each client's token exchange (granted scopes and tags) against it. |
| `.env` | OAuth client ID and secret, mode 0600, gitignored, escrowed in the password manager as a whole file. Only `scripts/api.sh` reads it. |
| `.env.example` | Tracked template for `.env`, with `CHANGE_ME` placeholders. |
| `scripts/` | `policy.sh` (pull/diff/push/status), `api.sh` (the only credential reader), `authkey.sh` (mints auth keys), `lint.sh` and `lint-test.sh`, `smoke.sh`, `doctor.sh` and `doctor-test.sh` (the `--- Tailnet ---` checks and their fixtures), `keyscan.sh`, `keyscan-test.sh`, and `lib/` (`conf.sh`, `hujson2json.pl`). |

## Policy lineage (read before pushing)

Three facts govern every push:

1. **Tailscale stores the policy in canonical HuJSON formatting.** After a
   push, live can differ from `policy.hujson` only in whitespace and layout.
   `policy-push` then writes Tailscale's stored bytes back to `policy.hujson`,
   so the repo file stays byte-identical to live. Expect that rewrite after
   editing by hand, and review it with `git diff`.
2. **Commit `policy.hujson` right after every successful push.** `policy-push`
   reminds you when the file differs from `HEAD`. A plain push checks that live
   matches some committed version of the file (git history). An uncommitted
   or unpushed edit breaks that check on the next push.
3. **Never end the file with a comment.** Tailscale's validator rejects a file
   whose last line is a `//` comment ("parsing comment: unexpected EOF"). Comments
   on any other line, including the leading comment on line 1, are accepted.

## Bootstrap paths

Both paths start the same way: create the `dotfiles-admin` OAuth client
(see [Clients](#clients)), then `cp .env.example .env && chmod 600 .env` and
fill in its ID and secret.

**(a) Adopting an existing tailnet**

1. `dotfiles tailscale policy-pull`: writes the live policy to `policy.hujson`.
2. Commit `policy.hujson`.
3. Edit `policy.hujson`, then run `dotfiles tailscale policy-diff` and
   `dotfiles tailscale lint-test`.
4. `dotfiles tailscale policy-push`: shows the diff and asks `[y/N]`.
5. Commit `policy.hujson` again, even if the push reformatted it.

**(b) A new tailnet**

1. Update the tailnet identity to the new tailnet before pushing: `TAILNET`
   and `TAILNET_DNS_SUFFIX` in `tailnet.conf` (the node name stays `cxmini`), the `cxmini` IP in `policy.hujson`
   (`hosts`), the test user in `policy.hujson` (`tests`, `cxreiff@github` today),
   and the tailnet name in `policy.hujson`'s line-1 comment (`cxreiff.github` today).
2. `dotfiles tailscale policy-push --init`: shows the diff against the default
   policy, asks for confirmation, then pushes without `If-Match`.
3. Commit `policy.hujson`.

**Lineage refusals.** A plain `policy-push` refuses when live matches no
committed version. That happens on a new tailnet or after an admin-console edit.
Resolve it with `dotfiles tailscale policy-diff`, then either:

- `dotfiles tailscale policy-pull --force` and commit, to adopt the console
  edit into the repo; or
- `dotfiles tailscale policy-push --init`, to overwrite the console edit with
  the repo file.

A push that fails the `If-Match` check (HTTP 412) means live changed after the
last fetch. Run `policy-diff` and retry. `policy-push` never POSTs after a lint
or validate failure.

## Clients

Create the clients in this order:

1. `dotfiles-admin` (the table below).
2. Push a policy that declares `tag:cxagents` in `tagOwners`: `dotfiles tailscale policy-push`, or `--init` on a new tailnet.
3. `dotfiles-authkeys`. Tailscale accepts a client's tags only if they appear in `tagOwners`, so this client cannot come first.

Create each client at https://login.tailscale.com/admin/settings/oauth with
exactly the scopes and tags below, as declared in `clients.conf`:

| Client | Scopes | Tags |
|---|---|---|
| `admin` (`dotfiles-admin`) | `devices:core:read devices:posture_attributes dns logs:configuration:read policy_file` | none |
| `authkeys` (`dotfiles-authkeys`) | `auth_keys` (Auth Keys, write) only | `tag:cxagents` |

The client secret is shown once. Copy it into `.env` and into the password
manager escrow entry at the same time. The authkeys client's ID and secret go
in `.env` as `TS_AUTHKEYS_CLIENT_ID` and `TS_AUTHKEYS_CLIENT_SECRET`.

`dotfiles stacks doctor`'s `--- Tailnet ---` section runs one token exchange per
client. It FAILs unless the granted scopes equal the row's scopes exactly, extra
scopes included, and the tags the exchange reports equal the row's tags. The
exchange reports the tags, so the tag check is exact. The authkeys client was
granted exactly `auth_keys`; no extra scope is added implicitly
(`tailscale/scripts/api.sh --client authkeys --granted-scopes` prints `auth_keys`).

The authkeys client cannot write the policy or the DNS nameservers. Those
writes return HTTP 404 (the API hides ACL and DNS paths outside the client's
scopes, reads included). `smoke` AC2.4 asserts the refusal and fails on any
accepted write.

### Minting auth keys

`dotfiles tailscale authkey tag:cxagents` mints one key per call through the
authkeys client. Each key is single-use, pre-authorized, non-ephemeral, tagged
`tag:cxagents`, and expires in 10 minutes. The key is printed on stdout and
nothing else. Pipe it straight into the consumer and never store it. The
`tag:` argument must match `tag:[a-z0-9-]+`; any other value exits 2.

Deleting a key (`DELETE /tailnet/{tailnet}/keys/{id}`) does not remove it from
the API. A later GET returns 200 with `revoked` set and `invalid: true`, not
404. Check for a live key by those fields, not by the status code. `smoke`
AC5.2 mints one key, verifies its fields, deletes it, and confirms the revoked
state.

## Tailnet settings checklist

The API cannot set these. Set them in the admin console:

1. **MagicDNS** on. Checked by `dotfiles stacks doctor`'s `--- Tailnet ---` section: it reads `tailscale status --json` and FAILs if MagicDNS is off, or if the tailnet name or DNS suffix differs from `tailnet.conf`. It also FAILs when this node's own name is not `NODE_HOSTNAME.<suffix>`: a `tailscale up --hostname=cxmini` that found the name taken joins as `cxmini-1`, which breaks the WebUI origin, the serve URLs and saved logins. Fix it per `docs/migration-recovery.md`. It also FAILs when the policy's `hosts.<NODE_HOSTNAME>` entry is not this node's IPv4 (edit `policy.hujson` and `policy-push`; see CLAUDE.md node-IP artifacts).
2. **HTTPS certificates** on. Checked by the `--- cxagents ---` certificate check: the forwarder's `check` requires a valid certificate with more than 14 days left.
3. **Tailnet Lock** off. Checked by `--- Tailnet ---`: it reads `tailscale lock status` and FAILs if Tailnet Lock is enabled.
4. **Device approval** off. Not checked by doctor. Confirm it by hand in the admin console.

## Credentials

`scripts/api.sh` is the only code that reads the OAuth client values in `.env`.
Its contract:

- Exit 0 on a 2xx response.
- Exit 2 when credentials are missing, placeholder, or deprecated. Nothing is sent.
- Exit 3 on an HTTP or network error. The message goes to stderr, for example
  `api.sh: GET ... -> HTTP 403: ...`.
- The client secret reaches `curl` on stdin, never on the command line.
- The access token is passed through a header file, not an argument.
- Neither the secret nor the token is ever printed.
- `TAILSCALE_ENV_FILE` overrides the `.env` path, for tests.

Deprecated credential names are rejected with a rename hint.

### PAT revocation (one-time, after the OAuth migration is merged)

The adguard `dns_token` PAT (full-admin `all` scopes, expires 2026-11-22) is
retired. Until the migration is on `main`, the live boot path still uses it,
so do these in order, from the main checkout:

1. `dotfiles stacks adguard tailnet-dns-status` succeeds (now via OAuth).
2. Remove the `TAILSCALE_PAT=` line from `stacks/adguard/.env` (and its escrow copy).
3. `dotfiles stacks adguard tailnet-dns-status` still succeeds.
4. Revoke the token at https://login.tailscale.com/admin/settings/keys.
5. `dotfiles stacks doctor`: no `TAILSCALE_PAT` WARN in `--- Tailnet ---`.
