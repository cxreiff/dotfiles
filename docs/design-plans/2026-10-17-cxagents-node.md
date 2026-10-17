# cxagents Node Design

## Summary

This design adds a single, locked-down node to the operator's private Tailscale network (tailnet), named `cxagents`, so that web servers and other network services started by AI agents running in containers can be opened from the operator's own devices. Today an agent can start a dev server inside its container, but nothing outside can reach it. The new node publishes every agent-run server at `https://cxagents.faun-fir.ts.net:<port>`, with a real, browser-trusted certificate and no client setup. The server's own port number is the only thing that varies per server. Services that are not HTTP, such as SSH-style or database-style protocols, pass through as raw TCP. The node can receive connections but can never start any, and a few infrastructure ports (3100 and everything below 1024) are blocked.

The approach has three parts. First, a small purpose-built Go program, the "forwarder", joins the tailnet as the `cxagents` node. It accepts a connection on any port, looks the port up in a tracked routing file, connects to the target container on a private Docker network, and relays traffic both ways. It detects whether the client is speaking TLS and, if so, terminates it with the node's certificate. It also exposes a status endpoint that agents can query from inside their container to see what is being served and to diagnose conflicts. Second, a new top-level `tailscale/` module puts the tailnet access policy in the repo as code, with recipes to pull, diff, validate and push it. `doctor` flags any drift from the live policy. The same module holds scoped, tailnet-owned OAuth credentials that replace the existing full-admin personal access token (PAT) used by the DNS failover scripts. Third, the node logs in with a short-lived, single-use auth key that is minted on demand and never stored, and the existing `connectome` stack opts in as the first target. The work is split into seven phases so that a lost machine can be rebuilt from the repo and docs along one defined path.

## Definition of Done

- A locked-down tagged `cxagents` tailnet node (one for all agents) through
  which any server an agent runs in its container is reachable from the
  operator's devices at `https://cxagents.faun-fir.ts.net:<port>` with a
  publicly-trusted cert and no client-side setup; non-HTTP servers pass through
  as raw TCP. The node can't initiate connections to anything; port 3100 and
  other infra ports are never reachable. Every port an agent listens on (except
  blocked infra ports) being reachable from the operator's own devices is
  accepted.
- Agents get a robust interface: either publishing is trivially automatic, or
  they have tools to inspect what's served/free and get clear feedback on
  conflicts (choice made in brainstorming). Built for today's single `shell`,
  structured so more agent containers drop in.
- The tailnet policy lives in the repo, with a `dotfiles` recipe that validates
  and pushes it; `doctor` fails on drift between repo and live policy.
- A shared Tailscale OAuth client credential (scoped, non-expiring) in a
  generic location replaces the adguard PAT, used by policy push, the drift
  check and `tailnet-dns`.

Out of scope: tagging cxmini, Tailscale Services, Funnel/public exposure, the
LAN-egress lockdown of agent containers.

## Acceptance Criteria

### cxagents-node.AC1: Tailnet policy is code (Phase 1)
- **cxagents-node.AC1.1 Success:** `dotfiles tailscale policy-pull` on a fresh checkout writes `tailscale/policy.hujson` byte-identical to the live policy; `policy-status` then prints `in-sync`.
- **cxagents-node.AC1.2 Failure:** `policy-pull` refuses (non-zero, file untouched) when `policy.hujson` exists and `--force` is not given.
- **cxagents-node.AC1.3 Success:** `policy-push` of an edited file validates via the API, shows the diff, asks for confirmation, and after the push `policy-status` is `in-sync` and the live ETag equals `shasum -a 256 tailscale/policy.hujson`.
- **cxagents-node.AC1.4 Failure:** `policy-push` aborts with "live policy changed; run policy-diff" and changes nothing when the live policy changed after the diff (412).
- **cxagents-node.AC1.5 Failure:** `policy-push` of a file the API rejects at validate, or the lint rejects, never POSTs.
- **cxagents-node.AC1.6 Edge:** `policy-diff` exits 0 with no output when repo and live are identical, non-zero with a unified diff otherwise.

### cxagents-node.AC2: Credentials are shared and least-privilege (Phases 1, 3)
- **cxagents-node.AC2.1 Success:** `api.sh --client admin GET /tailnet/-/dns/nameservers` returns 200 using only `tailscale/.env`.
- **cxagents-node.AC2.2 Failure:** `api.sh` exits 2 with a hint naming `tailscale/.env.example` when credentials are missing or still placeholders; it never prints a secret or token.
- **cxagents-node.AC2.3 Failure:** the admin client is refused (403) on `/tailnet/-/keys`.
- **cxagents-node.AC2.4 Failure:** the authkeys client is refused on `/tailnet/-/acl` writes and `/tailnet/-/dns/nameservers` writes.
- **cxagents-node.AC2.5:** `tailscale/.env` is mode 0600 and gitignored; no file outside `tailscale/` contains a Tailscale client secret, PAT or auth key key name.

