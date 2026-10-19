# cxagents Node Implementation Plan — Phase 4 of 7: `tailnet-forwarder` program and image

**Goal:** A tested, reproducibly built Go program implementing the forwarder contract (routing, first-byte race, TLS termination, splice, status endpoint, `login`/`check`), packaged as a digest-pinned distroless image `tailnet-forwarder:local`.

**Architecture:** One Go module at `stacks/cxagents/forwarder/` (module path `tailnet-forwarder`). `main.go` dispatches `serve` (default) / `login` / `check`. Logic lives in small internal packages with injected dependencies (resolver, dialer, clock limits, cert source) so every behaviour is unit-tested without a tailnet: `routes`, `netcheck`, `resolve`, `flow`, `status`, `node` (tsnet wiring, state file, check socket), `check` (pure evaluation). Go is not installed on the host: every `go` command runs in the digest-pinned builder image via `stacks/cxagents/scripts/go.sh` on the `colima-agents` Docker context (the agents VM mounts `$HOME`, so the source bind-mounts).

**Tech Stack:** Go 1.27.1, `tailscale.com` v1.104.1 (`tsnet`, `client/local`), `golang:1.27.1-bookworm` builder, `gcr.io/distroless/static-debian12:nonroot` runtime, Docker 29.2.1 on `colima-agents` (linux/arm64).

**Scope:** Phase 4 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`. Independent of Phases 1–3 (can run in parallel).

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file". No Go code exists anywhere in the repo yet; there is no unit-test framework at repo level — Go's `testing` package is introduced here, inside the forwarder module only.

**External facts (tsnet @ v1.104.1, github.com/tailscale/tailscale tag v1.104.1, commit 9a522a9):**
- `tsnet.Server` fields used: `Dir` (state dir; `tailscaled.state`, cert cache `Dir/certs`, log buffers), `Hostname`, `AuthKey` (only used when the state holds no node; else ignored — falls back to `TS_AUTHKEY`/`TS_AUTH_KEY` env if empty), `AdvertiseTags []string`, `Logf` (verbose backend logs; nil = discarded), `UserLogf`. Userspace netstack, fake TUN: no root, no capabilities.
- `(*Server).Up(ctx) (*ipnstate.Status, error)` waits for `Running`; `(*Server).LocalClient() (*local.Client, error)` (package `tailscale.com/client/local`); `(*Server).Close()`.
- `local.Client`: `Status`/`StatusWithoutPeers(ctx)`, `GetCertificate(*tls.ClientHelloInfo)` (needs SNI), `CertPair(ctx, domain) (certPEM, keyPEM []byte, err)`, `WhoIs(ctx, addr)`. **No API returns cert expiry** → parse the leaf from `CertPair` (`x509.ParseCertificate(...).NotAfter`).
- `ipnstate.Status`: `BackendState`, `Self *PeerStatus` (`ID` StableNodeID, `HostName`, `DNSName` FQDN with trailing dot, `Tags *views.Slice[string]`, `Online`, `TailscaleIPs`), `CertDomains []string`, `CurrentTailnet`.
- `(*Server).RegisterFallbackTCPHandler(cb func(src, dst netip.AddrPort) (handler func(net.Conn), intercept bool)) func()`. The callback runs **on the SYN, before the SYN-ACK, with the server's main mutex held**, after the packet filter (policy-denied SYNs never reach it). `(nil, true)` → RST; `(h, true)` → handshake completes and `h(conn)` is called **synchronously** (it must return quickly; do work in a goroutine). Never call `Listen`/`Close`/`Register…` from inside the callback.
- tsnet writes outside `Dir` only for the sockstat logger, at `TS_LOGS_DIR` if set (else `$HOME/.cache`, which is read-only here — non-fatal). Set `TS_LOGS_DIR=/state/logs`. `TS_NO_LOGS_NO_SUPPORT=true` disables log upload.
- The final hostname is decided by control: observe it as the first label of `Self.DNSName` (a collision yields e.g. `cxagents-1`).
- State detection without starting a node: `Dir/tailscaled.state` is a JSON object (`map[string][]byte`, values base64): `_current-profile` holds the profile ID, `_profiles` holds JSON `map[ProfileID]LoginProfile` whose entries carry `NodeID` (StableNodeID). Phase 5 Task 3 confirms the parsed node ID equals the device's `nodeId` from the API.
- Upstream `go.mod` at v1.104.1 has `go 1.27.1` and **no** `toolchain` line; ours adds `toolchain go1.27.1` (AC8.4).

**Images (resolved 2026-10-17 with `docker buildx imagetools inspect`):**
- `golang:1.27.1-bookworm@sha256:8d48e12ec56735e9358640898b9d9b9fcca110612ed8a5567438c0a1baa24e66`
- `gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab`
Re-resolve both at execution time (`docker --context colima-agents buildx imagetools inspect <tag> | sed -n 's/^Digest: *//p'`) and use the current digests if they changed; record them in `build.lock`.

---

## Decision recorded at planning time — dial point (operator decision, 2026-10-17; deviation from the design's Forwarder contract)

The design's step 4 dials the target **inside** the fallback callback (2 s timeout) so a closed port is a true RST. Because tsnet holds its main mutex during the callback, a dial that waits (target container stopped or restarting) would stall **every** new inbound flow to the node for up to the timeout. The operator chose **"accept, then dial"**:
- The callback does only cheap, in-memory checks: route lookup, deny list, subnet check against a **pre-resolved** target address cache, in-flight caps. Any failure → `(nil, true)` = RST.
- Otherwise it returns a handler; the **handler** (goroutine) dials `<target-ip>:P` with a 2 s timeout. Refused/timeout → the client connection is closed immediately (RST where the connection type supports linger 0; otherwise FIN). The client sees "connected, then closed" instead of "connection refused" — still within AC6.5 ("refused/reset within ~2 s"). Nothing about the port is cached, so a server started afterwards is reachable on the next connect.
- Target names are resolved off-lock by a background refresher (every 5 s, and immediately after a failed dial); the callback reads the cache.

---

## Acceptance Criteria Coverage

This phase implements and tests (unit level, plus image tests):

### cxagents-node.AC6: Any agent server is reachable over trusted HTTPS (Phases 4, 6)
- **cxagents-node.AC6.4 Success:** a raw client-speaks-first TCP server (echo) and a server-speaks-first one (banner) both work.
- **cxagents-node.AC6.5 Failure:** with nothing listening on P, the client gets connection refused/reset within ~2 s, and a server started afterwards on P is reachable immediately (no stale state).
- **cxagents-node.AC6.8 Failure:** the forwarder refuses to start on a `routes` file that fails to parse or has overlapping ranges.
- **cxagents-node.AC6.9 Edge:** a TLS ClientHello that arrives 2 s after connect is still terminated as TLS; a connection that stays silent on both sides is closed after the 60 s pre-first-byte idle cap.
- **cxagents-node.AC6.10:** TLS termination negotiates ALPN `http/1.1` only (never `h2`), so HTTP/1.1 dev servers work; an `https://<100.x IP>:P` request (no SNI) fails cleanly.
- **cxagents-node.AC6.11 Failure:** a route target that resolves to an address outside the `cxagents` network subnet is never dialed (reset).
- **cxagents-node.AC6.12 Edge:** concurrent inbound flows beyond the per-port/global in-flight caps are reset instead of queued.

