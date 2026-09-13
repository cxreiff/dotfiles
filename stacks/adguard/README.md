# adguard stack

AdGuard Home in the `bridged` Colima VM with `network_mode: host`,
so DNS source IPs are preserved per-client.

## Fresh-device setup

Prerequisites: Stage 2 setup complete (`dotfiles stow setup-colima` and `dotfiles stacks vm-up` already run).

```sh
dotfiles stacks adguard up           # boot AGH (creates volume dirs, starts wizard on :3000)
# complete wizard (see below)
dotfiles stacks adguard serve        # expose admin UI via Tailscale at https://<host>.<tailnet>.ts.net:8689
dotfiles stacks dns-forward-install  # relay this node's Tailscale IP :53 -> AGH (for tailnet DNS; sudo)
```

`dotfiles stacks adguard advertise` (advertise the VM LAN IP as a Tailscale
subnet route) is **optional** — only needed if you want to reach the AGH
admin UI by its LAN IP over Tailscale. Tailnet **DNS** no longer depends on
it; see [Away-from-home DNS](#away-from-home-dns-the-node-ip-relay) below.

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

## Away-from-home DNS (the node-IP relay)

AGH listens inside the bridged VM on a **LAN IP** (e.g. `192.168.1.78`).
That address is not on the tailnet, so a tailnet client (your phone away
from home) can only reach it via an *approved subnet route* — and that's
fragile two ways:

- If the client doesn't accept subnet routes, queries to the VM IP go
  nowhere. With Tailscale's "Override local DNS" on, the client has **no DNS
  fallback**, so *all* name resolution dies (web/apps break) even though
  tailnet IPs — like an SSH target at `100.x` — still work. That exact
  asymmetry (SSH fine, everything else dead) is the tell.
- If the remote network reuses `192.168.1.0/24` (most home/cafe routers do),
  the client thinks the VM IP is a local host and never routes it over
  Tailscale at all.

**Fix:** the `dns-forward` LaunchDaemon (`dotfiles stacks
dns-forward-install`) runs a socat relay on this Mac that forwards the
node's **Tailscale IP** `:53` (UDP+TCP) to AGH at the VM IP `:53`. A native
`100.x` node address is carried by *every* Tailscale client unconditionally
— no subnet route, immune to the `192.168.1.x` collision. Global NS then
points at the node IP (handled automatically by `tailnet-dns-on`, below),
not the VM IP.

```sh
dotfiles stacks dns-forward-install   # install/repair the relay (sudo; bakes in node IP + VM IP)
```

- Runs as **root** (binding `:53` is privileged) — the only stacks daemon
  that does; socat needs no user context. `brew install socat` is a Stage-2
  prerequisite.
- The relay's *target* is the bridged VM IP, so `bridged-ip-changed`
  reinstalls it automatically when that IP changes.
- `dotfiles stacks doctor`'s `--- DNS forwarder ---` check probes the relay
  (`dig @<node-ip>`) and fails if it's installed but not answering.
- Remove it with `sudo launchctl bootout
  system/com.cxreiff.dotfiles.dns-forward && sudo rm
  /Library/LaunchDaemons/com.cxreiff.dotfiles.dns-forward.plist`.

## DNS failover

`adguard up`/`down` automatically toggle the tailnet's Global Nameservers
between AGH (when up) and a public fallback (when down) so AGH maintenance
never strands devices on a dead resolver.

```sh
dotfiles stacks adguard tailnet-dns-status   # current Global NS JSON
dotfiles stacks adguard tailnet-dns-on       # set NS to this node's Tailscale IP (the dns-forward relay)
dotfiles stacks adguard tailnet-dns-off      # set NS to TAILNET_DNS_FALLBACK
```

Setup:

1. Generate a Tailscale PAT at
   <https://login.tailscale.com/admin/settings/keys>
   (90-day max expiry; the token inherits your account's tailnet permissions,
   which on a tailnet you own/admin includes DNS read+write — the key UI
   has no per-scope selector). **The token silently expires after 90
   days.** When it does, `adguard up` fails at the `tailnet-dns on` step
   with `API GET failed: … 401`, Global NS is left wherever it was, and
   `doctor` only emits `[WARN] tailnet-dns status unavailable` — easy to
   miss. Symptom seen 2026-08-24 after a reboot: tailnet Global NS empty,
   nobody on the tailnet using AGH. Fix: regenerate the token, update
   `.env`, run `dotfiles stacks adguard tailnet-dns-on`. Set a reminder
   for ~80 days after each rotation (last rotated 2026-08-24).
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

Current stock ASUSWRT on the RT-AC68U advertises **two** LAN DHCP DNS
servers (verified 2026-08-24: a fresh lease on this host carries
`domain_name_server = {192.168.1.78, 192.168.1.1}`). An earlier version
of this section claimed a single field — that was wrong / outdated.

| Field | UI path | Value | Why |
|---|---|---|---|
| LAN DHCP DNS 1 | LAN → DHCP Server → "DNS and WINS Server Setting" → DNS Server | bridged VM IP (e.g. `192.168.1.78`) | All LAN clients filter through AGH. |
| LAN DHCP DNS 2 / "Advertise router's IP" | same section | router IP (`192.168.1.1`) — **deliberate, see caveat** | Unfiltered fallback so the LAN keeps resolving when AGH/this host is down (e.g. after a power outage). |
| WAN DNS | WAN → Internet Connection → "WAN DNS Setting" | Automatic (ISP) or `1.1.1.1` — anything **except** `192.168.1.78` | Only the router's own queries (DDNS, NTP, firmware checks) use this; it must not depend on AGH. |

**Caveat on the second entry:** it is an unfiltered escape hatch. Clients
do not strictly prefer the first server — macOS/iOS move to the next
resolver after a timeout and stick with it for a while, Windows
round-robins, some IoT devices use both — so a slice of LAN traffic will
bypass AGH filtering and its query log unpredictably. This is accepted in
exchange for not losing LAN DNS entirely when AGH is down (which is what
happened after the 2026-08-23 power outage and forced ad-hoc router
edits). If filtering coverage matters more than outage resilience, clear
the second entry.

Failure modes:

- **AGH up, on-LAN client**: client queries the AGH VM IP via DHCP. Filtered
  resolution. Normal operation (modulo the caveat above).
- **AGH down, on-tailnet client (any network)**: `dotfiles stacks adguard
  down` flips Tailscale Global Nameservers to the public fallback before
  stopping AGH (Phase 5). Tailnet devices keep resolving.
- **AGH down, on-LAN client *not* on the tailnet**: client falls through to
  `192.168.1.1` (unfiltered) after its OS-specific timeout. Resolution
  continues, slower at first. Mitigations still worth keeping: (a) keep
  planned AGH downtime short; (b) AGH's own `fallback_dns` config covers
  AGH-upstream failures, which are the more common outage.

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
  stock ASUSWRT)" above (two LAN DNS entries; WAN DNS anything but the AGH IP).

### Tailscale admin console

**Global nameserver is set automatically** by `dotfiles stacks adguard
tailnet-dns-on` (run on every `adguard up`) — it points Global NS at this
node's Tailscale IP, served by the `dns-forward` relay. The only manual DNS
step is toggling **"Override local DNS"** at
<https://login.tailscale.com/admin/dns> if you want tailnet devices to use
AGH even on cellular / other networks. (With Override on and the relay
healthy, this is robust; the relay preflight in `tailnet-dns-on` refuses to
point Global NS at a dead relay, so it can't strand devices.)

**Optional — subnet route approval** (only if you ran `adguard advertise` to
reach the AGH admin UI by its LAN IP over Tailscale): approve it at
<https://login.tailscale.com/admin/machines> → find this host → "Edit route
settings" → enable `<VM_IP>/32`. Tailnet DNS does **not** need this.

## Changing the admin port later

`internal_port` in `justfile` is the source of truth. To change:

1. `dotfiles stacks adguard down`
2. Edit `internal_port` in `stacks/adguard/justfile`
3. Edit `~/.volumes/adguard/conf/AdGuardHome.yaml` line `address:` to match
4. `dotfiles stacks adguard up`
