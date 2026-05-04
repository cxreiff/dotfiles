# adguard stack

AdGuard Home in the `bridged` Colima VM with `network_mode: host`,
so DNS source IPs are preserved per-client.

## Fresh-device setup

Prerequisites: Stage 2 setup complete (`dotfiles stow setup-colima` and `dotfiles stacks vm-up` already run).

```sh
dotfiles stacks adguard up         # boot AGH (creates volume dirs, starts wizard on :3000)
# complete wizard (see below)
dotfiles stacks adguard serve      # expose via Tailscale at https://<host>.<tailnet>.ts.net:8689
dotfiles stacks adguard advertise  # advertise VM IP as Tailscale subnet route
```

## First-run wizard

1. Find the VM IP: `colima list` → look at the `bridged` row's address.
2. Open `http://<VM_IP>:3000` in a browser.

### Admin Web Interface
- **Listen interface**: All interfaces
- **Port**: `18689` (matches `internal_port` in `justfile`)

### DNS Server
- **Listen interface**: pick the entry whose IP matches the VM IP — labeled
  `col0`, NOT `eth0`. (`eth0` is Colima's internal `192.168.5.x` network where
  dnsmasq holds port 53; binding "All interfaces" or `eth0` will fail with
  `address already in use`.)
- **Port**: `53`

### Authentication
- Set admin username and a strong password.

### Configure Devices / Open Dashboard
- Informational. Continue. Admin UI moves to `http://<VM_IP>:18689`.

## DNS failover

`adguard up`/`down` automatically toggle the tailnet's Global Nameservers
between AGH (when up) and a public fallback (when down) so AGH maintenance
never strands devices on a dead resolver.

```sh
dotfiles stacks adguard tailnet-dns-status   # current Global NS JSON
dotfiles stacks adguard tailnet-dns-on       # set NS to bridged VM IP
dotfiles stacks adguard tailnet-dns-off      # set NS to TAILNET_DNS_FALLBACK
```

Setup:

1. Generate a Tailscale PAT at
   <https://login.tailscale.com/admin/settings/keys>
   (90-day max expiry; the token inherits your account's tailnet permissions,
   which on a tailnet you own/admin includes DNS read+write).
2. `cp .env.example .env && chmod 600 .env`; paste the PAT.