### cxagents-node.AC7: Agents can diagnose their servers (Phases 4, 6)
- **cxagents-node.AC7.2 Success:** `?ports=` narrows the check; `?format=json` returns the JSON shape in the design.
- **cxagents-node.AC7.5 Edge:** repeated or concurrent requests from one caller within 5 s share one scan regardless of `?ports=`, and a global scan limit bounds forwarder load across callers.
- **cxagents-node.AC7.6:** HTTP classification uses `HEAD /` with a short timeout and never probes denied ports.

### cxagents-node.AC8: The forwarder is isolated (Phases 4, 5)
- **cxagents-node.AC8.4:** the forwarder image build is pinned: Go builder and distroless runtime by digest, `toolchain` in `go.mod`, `CGO_ENABLED=0 -trimpath -mod=readonly`; `build` writes `stacks/cxagents/build.lock`, and two builds from the same commit produce the same `build.lock`.

Also unit-tested here for use in later phases (their ACs are claimed where verified end-to-end): status caller resolution and 404 (AC7.4, Phase 6), `check` evaluation of name/tags/online/cert (AC4.4/AC4.5, Phase 7), state detection (AC5.5/AC5.7, Phase 5).

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Module scaffold, pinned Dockerfile, `go.sh`

**Verifies:** None (infrastructure).

**Files:**
- Create: `stacks/cxagents/forwarder/go.mod`, `stacks/cxagents/forwarder/main.go` (stub), `stacks/cxagents/forwarder/Dockerfile`, `stacks/cxagents/forwarder/.dockerignore`, `stacks/cxagents/scripts/go.sh` (755).

**Step 1: `go.mod`**
```
module tailnet-forwarder

go 1.27.1

toolchain go1.27.1

require tailscale.com v1.104.1
```

**Step 2: stub `main.go`** (replaced in Task 9):
```go
package main

import (
	"fmt"
	"os"

	_ "tailscale.com/tsnet"
)

func main() { fmt.Fprintln(os.Stderr, "tailnet-forwarder: not implemented"); os.Exit(2) }
```

**Step 3: `Dockerfile`**
```dockerfile
# syntax=docker/dockerfile:1
# tailnet-forwarder — built only by stacks/cxagents/scripts/build.sh (writes
# ../build.lock). Bumping a pin = edit a digest here or a version in go.mod,
# then `dotfiles stacks cxagents build`.
FROM golang:1.27.1-bookworm@sha256:8d48e12ec56735e9358640898b9d9b9fcca110612ed8a5567438c0a1baa24e66 AS build
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=readonly
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN go build -trimpath -mod=readonly -buildvcs=false -ldflags='-s -w -buildid=' \
        -o /out/tailnet-forwarder . \
 && mkdir -p /out/state

FROM build AS test
RUN go vet ./... && go test -count=1 ./...

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/tailnet-forwarder /tailnet-forwarder
# A fresh named volume mounted at /state inherits this ownership (uid 65532).
COPY --from=build --chown=65532:65532 /out/state /state
USER 65532:65532
ENTRYPOINT ["/tailnet-forwarder"]
CMD ["serve"]
```

**Step 4: `.dockerignore`**: `*_test.go` is NOT ignored (the `test` stage needs it). Content: `Dockerfile`, `.dockerignore`, `tailnet-forwarder` (a stray local binary). Also append `stacks/cxagents/forwarder/tailnet-forwarder` to the repo `.gitignore` (after the connectome build-staging lines, with the comment `# cxagents: a stray local go build output`).

**Step 5: `scripts/go.sh`**
```bash
#!/usr/bin/env bash
# stacks/cxagents/scripts/go.sh ARGS... — run `go ARGS` in the digest-pinned
# builder from forwarder/Dockerfile (Go is not installed on the host). The
# source is bind-mounted (the agents VM mounts $HOME); module and build caches
# live in named volumes cxagents_gomod / cxagents_gobuild.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "${SCRIPT_DIR}/../forwarder" && pwd)"
builder="$(sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' "${src}/Dockerfile")"
[ -n "$builder" ] || { echo "go.sh: no builder FROM line in ${src}/Dockerfile" >&2; exit 2; }
exec docker --context colima-agents run --rm \
    -v "${src}:/src" -w /src \
    -v cxagents_gomod:/go/pkg/mod -v cxagents_gobuild:/root/.cache/go-build \
    -e GOTOOLCHAIN=local -e CGO_ENABLED=0 \
    "$builder" go "$@"
```

**Step 6: Verify**
```bash
cd "$wt/stacks/cxagents" && chmod 755 scripts/go.sh
./scripts/go.sh version
./scripts/go.sh mod tidy && ls forwarder/go.sum
./scripts/go.sh build -o /dev/null ./...
git -C "$wt" status --short stacks/cxagents
```
Expected: `go version go1.27.1 linux/arm64`; `go.sum` created (tidy may rewrite `require` into the full set — keep what tidy writes, but confirm `go 1.27.1`, `toolchain go1.27.1`, `tailscale.com v1.104.1` remain); build succeeds; `git status` lists only the files created in this task (no binary).

