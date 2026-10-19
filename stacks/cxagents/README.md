# cxagents stack

One locked-down tailnet node, `cxagents`, that gives tailnet members a way to reach dev servers running in
agent containers without giving those containers anything else on the tailnet. The node is a tsnet forwarder
([`forwarder/`](forwarder/)) in the `agents` Colima VM. A tailnet member connects to
`https://cxagents.faun-fir.ts.net:<port>`; the forwarder relays the flow to the container with that name on
the `cxagents` Docker network, on the same port. Each agent-facing target joins the
`cxagents` network as an external network. The first target is connectome's `shell` container (`connectome-shell`). It joins `cxagents` through the optional overlay in `stacks/connectome` (see its README).

Two pieces of asymmetry vs the other stacks:

- The node has its own tailnet identity (`cxagents`, tagged `tag:cxagents`), so it is a tailnet peer. The
  policy decides what it can reach; it reaches nothing on `cxmini` except what the policy allows.
- No auth key is ever in the environment, a compose file, a `.env` or `docker inspect`. `login` mints a
  single-use key and feeds it to a one-shot container on stdin. See [Login and identity](#login-and-identity).

## Fresh-device setup

Prerequisites: Stage 2 setup complete (`dotfiles stow setup-colima` already run), the `agents` VM available,
and `tailscale/.env` restored from the password-manager escrow (both tailnet OAuth clients; mode 0600), and the tailnet policy declaring `tag:cxagents` already pushed (see `tailscale/README.md`, Clients). The
`agents` VM must be running for every step below.

```sh
dotfiles stacks vm-agents-up
dotfiles stacks cxagents build        # tests (incl. -race) in the pinned builder, image, build.lock
dotfiles stacks cxagents image-test   # hardened-runtime assertions against the built image
dotfiles stacks cxagents login        # registers the node; never stores a key
dotfiles stacks cxagents up           # refuses on a missing image, an empty state, or an unreadable state
dotfiles stacks cxagents ps           # forwarder healthy
```

`login` prints an admin-console URL and stops when a `cxagents` device already exists on the tailnet that
this state does not own. Delete that device in the admin console, then re-run `login`. See
[Login and identity](#login-and-identity).

`build` writes `build.lock` (the toolchain, Tailscale version, base images by digest, and the binary's
SHA-256). Two builds from the same commit produce the same `build.lock`.

The compose file bind-mounts `./routes` from the checkout the stack was created from. After this branch
is merged, re-create the stack from the main checkout: run `dotfiles stacks cxagents up` there. Compose
recreates the forwarder with the main checkout's `routes` (the state volume is kept). Do not delete the
worktree the stack was created from until that is done.

## Recipes

Run as `dotfiles stacks cxagents <recipe>`. `just -f stacks/cxagents/justfile --list` is the source of truth.

| Recipe | What it does |
|---|---|
| `build` | Runs the race tests in the pinned builder, then `--target test`, builds `tailnet-forwarder:local`, writes `build.lock`. On failure `build.lock` is left unchanged. |
| `image-test` | Static and hardened-runtime assertions against `tailnet-forwarder:local`, each in a throwaway `--network none` container. |
| `test` | `go test ./...` in the pinned builder (Go is not installed on the host). |
| `login` | Mints a single-use, non-ephemeral, pre-authorized key for `tag:cxagents` and pipes it into a one-shot `login` container. Runs the state/device matrix first. |
| `up` | Starts the forwarder. Refuses if the image is missing, the state is empty, or the state is unreadable, so boot and `up-all` never start a node waiting on a login. |
| `down` | Stops the forwarder. Refuses while another container (for example `connectome-shell`) still holds the `cxagents` network; stop that target first. |
| `restart` | Restarts the forwarder. Identity survives (see `smoke`). |
| `ps` | Container status, including stopped. |
| `logs` | Follows the forwarder log (last 100 lines). |
| `pull` | Fetches any digest-pinned base image that is missing locally. |
| `lint` | Static lockdown invariants 1–7 (policy, forwarder compose, routes, key names, identity). Also run by `dotfiles stacks doctor` (`--- cxagents ---`). |
| `lint-test` | Proves each lint invariant fails on a fixture that violates exactly that invariant. |
| `doctor-test` | Proves each `--- cxagents ---` FAIL path with fixtures: a missing forwarder, a missing or empty state volume, a renamed, untagged, offline or certificate-expiring node, and a dead routes target. Never touches the real node or its state. |
| `login-test` | The login state/device matrix (including the unreadable-state refusal and the `Y`/`yes` confirmation), and `up`'s empty- and unreadable-state refusals, against throwaway copies of the state volume. The real state is only read. |
| `smoke` | Live checks: the node is absent from every packet-filter source list on `cxmini`; the forwarder cannot reach `connectome:18768` or the onecli gateway; identity holds across `restart` and `down`/`up`. Then end-to-end through the forwarder, with stdlib servers started in `connectome-shell` and removed afterwards: HTTPS (system trust, no `-k`), plain HTTP and WebSocket on one port; raw TCP echo and banner; closed ports fail fast; port 3100 and 80 unreachable; loopback-only 47806 unreachable; the status endpoint lists the shell's ports and returns 404 to non-target peers; the WebUI guard (403 for same-site, cross-site and foreign Origin; 200 same-origin). `--long` (`dotfiles stacks cxagents smoke --long`, about 11 min) adds the 10-minute WebSocket idle. Restarts the forwarder and connectome (the `down`/`up` check runs last); never changes the forwarder's state or the policy. |
| `smoke-test` | Proves the packet-filter verdict `smoke` applies (bare, `/32`, `/128`, `0.0.0.0/0`, `::/0`, CGNAT, `*`, clean lists) on fixture netmaps. No tailscale or docker. |

`build` runs the race tests itself (`race-test.sh`), so `test` is only needed for a quick run without the
image build. The race detector needs cgo, which is enabled for the test run only. The binary and image are
built with `CGO_ENABLED=0`.

## Routes

`routes` is the forwarder's port table, a read-only bind into the forwarder. One line per target:

```
# target            ports        deny
connectome-shell    1024-65535   3100
```

- `target` is a Docker container name, unique per daemon (lint invariant 5 requires it to exist in a stack
  compose file).
- `ports` is an inclusive range within `1024-65535`. Ranges must not overlap (the forwarder refuses to start on
  a file that fails to parse or overlaps; lint invariant 6 checks the same).
- `deny` is a comma-separated list of ports inside the range that are never routed, or `-` for none.
- Lines starting with `#` are comments. Ports below 1024 are never routed.

The routes file is the master for deny ports. The policy's member grant to `tag:cxagents` is the range
minus the deny ports, and lint invariant 2 cross-checks it.

### Adding a target

1. Split the range that holds the port in `routes`: the new target gets its own line, and the old line keeps
   the rest. Put the target's deny ports on whichever line covers them.
2. Update the member grant `tag:cxagents` `ip` list in `tailscale/policy.hujson` to match the routed ranges
   (each range is inside one route and avoids that route's deny ports).
3. `dotfiles tailscale lint`, then `dotfiles tailscale policy-diff` and `dotfiles tailscale policy-push`
   (push confirms the diff and validates the policy against the live tailnet first).
4. `dotfiles stacks cxagents lint` and `dotfiles stacks cxagents lint-test`. Both must pass.
5. `dotfiles stacks cxagents restart`. The forwarder reads `routes` when it starts.

## Login and identity

`login` reads the node's state and the tailnet's `cxagents` devices, then does one of these (the matrix that
`login-test` covers):

| State | Tailnet | Result |
|---|---|---|
| Holds the node, and its device is named `cxagents` | Present | No-op: "already logged in". |
| Holds a node that is not named `cxagents` | Present | Stops. Prints the device's admin-console URL (`https://login.tailscale.com/admin/machines/<first address>`). Delete it, then re-run. |
| Holds a node whose device is gone | No `cxagents` device at all | Asks for confirmation (`[y/N]`), then wipes the state and registers. `y` or `yes`, in any letter case, confirm; any other answer, including the default, keeps the state ("aborted; state kept"). |
| Empty | Another `cxagents` device exists | Stops. Prints each device's admin-console URL. Delete it, then re-run. |
| Empty | No `cxagents` device | Mints a key and registers the node, then starts the forwarder. |
| Unreadable (corrupt state file, or the state check failed) | Any | Stops with "cannot read state ... nothing changed". Mints nothing, and blames no device: the state may still be healthy. |

If the image is missing, `login` stops and prints the `build` command. `up` also refuses on a missing image.

The key exists only in a pipe from the mint script to the one-shot `login` container. It is single-use, expires
in 10 minutes, and is not written to disk or to the environment. The state volume `cxagents_state` holds the node's
keys and its certificate cache. It is disposable and is not backed up: losing it costs a re-login and a new
certificate, and certificates are rate-limited by Let's Encrypt, so do not wipe the state casually.

## Hardening

The forwarder runs under the lockdown in [`compose.yaml`](compose.yaml) (AC8.2), which lint enforces:

- Non-root (uid 65532), `cap_drop: ALL`, `no-new-privileges`, read-only root filesystem.
- No published ports. The status endpoint (`http://cxagents-forwarder:8080/status`) binds the `cxagents`
  interface only, so it is not reachable from the tailnet; callers on that network that are not a route target get 404.
- Bounded json-file logging (10 MB, 3 files).
- Attached to the `cxagents` network only. The network is not `internal` because the node needs egress to the
  Tailscale control plane and DERP.
- No privileged mode, no `cap_add`, no `devices`, no host `pid`, `ipc`, `userns_mode` or `cgroup` namespace, no
  `volumes_from`, no `sysctls`, and no `security_opt` entry that is `unconfined` or a `disable`. Exactly two volumes:
  the state volume at `/state` and the read-only bind of `routes`.
- Image: builder and runtime base images pinned by digest (distroless, nonroot). The binary is built with
  `CGO_ENABLED=0 -trimpath -mod=readonly`; `build.lock` records its hash.

The lint (`dotfiles stacks cxagents lint`) fails on:

1. Any grant, ACL or SSH rule whose source is not on the source allowlist: `autogroup:member`, `autogroup:admin`,
   `autogroup:owner`, `autogroup:it-admin`, `autogroup:network-admin`, `autogroup:billing-admin`,
   `autogroup:auditor`, `group:<name>`, or a user login (`name@provider`). Any other source (`tag:cxagents`, `*`,
   other autogroups, CIDRs, host aliases, ipsets) fails, because it may denote the node.
2. A grant that may reach `tag:cxagents`. A grant is selected unless every one of its destinations is on the
   destination allowlist: `autogroup:member`, `autogroup:self`, `autogroup:internet`, `group:<name>`, a user
   login, or `tag:<name>` with `<name>` not `cxagents` in any letter case. A grant with no `dst` array, or an
   empty one, is selected too. A selected grant passes only if its `ip` list is non-empty and each entry is a
   `tcp:N` or `tcp:N-M` range inside one route that contains none of that route's deny ports. So a grant with any
   destination outside the allowlist counts as reaching cxagents: its ports must be tcp ranges inside routes,
   avoiding deny ports. An ACL destination outside the allowlist is refused: its host part (before the last colon)
   must be on the destination allowlist, or the ACL fails. Use a grant instead.
3. Forwarder compose hardening (the list above).
4. An auth-key or OAuth key name in any stack's `.env` or compose environment (key names only; no values are read).
5. A route target that is not a container name in a stack compose file.
6. Routes that do not parse, start below 1024, end above 65535, overlap, or place a deny port outside their range.
7. Forwarder identity not being `cxagents` / `tag:cxagents`, or the tag missing from `tagOwners`.

`lint-test` proves each of those fails on a fixture that violates exactly that invariant. `smoke` checks the
network side: the node is not a source in any packet-filter rule on `cxmini`, and the forwarder cannot reach
`connectome:18768` or the onecli gateway. The policy also denies `tag:cxagents` the SSH, DNS and connectome WebUI
ports on `cxmini`.

## Doctor

`dotfiles stacks doctor` runs `stacks/cxagents/scripts/doctor.sh` and prints its lines under `--- cxagents ---`. The checks are read-only. They read no `.env` value; the lint reads key names only:

- The agents VM is running. If it is not, the section reports OFF, not FAIL.
- The image `tailnet-forwarder:local` exists.
- The state volume `cxagents_state` exists and holds a node. A missing volume is a FAIL, and doctor does not create it. An empty or unreadable state is a FAIL. While the image is missing the state check is skipped (OFF): the check needs the image, and doctor never pulls one.
- The forwarder container is running and healthy.
- The node, by the forwarder's own `check`: named `cxagents`, tagged `tag:cxagents` and no other tag, online, and with a certificate valid for more than 14 days. Each `problem:` line is a FAIL. A passing check prints the node, its tags and its certificate expiry.
- Each `routes` target is running. A running target that is not on the `cxagents` network is a WARN (for example, connectome was started without the overlay).
- The lockdown lint (`lint.sh`, invariants 1-7).

`dotfiles stacks cxagents doctor-test` proves the FAIL paths with fixtures.

## Accepted exposures

Each of these is accepted for this single-operator tailnet.

- **Same-site with the cxmini services.** `cxagents.faun-fir.ts.net` and every other `*.faun-fir.ts.net` service share a site, so an agent page is same-site with them. Residual: while logged in to AdGuard, FreshRSS, Wallabag, Homebridge or the connectome WebUI, an agent page can send forged same-site requests and set cookies for `Domain=faun-fir.ts.net`. The WebUI cross-site guard covers only the WebUI (see `stacks/connectome/README.md`, Known exposures), and password-manager exact-host matching (below) keeps saved logins off the agent host.
- **Every allowed port is reachable.** Members the policy grants reach every port in `routes` (1024-65535 except 3100 today). Agents in different targets are not isolated from each other.
- **The status endpoint is unauthenticated.** `http://cxagents-forwarder:8080/status` answers without credentials to any route target on the `cxagents` network, and it lists the target ports and deny ports. Other callers get 404.
- **Plain HTTP works.** `http://cxagents.faun-fir.ts.net:<port>` reaches the same servers as HTTPS. Browsers treat that origin as insecure.
- **The lockdown limits the node, not the agent.** The policy and the packet filter limit what the node can reach. The agent's own outbound traffic, from the shell and connectome through the agents VM's NAT, is unchanged.
- **The hostname is public.** `cxagents.faun-fir.ts.net` appears in Certificate Transparency logs with its certificate.

## Operator step: password manager

This step is not automated. The user does it in the password manager. On every saved `*.faun-fir.ts.net` login (FreshRSS, Wallabag, Homebridge, AdGuard, the connectome WebUI), set **exact host** URI matching, so the password manager never offers those logins on `cxagents.faun-fir.ts.net`. It is a per-login setting that syncs with the vault. Until it is set, the same-site exposure above is wider than it needs to be.

## Dial behaviour

The forwarder accepts a tailnet flow first, then dials the target in the background. This is deliberate: dialing
inside the tsnet callback would stall every new inbound flow to the node while a target is starting.

- **Routed port, nothing listening:** the client's connection is accepted, then closed within about 2 seconds
  (a reset where the connection supports it, otherwise a plain close). The client sees "connected, then closed", not "connection refused". Nothing is
  cached, so a server started on that port later is reachable on the next connect.
- **Policy-blocked port** (below 1024, a deny port, or any port the grant does not include): the packet filter
  drops the packets, so the client times out. It does not get a refusal.
- A target name is resolved every 5 seconds, and again after a failed dial, so a restarted target is picked up
  without a restart of the forwarder.