### cxagents-node.AC3: adguard uses the shared credential (Phase 2)
- **cxagents-node.AC3.1 Success:** `tailnet-dns-on/off/status` behave exactly as before with no `TAILSCALE_PAT` in any file.
- **cxagents-node.AC3.2 Failure:** with `tailscale/.env` missing, `tailnet-dns.sh on` exits non-zero with the recovery hint and leaves Global NS unchanged; `adguard up` surfaces that exit code.
- **cxagents-node.AC3.3:** `TAILSCALE_PAT` is absent from `stacks/adguard/.env.example`, adguard README and scripts.

### cxagents-node.AC4: doctor covers the tailnet and the node (Phases 2, 7)
- **cxagents-node.AC4.1 Success:** `--- Tailnet policy ---` reports `[OK]` when repo SHA-256 equals the live ETag.
- **cxagents-node.AC4.2 Failure:** it reports `[FAIL]` when the live policy differs from the repo (e.g. after an admin-console edit).
- **cxagents-node.AC4.3 Edge:** missing `tailscale/.env` or unreachable API is `[WARN]`, not `[FAIL]`; `tailscale/.env` with wrong mode or missing keys is `[FAIL]`.
- **cxagents-node.AC4.4 Success:** `--- cxagents ---` reports the forwarder running, node `cxagents` online with tags `[tag:cxagents]`, and the cert valid >14 days.
- **cxagents-node.AC4.5 Failure:** forwarder stopped, node offline/untagged/renamed (e.g. `cxagents-1`), cert ≤14 days, or a `routes` target with no running container → `[FAIL]`.
- **cxagents-node.AC4.6:** doctor still reads only `.env` key names, never values (aside from the existing BRIDGE_USERNAME exception).

### cxagents-node.AC5: The node is tagged, locked down and logged in without a stored key (Phases 3, 5)
- **cxagents-node.AC5.1 Success:** after the Phase 3 push, the user's devices still reach each other on all ports (existing cxmini serve URLs load from cxmacbook/cxphone; Taildrive and SSH unchanged).
- **cxagents-node.AC5.2 Success:** `dotfiles tailscale authkey tag:cxagents` prints one single-use, pre-authorized, non-ephemeral key expiring in ≤10 minutes.
- **cxagents-node.AC5.3 Failure:** no tailnet peer's packet filter lists the cxagents node's IPs as a source (checked on cxmini via `tailscale debug netmap`).
- **cxagents-node.AC5.4 Success:** `dotfiles stacks cxagents login` on empty state registers a node named exactly `cxagents`, tagged `tag:cxagents`, key expiry disabled.
- **cxagents-node.AC5.5 Edge:** `login` with existing state is a no-op; with empty state but a pre-existing `cxagents` device, it stops before minting and prints that device's admin URL.
- **cxagents-node.AC5.6 Success:** the node keeps its name and identity across `restart`, `down`/`up`, and an agents VM restart, with no auth key in `.env`, compose files or container environment after login.

### cxagents-node.AC6: Any agent server is reachable over trusted HTTPS (Phases 4, 6)
- **cxagents-node.AC6.1 Success:** an HTTP server on `shell` `0.0.0.0:P` (any allowed P) loads at `https://cxagents.faun-fir.ts.net:P` with certificate verification on (`curl` without `-k`; browser shows no warning).
- **cxagents-node.AC6.2 Success:** the same server also answers at `http://cxagents.faun-fir.ts.net:P`.
- **cxagents-node.AC6.3 Success:** WebSockets work over `wss://` on the same port (live-reload), and an idle WebSocket survives 10 minutes.
- **cxagents-node.AC6.4 Success:** a raw client-speaks-first TCP server (e.g. echo) and a server-speaks-first one (banner) both work through `nc`.
- **cxagents-node.AC6.5 Failure:** with nothing listening on P, the client gets connection refused/reset within ~2 s, and a server started afterwards on P is reachable immediately (no stale state).
- **cxagents-node.AC6.6 Failure:** port 3100 and ports <1024 are unreachable from the tailnet, even though shell listens on 3100.
- **cxagents-node.AC6.7 Failure:** a server bound only to `127.0.0.1` in shell is unreachable (refused).
- **cxagents-node.AC6.8 Failure:** the forwarder refuses to start on a `routes` file that fails to parse or has overlapping ranges.

### cxagents-node.AC7: Agents can diagnose their servers (Phases 4, 6)
- **cxagents-node.AC7.1 Success:** `curl http://forwarder/status` from shell returns its target name, range, deny list, base URL, and each listening port with its URL and http/tls classification.
- **cxagents-node.AC7.2 Success:** `?ports=` narrows the check; `?format=json` returns the JSON shape in the design.
- **cxagents-node.AC7.3 Edge:** a loopback-only server does not appear in `listening`, while it does appear in shell's own `ss -ltn`.
- **cxagents-node.AC7.4 Failure:** a caller with no route gets `404 not a cxagents target`; the status endpoint is not reachable from the tailnet.
- **cxagents-node.AC7.5 Edge:** repeated full scans within 5 s are served from cache (no second scan).

