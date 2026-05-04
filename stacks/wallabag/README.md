# wallabag stack

[Wallabag](https://www.wallabag.org/) (read-it-later) in the `shared` Colima
VM. Single container with host bind mounts under `~/.volumes/wallabag/`.

## Fresh-device setup

Prerequisites: stow + the default Colima profile already up.

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env                          # fill in PUBLIC_HOST, WALLABAG_SECRET, ADMIN_*

dotfiles stacks wallabag up           # boot — first run auto-installs schema + default admin
dotfiles stacks wallabag bootstrap    # one-time: replace default admin with ADMIN_* from .env
dotfiles stacks wallabag serve        # expose via Tailscale at https://<host>.<tailnet>.ts.net:8766
```

`bootstrap` is idempotent — safe to re-run if you change `ADMIN_*` values
later (it just won't be able to recover the deactivated default user).

## .env keys

| Key | Purpose |
|---|---|
| `PUBLIC_HOST` | Tailscale MagicDNS hostname (e.g., `cxreiff-mini.faun-fir.ts.net`) |
| `PUBLIC_PORT` | Tailscale-side HTTPS port (matches `serve_port` in justfile) |
| `INTERNAL_PORT` | Mac localhost forward port (matches `internal_port`) |
| `WALLABAG_SECRET` | Symfony app secret — `openssl rand -hex 32`. **Must override** the insecure upstream default |
| `SERVER_NAME` | Friendly instance name shown in TOTP issuer entry, etc. |
| `ADMIN_USERNAME` | Used by `bootstrap` to create the real admin |
| `ADMIN_EMAIL` | Same |
| `ADMIN_PASSWORD` | Same — `openssl rand -base64 16` |

`.env` is gitignored; `.env.example` is the tracked template.

## Volumes

| Host path | Container path | Contents |
|---|---|---|
| `~/.volumes/wallabag/data` | `/var/www/wallabag/data` | SQLite DB (`db/wallabag.sqlite`), assets |
| `~/.volumes/wallabag/images` | `/var/www/wallabag/web/assets/images` | Cached article images |

`init` (a `up` prerequisite) creates these directories. `backup` and `restore`
recipes target them via the shared `stacks/scripts/backup.sh` /
`restore.sh`. `restore` refuses to overwrite a non-empty destination unless
`--force` is passed.

## First-run automation

The upstream entrypoint runs `wallabag:install --env=prod -n` automatically
the first time the `data` volume is empty, which provisions the SQLite
schema and creates a hardcoded default user `wallabag:wallabag`. Subsequent
starts are no-ops because the install state lives in the named `data`
volume.

Wallabag exposes **no** env var for customising the initial admin
credentials, so we run a `bootstrap` recipe after first `up`:

1. `bin/console fos:user:create $ADMIN_USERNAME ... --super-admin` — create
   the real admin from `.env`.
2. `bin/console fos:user:deactivate wallabag` — disable the default
   account so `wallabag:wallabag` can no longer log in.

The default `wallabag` user remains in the DB (FOSUserBundle has no delete
command), but is deactivated and cannot authenticate.

## Manual steps not in the justfile

None on the LAN side beyond running `bootstrap` once. As with freshrss, the
`PUBLIC_HOST` / `PUBLIC_PORT` values in `.env` must match the actual
Tailscale serve URL — wallabag uses `SYMFONY__ENV__DOMAIN_NAME` to build
absolute URLs and OAuth redirects.

## Changing the public port later

`serve_port` in `justfile` is the source of truth. To change:

1. `dotfiles stacks wallabag down`
2. Edit `serve_port` / `internal_port` in `stacks/wallabag/justfile`
3. Edit `PUBLIC_PORT` / `INTERNAL_PORT` in `stacks/wallabag/.env` to match
4. `{{tailscale}} serve reset` (or `--https=<old> off`) to drop the prior serve
5. `dotfiles stacks wallabag up && dotfiles stacks wallabag serve`
