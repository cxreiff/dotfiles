# adguard stack

AdGuard Home in the bridged `adguard` Colima VM with `network_mode: host`,
so DNS source IPs are preserved per-client.

## Fresh-device setup

Prerequisites: stow + colima profiles already up (see `../README.md` and
`../../stow/README.md`).

```sh
dotfiles stacks adguard up         # boot AGH (creates volume dirs, starts wizard on :3000)
# complete wizard (see below)
dotfiles stacks adguard serve      # expose via Tailscale at https://<host>.<tailnet>.ts.net:8689
dotfiles stacks adguard advertise  # advertise VM IP as Tailscale subnet route
```

## First-run wizard

1. Find the VM IP: `colima list` → look at the `adguard` row's address.
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

## Manual steps not in the justfile

### Router (RT-AC68U or equivalent)

- **DHCP reservation**: pin the AGH VM's MAC to its current IP.
  - MAC: `52:55:55:c6:d2:9f` (deterministic, stable across `colima stop`/`start`)
  - IP: whatever the VM currently has (`colima list`)
  - On Asus routers, set "Manual Assignment" master toggle to "Yes" or
    reservations won't be enforced.
- **DHCP DNS**:
  - Primary: `<VM_IP>` (AGH)
  - Secondary: `1.1.1.1` (fallback if AGH is down — internet survives)

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