### cxagents-node.AC8: The forwarder is isolated (Phase 5)
- **cxagents-node.AC8.1 Failure:** from inside the forwarder's network namespace, `connectome:18768` and the onecli gateway are unreachable.
- **cxagents-node.AC8.2:** the forwarder container runs non-root with `cap_drop: ALL`, `no-new-privileges`, read-only root, no published ports, and only the `cxagents` network (lint-enforced).
- **cxagents-node.AC8.3:** lint fails if any grant has `tag:cxagents` as a source, if any grant to `tag:cxagents` includes a `routes` deny port, or if an auth-key/OAuth key name appears in a stack `.env` or compose environment; lint-test proves each.

### cxagents-node.AC9: connectome is the first target (Phase 6)
- **cxagents-node.AC9.1 Success:** `shell` is on the `cxagents` network; connectome `up` refuses with a clear message when the `cxagents` network is missing.
- **cxagents-node.AC9.2:** the agent prompt states the URL pattern, the 0.0.0.0 bind rule, the allowed ports, the status endpoint and the Vite host-check note.
- **cxagents-node.AC9.3:** connectome's existing `lint`, `lint-test` and `smoke` still pass.
- **cxagents-node.AC9.4 Success:** `up-all` brings up onecli, cxagents, connectome in that order; `down-all` stops connectome before cxagents.

### cxagents-node.AC10: Rebuild path is defined (Phase 7)
- **cxagents-node.AC10.1:** `docs/migration-recovery.md` covers, in order, restoring `tailscale/.env` from escrow, `cxagents build`, `cxagents login`, and the stale-device step; following it on a fresh device yields doctor with no FAILs.
- **cxagents-node.AC10.2:** `tailscale/README.md` documents the one-time tailnet bootstrap order (admin client → pull → edit/push → authkeys client) and PAT revocation.
- **cxagents-node.AC10.3:** CLAUDE.md reflects the four repo areas, the `tailscale/` module, OAuth in place of the PAT rotation section, and the new reproducible-vs-runtime rows.

## Glossary

