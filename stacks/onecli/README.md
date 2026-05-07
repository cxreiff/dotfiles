# onecli stack

[onecli](https://github.com/onecli/onecli) — credential vault that gives AI
agents access to services without exposing keys. Runs in the `agents`
Colima VM as the credential broker for [nanoclaw](https://github.com/onecli/nanoclaw).

Two services in one Compose project: a Postgres 18 instance for the
encrypted ciphertext store, and the upstream `ghcr.io/onecli/onecli`
image (Next.js dashboard on `:10254` + Rust gateway on `:10255` bundled
into a single container).

**Two pieces of asymmetry vs the other stacks:**

- State lives in Docker named volumes inside the `agents` VM, not
  under `~/.volumes/onecli/`. See [Volumes](#volumes).
- Onecli runs in `AUTH_MODE=local` (no `NEXTAUTH_SECRET`, single
  hardcoded `admin@localhost` user, no auth on the localhost gateway).
  See [Auth model](#auth-model).

## Fresh-device setup

Prerequisites: Stage 2 setup complete (`dotfiles stow setup-colima`
already run), plus the host `onecli` CLI on PATH. If you don't have it:
`curl -fsSL onecli.sh/cli/install | sh`. The `agents` VM is on-demand;
bring it up first.

```sh
dotfiles stacks vm-agents-up

cp .env.example .env
chmod 600 .env
$EDITOR .env                                   # generate POSTGRES_PASSWORD (command in the file)

dotfiles stacks onecli up                      # first boot — Docker creates onecli_pgdata + onecli_app-data
dotfiles stacks onecli ps                      # both services healthy
dotfiles stacks onecli bootstrap               # required: lazy-create local-admin + register host CLI's API key
```

`bootstrap` is idempotent. After it runs, `onecli secrets list` and the
rest of the host CLI are usable from any shell on the Mac. The
dashboard is at `http://127.0.0.1:10254` (the `agents` VM uses Colima
`network.mode: shared`, so 127.0.0.1 on the Mac forwards into the VM).
There is no `serve` recipe — onecli is local-only by design.

## .env keys

| Key | Purpose |
|---|---|
| `POSTGRES_USER` | Postgres role used by the dashboard. Default `onecli` is fine |
| `POSTGRES_PASSWORD` | **Must override** the insecure upstream default. `openssl rand -hex 24` |
| `POSTGRES_DB` | Database name. Default `onecli` is fine |
| `ONECLI_BIND_HOST` | (optional) Defaults to `127.0.0.1`. Don't change — see [Auth model](#auth-model); the loopback bind is the security boundary |
| `ONECLI_APP_PORT` | (optional) Default `10254` |
| `ONECLI_GATEWAY_PORT` | (optional) Default `10255` |
| `ONECLI_VERSION` | (optional) Defaults to `latest` |

The encryption key (`SECRET_ENCRYPTION_KEY`) is auto-generated on first
start and persisted inside the `app-data` named volume. It is
deliberately **not** templated into `.env` — rotating it would orphan
every credential currently stored in `pgdata`.

`.env` is gitignored; `.env.example` is the tracked template.

## Auth model

Onecli's two supported modes:

| Mode | Trigger | What it means |
|---|---|---|
| `local` (this stack) | `NEXTAUTH_SECRET` absent at container start | Single-user. Hardcoded `admin@localhost` (created lazily on first authenticated HTTP hit). No auth on the dashboard or gateway — anyone who can reach `127.0.0.1:10254` is admin |
| `oauth` | `NEXTAUTH_SECRET` set, plus a configured provider | Multi-user via Google / GitHub / etc. Real session cookies, real CSRF |

We're in `local` mode. The reasons:

- It's what the upstream installer (`curl onecli.sh/install | sh`)
  ships and what nanoclaw's setup flow assumes.
- We don't have a public hostname to point oauth at, and adding a
  third-party identity provider for a single-user vault is overkill.
- The `127.0.0.1` bind is the security boundary — the gateway is
  unreachable from the LAN, the tailnet, and other VMs.

**The honest threat model:** an attacker who can run code on this Mac
as your UID can simply `curl http://127.0.0.1:10254/api/secrets/...`
and read every credential plaintext. There is no auth in front of the
gateway in local mode. Same-UID compromise = vault compromise.

What we _do_ defend against is the realistic envelope around that:
named volumes inside the VM (rather than `~/.volumes/onecli/`) keep
the encrypted store and key out of casual filesystem-level disclosure
paths — incidental backups of `~`, screen shares that show a
`find ~/.volumes`, malware that scans home dirs for files matching
common DB extensions. Those are real protections; they're not a wall
against an adversary who already has the gateway URL and active code
execution.

If your threat model is stronger than that — multi-user host, agents
running as different UIDs, or anything reaching the localhost gateway
that you don't trust — `AUTH_MODE=local` is wrong for you. Switch to
`oauth` and put a real identity provider in front. That's a deliberate
config change deserving its own README, not a small tweak.

### Why we can't customise `admin@localhost`

The dashboard hardcodes the local-admin's email and display name as
string constants in the bundled JS. There's no env hook for swapping
in `ADMIN_EMAIL` / `ADMIN_USERNAME` from `.env`. We could `UPDATE` the
row in `pgdata` post-bootstrap, but there's no functional point —
local mode skips authentication, so nothing checks the email. The
field is purely cosmetic ("you're logged in as admin@localhost" in the
top-right of the dashboard). Live with it.

## Volumes

| Volume (Docker named, project-prefixed) | Container path | Contents |
|---|---|---|
| `onecli_pgdata` | `/var/lib/postgresql` | AES-256-GCM ciphertext of stored credentials |
| `onecli_app-data` | `/app/data` | Auto-generated `SECRET_ENCRYPTION_KEY` (the key that decrypts `pgdata`) |

### Why named volumes (and not `~/.volumes/onecli/`)

Every other stack in this repo uses bind mounts under
`~/.volumes/<stack>/`. onecli does not.

What's at stake: `pgdata` holds the AES-256-GCM ciphertext, `app-data`
holds the encryption key. Anyone who reads both can offline-decrypt
the whole vault. Keeping these inside the VM rather than on the Mac
filesystem doesn't stop an active same-UID attacker (see [Auth
model](#auth-model) — they can `curl` the gateway directly), but it
does keep the bytes out of:

- backups of `~` that don't know to exclude `~/.volumes/`
- screen shares, `find ~`, `ls -laR ~`, anything that walks the home tree
- malware or grep-based scrapers looking for files matching common DB extensions

The cost of breaking repo symmetry here is one custom backup recipe
and a small special-case in `doctor.sh`; the benefit is removing a
class of accidental disclosure paths. The backup/restore/doctor
plumbing is adapted to match (see below).

## Nanoclaw integration

Point `nanoclaw` at `http://127.0.0.1:10254` for dashboard / gateway
calls. The upstream `onecli` CLI tool's `~/.onecli/config.json`
(`{"api-host": "http://127.0.0.1:10254"}`) is unaffected — same host,
same port, just managed via this stack instead of the upstream
installer's untracked `~/.onecli/docker-compose.yml`.

## Migration from the upstream installer

If you previously ran `curl -fsSL https://onecli.sh/install | sh`:

1. `~/.onecli/docker-compose.yml` is now **obsolete** and can be
   deleted. It's byte-equivalent to upstream modulo the
   `${ONECLI_VERSION:-latest}` flattening; this stack's
   `compose.yaml` supersedes it.
2. `~/.onecli/config.json` and `~/.onecli/credentials/` are CLI client
   state — leave them alone.
3. The installer's `docker compose up` ran in whatever Docker context
   was active at the time, which may not be `colima-agents`. If you
   see orphan `pgdata` / `app-data` volumes when running
   `docker --context <other> volume ls`, prune them after confirming
   nothing else uses them. Otherwise you'll have two parallel vaults
   and waste storage.

## Backup notes

`dotfiles stacks onecli backup` runs a throwaway `alpine` container in
`colima-agents` that mounts the named volumes read-only and tars them
to `~/.volume-backups/daily/onecli-YYYY-MM-DD.tgz` — same naming and
location the rest of the stacks use, so `backup-rotate.sh` GFS
promotion picks it up unchanged.

The recipe gates on `colima-agents` actually being running:

- VM down → recipe prints "skipping backup" and exits 0 (so the
  nightly `backup-all` LaunchAgent doesn't fail when you've left the
  VM off).
- VM up → recipe runs `compose down`, snapshots, runs `compose up -d`.
  Quiesces Postgres for the duration of the tar (consistent with
  freshrss / wallabag).

`dotfiles stacks doctor` reports onecli's backup-age check as `[OFF]`
informationally while `colima-agents` is stopped, and `FAIL` if the VM
has been up for more than 36 hours without a fresh backup landing.

`dotfiles stacks onecli restore <tarball>` is the inverse — it
**refuses** to restore over non-empty volumes (same spirit as
`scripts/restore.sh`'s `--force` gate). To intentionally clobber:
`down`, `docker --context colima-agents volume rm onecli_pgdata
onecli_app-data`, then `restore`.
