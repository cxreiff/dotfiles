# freshrss stack

FreshRSS in the `shared` Colima VM. Runs as a single container with host
bind mounts under `~/.volumes/freshrss/`.

## Fresh-device setup

Prerequisites: stow + the default Colima profile already up.

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env                     # fill in PUBLIC_HOST, ADMIN_*

dotfiles stacks freshrss up      # boot — first-run install is automated by .env
dotfiles stacks freshrss serve   # expose via Tailscale at https://<host>.<tailnet>.ts.net:8765
```

## .env keys

| Key | Purpose |
|---|---|
| `PUBLIC_HOST` | Tailscale MagicDNS hostname (e.g., `cxreiff-mini.faun-fir.ts.net`) |
| `PUBLIC_PORT` | Tailscale-side HTTPS port (matches `serve_port` in justfile) |
| `INTERNAL_PORT` | Mac localhost forward port (matches `internal_port`) |
| `ADMIN_EMAIL` | Admin contact, used by FreshRSS install |
| `ADMIN_USERNAME` | Initial admin login |
| `ADMIN_PASSWORD` | Strong password — `openssl rand -base64 16` |
| `ADMIN_API_PASSWORD` | Separate password for API/RSS clients (Reeder, etc.) |

`.env` is gitignored; `.env.example` is the tracked template.

## Volumes

| Host path | Container path | Contents |
|---|---|---|
| `~/.volumes/freshrss/data` | `/var/www/FreshRSS/data` | SQLite DB, user accounts, feed/article state |
| `~/.volumes/freshrss/extensions` | `/var/www/FreshRSS/extensions` | Installed UI extensions |

`init` (a `up` prerequisite) creates these directories. `backup` and `restore`
recipes target them via the shared `stacks/scripts/backup.sh` /
`restore.sh`. `restore` refuses to overwrite a non-empty destination unless
`--force` is passed.

## First-run automation

The compose file's `FRESHRSS_INSTALL` and `FRESHRSS_USER` env blocks invoke
FreshRSS's CLI installer on first start, using the values from `.env`. No web
wizard. Subsequent starts are no-ops because the install state is in the named
`data` volume.

## Manual steps not in the justfile

None on the LAN side. If you want the FreshRSS UI to render correct asset
URLs and login redirects, the `PUBLIC_HOST` / `PUBLIC_PORT` values in `.env`
must match the actual Tailscale serve URL.