- **cxagents**: The name of the new tailnet node, of the new stack (`stacks/cxagents/`), and of the private Docker network that links the forwarder to its target containers.
- **Tailnet**: The operator's private Tailscale network of their own devices (here `cxreiff.github`, with DNS suffix `faun-fir.ts.net`).
- **MagicDNS**: Tailscale's automatic DNS naming for tailnet devices, such as `cxagents.faun-fir.ts.net`.
- **Tailnet policy (HuJSON)**: The tailnet-wide file that defines which devices and tags may reach which others, on which ports. HuJSON is JSON that allows comments and trailing commas. Here it is `tailscale/policy.hujson`.
- **Grant**: A rule in the tailnet policy that allows a source to reach a destination on given ports. The design replaces the allow-everything grant with narrower ones.
- **Tag (`tag:cxagents`)**: A Tailscale label that gives a machine a non-user identity. Tagged nodes have key expiry disabled, and policy can restrict what they may do.
- **`autogroup:member` / `autogroup:self` / `autogroup:tagged` / `autogroup:admin`**: Built-in policy groups. They mean, respectively, the tailnet's own users' devices, the user's own devices, any tagged node, and tailnet admins.
- **tagOwners**: The policy section that says who may assign a given tag.
- **ETag / If-Match / 412**: HTTP optimistic-concurrency headers. The live policy's ETag is the SHA-256 of its bytes. A push sends it as `If-Match`, and a stale value returns HTTP 412 and changes nothing. This is how push-conflict and drift detection work.
- **Drift**: The repo's policy file differing from the live tailnet policy, for example after an admin-console edit.
- **OAuth client (`dotfiles-admin`, `dotfiles-authkeys`)**: A scoped Tailscale API credential that is exchanged for a 1-hour bearer token. It replaces the full-admin PAT. The admin client handles policy and DNS. The authkeys client may only mint tagged auth keys.
- **PAT (personal access token)**: The existing Tailscale API token used by the adguard DNS scripts. It expires every 90 days and carries full-admin scope, so it is being retired.
- **Auth key**: A one-time Tailscale credential used to register a new node. Here it is single-use, pre-authorized, valid for 10 minutes, and never stored.
- **`api.sh`**: The only script that reads the OAuth secrets. It wraps authenticated Tailscale API calls and has defined exit codes (2 for missing credentials, 3 for API errors).
- **tsnet**: Tailscale's Go library for embedding a tailnet node inside a program. It lets the forwarder be a node itself, without a separate Tailscale daemon.
- **`RegisterFallbackTCPHandler`**: The tsnet hook that receives every inbound TCP connection on a port with no explicit listener. It lets one node serve all ports.
- **Forwarder (`tailnet-forwarder`)**: The generic Go program that is the node. It routes, terminates TLS, relays traffic and serves the status endpoint.
- **`routes` file**: The tracked table mapping a target container name to a port range and deny list. It must not overlap, or the forwarder refuses to start.
- **Target**: A container the forwarder relays to, named by its Docker DNS name. Today this is only connectome's `shell`.
- **Peek / splice**: Peek means briefly reading the client's first bytes to classify the connection as TLS or raw. Splice means copying bytes both ways between two connections.
- **TLS ClientHello / TLS termination**: The first message of a TLS handshake. Terminating TLS means the forwarder decrypts HTTPS using the node certificate and passes plaintext to the target.
- **Half-close**: Closing one direction of a connection while the other stays open. It lets protocols finish cleanly.
- **RST / connection refused**: A TCP reset. The forwarder uses it to tell clients immediately that nothing is listening, rather than hanging.
- **Server-speaks-first protocol**: A protocol where the server sends data before the client does (SSH, SMTP, MySQL). It is why the peek step has a timeout and falls back to raw splicing.
- **Let's Encrypt cert / rate limits**: Tailscale obtains one publicly trusted certificate for the node from Let's Encrypt. It is cached in node state because repeated re-issuance can hit rate limits.
- **Status endpoint**: A read-only HTTP endpoint (`http://forwarder/status`), reachable only on the `cxagents` Docker network. Agents use it to see which ports are listening, their URLs and whether they speak HTTP.
- **Colima / agents VM**: Colima runs Docker inside lightweight VMs on the Mac. The `agents` VM hosts the onecli and connectome stacks and now cxagents.
- **connectome / `shell`**: The agent-hosting stack and its `shell` container, which is the first target for this feature.
- **onecli / `onecli-agents` network**: The credential-vault stack. It owns an external Docker network that connectome joins. The `cxagents` network copies this pattern.
- **Docker network (external / internal)**: A virtual network between containers. "External" means created by one stack and joined by another. A non-internal network allows outbound traffic.
- **Named volume (`cxagents_state`)**: Docker-managed storage inside the VM. It holds the node's key and certificate cache and is deliberately not backed up.
- **Distroless static image**: A minimal container image with no shell or package manager, running a statically compiled binary. It reduces attack surface.
- **Container hardening (`cap_drop: ALL`, `no-new-privileges`, `read_only`)**: Compose settings that remove Linux capabilities, block privilege escalation and make the root filesystem read-only.
- **`dotfiles` / `just` recipes / `mod`**: The repo's command entry point. `just` is a task runner, and `mod` mounts a sub-module of recipes such as `dotfiles tailscale ...`.
- **`doctor`**: The repo's read-only health check (`dotfiles stacks doctor`). It gains sections for tailnet policy and cxagents.
- **Lint / lint-test / smoke**: Lint is a static invariant check. Lint-test proves the lint catches bad fixtures. Smoke is an end-to-end check against the live system.
- **Escrow**: Storing a secret copy (here `tailscale/.env`) in the password manager so a rebuild can restore it.
- **Vite host check**: A dev-server (Vite) setting that rejects requests for unrecognized hostnames. Agents must allow `cxagents.faun-fir.ts.net` for it to work.
- **Taildrive**: Tailscale's file-sharing feature. It is unchanged by this design.
- **`tailscale-rs`**: Tailscale's experimental Rust implementation. It is noted as a future porting target but is not used now.
- **Declarativeness (NixOS sense)**: The principle that the repo should fully describe the system, so a lost machine can be rebuilt to the same state from it.
- **AC (acceptance criteria) IDs**: Labels such as `cxagents-node.AC6.3` used to trace tests and phases to requirements.

## Verified findings

Probed live on 2026-10-17 (tailnet `cxreiff.github`, MagicDNS `faun-fir.ts.net`):

- **Live policy is the default**: grants `*`→`*` all ports plus a Taildrive
  grant (`autogroup:member`→`autogroup:self`), two SSH rules (`accept` non-root
  / `check` root, both `autogroup:member`→`autogroup:self`), one `nodeAttrs`
  (Taildrive). 92 lines of HuJSON, comments included. All four nodes are
  user-owned; nothing is tagged; Tailnet Lock is off.
- **Existing PAT is full-admin**: the adguard `dns_token` PAT has scopes
  `all`/`all:read` (expires 2026-11-22), not DNS-only as the adguard docs say.
- **OAuth works on this plan**: the `dotfiles-admin` client (created
  2026-10-17, stored in `tailscale/.env`) exchanges for a 1 h bearer token with
  scopes `devices:core:read devices:posture_attributes policy_file dns
  logs:configuration:read`. Reads of the policy (HuJSON and JSON), validate,
  DNS nameservers (`/tailnet/-/` and `/tailnet/cxreiff.github/`) and
  `/devices` succeed; `/keys` is refused (403).
- **Policy round-trips byte-exact**: a pushed HuJSON (with an added comment)
  reads back byte-identical. A push with a stale `If-Match` returns
  `412 precondition failed, invalid old hash` and changes nothing. **The ETag is
  the SHA-256 of the policy bytes**, so drift is `shasum -a 256` vs the live
  ETag. Probe left the live policy byte-identical to its original.
