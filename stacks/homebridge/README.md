# homebridge stack

[Homebridge](https://homebridge.io/) in the `bridged` Colima VM with
`network_mode: host`. Bridged + host networking is what makes
HomeKit/mDNS discovery actually work from Apple devices on the LAN — see
the networking section at the bottom for the why.

## Pairing identity

`BRIDGE_USERNAME` (a MAC-format ID) and `HOMEKIT_PIN` are pairing-identity
critical. Once HomeKit accessories are paired against a bridge with a
specific `BRIDGE_USERNAME` + `HOMEKIT_PIN`, those values become permanent
identifiers in the user's iOS Home database.

**Never regenerate `BRIDGE_USERNAME` or `HOMEKIT_PIN` on a paired
bridge.** Doing so silently breaks the HomeKit pairing — accessories
appear "responding" in Home but commands silently fail, until the user
deletes the bridge from Home and re-pairs every accessory.

Restoring `~/.volumes/homebridge/` from a backup is the **only** path that
preserves the pairing identity across a device move:

```sh
# On the old device
dotfiles stacks homebridge backup    # writes ~/.volume-backups/daily/homebridge-YYYY-MM-DD.tgz

# On the new device, before first homebridge up
dotfiles stacks homebridge restore /path/to/homebridge-YYYY-MM-DD.tgz --force
dotfiles stacks homebridge up        # init sees existing config.json, doesn't reseed
```

`config.json` (rendered from `config.json.template` at first `up` via
envsubst) bakes `BRIDGE_USERNAME`, `HOMEKIT_PIN`, and `HAP_PORT` into the
runtime config. The init recipe is intentionally idempotent — it skips
re-seeding if `config.json` already exists, so restoring a backup before
first `up` is the right pattern.

## Fresh-device setup

Prerequisites: Stage 2 setup complete (`dotfiles stow setup-colima` and `dotfiles stacks vm-up` already run). `jq` on the host (`brew install jq`) for the `bootstrap` recipe.

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env                            # PUBLIC_HOST, BRIDGE_USERNAME, HOMEKIT_PIN, ADMIN_*

dotfiles stacks homebridge up           # init seeds config.json on first up; container boots
dotfiles stacks homebridge bootstrap    # one-time: rotate Config UI X admin password from .env
dotfiles stacks homebridge serve        # expose UI via Tailscale at https://<host>.<tailnet>.ts.net:8767
```

Then in the iOS Home app: **Add Accessory → I Don't Have a Code or Cannot
Scan → enter `HOMEKIT_PIN` from `.env`**. The bridge appears via mDNS and
pairs in a few seconds. Plugins are added through the Config UI X web
interface afterwards.

## .env keys

| Key | Purpose |
|---|---|
| `PUBLIC_HOST` | Tailscale MagicDNS hostname (e.g., `cxreiff-mini.faun-fir.ts.net`) |
| `PUBLIC_PORT` | Tailscale-side HTTPS port for the Config UI X (matches `serve_port`) |
| `INTERNAL_PORT` | Port Config UI X listens on inside the bridged VM (matches `internal_port`) |
| `BRIDGE_NAME` | Bridge name shown in the Home app |
| `BRIDGE_USERNAME` | MAC-format ID baked into the HomeKit pairing — **must stay stable** for paired accessories to keep working |
| `HAP_PORT` | HomeKit Accessory Protocol port (any free port; 51826 is conventional) |
| `HOMEKIT_PIN` | 8-digit pin entered during pairing |
| `ADMIN_USERNAME` | Config UI X admin username (set non-`admin` to create a new admin and remove the default) |
| `ADMIN_PASSWORD` | Config UI X admin password (`openssl rand -base64 16`) |

`.env` is gitignored; `.env.example` is the tracked template.

## What's declarative, what isn't

Declarative on first `up`:
- `config.json` rendered from `config.json.template` via `envsubst` —
  bridge identity, HomeKit pin, HAP port, Config UI X port, and
  `bind: ["col0"]` to constrain mDNS to the bridged interface inside the
  VM.
- Config UI X admin credentials seeded by the `bootstrap` recipe from
  `.env` (HTTP API; the homebridge image ships no CLI for user
  management).

Not declarative:
- HomeKit pairing itself — must happen once per (device + Apple account)
  pair, in the Home app.
- Plugin install — done via Config UI X. Once installed, plugins persist
  in `~/.volumes/homebridge/node_modules/` and survive container
  recreation, so this is a one-time step per stack lifetime.

## Reproducibility on a new device

`~/.volumes/homebridge/` is the entire bridge state — `config.json`,
plugins, `persist/` (HomeKit pairing keys), `accessories/` (cached
metadata), `auth.json` (Config UI X users). The directory is fully
portable; restoring it onto a new Mac means **no re-pairing of any
accessory** in the Home app.

```sh
# On the old device
tar -C ~/.volumes -czf homebridge-backup.tgz homebridge

# On the new device, before first `up`
mkdir -p ~/.volumes
tar -C ~/.volumes -xzf homebridge-backup.tgz
dotfiles stacks homebridge up        # init sees existing config.json and skips seeding
dotfiles stacks homebridge serve
```

The `init` recipe is intentionally idempotent (won't overwrite an existing
`config.json`), so restoring before first `up` is safe.

## Networking — why this stack lives in `bridged`

Homebridge advertises HomeKit accessories via mDNS/Bonjour. Apple devices
on the LAN need to receive those multicast packets on the same broadcast
domain. Three networking models were considered:

| Approach | mDNS reaches LAN? | Verdict |
|---|---|---|
| `shared` profile (vz/vzNAT) + `network_mode: host` | ❌ multicast trapped in vz | Pairing wouldn't work. Per official Homebridge docs and reproduced upstream. |
| `bridged` profile + `network_mode: host` | ✅ via `col0` bridged interface | **In use.** |
| Native macOS install (`hb-service install`) | ✅ | Works fine; out of this repo's pattern. Listed here as the escape hatch. |

The `bind: ["col0"]` line in `config.json` matters: inside the qemu VM the
LAN-bridged interface is `col0` (NOT `eth0` — that's the internal
`192.168.5.x` network where Colima's dnsmasq lives). Restricting Homebridge
to advertise only on `col0` avoids confused HomeKit clients trying to
connect via the internal network. Same gotcha that bites the AdGuard wizard
in the sibling stack.

## Manual steps not in the justfile

- **HomeKit pairing.** First pairing in the Home app, plus pairing again
  for any additional Apple ID/Home you want to control the bridge from.
- **DHCP reservation (optional but recommended).** The bridged VM gets a
  DHCP lease from the LAN router. Pin the VM's MAC to its current IP so
  the HAP port doesn't change after a router reboot. The MAC is stable
  across `colima stop`/`start`. Find it with `colima ssh -p bridged -- ip
  link show col0`.
- **Plugin install.** Through Config UI X.

## Changing ports later

`serve_port` / `internal_port` in `justfile` are the source of truth. When
changing `internal_port`:

1. `dotfiles stacks homebridge down`
2. Edit `internal_port` in `stacks/homebridge/justfile`
3. Edit `INTERNAL_PORT` in `stacks/homebridge/.env`
4. Edit `~/.volumes/homebridge/config.json`'s
   `platforms[0].port` to match
5. `{{tailscale}} serve --https=<old> off` if you're also changing `serve_port`
6. `dotfiles stacks homebridge up && dotfiles stacks homebridge serve`

`HAP_PORT` is independent of the UI port and lives in `config.json` only;
**don't change it after pairing** without expecting to re-pair, since it's
part of the bridge identity Apple devices remember.