Why the API and not Tailscale's multi-resolver fallback: Tailscale's
client-side fallback ordering is unreliable on macOS
([tailscale#12677](https://github.com/tailscale/tailscale/issues/12677)),
so the only reliable mechanism is to **switch** Global NS as a deliberate
binary state. The CLI doesn't support this configuration
([tailscale#5430](https://github.com/tailscale/tailscale/issues/5430)),
so the API is the only path.

If `tailnet-dns` ever leaves the tailnet pointed at a dead AGH (PAT
expired, API outage), recover manually at
<https://login.tailscale.com/admin/dns>.

### First-time wizard

On a brand-new install, the very first `dotfiles stacks adguard up`
launches AGH in setup-wizard mode (only the `:3000` web UI is listening;
no DNS bind on `col0` yet). The new auto-hook detects this state via
`~/.volumes/adguard/conf/AdGuardHome.yaml` not containing a
`bind_hosts:` IP and **silently no-ops** instead of trying to flip
Tailscale Global NS at a non-listening server. Expected output of the
first `up`:

```
wait-healthy: AGH wizard not yet complete (no bind_hosts in ...)
  Complete the wizard at http://<vm-ip>:3000 (bind to col0 — see above).
  Then re-run: dotfiles stacks adguard restart
```

After completing the wizard (Listen interface = `col0`), run `dotfiles
stacks adguard restart` — the next `up` invocation finds `bind_hosts:`
populated, polls `dig`, and flips Global NS to AGH normally.

### Recovering from a half-down stack

`down-all` brings stacks down in DNS-aware order (apps before adguard).
If the adguard step fails because `tailnet-dns.sh off` can't reach the
Tailscale API (revoked PAT, network outage), the recipe halts with a
non-zero exit and AGH stays running — apps are already down. Recover:

```sh
dotfiles stacks adguard tailnet-dns-status   # diagnose API reachability
# either fix the PAT, or use the manual web-UI fallback at
# https://login.tailscale.com/admin/dns to set Global NS to 1.1.1.1
dotfiles stacks adguard down                 # retry the down (now succeeds)
```

`dotfiles stacks doctor`'s `--- DNS failover ---` check flags the
half-down state explicitly.

## Router-side configuration (RT-AC68U, stock ASUSWRT)

Stock ASUSWRT on the RT-AC68U exposes a **single** LAN DHCP "DNS Server"
field (no second slot, no "Advertise router's IP" toggle). DHCP Option 6
multi-DNS is only available on Merlin firmware via `dnsmasq.conf.add` —
not relevant here.

| Field | UI path | Value | Why |
|---|---|---|---|
| LAN DHCP DNS | LAN → DHCP Server → "DNS and WINS Server Setting" → DNS Server | bridged VM IP (e.g. `192.168.1.78`) | All LAN clients filter through AGH. |
| WAN DNS | WAN → Internet Connection → "WAN DNS Setting" | `1.1.1.1` (and `1.0.0.1` if a second slot is shown) | The router's own outbound queries (DDNS, NTP, firmware checks) keep working when AGH is down. |

Failure modes:

- **AGH up, on-LAN client**: client queries the AGH VM IP via DHCP. Filtered
  resolution. Normal operation.
- **AGH down, on-tailnet client (any network)**: `dotfiles stacks adguard
  down` flips Tailscale Global Nameservers to the public fallback before
  stopping AGH (Phase 5). Tailnet devices keep resolving.
- **AGH down, on-LAN client *not* on the tailnet**: client's single DHCP-
  advertised DNS is unreachable. **DNS resolution stops** until AGH comes
  back. This is a hardware constraint of stock ASUSWRT — there's no
  router-advertised secondary to fall through to. OS-level DHCP-DNS
  failover behavior is unreliable across platforms anyway (Windows can
  hang minutes on a dead primary; iOS is sticky to first responder), so a
  hypothetical second slot would not have made this materially better.
  Mitigations: (a) keep planned AGH downtime short; (b) AGH's own
  `fallback_dns` config covers AGH-upstream failures, which are the more
  common outage; (c) if you ever need to take AGH down for an extended
  window, manually set the LAN DHCP DNS field to `1.1.1.1` first.

References: AdGuard Home Configuration wiki (`fallback_dns`); Pi-hole
forum thread on ASUS LAN-vs-WAN DNS distinction; ASUS support FAQ on
DHCP DNS field semantics.

## Manual steps not in the justfile

### Router (RT-AC68U or equivalent)

- **DHCP reservation**: pin the AGH VM's MAC to its current IP.
  - MAC: stable across `colima stop`/`start` for a given VM, but a *fresh* VM
    (`colima delete` + recreate, or first-boot on a new device) gets a new
    one. Discover with: `colima ssh -p bridged -- ip link show col0` — the
    `link/ether` line is the MAC.
  - IP: whatever the VM currently has (`colima list`)
  - On Asus routers, set "Manual Assignment" master toggle to "Yes" or
    reservations won't be enforced.
- **DHCP DNS** + **WAN DNS**: see "Router-side configuration (RT-AC68U,
  stock ASUSWRT)" above for the corrected single-field config.

### Tailscale admin console

After `dotfiles stacks adguard advertise` runs, two manual steps remain:

1. **Approve subnet route** at <https://login.tailscale.com/admin/machines>
   → find this host → "Edit route settings" → enable `<VM_IP>/32`.
2. **Set Global nameserver** at <https://login.tailscale.com/admin/dns>
   → "Global nameservers" → add `<VM_IP>`. Toggle "Override local DNS" if you
   want Tailnet devices to use AGH even when on cellular / other networks.

## Changing the admin port later

`internal_port` in `justfile` is the source of truth. To change:

1. `dotfiles stacks adguard down`
2. Edit `internal_port` in `stacks/adguard/justfile`
3. Edit `~/.volumes/adguard/conf/AdGuardHome.yaml` line `address:` to match
4. `dotfiles stacks adguard up`