- **tsnet** (`tailscale.com/tsnet`, latest upstream v1.104.1):
  `(*Server).RegisterFallbackTCPHandler` (since v1.52) receives every inbound
  TCP flow on a port with no explicit listener; the packet filter (tailnet
  policy) runs before it. One node cert (Let's Encrypt, via
  `LocalClient().GetCertificate`) covers every port; MagicDNS + HTTPS are
  already enabled (cxmini serves HTTPS). Tailscale issues no subdomain or
  wildcard certs, so the port is the only per-server dimension. tsnet exposes
  only in-process dialing; other processes cannot use the node.
- **Stock `tailscale/tailscale` image** can't express "all ports": its serve
  config is exact-port entries only, which would need a controller (rejected).
- **Rust**: Tailscale's `tailscale-rs` (April 2026) is an experimental preview
  that Tailscale says is unstable and insecure until audited; Go is used for
  the forwarder.

## Architecture

Two new modules plus one opt-in edit to connectome.

```
your devices ──tailnet──▶ cxagents node (tsnet, in container `cxagents-forwarder`)
                              │  policy: members → tag:cxagents tcp:1024-3099,3101-65535
                              │  tag:cxagents → (nothing)
                              ▼
                       Docker network `cxagents` (agents VM)
                              ▼
                       target container (connectome `shell`), port P
```

### `tailscale/` — tailnet-wide management (new top-level module)

`mod tailscale` in the root `justfile`, beside `stacks` and `stow`. Owns
everything that is tailnet-global; stacks read it, it never references a stack.

- `tailscale/policy.hujson` — the tailnet policy, source of truth.
- `tailscale/.env` (0600, gitignored) + tracked `.env.example` — two OAuth
  clients, escrowed in the password manager:
  - `TS_ADMIN_CLIENT_ID` / `TS_ADMIN_CLIENT_SECRET` — `dotfiles-admin`:
    `policy_file`, `dns`, plus the required `devices:core:read`,
    `devices:posture_attributes`. No tags.
  - `TS_AUTHKEYS_CLIENT_ID` / `TS_AUTHKEYS_CLIENT_SECRET` —
    `dotfiles-authkeys`: `auth_keys` only, tags `tag:cxagents`.
- `tailscale/scripts/api.sh` — the only code that reads the client secrets.
  Contract:
  ```
  api.sh [--client admin|authkeys] METHOD PATH [curl args...]
    PATH is relative to https://api.tailscale.com/api/v2 (e.g. /tailnet/-/acl)
    stdout: response body; exit 0 on 2xx, 3 on HTTP/API error (status + message
    on stderr), 2 on missing/placeholder credentials
  ```
  It exchanges the client at `/api/v2/oauth/token` per invocation (tokens last
  1 h; no caching on disk).
- Recipes (`dotfiles tailscale …`):
  - `policy-pull [--force]` — writes the live HuJSON to `policy.hujson`;
    refuses if the file exists unless forced (bootstrap only).
  - `policy-diff` — `diff` of live bytes vs repo; exit 0 when identical.
  - `policy-push` — lint → API validate → show diff → confirm → POST with
    `If-Match` = the ETag of the bytes that were diffed. A 412 aborts with
    "live policy changed; run policy-diff".
  - `policy-status` — prints `in-sync` / `drift` (repo SHA-256 vs live ETag).
  - `authkey <tag>` — prints one auth key: single-use, pre-authorized,
    non-ephemeral, 10-minute expiry, tagged `<tag>`.
  - `lint`, `lint-test`, `smoke`.

### `stacks/cxagents/` — the cxagents node (new stack)

Named for the node because the stack maps one-to-one onto it. Docker context
`colima-agents`.