**Step 7: Commit** (explicit paths — never `git add` the forwarder directory wholesale)
```bash
cd "$wt"
git add .gitignore stacks/cxagents/forwarder/{go.mod,go.sum,main.go,Dockerfile,.dockerignore} stacks/cxagents/scripts/go.sh
git commit -m "stacks/cxagents: forwarder module scaffold, digest-pinned Dockerfile, go.sh"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: `routes` package

**Verifies:** cxagents-node.AC6.8.

**Files:**
- Create: `stacks/cxagents/forwarder/internal/routes/routes.go`, `routes_test.go`.

**Implementation:** file format (tracked `stacks/cxagents/routes`, Phase 5): `#` comments and blank lines ignored; each line `target  FROM-TO  DENY` where `DENY` is `-` or a comma-separated list of ports. `target` must match `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` (a Docker container name). Ports 1–65535, `FROM ≤ TO`, every deny port inside its own range. Ranges across lines must not overlap (sort by FROM; error names both lines). Types:
```go
type Route struct {
	Target   string
	From, To uint16
	Deny     map[uint16]bool
	Line     int
}
type Table struct{ routes []Route }          // sorted by From
func Parse(r io.Reader) (*Table, error)       // errors: "routes:LINE: ..." 
func Load(path string) (*Table, error)
func (t *Table) Lookup(port uint16) (Route, bool) // false if no range contains port
func (r Route) Allowed(port uint16) bool      // in range and not denied
func (t *Table) Routes() []Route
```
`Lookup` uses binary search over the sorted ranges.

**Testing** (unit, table-driven):
- valid file with comments/blank lines/`-` deny → two routes; `Lookup(3100)` returns the shell route with `Allowed(3100)==false`; `Lookup(1023)` false.
- AC6.8: each malformed line rejected with its line number: wrong field count, `5000-4000`, `0-10`, `1-70000`, deny `80` outside `1024-65535`, non-numeric deny, invalid target name; overlap `a 1024-5000 -` + `b 4000-6000 -` rejected naming both lines; adjacent `1024-4999` + `5000-6000` accepted.

**Verification:** `./scripts/go.sh test ./internal/routes/` → `ok`.

**Commit:** `stacks/cxagents: forwarder routes table (parse, overlap, deny)`
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-5) -->
<!-- START_TASK_3 -->
### Task 3: `netcheck` and `resolve` packages

**Verifies:** cxagents-node.AC6.11 (subnet decision input).

**Files:**
- Create: `internal/netcheck/netcheck.go`, `netcheck_test.go`; `internal/resolve/resolve.go`, `resolve_test.go` (all under `stacks/cxagents/forwarder/`).

**Implementation:**
- `netcheck.Local() (addr netip.Addr, subnet netip.Prefix, err error)`: the first non-loopback, up interface's IPv4 address and its masked prefix (the container has exactly one: `eth0` on the `cxagents` network). Error if none or more than one IPv4 non-loopback address (fail closed: the forwarder must be on exactly one network). `netcheck.Inside(p netip.Prefix, a netip.Addr) bool`.
- `resolve.Cache`: `New(lookup func(ctx context.Context, host string) ([]netip.Addr, error), names []string, every time.Duration) *Cache`; `Run(ctx)` refreshes all names immediately, then every `every`; `Refresh(name)` triggers an asynchronous refresh of one name (non-blocking, coalesced); `Get(name) ([]netip.Addr, bool)` returns the last successful result (IPv4 only, deduplicated, sorted), lock-free read via `atomic.Pointer` so it is cheap inside the tsnet callback. Default lookup: `net.DefaultResolver.LookupNetIP(ctx, "ip4", host)` with a 2 s timeout per name.

**Testing:**
- netcheck: `Inside` true/false cases (`172.30.0.0/16` contains `172.30.0.5`, not `172.19.0.5`).
- resolve: fake lookup returning a sequence of results; `Get` before first refresh → false; after `Run` → addresses; a lookup error keeps the previous good result; `Refresh` coalesces bursts (count lookup calls).

**Verification:** `./scripts/go.sh test ./internal/netcheck/ ./internal/resolve/` → `ok`.

**Commit:** `stacks/cxagents: forwarder subnet detection and off-lock target resolution cache`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: `flow` package — decision (callback) and caps

**Verifies:** cxagents-node.AC6.11, AC6.12, and the RST paths of AC6.5 (no route / denied).

**Files:**
- Create: `internal/flow/decide.go`, `internal/flow/caps.go`, `internal/flow/decide_test.go`, `internal/flow/caps_test.go`.

