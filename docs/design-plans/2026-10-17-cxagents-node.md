# cxagents Node Design

**Status:** Revision 2 (2026-10-17). Revision 1 was validated section by
section with the operator; revision 2 incorporates the design, security and
declarativeness reviews and the operator's decisions on them (see
[Review record](#review-record)).

## Summary

This design adds a single, locked-down node to the operator's private Tailscale network (tailnet), named `cxagents`, so that web servers and other network services started by AI agents running in containers can be opened from the operator's own devices. Today an agent can start a dev server inside its container, but nothing outside can reach it. The new node publishes every agent-run server at `https://cxagents.faun-fir.ts.net:<port>`, with a real, browser-trusted certificate and no client setup. The server's own port number is the only thing that varies per server. Services that are not HTTP, such as SSH-style or database-style protocols, pass through as raw TCP. The node can receive connections but can never start any, and a few infrastructure ports (3100 and everything below 1024) are blocked.

The approach has three parts. First, a small purpose-built Go program, the "forwarder", joins the tailnet as the `cxagents` node. It accepts a connection on any port, looks the port up in a tracked routing file, connects to the target container on a private Docker network, and relays traffic both ways. It detects whether the client is speaking TLS and, if so, terminates it with the node's certificate. It also exposes a status endpoint that agents can query from inside their container to see what is being served. Second, a new top-level `tailscale/` module declares the tailnet in the repo: the access policy (with built-in policy tests), the expected OAuth clients and their scopes, and the tailnet's identity. Recipes pull, diff, validate and push the policy, and `doctor` flags any drift. The same module's scoped, tailnet-owned OAuth credentials replace the existing full-admin personal access token (PAT) used by the DNS failover scripts. Third, the node logs in with a short-lived, single-use auth key that is minted on demand, passed on stdin and never stored, and the existing `connectome` stack opts in as the first target through an optional compose overlay. Because agent pages share a registrable domain (`faun-fir.ts.net`) with the operator's other services, the design also adds a cross-site request guard to the connectome WebUI and records the remaining same-site exposure. The work is split into seven phases so that a lost machine can be rebuilt from the repo and docs along one defined path.

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

### cxagents-node.AC1: Tailnet policy is code (Phase 1, tests extended in Phase 3)
- **cxagents-node.AC1.1 Success:** with `tailscale/policy.hujson` absent, `dotfiles tailscale policy-pull` writes it byte-identical to the live policy; `policy-status` then prints `in-sync`.
- **cxagents-node.AC1.2 Failure:** `policy-pull` refuses (non-zero, file untouched) when `policy.hujson` exists and `--force` is not given.
- **cxagents-node.AC1.3 Success:** `policy-push` of an edited file validates via the API, shows the diff, asks for confirmation, and afterwards `policy-status` is `in-sync` and the live ETag (quotes stripped) equals `shasum -a 256 tailscale/policy.hujson`.
- **cxagents-node.AC1.4 Failure:** `policy-push` aborts with "live policy changed; run policy-diff" and changes nothing when the live policy changed after the diff (412).
- **cxagents-node.AC1.5 Failure:** `policy-push` of a file that the lint rejects, or that the API rejects at validate (including a failing policy `tests`/`sshTests` entry), never POSTs.
- **cxagents-node.AC1.6 Edge:** `policy-diff` exits 0 with no output when repo and live are identical, non-zero with a unified diff otherwise.
- **cxagents-node.AC1.7 Success:** `policy.hujson` carries policy `tests` asserting members reach cxmini on tcp:22 and tcp:53/udp:53 and the serve ports; members are denied `tag:cxagents` tcp:3100 and tcp:80; `tag:cxagents` reaches nothing on cxmini. A push that would break any of these is rejected by validate.
- **cxagents-node.AC1.8 Success:** on a tailnet whose live policy differs from the repo (new tailnet), `policy-push --init` shows the diff, confirms, and pushes the repo policy without the If-Match precondition; plain `policy-push` refuses there with a hint to use `--init`.

### cxagents-node.AC2: Credentials are shared, declared and least-privilege (Phases 1, 3)
- **cxagents-node.AC2.1 Success:** `api.sh --client admin GET /tailnet/-/dns/nameservers` returns 200 using only `tailscale/.env`.
- **cxagents-node.AC2.2 Failure:** `api.sh` exits 2 with a hint naming `tailscale/.env.example` when credentials are missing or still placeholders, and exits 2 naming the replacement keys when it finds the deprecated `TS_OAUTH_CLIENT_*` keys; it never prints a secret or token.
- **cxagents-node.AC2.3 Failure:** the admin client is refused (403) on `/tailnet/-/keys`.
- **cxagents-node.AC2.4 Failure:** the authkeys client is refused on `/tailnet/-/acl` writes and `/tailnet/-/dns/nameservers` writes.
- **cxagents-node.AC2.5:** `tailscale/.env` is mode 0600 and gitignored; no file outside `tailscale/` contains a Tailscale client secret, PAT or auth key key name.
- **cxagents-node.AC2.6 Failure:** doctor FAILs when a client's granted scopes (the `scope` field of its token exchange) or tags differ from `tailscale/clients.conf`, including extra scopes.

### cxagents-node.AC3: adguard uses the shared credential (Phase 2)
- **cxagents-node.AC3.1 Success:** `tailnet-dns-on/off/status` behave exactly as before with no `TAILSCALE_PAT` in any file.
- **cxagents-node.AC3.2 Failure:** with `tailscale/.env` missing, `tailnet-dns.sh on` exits non-zero with the recovery hint and leaves Global NS unchanged; `adguard up` surfaces that exit code.
- **cxagents-node.AC3.3:** `TAILSCALE_PAT` is absent from `stacks/adguard/.env.example`, the adguard README and scripts.

### cxagents-node.AC4: doctor covers the tailnet and the node (Phases 2, 7)
- **cxagents-node.AC4.1 Success:** `--- Tailnet ---` reports `[OK]` when repo SHA-256 equals the live ETag.
- **cxagents-node.AC4.2 Failure:** it reports `[FAIL]` when the live policy differs from the repo (e.g. after an admin-console edit).
- **cxagents-node.AC4.3 Edge:** missing `tailscale/.env` or unreachable API is `[WARN]`, not `[FAIL]`; `tailscale/.env` with wrong mode or missing keys is `[FAIL]`.
- **cxagents-node.AC4.4 Success:** `--- cxagents ---` reports, via `docker exec cxagents-forwarder /tailnet-forwarder check`, the node online as exactly `cxagents` with tags `[tag:cxagents]` and the cert valid >14 days.
- **cxagents-node.AC4.5 Failure:** forwarder stopped, empty state, node offline/untagged/renamed (e.g. `cxagents-1`), cert ≤14 days, or a `routes` target with no running container → `[FAIL]`.
- **cxagents-node.AC4.6:** doctor still reads only `.env` key names, never values (aside from the existing BRIDGE_USERNAME exception).
- **cxagents-node.AC4.7 Failure:** doctor FAILs when `tailscale status --json` MagicDNS suffix or tailnet name differs from `tailscale/tailnet.conf`, when MagicDNS is off, or when Tailnet Lock is on; WARNs when a `TAILSCALE_PAT` key name exists in any `.env`.

### cxagents-node.AC5: The node is tagged, locked down and logged in without a stored key (Phases 3, 5)
- **cxagents-node.AC5.1 Success:** after the Phase 3 push, the user's devices still reach each other on all ports (existing cxmini serve URLs load from cxmacbook/cxphone; Taildrive and SSH unchanged).
- **cxagents-node.AC5.2 Success:** `dotfiles tailscale authkey tag:cxagents` prints one single-use, pre-authorized, non-ephemeral key expiring in ≤10 minutes.
- **cxagents-node.AC5.3 Failure:** once the node exists, no tailnet peer's packet filter lists the cxagents node's IPs as a source (checked on cxmini via `tailscale debug netmap`).
- **cxagents-node.AC5.4 Success:** `dotfiles stacks cxagents login` on empty state with no existing device registers a node named exactly `cxagents`, tagged `tag:cxagents`, key expiry disabled; the key goes in on stdin to a one-shot container and appears in no compose file, `.env`, or `docker inspect` output.
- **cxagents-node.AC5.5 Edge:** `login` across the state/device matrix — state valid + device present → no-op; state empty + device present → stops before minting and prints that device's admin-console URL; state present + device missing → confirms, wipes state, re-registers; image missing → stops before minting with "run `cxagents build`".
- **cxagents-node.AC5.6 Success:** the node keeps its name and identity across `restart`, `down`/`up`, and an agents VM restart.
- **cxagents-node.AC5.7 Failure:** `cxagents up` (and therefore `up-all` and the boot daemon) on empty state refuses with "run `dotfiles stacks cxagents login`" instead of starting a forwarder that waits on an interactive login.

### cxagents-node.AC6: Any agent server is reachable over trusted HTTPS (Phases 4, 6)
- **cxagents-node.AC6.1 Success:** an HTTP server on `connectome-shell` `0.0.0.0:P` (any allowed P) loads at `https://cxagents.faun-fir.ts.net:P` with certificate verification on (`curl` without `-k`; browser shows no warning). (end-to-end, Phase 6)
- **cxagents-node.AC6.2 Success:** the same server also answers at `http://cxagents.faun-fir.ts.net:P`.
- **cxagents-node.AC6.3 Success:** WebSockets work over `wss://` on the same port (live-reload), and an idle WebSocket survives 10 minutes.
- **cxagents-node.AC6.4 Success:** a raw client-speaks-first TCP server (echo) and a server-speaks-first one (banner) both work.
- **cxagents-node.AC6.5 Failure:** with nothing listening on P, the client gets connection refused/reset within ~2 s, and a server started afterwards on P is reachable immediately (no stale state).
- **cxagents-node.AC6.6 Failure:** port 3100 and ports <1024 are unreachable from the tailnet, even though shell listens on 3100. (end-to-end, Phase 6)
- **cxagents-node.AC6.7 Failure:** a server bound only to `127.0.0.1` in shell is unreachable (refused).
- **cxagents-node.AC6.8 Failure:** the forwarder refuses to start on a `routes` file that fails to parse or has overlapping ranges.
- **cxagents-node.AC6.9 Edge:** a TLS ClientHello that arrives 2 s after connect is still terminated as TLS; a connection that stays silent on both sides is closed after the 60 s pre-first-byte idle cap.
- **cxagents-node.AC6.10:** TLS termination negotiates ALPN `http/1.1` only (never `h2`), so HTTP/1.1 dev servers work; an `https://<100.x IP>:P` request (no SNI) fails cleanly.
- **cxagents-node.AC6.11 Failure:** a route target that resolves to an address outside the `cxagents` network subnet is never dialed (reset).
- **cxagents-node.AC6.12 Edge:** concurrent inbound flows beyond the per-port/global in-flight caps are reset instead of queued.

### cxagents-node.AC7: Agents can diagnose their servers (Phases 4, 6)
- **cxagents-node.AC7.1 Success:** `curl http://cxagents-forwarder:8080/status` from shell returns its target name, range, deny list, base URL, and each listening port with its URL and http/tls classification.
- **cxagents-node.AC7.2 Success:** `?ports=` narrows the check; `?format=json` returns the JSON shape in the design.
- **cxagents-node.AC7.3 Edge:** a loopback-only server does not appear in `listening`, while it does appear in shell's own `ss -ltn`.
- **cxagents-node.AC7.4 Failure:** a caller whose source IP matches no route target gets `404 not a cxagents target`; the status endpoint is not reachable from the tailnet.
- **cxagents-node.AC7.5 Edge:** repeated or concurrent requests from one caller within 5 s share one scan regardless of `?ports=`, and a global scan limit bounds forwarder load across callers.
- **cxagents-node.AC7.6:** HTTP classification uses `HEAD /` with a short timeout and never probes denied ports.

### cxagents-node.AC8: The forwarder is isolated (Phases 4, 5)
- **cxagents-node.AC8.1 Failure:** from inside the forwarder's network namespace, `connectome:18768` and the onecli gateway are unreachable.
- **cxagents-node.AC8.2:** the forwarder container runs non-root (uid 65532) with `cap_drop: ALL`, `no-new-privileges`, read-only root, no published ports, bounded json-file logging, and only the `cxagents` network (lint-enforced).
- **cxagents-node.AC8.3:** lint fails if any grant has `tag:cxagents` as a source, if any grant to `tag:cxagents` includes a `routes` deny port, or if an auth-key/OAuth key name appears in a stack `.env` or compose environment; lint-test proves each.
- **cxagents-node.AC8.4:** the forwarder image build is pinned: Go builder and distroless runtime by digest, `toolchain` in `go.mod`, `CGO_ENABLED=0 -trimpath -mod=readonly`; `build` writes `stacks/cxagents/build.lock`, and two builds from the same commit produce the same `build.lock`.

### cxagents-node.AC9: connectome is the first target (Phase 6)
- **cxagents-node.AC9.1 Success:** with the `cxagents` network present, connectome `up` includes `compose.cxagents.yaml` and `connectome-shell` joins `cxagents`; without it, connectome starts without the overlay and prints a warning.
- **cxagents-node.AC9.2:** the agent prompt states the URL pattern, the 0.0.0.0 bind rule, the allowed ports, the status endpoint (and to self-test with it, not the public URL), the Vite host-check note, no wildcard CORS, and that backends see plain HTTP without `X-Forwarded-Proto` and share cookies across ports.
- **cxagents-node.AC9.3:** connectome's existing `lint`, `lint-test` and `smoke` still pass.
- **cxagents-node.AC9.4 Success:** `up-all` brings up onecli, cxagents, connectome in that order; `down-all` stops connectome before cxagents.
- **cxagents-node.AC9.5 Failure:** the connectome WebUI rejects with 403 any request whose `Sec-Fetch-Site` is `same-site` or `cross-site`, or whose `Origin` is not in `allowedOrigins`; same-origin use from `https://cxmini.faun-fir.ts.net:8768` is unaffected.

### cxagents-node.AC10: Rebuild path is defined (Phase 7)
- **cxagents-node.AC10.1:** `docs/migration-recovery.md` covers, in order: restore `tailscale/.env` from escrow, `cxagents build`, delete stale `cxagents` (and `cxmini`) devices if `login`/`tailscale up` report them, `cxagents login`, then connectome; following it on a fresh device yields doctor with no FAILs.
- **cxagents-node.AC10.2:** `tailscale/README.md` documents both bootstrap paths (first adoption via `policy-pull`; new tailnet via `policy-push --init`), the client-creation order, the tailnet settings checklist, and PAT revocation.
- **cxagents-node.AC10.3:** CLAUDE.md reflects the four repo areas, the `tailscale/` module, OAuth in place of the PAT rotation section, the new reproducible-vs-runtime rows, and adds the `policy.hujson` cxmini host entry to the list of artifacts to update after a node-IP change.
- **cxagents-node.AC10.4:** the operator step to set exact-host matching on saved `*.faun-fir.ts.net` logins in the password manager is documented, and the residual same-site exposure is listed in `stacks/cxagents/README.md`.

## Glossary

- **cxagents**: The name of the new tailnet node, of the new stack (`stacks/cxagents/`), and of the private Docker network that links the forwarder to its target containers. Each maps one-to-one onto the node.
- **Tailnet**: The operator's private Tailscale network of their own devices (here `cxreiff.github`, with DNS suffix `faun-fir.ts.net`).
- **MagicDNS**: Tailscale's automatic DNS naming for tailnet devices, such as `cxagents.faun-fir.ts.net`.
- **Same-site / registrable domain / Public Suffix List**: Browsers treat hosts under the same registrable domain as the same "site". `ts.net` is on the Public Suffix List, so a tailnet's registrable domain is `faun-fir.ts.net` and all its nodes are same-site. That matters for cookie scoping, SameSite rules and password-manager matching.
- **Tailnet policy (HuJSON)**: The tailnet-wide file that defines which devices and tags may reach which others, on which ports. HuJSON is JSON that allows comments and trailing commas. Here it is `tailscale/policy.hujson`.
- **Grant**: A rule in the tailnet policy that allows a source to reach a destination on given ports.
- **Policy `tests` / `sshTests`**: Assertions inside the policy file that Tailscale evaluates on every validate/save; a failing test rejects the policy.
- **Tag (`tag:cxagents`)**: A Tailscale label that gives a machine a non-user identity. Tagged nodes have key expiry disabled, and policy can restrict what they may do.
- **`autogroup:member` / `autogroup:self` / `autogroup:tagged` / `autogroup:admin`**: Built-in policy groups: the tailnet's users' devices, the user's own devices, any tagged node, and tailnet admins.
- **tagOwners**: The policy section that says who may assign a given tag.
- **ETag / If-Match / 412**: HTTP optimistic-concurrency headers. The live policy's ETag is the SHA-256 of its bytes. A push sends it as `If-Match`; a stale value returns HTTP 412 and changes nothing.
- **Drift**: The repo's declared tailnet state (policy, clients, identity) differing from the live tailnet.
- **OAuth client (`dotfiles-admin`, `dotfiles-authkeys`)**: A scoped, tailnet-owned Tailscale API credential that is exchanged for a 1-hour bearer token. Declared in `tailscale/clients.conf`.
- **PAT (personal access token)**: The existing Tailscale API token used by the adguard DNS scripts. It expires every 90 days and carries full-admin scope, so it is being retired.
- **Auth key**: A one-time Tailscale credential used to register a new node. Here it is single-use, pre-authorized, valid for 10 minutes, passed on stdin, and never stored.
- **`api.sh`**: The only script that reads the OAuth secrets. It wraps authenticated Tailscale API calls and has defined exit codes (2 for missing credentials, 3 for API errors).
- **tsnet**: Tailscale's Go library for embedding a tailnet node inside a program.
- **`RegisterFallbackTCPHandler`**: The tsnet hook that receives every inbound TCP connection on a port with no explicit listener. It lets one node serve all ports.
- **Forwarder (`tailnet-forwarder`)**: The generic Go program that is the node. It routes, terminates TLS, relays traffic, serves the status endpoint and has `login`/`check` subcommands.
- **`routes` file**: The tracked table mapping a target container name to a port range and deny list. Ranges must not overlap, or the forwarder refuses to start.
- **Target**: A container the forwarder relays to, named by its unique container name (today `connectome-shell`).
- **First-byte race / splice**: The forwarder waits for whichever side sends first: a TLS ClientHello from the client means terminate TLS; any other client byte or a server byte first means raw pass-through. Splicing copies bytes both ways between two connections.
- **TLS termination / ALPN / SNI**: The forwarder decrypts HTTPS with the node certificate and passes plaintext on. ALPN is the in-handshake protocol choice (pinned to `http/1.1`). SNI is the hostname the client sends, needed to pick the certificate.
- **Half-close**: Closing one direction of a connection while the other stays open.
- **RST / connection refused**: A TCP reset, used to tell clients immediately that nothing is listening.
- **Server-speaks-first protocol**: A protocol where the server sends data before the client does (SSH, SMTP, MySQL).
- **Let's Encrypt cert / rate limits**: Tailscale obtains one publicly trusted certificate for the node from Let's Encrypt. It is cached in node state; repeated re-issuance can hit rate limits.
- **Status endpoint**: A read-only HTTP endpoint (`http://cxagents-forwarder:8080/status`), reachable only on the `cxagents` Docker network.
- **Compose overlay (`compose.cxagents.yaml`)**: An extra compose file layered on connectome's `compose.yaml` only when the `cxagents` network exists, making the opt-in soft.
- **Colima / agents VM**: Colima runs Docker inside lightweight VMs on the Mac. The `agents` VM hosts onecli, connectome and now cxagents.
- **connectome / `shell`**: The agent-hosting stack and its untrusted `shell` container (container name `connectome-shell`).
- **onecli / `onecli-agents` network**: The credential-vault stack, which owns an external Docker network that connectome joins. `cxagents` copies this pattern.
- **Named volume (`cxagents_state`)**: Docker-managed storage inside the VM holding the node's keys and cert cache. Disposable and not backed up.
- **Distroless static image**: A minimal container image with no shell or package manager, running a statically compiled binary.
- **`build.lock`**: A tracked record of the forwarder's build inputs (Go version, `tailscale.com` version, base image digests), like connectome's `sources.lock`.
- **`dotfiles` / `just` recipes / `mod`**: The repo's command entry point. `just` is a task runner, and `mod` mounts a sub-module of recipes such as `dotfiles tailscale ...`.
- **`doctor`**: The repo's read-only health check (`dotfiles stacks doctor`).
- **Lint / lint-test / smoke**: Static invariant check; proof the lint catches bad fixtures; end-to-end check against the live system.
- **Escrow**: Storing a secret copy (here `tailscale/.env`) in the password manager so a rebuild can restore it.
- **Vite host check**: A Vite dev-server setting that rejects requests for unrecognized hostnames.
- **`tailscale-rs`**: Tailscale's experimental Rust implementation, a future porting target.
- **Declarativeness (NixOS sense)**: The repo fully describes the system, so a lost machine can be rebuilt to the same state from it.
- **AC (acceptance criteria) IDs**: Labels such as `cxagents-node.AC6.3` used to trace tests and phases to requirements.

## Verified findings

Probed live on 2026-10-17 (tailnet `cxreiff.github`, MagicDNS `faun-fir.ts.net`):

- **Live policy is the default**: grants `*`→`*` all ports plus a Taildrive
  grant (`autogroup:member`→`autogroup:self`), two SSH rules (`accept` non-root
  / `check` root, both `autogroup:member`→`autogroup:self`), one `nodeAttrs`
  (Taildrive). 92 lines of HuJSON, comments included. All four nodes are
  user-owned; nothing is tagged; no subnet routes, exit nodes or shared-in
  nodes; Tailnet Lock is off. Replacing `*`→`*` with member→member breaks
  nothing that exists today.
- **Existing PAT is full-admin**: the adguard `dns_token` PAT has scopes
  `all`/`all:read` (expires 2026-11-22), not DNS-only as the adguard docs say.
- **OAuth works on this plan**: the `dotfiles-admin` client (created
  2026-10-17, stored in `tailscale/.env` as `TS_OAUTH_CLIENT_ID/SECRET`)
  exchanges for a 1 h bearer token with scopes `devices:core:read
  devices:posture_attributes policy_file dns logs:configuration:read`
  (`logs:configuration:read` is added implicitly). Reads of the policy (HuJSON
  and JSON), validate, DNS nameservers (`/tailnet/-/` and
  `/tailnet/cxreiff.github/`) and `/devices` succeed; `/keys` is refused (403).
- **Policy round-trips byte-exact**: a pushed HuJSON (with an added comment)
  reads back byte-identical. A push with a stale `If-Match` returns
  `412 precondition failed, invalid old hash` and changes nothing. **The ETag
  is the quoted SHA-256 of the policy bytes**, so drift is `shasum -a 256` vs
  the live ETag. The probe left the live policy byte-identical to its original.
- **Same-site**: `ts.net` is on the Public Suffix List (private section), so
  `cxagents.faun-fir.ts.net` and `cxmini.faun-fir.ts.net` are same-site.
  cxmini serves the connectome WebUI (:8768, basic auth), FreshRSS (:8765),
  Wallabag (:8766), Homebridge (:8767) and AdGuard (:8689, :8189).
- **Docker DNS** (Docker 29.2.1, Compose 5.1.3): containers get both their
  container name and their service name as aliases on every network,
  external ones included; a PTR lookup returns `<container>.<network>`.
  `connectome-shell` runs as uid 1000, listens only on `0.0.0.0:3100`, has no
  `nc`/`dig`, and sets only `HTTPS_PROXY`.
- **tsnet** (`tailscale.com/tsnet`, latest upstream v1.104.1):
  `(*Server).RegisterFallbackTCPHandler` (since v1.52) is called for every
  inbound TCP flow on a port with no explicit listener, after the packet filter
  (tailnet policy) and before the handshake completes; returning
  `intercept=false` or a nil handler resets the flow. One node cert (Let's
  Encrypt, via `LocalClient().GetCertificate`, requires SNI) covers every port.
  MagicDNS + HTTPS are already enabled. Tailscale issues no subdomain or
  wildcard certs. tsnet exposes only in-process dialing.
- **Stock `tailscale/tailscale` image** can't express "all ports": its serve
  config is exact-port entries only (rejected).
- **Second tailnet + node sharing** (considered for site isolation): needs a
  separate free account (multiple tailnets per account are alpha/sales-only),
  an untagged user-owned node (tagged machines can't be shared), and a manual
  invite that is likely lost on re-registration (rejected).
- **Rust**: `tailscale-rs` (April 2026) is an experimental preview Tailscale
  calls unstable and insecure until audited; Go is used.

## Architecture

Two new modules, one opt-in overlay in connectome, and one connectome-host
patch.

```
your devices ──tailnet──▶ cxagents node (tsnet, container `cxagents-forwarder`)
                              │  policy: members → tag:cxagents tcp:1024-3099,3101-65535
                              │  tag:cxagents → (nothing)
                              ▼
                       Docker network `cxagents` (agents VM)
                              ▼
                       target container (`connectome-shell`), port P
```

### `tailscale/` — the tailnet, declared (new top-level module)

`mod tailscale` in the root `justfile`, beside `stacks` and `stow`. Owns
everything tailnet-global; stacks read it, it never references a stack.

Tracked declarations:

- `tailscale/policy.hujson` — the tailnet policy, source of truth, including
  policy `tests`/`sshTests` (see Policy).
- `tailscale/tailnet.conf` — non-secret tailnet identity, read by every script
  that needs it instead of hardcoding:
  ```
  TAILNET=cxreiff.github          # API name
  TAILNET_DNS_SUFFIX=faun-fir.ts.net
  ```
- `tailscale/clients.conf` — the expected OAuth clients, compared by doctor
  against each token exchange's granted `scope`:
  ```
  # client     scopes (exact set granted at exchange)                                         tags
  admin        devices:core:read devices:posture_attributes dns logs:configuration:read policy_file   -
  authkeys     auth_keys                                                                      tag:cxagents
  ```
- `tailscale/README.md` — bootstrap paths, client creation, and a numbered
  tailnet settings checklist for what the API can't set: MagicDNS on, HTTPS
  certificates on, Tailnet Lock off, device approval off. Doctor checks what
  it can (MagicDNS and suffix via `tailscale status --json`, Tailnet Lock via
  `tailscale lock status`, HTTPS via the forwarder's cert).

Secrets: `tailscale/.env` (0600, gitignored) + tracked `.env.example`,
escrowed in the password manager:
- `TS_ADMIN_CLIENT_ID` / `TS_ADMIN_CLIENT_SECRET` — `dotfiles-admin`.
- `TS_AUTHKEYS_CLIENT_ID` / `TS_AUTHKEYS_CLIENT_SECRET` — `dotfiles-authkeys`.

The live file still uses `TS_OAUTH_CLIENT_*` from the probe; Phase 1 renames
them (and the escrow copy). `api.sh` refuses the old names with a pointer to
the new ones.

`tailscale/scripts/api.sh` is the only code that reads the client secrets:

```
api.sh [--client admin|authkeys] METHOD PATH [curl args...]
  PATH is relative to https://api.tailscale.com/api/v2 (e.g. /tailnet/-/acl)
  stdout: response body; exit 0 on 2xx, 3 on HTTP/API error (status + message
  on stderr), 2 on missing/placeholder/deprecated credentials
api.sh --client admin --granted-scopes
  prints the space-separated scope string of a fresh token exchange
```

It exchanges the client at `/api/v2/oauth/token` per invocation (tokens last
1 h; nothing cached on disk) and sends the secret via `--data-urlencode` from
a variable, never argv of a long-lived process or stdout.

Recipes (`dotfiles tailscale …`):
- `policy-pull [--force]` — writes the live HuJSON to `policy.hujson`;
  refuses if the file exists unless forced. Used once, when first adopting an
  existing tailnet.
- `policy-diff` — `diff` of live bytes vs repo; exit 0 when identical.
- `policy-push [--init]` — lint → API validate (runs policy `tests`) → show
  diff → confirm → POST with `If-Match` = the ETag of the bytes that were
  diffed; a 412 aborts with "live policy changed; run policy-diff". `--init`
  is for a new tailnet whose live policy is the default: it skips `If-Match`
  after showing the diff and confirming.
- `policy-status` — prints `in-sync` / `drift` (repo SHA-256 vs live ETag with
  quotes stripped; falls back to a byte compare if the ETag isn't a 64-hex
  string).
- `authkey <tag>` — prints one auth key: single-use, pre-authorized,
  non-ephemeral, 10-minute expiry, tagged `<tag>`.
- `lint`, `lint-test`, `smoke`.

### Policy (in `tailscale/policy.hujson`)

Starting from the pulled live policy:

- `tagOwners`: `"tag:cxagents": ["autogroup:admin"]`.
- `hosts`: `"cxmini": "100.70.208.32"` (for tests; listed in CLAUDE.md with
  the other artifacts that bake cxmini's node IP).
- Replace grant `*`→`*` with `autogroup:member`→`autogroup:member`
  `ip: ["*"]` (today's behavior between the operator's devices).
- Add grant `autogroup:member`→`tag:cxagents` `ip: ["tcp:1024-3099",
  "tcp:3101-65535"]`.
- No grant or ACL with `tag:cxagents`, `*` or `autogroup:tagged` as source.
- `tests`: members accept `cxmini:22`, `cxmini:53` (tcp/udp) and the serve
  ports; members deny `tag:cxagents:3100` and `tag:cxagents:80`; members accept
  `tag:cxagents:5173`; `tag:cxagents` deny `cxmini:22`, `cxmini:53`.
- Taildrive, SSH and `nodeAttrs` unchanged.

`stacks/cxagents/routes` is the master for deny ports; the grant ranges follow
it and the cxagents lint cross-checks them.

### `stacks/cxagents/` — the cxagents node (new stack)

Named for the node (one-to-one). Docker context `colima-agents`.

- `stacks/cxagents/forwarder/` — Go module, program `tailnet-forwarder`
  (generic: config tells it its hostname, tag and routes). `go.mod` pins
  `tailscale.com` and a `toolchain` directive.
- `stacks/cxagents/forwarder/Dockerfile` — `golang:<x.y.z>@sha256:…` builder,
  `CGO_ENABLED=0 go build -trimpath -mod=readonly`; runtime
  `gcr.io/distroless/static-debian12:nonroot@sha256:…` (uid 65532). The
  builder creates `/state` and the runtime copies it with
  `--chown=65532:65532`, so a fresh named volume inherits that ownership.
- `stacks/cxagents/scripts/build.sh` → image `tailnet-forwarder:local`;
  writes `stacks/cxagents/build.lock` (Go version, `tailscale.com` version,
  base digests). Bumping a pin is a deliberate edit to the Dockerfile/`go.mod`
  followed by `build`.
- `compose.yaml`, service `forwarder`, container `cxagents-forwarder`:
  `cap_drop: ALL`, `no-new-privileges`, `read_only: true`, no published ports,
  `restart: unless-stopped`, `logging: json-file max-size 10m max-file 3`,
  healthcheck `/tailnet-forwarder check`. Volume `cxagents_state` at `/state`
  (`tsnet.Server.Dir`). Networks: only `cxagents`, created and owned by this
  stack (`name: cxagents`, bridge, not internal; egress only for Tailscale
  control/DERP). Environment: hostname `cxagents`, tag `tag:cxagents`,
  routes path, status address `:8080`, `TS_NO_LOGS_NO_SUPPORT=true`. No auth
  key variable.
- `stacks/cxagents/routes` — tracked, read-only bind:
  ```
  # target            ports        deny
  connectome-shell    1024-65535   3100
  ```
  `target` is a container name (unique per Docker daemon, unlike service
  names). Ranges must not overlap. A future target splits a range.

### Forwarder contract

`tailnet-forwarder` subcommands: `serve` (default), `login` (reads an auth key
on stdin, brings the node up, waits for a cert, writes state, exits), `check`
(prints node name, ID, tags, online state and cert expiry from local state
and the tsnet LocalClient; `--state-only` reports only whether state holds a
node; exit non-zero on any problem).

At startup `serve` validates `routes` (refuse to start on parse error or
overlap), fetches the cert once (so the first browser hit doesn't wait on
Let's Encrypt), and refreshes it daily.

For each inbound tailnet TCP flow to port P (already allowed by the policy),
inside the fallback callback:

1. Look up P in `routes`. No route or P denied → `intercept=false` (RST).
2. Resolve the target and require the address to be inside the `cxagents`
   network's subnet; otherwise RST.
3. Enforce in-flight caps (per port and global); over the cap → RST.
4. Dial `<target>:P`, 2 s timeout; refused/timeout → RST (client sees
   "connection refused"). Nothing is cached. On success return a handler.

In the handler, wait for the first byte from either side (60 s idle cap):
- client sends `0x16 0x03…` (TLS ClientHello) → terminate TLS with the node
  cert, ALPN `http/1.1` only, then splice plaintext;
- client sends anything else → replay it to the target, splice raw;
- target sends first (SSH/SMTP banner) → forward it, splice raw.

Splice both directions with half-close; no idle timeout after the first byte
(live-reload sockets survive). One log line per flow (time, src node, port,
target, `tls|raw`, outcome); tsnet's own logs go through a filtered logger.

**Status endpoint** — `:8080` on the `cxagents` interface only, never the
tailnet. Read-only, unauthenticated:

```
GET http://cxagents-forwarder:8080/status[?ports=5173,8000][&format=json]

text (default):
  target: connectome-shell
  node:   https://cxagents.faun-fir.ts.net:<port>
  range:  1024-65535   deny: 3100
  listening (reachable from the forwarder):
    5173  http=yes   https://cxagents.faun-fir.ts.net:5173
    9000  http=no    (raw TCP)  cxagents.faun-fir.ts.net:9000

json:
  {"target":"connectome-shell","node":"cxagents.faun-fir.ts.net",
   "range":{"from":1024,"to":65535},"deny":[3100],
   "listening":[{"port":5173,"http":true,"url":"https://cxagents.faun-fir.ts.net:5173"}]}
```

The caller is identified by forward-resolving every `routes` target and
matching the request's source IP (a target resolving to more than one IP is
reported as ambiguous). No match → `404 not a cxagents target`. Scans use
bounded concurrency under one global limit, skip denied ports, classify HTTP
with `HEAD /` and a short timeout, and are cached and coalesced per caller for
5 s regardless of `?ports=`.

### Login and node identity

`cxagents_state` holds only the node's keys (its tailnet identity) and the
cert cache. It is disposable and not backed up; losing it costs a re-login,
a new tailnet IP (unused: everything uses the MagicDNS name) and a new cert.

`dotfiles stacks cxagents login`:

1. Image `tailnet-forwarder:local` missing → stop: "run `cxagents build`".
2. Read local state (`check --state-only` in a one-shot container) and the
   device list (admin client, `devices:core:read`):
   - state holds a node and a `cxagents` device with that ID exists → no-op.
   - state empty and a `cxagents` device exists → stop, print that device's
     admin-console URL and "delete it, then re-run login" (operator decision:
     manual, guided).
   - state holds a node whose device no longer exists → confirm, wipe
     `cxagents_state`, continue.
3. `dotfiles tailscale authkey tag:cxagents | docker run --rm -i -v
   cxagents_state:/state … tailnet-forwarder:local login`. The key exists only
   in that pipe; it is spent on first use and expires in 10 minutes.
4. `compose up -d`.

`dotfiles stacks cxagents up` refuses on empty state ("run `cxagents login`"),
so `up-all` and the boot daemon never start a forwarder waiting on an
interactive login.

### Target opt-in (connectome)

- `stacks/connectome/compose.cxagents.yaml` (new overlay): `shell` joins
  external network `cxagents`.
- `stacks/connectome/justfile`: computes the compose file set once —
  `-f compose.yaml` plus `-f compose.cxagents.yaml` when network `cxagents`
  exists — and uses it in every compose-invoking recipe; `up` warns when the
  overlay is skipped. connectome keeps its hard dependency on onecli only.
- `stacks/connectome/recipes/agent.json` `systemPrompt`: one paragraph —
  servers on `0.0.0.0:<port>` (1024–65535, not 3100) are at
  `https://cxagents.faun-fir.ts.net:<port>` (`http://` also works); check and
  self-test with `curl http://cxagents-forwarder:8080/status` (the public URL
  goes through the HTTPS proxy from inside shell); Vite-style host checks must
  allow `cxagents.faun-fir.ts.net`; never enable wildcard CORS; backends see
  plain HTTP with no `X-Forwarded-Proto`, and cookies are shared across ports.
- connectome-host local patch (tracked in `sources.lock` like the existing
  patches): the WebUI rejects with 403 requests whose `Sec-Fetch-Site` is
  `same-site`/`cross-site` or whose `Origin` is not in `allowedOrigins`
  (already `https://cxmini.faun-fir.ts.net:8768`).

### Ordering

`stacks/justfile`: `mod cxagents`; `up-all` order adguard, freshrss,
homebridge, onecli, **cxagents**, connectome, wallabag; `down-all` stops
connectome before cxagents (an external network with active endpoints can't
be removed); `ps-all` includes it; `backup-all` does not.

## Existing Patterns

- **External network owned by a provider stack, joined by consumers**: onecli
  owns `onecli-agents` and connectome joins it. `cxagents` follows this, but as
  a soft opt-in (overlay) because previews are not essential to the agent.
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
- **Locally built images with a lock file** (`connectome/scripts/build.sh`,
  `sources.lock`); `build.lock` mirrors it and goes further by pinning base
  images by digest.
- **Local patches on connectome clones** recorded in `sources.lock`.
- **Absolute `/opt/homebrew/bin/tailscale`** in scripts (LaunchDaemon PATH).

New patterns:

- **First top-level module with its own `.env`** (`tailscale/`). Justified:
  the policy, tailnet identity and API credentials are tailnet-global.
- **Declared external state with doctor drift checks** for things outside the
  machine: policy (ETag), OAuth client scopes (token exchange), tailnet
  identity and settings.
- **First image built from in-repo source**, pinned by digest.
- **First tagged node and first non-default tailnet policy.**
- **Optional compose overlay** for a non-essential cross-stack link.

## Implementation Phases

<!-- START_PHASE_1 -->
### Phase 1: `tailscale/` module and policy as code
**Goal:** The tailnet's policy, identity and clients are declared in the repo;
the policy is pushable safely and checkable for drift with the
`dotfiles-admin` client.

**Components:**
- Root `justfile`: `mod tailscale`.
- `tailscale/justfile`, `.env.example`, `README.md` (bootstrap paths, client
  creation order, settings checklist), `tailnet.conf`, `clients.conf`.
- `tailscale/.env` key rename to `TS_ADMIN_CLIENT_*` (and escrow update,
  operator).
- `tailscale/scripts/api.sh` (contract above).
- `tailscale/scripts/policy.sh` behind `policy-pull|diff|push|status`.
- `tailscale/policy.hujson` — pulled from live and committed, plus `hosts` and
  the member/cxmini `tests` (no cxagents changes yet).
- `tailscale/scripts/lint.sh` + `lint-test.sh` (+ fixtures): parses; no `*`,
  tag or `autogroup:tagged` source in grants/ACLs; every used tag in
  `tagOwners`; `tests` present.
- `tailscale/scripts/smoke.sh`.

**Dependencies:** the existing `dotfiles-admin` client.

**Done when:** pull → commit → `policy-status` `in-sync`; pushing the
tests-only change succeeds and a stale `If-Match` push is refused; lint,
lint-test and smoke pass; `policy-push --init` runs against the live tailnet
up to its confirm prompt and is declined, and plain `policy-push` refuses a
fixture repo policy that differs from live with the `--init` hint (covers
AC1.1–AC1.8, AC2.1–AC2.3, AC2.5).
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: adguard on the shared credential; doctor tailnet section
**Goal:** `tailnet-dns.sh` uses `api.sh`; the full-admin PAT is retired;
doctor checks the declared tailnet state.

**Components:**
- `stacks/adguard/scripts/tailnet-dns.sh`: auth via
  `tailscale/scripts/api.sh` (admin client); `TAILSCALE_PAT` removed from
  `stacks/adguard/.env.example` and the operator's `.env`;
  `TAILNET_DNS_FALLBACK` stays.
- `stacks/adguard/README.md` credential section rewritten.
- `stacks/scripts/doctor.sh`: new `--- Tailnet ---` section (policy SHA-256 vs
  live ETag; each client's granted scopes vs `clients.conf`; MagicDNS suffix
  and tailnet name vs `tailnet.conf`; Tailnet Lock off; tailscale lint;
  `tailscale/.env` mode/keys; WARN on any `TAILSCALE_PAT` key name).
- Operator step (last): revoke the `dns_token` PAT after `tailnet-dns-status`
  passes on the new credential.

**Dependencies:** Phase 1.

**Done when:** `tailnet-dns-on/off/status` work with no `TAILSCALE_PAT`
anywhere; doctor shows `[OK]` and FAILs on induced policy drift and on a
scope mismatch (covers AC2.6, AC3, AC4.1–AC4.3, AC4.7).
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: cxagents policy and auth-key minting
**Goal:** The tailnet knows `tag:cxagents`, grants members its allowed ports,
gives it no outbound access, and auth keys can be minted.

**Components:**
- `tailscale/policy.hujson`: `tagOwners`, grant changes and the cxagents
  `tests`, pushed with `policy-push`.
- Operator step: create `dotfiles-authkeys` (`auth_keys`, tag `tag:cxagents`)
  after the push; add `TS_AUTHKEYS_CLIENT_*` to `.env` and the escrow.
- `authkey <tag>` recipe; `clients.conf` authkeys row checked by doctor.

**Dependencies:** Phase 2.

**Done when:** member-to-member connectivity unchanged; `authkey
tag:cxagents` returns a key; the authkeys client is refused on policy and DNS
writes (covers AC2.4, AC5.1, AC5.2).
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: `tailnet-forwarder` program and image
**Goal:** A tested, reproducibly built Go program implementing the forwarder
contract.

**Components:**
- `stacks/cxagents/forwarder/` (`go.mod` with `toolchain`, `main.go` and
  packages for routes, flow handling, status, login/check).
- `stacks/cxagents/forwarder/Dockerfile` (digest-pinned builder and runtime,
  `/state` owned by 65532).
- Go unit tests: routes parse/overlap/deny; subnet check; in-flight caps;
  first-byte race (immediate ClientHello, ClientHello after 2 s, plain bytes
  replayed, server-first banner, 60 s silent close); ALPN `http/1.1`; RST on
  refused dial; status caller resolution, coalescing, global limit, `HEAD`
  classification, JSON/text shapes.
- `stacks/cxagents/scripts/build.sh` (writes `build.lock`), `image-test.sh`
  (non-root uid 65532, static, no shell, read-only root works, `check` runs).

**Dependencies:** None (can run in parallel with Phases 1–3).

**Done when:** `go test ./...` and `image-test` pass; two builds produce the
same `build.lock` (covers AC6.4, AC6.5, AC6.8–AC6.12, AC7.2, AC7.5, AC7.6,
AC8.4 at unit level).
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
- `stacks/cxagents/scripts/login.sh` (state/device matrix above).
- `stacks/cxagents/scripts/lint.sh` + `lint-test.sh`: `tag:cxagents` never a
  policy source; grants to it exclude every `routes` deny port; forwarder on
  `cxagents` network only, no published ports, hardening and log limits
  present; no auth-key/OAuth key names in any stack `.env` or compose
  environment; `routes` targets are container names.

**Dependencies:** Phases 3, 4.

**Done when:** `login` registers exactly `cxagents`, tagged; each login matrix
case behaves as specified; `up` on empty state refuses; identity survives
`restart` and a VM restart; the node is absent from every packet-filter
source list on cxmini; lint and lint-test pass (covers AC5.3–AC5.7, AC8.1–
AC8.3).
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: connectome as the first target; WebUI guard; end-to-end smoke
**Goal:** The agent's servers are reachable at
`https://cxagents.faun-fir.ts.net:<port>`, and agent pages can't drive the
connectome WebUI.

**Components:**
- `stacks/connectome/compose.cxagents.yaml`; `stacks/connectome/justfile`
  (compose file set, overlay warning); `stacks/connectome/recipes/agent.json`
  (prompt paragraph).
- connectome-host local patch (WebUI cross-site guard), rebuilt via
  `connectome build` and recorded in `sources.lock`.
- `stacks/cxagents/scripts/smoke.sh`, run from the Mac over the tailnet.

**Dependencies:** Phase 5.

**Done when:** smoke passes every end-to-end check; connectome `up` with and
without the `cxagents` network behaves as specified; the WebUI rejects
cross-site/same-site requests; connectome's existing `lint`, `lint-test` and
`smoke` still pass (covers AC6.1–AC6.7 end-to-end, AC7.1, AC7.3, AC7.4,
AC9.1–AC9.3, AC9.5).
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: doctor, docs, recovery
**Goal:** The new pieces are observable and the rebuild path is one documented
sequence.

**Components:**
- `stacks/scripts/doctor.sh`: `--- cxagents ---` section (container running
  and healthy; `check` output: exact name, tag, online, cert >14 days;
  cxagents lint; every `routes` target running).
- `CLAUDE.md` (four areas, `tailscale/` module, OAuth replacing the PAT
  section, `up-all`/`down-all` order, reproducible-vs-runtime rows, cxmini
  node-IP artifact list gains the policy `hosts` entry), `stacks/README.md`,
  `stacks/connectome/README.md` (overlay, WebUI guard, known exposures),
  `stacks/cxagents/README.md` (accepted exposures, password-manager step),
  `docs/migration-recovery.md` (restore `tailscale/.env`; `cxagents build`;
  stale-device steps for `cxagents` and `cxmini`; `cxagents login`; then
  connectome; new-tailnet path).

**Dependencies:** Phase 6.

**Done when:** `dotfiles stacks doctor` has no FAILs; docs match the recipes
(covers AC4.4–AC4.6, AC9.4, AC10).
<!-- END_PHASE_7 -->

## Additional Considerations

**Operator steps** (the only non-scripted actions, each documented where it
occurs):
- Once per tailnet: create `dotfiles-admin` (done 2026-10-17); after the
  Phase 3 push create `dotfiles-authkeys`. Keep `tailscale/.env` escrowed.
- Once per tailnet: the settings checklist in `tailscale/README.md`.
- Once: revoke the `dns_token` PAT (Phase 2).
- Once: set exact-host URI matching on the saved `*.faun-fir.ts.net` logins in
  the password manager (a per-login setting that syncs with the vault).
- On a host switch: delete the stale `cxagents` device when `login` prints its
  URL (and the stale `cxmini` device before `tailscale up`, an existing gap).

**Accepted exposures:**
- **Same-site with cxmini services.** Agent pages at
  `cxagents.faun-fir.ts.net` are same-site with cxmini's services. Residual
  after mitigations: while the operator is logged in to a cxmini app other
  than the connectome WebUI (AdGuard, FreshRSS, Wallabag, Homebridge), an agent
  page the operator opens could send it forged same-site requests, and could
  set `Domain=faun-fir.ts.net` cookies. Mitigated by the WebUI guard (the
  highest-value target) and password-manager host matching (credential
  harvesting).
- Every port an agent listens on in its range is reachable from the
  operator's devices (decided). Agents in different targets can reach each
  other's servers (same trust profile).
- The status endpoint is unauthenticated on the `cxagents` bridge; it reveals
  only the caller's own route and listening ports.
- `http://` still works on every port.
- The `tag:cxagents` lockdown limits the node, not the agent: agent containers
  keep their existing unrestricted LAN/tailnet egress through VM NAT
  (pre-existing, out of scope).
- The node's hostname is in public Certificate Transparency logs; only
  tailnet members can connect to it.

**Error handling:** the forwarder fails closed — bad `routes` (parse error,
overlap) → refuse to start; no route, deny, off-subnet target, cap exceeded or
dial failure → RST. `api.sh` distinguishes credential problems (exit 2) from
API errors (exit 3). `login` checks every precondition before minting a key.

**Let's Encrypt rate limits:** the cert is cached in `cxagents_state` and
re-issued only after a state loss; `login` only mints when state is empty.

**Future:** port the forwarder to `tailscale-rs` once Tailscale declares it
audited/stable; the contract is language-independent. More targets (e.g. a
revived nanoclaw in the agents VM) join `cxagents` and get a `routes` range.
A dedicated agent domain (DNS-01 cert, wildcard subdomains) would remove the
same-site exposure if it ever matters more.

## Review record

Revision 1 was reviewed on 2026-10-17 by three reviews: general/technical,
security (findings had to be stated as concrete attacker or mistaken-agent
scenarios), and declarativeness (rebuild from the repo along one path).
Revision 2 incorporates:

- **Technical:** first-byte race instead of a 300 ms peek (slow TLS clients
  over DERP); ALPN pinned to `http/1.1`; login as a stdin one-shot (no auth
  key in compose); routes by container name and status caller lookup by
  forward resolution (PTR returns container names; service aliases collide);
  `check` subcommand for doctor and healthcheck; cert warm-up and daily
  refresh; in-flight caps; state ownership, `Dir`, log limits; soft connectome
  opt-in; deleted-device recovery; phase/AC coverage corrected.
- **Security:** same-site with cxmini (PSL) → accepted with mitigations
  (operator decision): connectome-host WebUI guard, password-manager host
  matching, recorded residual; policy `tests` against lockout; off-subnet
  target check; global status-scan limit; CORS note in the agent prompt.
- **Declarativeness:** `tailnet.conf` (no hardcoded suffix), `clients.conf`
  with doctor scope checks, `policy-push --init` for a new tailnet, settings
  checklist plus doctor checks, `up` refuses on empty state, explicit `.env`
  rename, digest-pinned build with `build.lock`, ordered recovery steps;
  `cxagents_state` disposable with a manual, guided stale-device step
  (operator decision).