- `stacks/cxagents/forwarder/` — Go module, program `tailnet-forwarder`
  (generic: it doesn't know it is cxagents; config tells it). Pinned
  `tailscale.com` version in `go.mod`.
- Image `tailnet-forwarder:local`: Go builder stage → static distroless
  runtime, non-root. Built by `dotfiles stacks cxagents build` from in-repo
  source (no external clones).
- `compose.yaml`, service `forwarder`, container `cxagents-forwarder`:
  shared hardening (`cap_drop: ALL`, `no-new-privileges`), `read_only: true`,
  no published ports, `restart: unless-stopped`. Volume `cxagents_state`
  (tsnet state: node key + cert cache; not backed up). Networks: only
  `cxagents`, which this stack creates and owns (`name: cxagents`, bridge, not
  internal; egress only for Tailscale control/DERP).
- `stacks/cxagents/routes` — tracked routing table, read-only bind into the
  forwarder:
  ```
  # target   ports         deny
  shell      1024-65535    3100
  ```
  `target` is a DNS name on the `cxagents` network. Ranges must not overlap
  (forwarder refuses to start otherwise). A future target splits a range.
- Forwarder config via environment: `TS_HOSTNAME=cxagents`,
  `TS_ADVERTISE_TAGS=tag:cxagents`, `TS_AUTHKEY` (only on the login start,
  empty otherwise), routes path, status listen address.

### Forwarder contract

For each inbound tailnet TCP flow to port P (already allowed by the policy):

1. Look up P in `routes`. No route, or P denied → reject (RST).
2. Dial `<target>:P` on the `cxagents` network, 2 s timeout. Refused/timeout →
   reject (RST): the client sees "connection refused". Nothing is cached.
3. Peek up to ~300 ms for client bytes:
   - TLS ClientHello → terminate TLS with the node cert, splice plaintext.
   - other bytes → replay them to the target, splice raw.
   - no bytes (server-speaks-first: SSH, SMTP, MySQL) → splice raw.
4. Splice both directions with half-close; no idle timeout (live-reload
   sockets survive).

One log line per flow to stdout: time, src node, port, target, `tls|raw`,
outcome.

**Status endpoint** — listens on the `cxagents` network interface only, never
the tailnet. Read-only, unauthenticated (anyone on the bridge is a target):

```
GET http://forwarder/status[?ports=5173,8000][&format=json]

text (default):
  target: shell
  node:   https://cxagents.faun-fir.ts.net:<port>
  range:  1024-65535   deny: 3100
  listening (reachable from the forwarder):
    5173  tls=no  http=yes   https://cxagents.faun-fir.ts.net:5173
    9000  tls=no  http=no    (raw TCP)  cxagents.faun-fir.ts.net:9000

json:
  {"target":"shell","node":"cxagents.faun-fir.ts.net",
   "range":{"from":1024,"to":65535},"deny":[3100],
   "listening":[{"port":5173,"http":true,"url":"https://cxagents.faun-fir.ts.net:5173"}]}
```

Caller identity is resolved from its source IP via Docker DNS reverse lookup;
a caller with no route gets `404 not a cxagents target`. A full-range scan uses
bounded concurrency (~1 s on the bridge); results are cached 5 s per caller.

### Policy changes (in `tailscale/policy.hujson`)

Starting from the pulled live policy:

- `tagOwners`: `"tag:cxagents": ["autogroup:admin"]`.
- Replace grant `*`→`*` with `autogroup:member`→`autogroup:member` `ip: ["*"]`
  (preserves today's behavior between the user's own devices).
- Add grant `autogroup:member`→`tag:cxagents` `ip: ["tcp:1024-3099",
  "tcp:3101-65535"]`.
- No grant or ACL with `tag:cxagents` (or `*`, or `autogroup:tagged`) as
  source. Taildrive, SSH and `nodeAttrs` unchanged.

### Login and node identity

`dotfiles stacks cxagents login`:

1. If `cxagents_state` already holds a node, no-op ("already logged in").
2. Uses the admin client (`devices:core:read`) to check for an existing
   `cxagents` device. If one exists (state was lost), stop with the device's
   admin-console URL and the instruction to delete it, so the re-login gets
   the exact name `cxagents` and not `cxagents-1`.
3. Mints a key with `dotfiles tailscale authkey tag:cxagents` and starts the
   forwarder with `TS_AUTHKEY` set for that one `compose up`; the key is spent
   on first use and expires in 10 minutes. No auth key is stored anywhere.

Tagged nodes have key expiry disabled, so the node stays logged in as long as
`cxagents_state` survives.

### Target opt-in (connectome today)

- `stacks/connectome/compose.yaml`: `shell` joins external network
  `cxagents`.
- `stacks/connectome/justfile` `up`: also refuses when network `cxagents` is
  missing (same pattern as `onecli-agents`).
- `stacks/connectome/recipes/agent.json` `systemPrompt`: one paragraph —
  servers you start on `0.0.0.0:<port>` (1024–65535, not 3100) are at
  `https://cxagents.faun-fir.ts.net:<port>` (plain `http://` also works); check
  `curl http://forwarder/status`; dev servers with host checks (Vite) must
  allow `cxagents.faun-fir.ts.net`.

### Ordering

`stacks/justfile`: `mod cxagents`; `up-all` order adguard, freshrss,
homebridge, onecli, **cxagents**, connectome, wallabag; `down-all` stops
connectome before cxagents; `ps-all`/`pull-all` include it; `backup-all` does
not (no backed-up state).

## Existing Patterns

- **External network owned by a provider stack, joined by consumers**: onecli
  owns `onecli-agents`, connectome joins it and its `up` refuses without it
  (`stacks/connectome/justfile` `up`). `cxagents` follows this exactly.
- **Per-stack justfile + `docker --context colima-<profile>`**, recipes listed
  explicitly in `stacks/justfile` aggregates (no loops).
- **`.env` 0600 + tracked `.env.example`**, key names only in doctor/lints
  (`stacks/scripts/doctor.sh` Check B; `stacks/connectome/scripts/lint.sh`).
- **Secrets never echoed**: `init-env.sh` writes via temp file + `mv`;
  `tailnet-dns.sh` passes the token only in headers.
- **Static invariant lints + fixture lint-tests** (`connectome/scripts/lint.sh`,
  `lint-test.sh`), surfaced in `doctor` by parsing `[OK]`/`[FAIL]`.
- **Test scripts tagged with AC ids**, one line per check, cleanup trap
  (`connectome/scripts/image-test.sh`, `smoke.sh`).
- **Locally built images, pinned inputs** (`connectome/scripts/build.sh`,
  `sources.lock`).
- **Absolute `/opt/homebrew/bin/tailscale`** in scripts (LaunchDaemon PATH).

New patterns:

- **First top-level module with its own `.env`** (`tailscale/`); the repo had
  only per-stack `.env` files. Justified: the policy and API credentials are
  tailnet-global, used by adguard, cxagents and doctor.
- **First image built from in-repo source** (`stacks/cxagents/forwarder/`),
  vs connectome's external clones. Simpler: the Go module and `go.sum` pin
  everything.
- **First tagged node and first non-default tailnet policy.**

## Implementation Phases

<!-- START_PHASE_1 -->
### Phase 1: `tailscale/` module and policy as code
**Goal:** The tailnet policy is tracked in the repo, pushable safely and
checkable for drift, using the `dotfiles-admin` OAuth client.

**Components:**
- Root `justfile`: `mod tailscale`.
- `tailscale/justfile`, `tailscale/.env.example`, `tailscale/README.md`.
- `tailscale/scripts/api.sh` (contract above).
- `tailscale/scripts/policy.sh` behind `policy-pull|diff|push|status`.
- `tailscale/policy.hujson` — pulled from live, committed unchanged.
- `tailscale/scripts/lint.sh` + `lint-test.sh` (+ fixtures): no `*`/tag/
  `autogroup:tagged` source in grants/ACLs; every used tag defined in
  `tagOwners`; file parses.
- `tailscale/scripts/smoke.sh`.

**Dependencies:** `dotfiles-admin` client already in `tailscale/.env`
(created 2026-10-17; `.env` key names renamed to `TS_ADMIN_CLIENT_*`).

**Done when:** `policy-status` reports `in-sync` after pull; `policy-push` of
an unchanged file is a no-op exit 0; a stale `If-Match` push is refused; lint
and lint-test pass; smoke passes (covers AC1, AC2).
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: adguard on the shared credential; doctor tailnet section
**Goal:** `tailnet-dns.sh` uses `api.sh`; the full-admin PAT is retired;
doctor checks policy drift.

**Components:**
- `stacks/adguard/scripts/tailnet-dns.sh`: auth via `tailscale/scripts/api.sh`
  (admin client); `TAILSCALE_PAT` removed from `stacks/adguard/.env.example`
  and the operator's `.env`; `TAILNET_DNS_FALLBACK` stays.
- `stacks/adguard/README.md` credential section rewritten.
- `stacks/scripts/doctor.sh`: new `--- Tailnet policy ---` section (policy
  SHA-256 vs live ETag, admin token exchange, tailscale lint, `tailscale/.env`
  mode/keys); Check B extended to `tailscale/`.
- Operator step (documented, last): revoke the `dns_token` PAT in the admin
  console after `tailnet-dns-status` passes on the new credential.

**Dependencies:** Phase 1.

**Done when:** `tailnet-dns-on/off/status` work with no `TAILSCALE_PAT`
anywhere; doctor shows `[OK]` policy in sync and FAILs on an induced drift
(covers AC3, AC4.1–AC4.3).
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: cxagents policy and auth-key minting
**Goal:** The tailnet knows `tag:cxagents`, grants members access to its
allowed ports, gives it no outbound access, and auth keys can be minted.

**Components:**
- `tailscale/policy.hujson` edits (Policy changes, above), pushed with
  `policy-push`.
- Operator step: create `dotfiles-authkeys` client (`auth_keys`, tag
  `tag:cxagents`) after the push; add `TS_AUTHKEYS_CLIENT_*` to `.env`.
- `authkey <tag>` recipe in `tailscale/justfile`.

**Dependencies:** Phase 2.

**Done when:** member-to-member connectivity unchanged (cxmacbook→cxmini
serve URLs still load); `authkey tag:cxagents` returns a key, and the admin
client is refused when minting (covers AC2.4, AC5.1–AC5.3).
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: `tailnet-forwarder` program and image
**Goal:** A tested Go program implementing the forwarder contract.

**Components:**
- `stacks/cxagents/forwarder/` (`go.mod`, `main.go` + packages for routes,
  peek/splice, status).
- `stacks/cxagents/forwarder/Dockerfile` (builder → distroless static,
  non-root).
- Go unit tests: routes parse/overlap/deny; peek classification (TLS
  ClientHello, plain bytes replayed, silent client → raw); status caller
  resolution and output shapes; RST on refused dial.
- `stacks/cxagents/scripts/build.sh`, `image-test.sh` (non-root, static, no
  shell, read-only root works).

**Dependencies:** None (parallel with 1–3).

**Done when:** `go test ./...` and `image-test` pass (covers AC6.1–AC6.6,
AC7 unit-level).
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: `stacks/cxagents` stack and login
**Goal:** The cxagents node runs in the agents VM, logged in as
`tag:cxagents`, with no stored auth key.

**Components:**
- `stacks/cxagents/{compose.yaml,justfile,routes,README.md}`; recipes `build`,
  `image-test`, `login`, `up`, `down`, `restart`, `ps`, `logs`, `lint`,
  `lint-test`, `smoke`.
- `stacks/justfile`: `mod cxagents`, aggregates and ordering.
- `stacks/cxagents/scripts/lint.sh` + `lint-test.sh`: `tag:cxagents` never a
  policy source; grants to it exclude every `routes` deny port; forwarder on
  `cxagents` network only, no published ports, hardening present; no
  `TS_AUTHKEY`/OAuth key names in any stack `.env` or compose environment.

**Dependencies:** Phases 3, 4.

**Done when:** `login` brings up node `cxagents` (exact name, tagged);
re-running `login` is a no-op; `up`/`down` work; the node keeps its identity
across `restart` and VM restart; lint and lint-test pass (covers AC5.4–AC5.6,
AC8).
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: connectome as the first target; end-to-end smoke
**Goal:** The agent's servers are reachable at
`https://cxagents.faun-fir.ts.net:<port>`.

**Components:**
- `stacks/connectome/compose.yaml` (`shell` joins `cxagents`),
  `stacks/connectome/justfile` (`up` network check),
  `stacks/connectome/recipes/agent.json` (prompt paragraph).
- `stacks/cxagents/scripts/smoke.sh`, run from the Mac over the tailnet.

**Dependencies:** Phase 5.

**Done when:** smoke passes every end-to-end check (covers AC6, AC7, AC9
end-to-end) and connectome's existing `lint`/`smoke` still pass.
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: doctor, docs, recovery
**Goal:** The new pieces are observable and the rebuild path is documented.

**Components:**
- `stacks/scripts/doctor.sh`: `--- cxagents ---` section (container running;
  node online and tagged per `tailscale status`; cert valid >14 days; cxagents
  lint; every `routes` target exists).
- `CLAUDE.md` (four areas, `tailscale/` module, OAuth replacing the PAT
  section, `up-all` order, reproducible-vs-runtime rows), `stacks/README.md`,
  `stacks/connectome/README.md` (known exposures), `docs/migration-recovery.md`
  (restore `tailscale/.env`; `cxagents login`; one-time tailnet bootstrap
  order).

**Dependencies:** Phase 6.

**Done when:** `dotfiles stacks doctor` has no FAILs; docs match the
recipes (covers AC4.4–AC4.6, AC10).
<!-- END_PHASE_7 -->

## Additional Considerations

**Operator steps** (the only non-scripted actions; each is documented where
it occurs):
- Once per tailnet: create `dotfiles-admin` (done 2026-10-17), then after the
  Phase 3 push create `dotfiles-authkeys`. Escrow `tailscale/.env`.
- Once: revoke the `dns_token` PAT (Phase 2).
- Only after losing `cxagents_state` with the old device still present:
  delete the stale `cxagents` device in the admin console (`login` stops and
  prints the URL).

**Accepted exposures:**
- Every port an agent listens on in its range is reachable from the
  operator's devices (decided). Agents in different targets can reach each
  other's servers (same trust profile).
- The status endpoint is unauthenticated on the `cxagents` bridge; it reveals
  only the caller's own route and its own listening ports.
- Plain `http://` still works on every port; HTTPS is what browsers get when
  the URL says `https://`.
- Agent containers still have unrestricted LAN/tailnet egress through VM NAT
  (existing, out of scope).

**Error handling:** forwarder fails closed — bad `routes` file (parse error,
overlap) → refuse to start; no route/deny/dial failure → RST. `api.sh`
distinguishes missing credentials (exit 2) from API errors (exit 3).

**Let's Encrypt rate limits**: the cert is cached in `cxagents_state`;
repeated logins with fresh state could hit limits (documented wait ~34 h).
`login` only mints when state is empty.

**Future:** port the forwarder to `tailscale-rs` once Tailscale declares it
audited/stable; the contract above is language-independent. More targets
(e.g. a revived nanoclaw in the agents VM) join `cxagents` and get a `routes`
range.

**Required reviews before implementation planning** (in addition to the
normal review):
1. **Security review** that pokes holes in this design. Every finding must be
   stated as a concrete scenario — "X attacker could perform Y and gain Z" or
   "a mistaken agent could access X and cause Y" — in the context of a
   single-operator homelab tailnet; findings that can't be stated that way
   are dropped.
2. **Declarativeness review** (NixOS sense): the repo should be an effective
   proxy for the live system, and a lost Mac mini should be rebuildable to the
   same healthy state with one straightforward, repeatable, unambiguous path
   defined by docs and, preferably, recipes. Includes this design's additions
   (tailnet bootstrap, clients, login, policy).