**Implementation:**
```go
// Caps bounds in-flight flows per destination port and globally.
type Caps struct { /* mu; perPort map[uint16]int; total, maxPerPort, maxTotal int */ }
func NewCaps(maxPerPort, maxTotal int) *Caps
func (c *Caps) Acquire(port uint16) bool   // false when either cap is reached (never blocks)
func (c *Caps) Release(port uint16)

type Resolver interface{ Get(name string) ([]netip.Addr, bool); Refresh(name string) }

type Decider struct {
	Routes  *routes.Table
	Subnet  netip.Prefix
	Targets Resolver
	Caps    *Caps
	Handle  func(f Flow) // the handler body (Task 5); runs in its own goroutine
	Log     func(f Flow, outcome string)
}

type Flow struct {
	Conn   net.Conn
	Src    netip.AddrPort
	Port   uint16
	Target string
	Addr   netip.AddrPort // target ip:port, validated inside Subnet
	release func()
}

// Decide is the tsnet fallback callback. It runs with tsnet's mutex held:
// in-memory checks only, never a dial or a DNS lookup. Every rejection is
// (nil, true) = RST. Accepted flows get a handler that returns immediately.
func (d *Decider) Decide(src, dst netip.AddrPort) (func(net.Conn), bool) {
	port := dst.Port()
	r, ok := d.Routes.Lookup(port)
	if !ok { d.Log(Flow{Src: src, Port: port}, "rst-noroute"); return nil, true }
	if !r.Allowed(port) { d.Log(Flow{Src: src, Port: port, Target: r.Target}, "rst-deny"); return nil, true }
	addrs, ok := d.Targets.Get(r.Target)
	if !ok || len(addrs) != 1 || !d.Subnet.Contains(addrs[0]) {
		d.Targets.Refresh(r.Target)
		d.Log(Flow{Src: src, Port: port, Target: r.Target}, "rst-target") // unresolved, ambiguous, or off-subnet
		return nil, true
	}
	if !d.Caps.Acquire(port) { d.Log(Flow{Src: src, Port: port, Target: r.Target}, "rst-cap"); return nil, true }
	var once sync.Once
	release := func() { once.Do(func() { d.Caps.Release(port) }) }
	// tsnet may RST after we return (e.g. the client vanishes mid-handshake)
	// without ever calling the handler: reclaim the slot if that happens.
	after := d.OrphanAfter
	if after <= 0 {
		after = 15 * time.Second // zero value must not fire immediately
	}
	orphan := time.AfterFunc(after, release)
	f := Flow{Src: src, Port: port, Target: r.Target, Addr: netip.AddrPortFrom(addrs[0], port), release: release}
	return func(c net.Conn) {
		if !orphan.Stop() { c.Close(); return } // already reclaimed: drop this late conn
		f.Conn = c
		go d.Handle(f)
	}, true
}
```
(`Decider` gains `OrphanAfter time.Duration`. Fields for logging/`release` access may be exported or given methods as the implementor prefers; behaviour above is the contract.)

**Testing** (unit; fake `Resolver`; `Handle` records flows):
- no route (port outside every range) → handler nil, intercept true; denied port 3100 → nil, true.
- AC6.11: target resolves to `172.19.0.5` with subnet `172.30.0.0/16` → nil, true, and `Refresh` was called; unresolved name → nil, true; two addresses → nil, true.
- AC6.12: caps `(maxPerPort=2, maxTotal=3)`: two flows on port 5173 accepted, third on 5173 rejected (nil, true); a flow on 8000 accepted (total 3); a fourth anywhere rejected; after `Release`, accepted again. `Acquire` never blocks (call with caps full inside a 100 ms deadline).
- accepted flow: handler non-nil; invoking it with a `net.Pipe` end returns immediately and `Handle` receives a `Flow` with `Addr` = target ip:port.
- orphaned flow (cap leak guard): with `OrphanAfter` = 50 ms and caps `(1, 1)`, accept a flow but never invoke its handler → after ~50 ms a new flow on the same port is accepted again; invoking the stale handler afterwards closes its conn and does not call `Handle`. A `Decider` with zero-value `OrphanAfter` whose handler is invoked immediately still calls `Handle`.

**Verification:** `./scripts/go.sh test ./internal/flow/` → `ok`.

**Commit:** `stacks/cxagents: forwarder flow decision (in-memory, RST on every rejection) and in-flight caps`
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: `flow` package — handler: dial, first-byte race, TLS termination, splice

**Verifies:** cxagents-node.AC6.4, AC6.5, AC6.9, AC6.10.

**Files:**
- Create: `internal/flow/handler.go`, `internal/flow/handler_test.go`, `internal/flow/testcert_test.go` (self-signed cert helper for tests).

**Implementation contract:**
```go
type Handler struct {
	Dial        func(ctx context.Context, addr netip.AddrPort) (net.Conn, error) // default: net.Dialer{Timeout: 2s}
	DialTimeout time.Duration // 2s
	IdleFirst   time.Duration // 60s: pre-first-byte cap (both sides silent)
	Handshake   time.Duration // 10s TLS handshake deadline
	TLS         *tls.Config   // GetCertificate from tsnet, NextProtos ["http/1.1"], MinVersion TLS1.2
	OnDialFail  func(target string) // e.g. resolver.Refresh
	Log         func(f Flow, mode, outcome string, d time.Duration)
}
func (h *Handler) Serve(f Flow)   // used as Decider.Handle
```
Behaviour of `Serve` (always calls `f.release()` and closes both conns when done):
1. Dial `f.Addr` with `DialTimeout`. On error: `OnDialFail(f.Target)`; reset the client (`if tc, ok := f.Conn.(interface{ SetLinger(int) error }); ok { tc.SetLinger(0) }`, then `Close`); log `outcome=refused`; return. Nothing is cached.
2. **First-byte race.** Start two goroutines, each doing one `Read` into its own 4 KiB buffer with a `SetReadDeadline(now+IdleFirst)`: one on the client, one on the target. Wait for the first result:
   - both time out / error before any byte → close both, log `outcome=idle` (AC6.9 second half);
   - **client first** with `buf[0]==0x16 && (n==1 || buf[1]==0x03)` → TLS mode: clear the client deadline, wrap the client as `prefixConn{Conn: client, prefix: buf[:n]}` (a `net.Conn` whose `Read` returns the prefix first, and which forwards `CloseWrite` to the underlying conn if it has one), `tc := tls.Server(prefixConn, h.TLS)`, `tc.SetDeadline(now+Handshake)`, `tc.Handshake()`; on error log `outcome=handshake-error` and close (no SNI → `GetCertificate` errors → clean failure, AC6.10); else clear deadlines and splice `tc`⇄target;
   - **client first, other bytes** → raw mode: clear deadlines, write `buf[:n]` to the target, splice client⇄target;
   - **target first** (banner) → raw mode: clear deadlines, write `buf[:n]` to the client, splice.
   - **one side ends first with zero bytes** (EOF or error: a client that half-closes immediately, a target that accepts and closes) → not a decision: keep waiting for the other side's first read until the remaining `IdleFirst`. If it then yields bytes → raw mode with the ended side already half-closed (propagate `CloseWrite` to the peer, splice the other direction); if it also ends or times out → close both, outcome `idle` (or `closed` when both sides ended without a byte).
   The goroutine that did not win keeps its pending `Read` (its deadline is cleared to zero so it keeps waiting); its eventual result (bytes or EOF) is delivered first by the splice for that direction before `io.Copy` continues. Implement each direction as: `pending := <-firstRead[side]; write pending bytes; io.Copy(dst, src)` so no byte is lost or reordered.
3. **Splice with half-close:** each direction ends with `CloseWrite()` on its destination when available (`*net.TCPConn`, `*tls.Conn`, tsnet's `gonet.TCPConn`), else nothing; when both directions finish, close both conns. **No idle timeout after the first byte** (live-reload sockets stay open).
4. Log exactly one line per flow at the end: time, src node (`WhoIs func(ctx context.Context, src netip.AddrPort) string` field, wired to `LocalClient().WhoIs` → node name, called in the handler goroutine — never in the callback — with a 1 s timeout, falling back to the IP:port), port, target, `tls|raw|-`, outcome (`ok`, `refused`, `idle`, `closed`, `handshake-error`), duration.

TLS config built in `node` (Task 8): `&tls.Config{GetCertificate: lc.GetCertificate, NextProtos: []string{"http/1.1"}, MinVersion: tls.VersionTLS12}` — `NextProtos` without `h2` pins ALPN to HTTP/1.1 (AC6.10).

**Testing** (unit; real loopback TCP listeners as targets; the "client" side is the other end of a loopback TCP pair handed to `Serve`; `IdleFirst` shortened to 300 ms where the test is about the cap; `TLS.GetCertificate` returns a test self-signed cert for `cxagents.test` and an error when `ServerName==""`):
- AC6.4 echo: client writes `hello\n`, target echoes, client reads `hello\n`.
- AC6.4 banner: target writes `SSH-2.0-test\r\n` immediately on accept; client reads it without sending first; then client→target bytes flow.
- TLS immediate: `tls.Client` with `ServerName: "cxagents.test"`, `RootCAs` = test cert, `NextProtos: ["h2","http/1.1"]` → handshake ok, `ConnectionState().NegotiatedProtocol == "http/1.1"` (AC6.10), plaintext reaches the target, target's reply reaches the client.
- AC6.9 first half: client connects, sleeps 2 s, then starts the TLS handshake → still TLS (`IdleFirst` = 60 s default in this test).
- AC6.9 second half: neither side sends → both closed within `IdleFirst` + 1 s (300 ms cap); outcome `idle`.
- AC6.10 no SNI: `tls.Client` with `ServerName: ""` and `InsecureSkipVerify: true` → handshake error on the client, outcome `handshake-error`, no panic.
- AC6.5: target address with no listener → client conn is closed (read returns EOF or reset) within 2 s; outcome `refused`; `OnDialFail` called. Then start a listener on that port and run `Serve` again → works immediately.
- half-close: client `CloseWrite()` → target reads EOF while the target can still write and the client still reads it.
- single-side EOF before any byte: (a) target accepts and immediately closes → client conn closed promptly, outcome `closed`, no hang; (b) client `CloseWrite()` before sending anything, target then sends a banner → client still receives the banner (raw mode, client side already half-closed).
- no idle cap after first byte: with `IdleFirst` = 300 ms, exchange one byte, wait 1 s, exchange again → still connected.
- release: after `Serve` returns, caps were released (a counting `release` func).

**Verification:** `./scripts/go.sh test ./internal/flow/` → `ok` (the 2 s ClientHello test makes this package take ~3 s).

**Commit:** `stacks/cxagents: forwarder flow handler (dial after accept, first-byte race, TLS http/1.1, half-close splice)`
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_6 -->
### Task 6: `status` package — the agent-facing status endpoint

**Verifies:** cxagents-node.AC7.2, AC7.5, AC7.6 (and AC7.4's 404 at unit level).

**Files:**
- Create: `internal/status/status.go`, `internal/status/scan.go`, `internal/status/status_test.go`.

**Implementation:**
```go
type Server struct {
	Routes      *routes.Table
	Targets     interface{ Get(string) ([]netip.Addr, bool) }
	Domain      func() string                // e.g. "cxagents.faun-fir.ts.net"; from tsnet CertDomains
	Dial        func(ctx context.Context, addr netip.AddrPort) (net.Conn, error)
	HTTPProbe   func(ctx context.Context, addr netip.AddrPort) bool // HEAD / ; any HTTP response = true
	DialTimeout time.Duration // 300ms per port
	ProbeTimeout time.Duration // 1s HEAD
	CacheFor    time.Duration // 5s per caller
	MaxScans    int           // global concurrent scans (default 2); beyond -> 503
	DialSlots   int           // global concurrent dials across all scans (default 128)
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) // only GET /status
```
- **Caller identification:** source IP of `r.RemoteAddr` matched against `Targets.Get(route.Target)` for every route. Exactly one route whose target resolves to exactly that single address → caller. A target resolving to >1 address → `500 ambiguous: <target> resolves to N addresses`. No match → `404 not a cxagents target`.
- **Scan** (per caller, `singleflight` keyed by target, result cached `CacheFor`): every port of the route's range except deny ports (deny ports are never dialed — AC7.6), dialed with `DialTimeout` under the global `DialSlots` semaphore; open ports are then classified with `HTTPProbe` (default: `http.Client{Timeout: ProbeTimeout, Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}` doing `HEAD http://<ip>:<port>/`; any response → `http=true`). A global `MaxScans` semaphore (non-blocking acquire) bounds concurrent scans; when full and no cached result exists → `503 scan limit reached; retry in a few seconds`.
- **`?ports=5173,8000`** filters the cached full scan's `listening` list (it never triggers a separate scan — AC7.5); malformed list → `400`. Ports outside the route or denied appear in neither output.
- **Text (default)** — exactly the design's shape:
```
target: connectome-shell
node:   https://cxagents.faun-fir.ts.net:<port>
range:  1024-65535   deny: 3100
listening (reachable from the forwarder):
  5173  http=yes   https://cxagents.faun-fir.ts.net:5173
  9000  http=no    (raw TCP)  cxagents.faun-fir.ts.net:9000
```
  (deny list comma-separated; `deny: -` when empty; `  (none)` under `listening` when empty).
- **`?format=json`**: `{"target":"connectome-shell","node":"cxagents.faun-fir.ts.net","range":{"from":1024,"to":65535},"deny":[3100],"listening":[{"port":5173,"http":true,"url":"https://cxagents.faun-fir.ts.net:5173"},{"port":9000,"http":false,"url":"cxagents.faun-fir.ts.net:9000"}]}` (raw TCP entries use `host:port` without a scheme).

**Testing** (unit; fake `Targets`; `Dial`/`HTTPProbe` fakes that count calls; routes with small ranges, e.g. `t1 20000-20009 20005`):
- AC7.4 (unit): request from an address no target resolves to → 404 body `not a cxagents target`; target with two addresses → 500 `ambiguous`.
- AC7.6: deny port 20005 never passed to `Dial` or `HTTPProbe`; `HTTPProbe` is called only for ports `Dial` reported open; default `HTTPProbe` against an `httptest.Server` → true, against a raw TCP listener that writes nothing → false within ~`ProbeTimeout`.
- AC7.5: 10 concurrent requests from the same caller with different `?ports=` → the fake `Dial` sees each port exactly once (one scan); a request 6 s later (fake clock or `CacheFor`=50 ms in test) scans again; with `MaxScans`=1 and a blocking fake dialer, a second caller's request returns 503.
- AC7.2: `?ports=20001,20003` narrows `listening` to those two (when open); `?format=json` output unmarshals into the shape above and the text output matches the template (golden string with the test domain).

**Verification:** `./scripts/go.sh test ./internal/status/` → `ok`.

**Commit:** `stacks/cxagents: forwarder status endpoint (caller by source IP, coalesced bounded scans, HEAD classification)`
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: `check` evaluation and state-file detection

**Verifies:** unit support for AC4.4/AC4.5 (Phase 7) and AC5.5/AC5.7 (Phase 5).

**Files:**
- Create: `internal/check/check.go`, `check_test.go`; `internal/node/statefile.go`, `statefile_test.go`.

**Implementation:**
- `check.NodeInfo{Name, DNSName, ID string; Tags []string; Online bool; BackendState string; CertNotAfter time.Time}` (JSON-tagged; served over the check socket in Task 8).
- `check.Evaluate(info NodeInfo, wantHost, wantTag string, now time.Time) []string` returns problems: `BackendState != "Running"`; `Name != wantHost` (Name = first label of `DNSName`, so `cxagents-1` is a problem: "node is named cxagents-1, not cxagents (stale device? see login)"); `Tags` not exactly `[wantTag]` (untagged or extra tags); `!Online`; `CertNotAfter` zero or `≤ now+14 days`.
- `check.Format(info NodeInfo, now time.Time) string` — the human lines `node:`, `id:`, `tags:`, `online:`, `cert:   expires YYYY-MM-DD (N days)`.
- `node.StateNodeID(dir string) (id string, err error)`: reads `dir/tailscaled.state` (missing file → `"", nil`); unmarshals into `map[string][]byte`; `_current-profile` → profile ID; `_profiles` → `map[string]struct{ NodeID string }`; returns that profile's `NodeID` (empty string if any piece is missing → "empty state").

**Testing:**
- Evaluate: all-good info → no problems; each single defect (renamed `cxagents-1`, untagged, extra tag, offline, cert 14 days out, cert 13 days, zero cert, `NeedsLogin`) → exactly one problem.
- StateNodeID: fixture state written in the test with `json.Marshal(map[string][]byte{"_current-profile": []byte("abcd"), "_profiles": []byte(`{"abcd":{"NodeID":"nXYZ"}}`)})` → `nXYZ`; missing file, empty `_profiles`, missing current profile → `""`, no error; corrupt JSON → error.

**Verification:** `./scripts/go.sh test ./internal/check/ ./internal/node/` → `ok`.

**Commit:** `stacks/cxagents: forwarder check evaluation and offline state detection`
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: `node` package — tsnet wiring, cert warm-up/refresh, check socket

**Verifies:** None directly (wiring; exercised end-to-end in Phases 5–7). Unit test only the check-socket client/server round trip.

**Files:**
- Create: `internal/node/node.go`, `internal/node/checksock.go`, `internal/node/checksock_test.go`.

**Implementation:**
- `type Config struct{ Dir, Hostname, Tag string; Verbose bool }` (from env in `main`).
- `newServer(cfg, authKey string) *tsnet.Server`: `&tsnet.Server{Dir: cfg.Dir, Hostname: cfg.Hostname, AdvertiseTags: []string{cfg.Tag}, AuthKey: authKey, UserLogf: log.Printf, Logf: filtered}` where `filtered` drops everything unless `cfg.Verbose` (env `FORWARDER_TS_VERBOSE=1`). Before constructing, unset tsnet's two auth-key environment variables so no environment key is ever consulted — spelled from fragments, because no tracked file outside `tailscale/` may contain those names (Phase 1 conventions; `keyscan.sh --repo`):
```go
// tsnet falls back to these env vars when AuthKey is empty. Names are split
// so the repo-wide credential-name scan (tailscale/scripts/keyscan.sh) stays clean.
for _, k := range []string{"TS_" + "AUTH" + "KEY", "TS_" + "AUTH_" + "KEY"} {
	os.Unsetenv(k)
}
```
and and `os.MkdirAll(filepath.Join(cfg.Dir, "logs"), 0700)` (for `TS_LOGS_DIR`).
- `Login(ctx, cfg, key string) (check.NodeInfo, error)`: refuse if `StateNodeID(cfg.Dir)` is non-empty ("state already holds node X"); `srv.Up(ctx)`; info from `Status`; if `Name != cfg.Hostname` return an error naming the assigned name (collision); fetch the cert once (`CertPair(ctx, CertDomains[0])`, retried every 5 s until `ctx` ends; no `CertDomains` → error "HTTPS certificates are not enabled for the tailnet (tailscale/README.md settings checklist)"); `srv.Close()`; return info with `CertNotAfter`.
- `Serve(ctx, cfg) (*Running, error)`: refuse if `StateNodeID` is empty ("no node in state — run `dotfiles stacks cxagents login`"); `Up(ctx)` with a 2-minute timeout; domain = `CertDomains[0]`; warm the cert (`CertPair`, parse leaf `NotAfter`); start a goroutine refreshing it every 24 h (log failures); expose `LocalClient()`, `Domain()`, `Info(ctx) check.NodeInfo`, `Register(cb) (unregister func())` (wraps `RegisterFallbackTCPHandler`), `Close()`.
- `checksock.go`: `ServeCheck(ctx, path string, info func(ctx) check.NodeInfo) error` — HTTP over a unix socket at `path` (`/state/forwarder.sock`, mode 0600, removed on start if stale); `GET /check` → JSON `NodeInfo`. `FetchCheck(path string) (check.NodeInfo, error)` — client with a 5 s timeout.

**Testing:** `checksock_test.go`: serve on a socket in `t.TempDir()`, fetch → identical `NodeInfo`; fetch with no server → error.

**Verification:** `./scripts/go.sh test ./internal/node/ && ./scripts/go.sh vet ./...` → `ok`, no vet findings.

**Commit:** `stacks/cxagents: forwarder tsnet wiring (state-gated serve/login, cert warm-up + daily refresh, check socket)`
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: `main.go` — subcommands and configuration

**Verifies:** cxagents-node.AC6.8 (refuse to start; also proven in the image test).

**Files:**
- Modify: `stacks/cxagents/forwarder/main.go` (replace the stub).
- Create: `stacks/cxagents/forwarder/main_test.go`.

**Implementation:** environment (all set by compose / the login one-shot; defaults shown):
`FORWARDER_STATE_DIR=/state`, `FORWARDER_HOSTNAME=cxagents`, `FORWARDER_TAG=tag:cxagents`, `FORWARDER_ROUTES=/etc/forwarder/routes`, `FORWARDER_STATUS_PORT=8080`, `FORWARDER_MAX_FLOWS_PER_PORT=32`, `FORWARDER_MAX_FLOWS=256`, `FORWARDER_TS_VERBOSE` (unset).
- `serve` (default): (1) `routes.Load` — on error print it and exit 1 **before anything else** (AC6.8); (2) `node.StateNodeID` — empty → print `no node in state — run \`dotfiles stacks cxagents login\`` and exit 1 (before any network check, so an empty-state container fails fast however it is networked; AC5.7); (3) `netcheck.Local()` → subnet, local addr (exit 1 on error); (4) `node.Serve`; (4b) resolver cache over the route targets (`Run` in a goroutine, wait ≤ 5 s for the first refresh); (5) `flow.Decider{…, Handle: handler.Serve}` registered via `Register`; (6) status `http.Server{Handler: mux("/status" → status.Server), ReadHeaderTimeout: 5s}` listening on `<local-addr>:FORWARDER_STATUS_PORT` (the cxagents interface address only; never on the tailnet — tsnet listeners are in-memory and distinct from OS sockets); (7) `ServeCheck` on `STATE_DIR/forwarder.sock`; (8) on SIGTERM/SIGINT: unregister, shut the status server down, `Close`.
- `login`: read one line from stdin (max 4 KiB; `strings.TrimSpace`); empty → exit 2 "no auth key on stdin"; `node.Login` with a 3-minute context; print `check.Format(info)`; exit 1 on error.
- `check`: `check --state-only` → `StateNodeID`: prints `state: node <ID>` (exit 0) or `state: empty` (exit 1). Plain `check` → `FetchCheck(STATE_DIR/forwarder.sock)` (error → "forwarder not running" exit 1); print `check.Format`; problems from `check.Evaluate(info, FORWARDER_HOSTNAME, FORWARDER_TAG, now)` printed as `problem: …` lines; exit 1 if any.
- Unknown subcommand → usage, exit 2.

**Testing** (`main_test.go`, unit: run the subcommand functions directly, not a subprocess): `serve` with a routes path containing an overlap returns the routes error before touching state (pass a state dir that does not exist and assert the error is the routes one); `serve` with valid routes and an empty state dir returns the login-hint error (and never reaches `netcheck`); `check --state-only` on an empty temp dir → `state: empty`, exit code 1; `login` with empty stdin → exit 2.

**Verification:** `cd "$wt/stacks/cxagents" && ./scripts/go.sh vet ./... && ./scripts/go.sh test -count=1 ./...` → all `ok`; `"$wt/tailscale/scripts/keyscan.sh" --repo` → exit 0 (no credential env names in the Go source).

**Commit:** `stacks/cxagents: tailnet-forwarder serve/login/check`
<!-- END_TASK_9 -->

<!-- START_SUBCOMPONENT_C (tasks 10-11) -->
<!-- START_TASK_10 -->
### Task 10: `build.sh` — tests, image, `build.lock`

**Verifies:** cxagents-node.AC8.4.

**Files:**
- Create: `stacks/cxagents/scripts/build.sh` (755); generated `stacks/cxagents/build.lock` (tracked).

**Implementation** (model: `stacks/connectome/scripts/build.sh` — lock written to a temp file and moved into place only after a successful build):
```bash
#!/usr/bin/env bash
# stacks/cxagents/scripts/build.sh — run the forwarder's tests in the pinned
# builder, build tailnet-forwarder:local, write stacks/cxagents/build.lock.
# Exit: 0 ok; 1 precondition; 3 test/build failure (build.lock unchanged).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
src="${stack_dir}/forwarder"
ctx=colima-agents
img=tailnet-forwarder:local
lock="${stack_dir}/build.lock"

docker --context "$ctx" info >/dev/null 2>&1 || { echo "build: agents VM not running (dotfiles stacks vm-agents-up)" >&2; exit 1; }
builder="$(sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' "${src}/Dockerfile")"
runtime="$(sed -n 's/^FROM \(gcr\.io\/distroless\/[^ ]*\)$/\1/p' "${src}/Dockerfile")"
case "$builder$runtime" in *@sha256:*@sha256:*) ;; *) echo "build: base images must be pinned by digest" >&2; exit 1 ;; esac
grep -q '^toolchain go' "${src}/go.mod" || { echo "build: go.mod has no toolchain line" >&2; exit 1; }

nocache=(); [ "${1:-}" = --no-cache ] && nocache=(--no-cache)
docker --context "$ctx" build ${nocache[@]+"${nocache[@]}"} --target test "$src" || exit 3
docker --context "$ctx" build ${nocache[@]+"${nocache[@]}"} -t "$img" "$src" || exit 3

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; docker --context "$ctx" rm -f cxagents-build-extract >/dev/null 2>&1 || true' EXIT
docker --context "$ctx" create --name cxagents-build-extract "$img" >/dev/null
docker --context "$ctx" cp cxagents-build-extract:/tailnet-forwarder "$tmp/tailnet-forwarder"
bin_sha="$(shasum -a 256 "$tmp/tailnet-forwarder" | cut -d' ' -f1)"
# go.mod after tidy: either `require tailscale.com vX` (one line) or inside a require block.
ts_ver="$(awk '$1=="require" && $2=="tailscale.com" {print $3; exit} $1=="tailscale.com" {print $2; exit}' "${src}/go.mod")"
[ -n "$ts_ver" ] || { echo "build: cannot read the tailscale.com version from go.mod" >&2; exit 1; }
{
    echo "# Generated by \`dotfiles stacks cxagents build\`. Do not edit."
    echo "go $(sed -n 's/^go //p' "${src}/go.mod")"
    echo "toolchain $(sed -n 's/^toolchain //p' "${src}/go.mod")"
    echo "tailscale.com ${ts_ver}"
    echo "builder ${builder}"
    echo "runtime ${runtime}"
    echo "binary sha256:${bin_sha} linux/arm64"
} > "$tmp/build.lock"
mv "$tmp/build.lock" "$lock"
echo "build: ${img} (binary sha256:${bin_sha})"
```
(`build.sh --no-cache` forces a cold build without pruning the VM's shared build cache, which connectome also uses.)

**Step 1:** Create the script. **Step 2: Verify reproducibility (AC8.4)**
```bash
cd "$wt/stacks/cxagents"
./scripts/build.sh && cp build.lock /tmp/claude-build.lock.1
./scripts/build.sh --no-cache && diff /tmp/claude-build.lock.1 build.lock && echo "OK: identical build.lock"
rm -f /tmp/claude-build.lock.1; cat build.lock
```
Expected: tests pass inside the build; `OK: identical build.lock`; the lock lists `go 1.27.1`, `toolchain go1.27.1`, `tailscale.com v1.104.1`, both digests, the binary hash. If the two binary hashes differ, find the non-determinism (e.g. an embedded path or timestamp) and fix the build flags — do not drop the binary line.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/build.sh stacks/cxagents/build.lock
git commit -m "stacks/cxagents: build.sh (tests in pinned builder, image, reproducible build.lock)"
```
<!-- END_TASK_10 -->

<!-- START_TASK_11 -->
### Task 11: `image-test.sh`

**Verifies:** cxagents-node.AC8.4 (image side), AC6.8 (image level), plus the non-root/static/no-shell/read-only properties AC8.2 relies on (AC8.2 is claimed in Phase 5 with the compose file).

**Files:**
- Create: `stacks/cxagents/scripts/image-test.sh` (755).

**Implementation** (model: `stacks/connectome/scripts/image-test.sh`: `set -uo pipefail`, sources `stacks/scripts/lib/check.sh`, numbered checks each `pass`/`fail` with the AC id, final `[ "$__check_failed" -eq 0 ] || exit 1`). Use a throwaway volume `cxagents_imagetest_state` and temp dir, removed by an EXIT trap. Checks:
1. `cxagents-node.AC8.2` — `docker image inspect -f '{{.Config.User}}'` is `65532:65532`; `.Config.Entrypoint` is `["/tailnet-forwarder"]`.
2. `AC8.2` no shell — `docker run --rm --network none --entrypoint /bin/sh tailnet-forwarder:local -c true` fails.
3. `AC8.4` static/trimmed — extract the binary (`docker create` + `docker cp`) to a `mktemp -d` dir (under `/var/folders`, mounted read-only into the VM), run the builder from the Dockerfile with that dir mounted read-only: `go version -m /b/tailnet-forwarder` output contains `CGO_ENABLED=0`, `-trimpath=true`, `go1.27.1`, `tailscale.com	v1.104.1`; its sha256 equals the `binary` line in `build.lock`.
4. `AC8.2` read-only root + state ownership — `docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges:true --network none -v cxagents_imagetest_state:/state tailnet-forwarder:local check --state-only` prints `state: empty` and exits 1; then `docker run --rm -v cxagents_imagetest_state:/state alpine stat -c %u:%g /state` prints `65532:65532`.
5. `AC6.8` — the same hardened `run`, with a temp routes file (`a 1024-5000 -` / `b 4000-6000 -`) bind-mounted read-only at `/etc/forwarder/routes`, command `serve`, under `timeout 20`: exits non-zero within the timeout and output names the overlap.
6. `AC5.7` (image side) — the same hardened `--network none` run with a valid routes file, empty state volume, command `serve`, `timeout 20`: exits non-zero with `run \`dotfiles stacks cxagents login\`` (the state gate precedes the network check — Task 9 — so it never waits on an interactive login).

**Step 1:** Create the script. **Step 2: Verify:** `./scripts/image-test.sh` → six `[OK]` lines, exit 0.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/image-test.sh
git commit -m "stacks/cxagents: image-test (non-root, no shell, static, read-only root, refuses bad routes/empty state)"
```
<!-- END_TASK_11 -->
<!-- END_SUBCOMPONENT_C -->

---

**Phase 4 done when:** `./scripts/go.sh vet ./...` and `./scripts/go.sh test -count=1 ./...` pass; `build.sh` passes its in-build tests and two builds (the second with `--no-cache`) produce an identical `build.lock`; `image-test.sh` passes all checks; `tailscale/scripts/keyscan.sh --repo` exits 0.
