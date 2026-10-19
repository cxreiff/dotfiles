# cxagents Node Implementation Plan — Phase 6 of 7: connectome as the first target; WebUI guard; end-to-end smoke

**Goal:** Servers the agent runs in `connectome-shell` are reachable at `https://cxagents.faun-fir.ts.net:<port>`; the agent is told how to use it; agent pages cannot drive the connectome WebUI; an end-to-end smoke from the Mac proves it.

**Architecture:** A compose overlay `stacks/connectome/compose.cxagents.yaml` attaches `shell` to the external `cxagents` network. A wrapper `stacks/connectome/scripts/compose.sh` computes the file set once (overlay only when the network exists, warning on `up` otherwise) and every compose-invoking connectome recipe uses it. A local patch on the `connectome-host` clone (branch `local`) makes the WebUI reject `Sec-Fetch-Site: same-site|cross-site` and foreign `Origin`s on every request; it is recorded in `sources.lock` by `connectome build`. `stacks/cxagents/scripts/smoke.sh` gains end-to-end checks run from the Mac over the tailnet, with tiny Python test servers started inside the shell.

**Tech Stack:** Docker Compose overlays, bash, Python 3 stdlib (in `connectome-shell` and on the Mac), curl, macOS `nc`, TypeScript/Bun (`connectome-host`, tests with `bun test` in an `oven/bun:1-debian` container).

**Scope:** Phase 6 of 7 from `docs/design-plans/2026-10-17-cxagents-node.md`. Depends on Phase 5.

**Codebase verified:** 2026-10-17

See `phase_01.md` "Conventions used in every phase file".

**State found at verification:**
- `stacks/connectome/justfile`: compose is invoked as `docker --context {{context}} compose …` at lines 35 (`up`), 38 (`down`), 41 (`restart`), 44 (`ps`), 84/87/91 (`backup`: `compose ps -q --status running`, `compose start`, `compose stop`), 121/123 (`restore`: `compose stop`, `compose start` in the ERR trap). `up` (28–35) first refuses when `onecli-agents` is missing. No `-f` anywhere (default `compose.yaml`). `build.sh:69` builds with `-f compose.yaml` (unchanged: building needs no network).
- `stacks/connectome/compose.yaml`: service `shell` (container `connectome-shell`, networks `onecli-agents`, `connectome`), service `connectome` (container `connectome`); `onecli-agents` is `external: true`.
- `stacks/connectome/recipes/agent.json` line 8: `systemPrompt` is a single string.
- `stacks/connectome/scripts/lint.sh` parses only `compose.yaml` and has no network invariant; `smoke.sh` `check_ac9_4` compares named volumes only — neither is affected by a network-only overlay. `image-test.sh` check 13 greps `sources.lock` for specific patch subjects and expects exactly 4 `source` lines.
- `connectome-shell` has `python3`, `node`, `curl`, `openssl`, `socat`, `ss`; no `nc`. It listens on `0.0.0.0:3100` and has `HTTPS_PROXY`/`https_proxy` set (`NO_PROXY=localhost,127.0.0.1`); `http_proxy` is unset, so `curl http://…` goes direct.
- `~/Developer/connectome/connectome-host` is on branch `local` at `2ee8219` (matches `sources.lock`). WebUI: `src/modules/web-ui-module.ts` — `checkOrigin(req)` at lines 3304–3329 (allows when `allowedOrigins` is empty, when no `Origin` header, when `Origin` is in the list, or when the Origin host equals the `Host` header); it is applied on the WebSocket upgrade at 1006–1010 (`403 Forbidden`); basic auth via `checkAuth` (3331–3350). No code reads `Sec-Fetch-Site`. Tests: `test/web-ui-module.test.ts` (`bun test`). Recipe config `agent.json` lines 57–63: `allowedOrigins: ["https://cxmini.faun-fir.ts.net:8768"]`, `basicAuth` from `WEBUI_USER`/`WEBUI_PASS`.

**Live-system note:** recreating connectome from the worktree binds the worktree's `./recipes`; after merge, run `dotfiles stacks connectome up` from `main` (Phase 7 post-merge list). A host reboot before the merge runs `main`'s `up-all`, which recreates `connectome-shell` **without** the overlay and with `main`'s `recipes/` (the old prompt; the WebUI patch survives because it lives in the `connectome-host:local` image); after any pre-merge reboot re-run `$J stacks cxagents up && $J stacks connectome up` from the worktree. Every step below that restarts connectome interrupts the live agent for under a minute — tell the user before the first one.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### cxagents-node.AC6: Any agent server is reachable over trusted HTTPS (Phases 4, 6)
- **cxagents-node.AC6.1 Success:** an HTTP server on `connectome-shell` `0.0.0.0:P` (any allowed P) loads at `https://cxagents.faun-fir.ts.net:P` with certificate verification on (`curl` without `-k`; browser shows no warning). (end-to-end, Phase 6)
- **cxagents-node.AC6.2 Success:** the same server also answers at `http://cxagents.faun-fir.ts.net:P`.
- **cxagents-node.AC6.3 Success:** WebSockets work over `wss://` on the same port (live-reload), and an idle WebSocket survives 10 minutes.
- **cxagents-node.AC6.4 Success:** a raw client-speaks-first TCP server (echo) and a server-speaks-first one (banner) both work. *(end-to-end here; unit in Phase 4)*
- **cxagents-node.AC6.5 Failure:** with nothing listening on P, the client gets connection refused/reset within ~2 s, and a server started afterwards on P is reachable immediately (no stale state). *(end-to-end; per the Phase 4 dial-point decision the client sees the connection closed rather than refused)*
- **cxagents-node.AC6.6 Failure:** port 3100 and ports <1024 are unreachable from the tailnet, even though shell listens on 3100. (end-to-end, Phase 6)
- **cxagents-node.AC6.7 Failure:** a server bound only to `127.0.0.1` in shell is unreachable (refused).

### cxagents-node.AC7: Agents can diagnose their servers (Phases 4, 6)
- **cxagents-node.AC7.1 Success:** `curl http://cxagents-forwarder:8080/status` from shell returns its target name, range, deny list, base URL, and each listening port with its URL and http/tls classification.
- **cxagents-node.AC7.3 Edge:** a loopback-only server does not appear in `listening`, while it does appear in shell's own `ss -ltn`.
- **cxagents-node.AC7.4 Failure:** a caller whose source IP matches no route target gets `404 not a cxagents target`; the status endpoint is not reachable from the tailnet.

### cxagents-node.AC9: connectome is the first target (Phase 6)
- **cxagents-node.AC9.1 Success:** with the `cxagents` network present, connectome `up` includes `compose.cxagents.yaml` and `connectome-shell` joins `cxagents`; without it, connectome starts without the overlay and prints a warning.
- **cxagents-node.AC9.2:** the agent prompt states the URL pattern, the 0.0.0.0 bind rule, the allowed ports, the status endpoint (and to self-test with it, not the public URL), the Vite host-check note, no wildcard CORS, and that backends see plain HTTP without `X-Forwarded-Proto` and share cookies across ports.
- **cxagents-node.AC9.3:** connectome's existing `lint`, `lint-test` and `smoke` still pass.
- **cxagents-node.AC9.5 Failure:** the connectome WebUI rejects with 403 any request whose `Sec-Fetch-Site` is `same-site` or `cross-site`, or whose `Origin` is not in `allowedOrigins`; same-origin use from `https://cxmini.faun-fir.ts.net:8768` is unaffected.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Overlay and compose wrapper

**Verifies:** cxagents-node.AC9.1 (wiring).

**Files:**
- Create: `stacks/connectome/compose.cxagents.yaml`, `stacks/connectome/scripts/compose.sh` (755).
- Modify: `stacks/connectome/justfile` lines 35, 38, 41, 44, 84, 87, 91, 121, 123.

**Step 1: `compose.cxagents.yaml`**
```yaml
# Optional overlay (added by scripts/compose.sh only when the `cxagents`
# network exists): the agent's shell joins the cxagents node's network so
# servers it runs are reachable at https://cxagents.faun-fir.ts.net:<port>
# (stacks/cxagents). Only `shell` joins — never the connectome container.
services:
  shell:
    networks:
      - cxagents

networks:
  cxagents:
    external: true
```

**Step 2: `scripts/compose.sh`**
```bash
#!/usr/bin/env bash
# stacks/connectome/scripts/compose.sh [--warn] ARGS... — docker compose for
# this stack with the right file set: compose.yaml, plus compose.cxagents.yaml
# when the cxagents network exists (soft opt-in: agent previews are not
# essential; connectome's hard dependency is onecli only). --warn prints a
# warning when the overlay is skipped (used by `up`).
set -euo pipefail
stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ctx=colima-agents
warn=0
if [ "${1:-}" = --warn ]; then warn=1; shift; fi
files=(-f "${stack_dir}/compose.yaml")
if docker --context "$ctx" network inspect cxagents >/dev/null 2>&1; then
    files+=(-f "${stack_dir}/compose.cxagents.yaml")
elif [ "$warn" -eq 1 ]; then
    echo "connectome: network cxagents missing — starting without agent previews (dotfiles stacks cxagents up, then connectome up)" >&2
fi
exec docker --context "$ctx" compose --project-directory "$stack_dir" "${files[@]}" "$@"
```

**Step 3: justfile** — replace `docker --context {{context}} compose` with `./scripts/compose.sh` on each listed line; `up` (line 35) uses `./scripts/compose.sh --warn up -d`. Inside the `backup`/`restore` shebang recipes the cwd is the stack dir, so `./scripts/compose.sh` resolves. Add a comment above `up`: `# Joins the cxagents network (agent previews) when it exists; warns otherwise.`

**Step 4: Verify (static)**
```bash
cd "$wt/stacks/connectome"
docker compose -f compose.yaml -f compose.cxagents.yaml config --no-interpolate --format json | jq -c '(.services.shell.networks|keys), (.services.connectome.networks|keys)'
grep -n 'docker --context {{context}} compose' justfile; echo "(expect no lines)"
```
Expected: `["connectome","cxagents","onecli-agents"]`, `["connectome","onecli-agents"]`; no remaining direct compose lines.

**Step 5: Commit**
```bash
git add stacks/connectome/compose.cxagents.yaml stacks/connectome/scripts/compose.sh stacks/connectome/justfile
git commit -m "stacks/connectome: optional cxagents overlay via scripts/compose.sh (shell joins cxagents when present)"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Agent prompt paragraph

**Verifies:** cxagents-node.AC9.2.

**Files:**
- Modify: `stacks/connectome/recipes/agent.json` line 8 (`systemPrompt` string) — append one paragraph (after the existing text, separated by a space; JSON-escape quotes):

```
Servers you run in the shell are reachable by the operator: bind to 0.0.0.0 (never 127.0.0.1) on any port from 1024 to 65535 except 3100, and the server is at https://cxagents.faun-fir.ts.net:<port> (http:// also works; non-HTTP protocols pass through as raw TCP on the same host and port). To check what is reachable, run `curl http://cxagents-forwarder:8080/status` in the shell (add ?ports=5173 to narrow it, &format=json for JSON) and self-test with it, not with the public URL, which from inside the shell goes through the HTTPS proxy. Dev servers with a host check (e.g. Vite's server.allowedHosts) must allow cxagents.faun-fir.ts.net. Never enable wildcard CORS. Your backend sees plain HTTP with no X-Forwarded-Proto header even when the operator uses https, and cookies are shared across all ports of cxagents.faun-fir.ts.net.
```

**Step 1:** Edit with `jq` to avoid hand-escaping: `jq --arg p "<paragraph>" '.agent.systemPrompt += " " + $p' recipes/agent.json > recipes/agent.json.tmp && mv recipes/agent.json.tmp recipes/agent.json` (confirm the key path from the file: `agent.systemPrompt`; keep the file's 2-space formatting — compare `git diff` and reformat if jq changed unrelated lines).

**Step 2: Verify (AC9.2 checklist, static)**
```bash
p=$(jq -r .agent.systemPrompt "$wt/stacks/connectome/recipes/agent.json")
for s in 'https://cxagents.faun-fir.ts.net:<port>' '0.0.0.0' '1024 to 65535 except 3100' 'cxagents-forwarder:8080/status' 'not with the public URL' 'allowedHosts' 'wildcard CORS' 'X-Forwarded-Proto' 'cookies are shared'; do
  grep -qF "$s" <<<"$p" && echo "OK: $s" || echo "MISSING: $s"; done
$J stacks connectome lint
```
Expected: nine `OK:` lines; connectome lint all `[OK]`.

**Step 3: Commit**
```bash
git add stacks/connectome/recipes/agent.json
git commit -m "stacks/connectome: agent prompt explains cxagents previews and the status endpoint"
```
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_3 -->
### Task 3: connectome-host local patch — WebUI cross-site guard

**Verifies:** cxagents-node.AC9.5 (unit, in the clone).

**Files (outside this repo, in `~/Developer/connectome/connectome-host`, branch `local`):**
- Modify: `src/modules/web-ui-module.ts` (`checkOrigin` at ~3304–3329 and the request entry point that dispatches HTTP routes and the WS upgrade, ~1000–1040).
- Modify: `test/web-ui-module.test.ts`.

**Implementation:**
1. Read the request entry (`fetch` handler) around lines 1000–1040 to find where every HTTP request and the WS upgrade enter. Add a single guard at the top of that entry, **before** basic auth and routing, applied to all requests:
```ts
// local: agent pages on cxagents.faun-fir.ts.net are same-site with this
// WebUI (ts.net is on the Public Suffix List); reject anything a browser marks
// as same-site or cross-site, and any Origin outside allowedOrigins.
private crossSiteBlocked(req: Request): boolean {
  const site = req.headers.get('sec-fetch-site');
  if (site === 'same-site' || site === 'cross-site') return true;
  return !this.checkOrigin(req);
}
```
   and in the entry: `if (this.crossSiteBlocked(req)) return new Response('Forbidden', { status: 403 });`. The existing WS-upgrade `checkOrigin` call can stay (now redundant) — leave it to minimise the patch.
2. `checkOrigin` itself is unchanged: requests with no `Origin` (curl, top-level GET navigations that browsers send without Origin) and `Sec-Fetch-Site: same-origin`/`none` keep working; `Origin: https://cxmini.faun-fir.ts.net:8768` is in `allowedOrigins`.
3. Tests in `test/web-ui-module.test.ts`, following that file's existing setup for constructing the module and issuing requests: with `allowedOrigins = ["https://cxmini.faun-fir.ts.net:8768"]` and basic auth configured, expect 403 for `Sec-Fetch-Site: same-site`, for `Sec-Fetch-Site: cross-site`, and for `Origin: https://cxagents.faun-fir.ts.net:5173` (each on both a plain HTTP route and the WS upgrade path); expect the normal (non-403) response for `Sec-Fetch-Site: same-origin` + `Origin: https://cxmini.faun-fir.ts.net:8768` with valid basic auth, and for a request with neither header.

**Step 1: Run the tests without touching the clone's working tree** (so `connectome build`'s clean-tree check still passes):
```bash
docker --context colima-agents run --rm -v "$HOME/Developer/connectome/connectome-host:/src:ro" oven/bun:1-debian \
  sh -c 'cp -a /src /w && cd /w && bun install --frozen-lockfile >/dev/null && bun test test/web-ui-module.test.ts'
```
Run it first after writing the tests and before the implementation (the new cases fail), then after (all pass). Also run the whole suite once at the end (`bun test`) and compare against a run on the unpatched `local` HEAD: no new failures.

**Step 2: Commit in the clone**
```bash
cd ~/Developer/connectome/connectome-host
git status --porcelain            # only the two files
git add src/modules/web-ui-module.ts test/web-ui-module.test.ts
git commit -m "local: WebUI rejects same-site and cross-site requests (Sec-Fetch-Site, Origin)"
git status --porcelain            # empty
```

**Commit (this repo):** none yet (Task 4 records it via `build`).
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Rebuild connectome, record the patch, recreate the stack with the overlay

**Verifies:** cxagents-node.AC9.1 (with network), AC9.3 (image side).

**Files:**
- Modify (generated): `stacks/connectome/sources.lock` (new `patch connectome-host local: WebUI rejects same-site and cross-site requests (Sec-Fetch-Site, Origin)` line, new `sha=`).
- Modify: `stacks/connectome/scripts/image-test.sh` check 13 — add the grep for `patch connectome-host local: WebUI rejects same-site` alongside the existing patch-subject greps.
- Modify: `stacks/connectome/README.md` `## Sources and local patches` — add the patch to the list with one line on what it does and why (agent pages are same-site with the WebUI), so it can be re-applied by hand on a fresh device.

**Step 1 (tell the user: this recreates connectome and connectome-shell):**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J stacks connectome build && $J stacks connectome image-test
$J stacks connectome up
docker --context colima-agents inspect connectome-shell -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
docker --context colima-agents inspect connectome -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```
Expected: build and image-test pass; `up` prints no overlay warning; shell networks include `cxagents`; the `connectome` container's do not.

**Step 2: Commit**
```bash
git add stacks/connectome/sources.lock stacks/connectome/scripts/image-test.sh stacks/connectome/README.md
git commit -m "stacks/connectome: WebUI cross-site guard patch recorded (sources.lock, image-test, README)"
```
<!-- END_TASK_4 -->

<!-- START_SUBCOMPONENT_B (tasks 5-6) -->
<!-- START_TASK_5 -->
### Task 5: Smoke test servers

**Verifies:** None directly (test fixtures for Task 6).

**Files:**
- Create: `stacks/cxagents/scripts/smoke/ws_echo_server.py`, `ws_client.py`, `echo_server.py`, `banner_server.py` (Python 3 stdlib only; no third-party packages).

**Implementation:**
- `echo_server.py PORT [BIND]` — threaded TCP server (`socketserver.ThreadingTCPServer`, `allow_reuse_address`), echoes every byte; default bind `0.0.0.0`.
- `banner_server.py PORT` — on accept, immediately sends `SSH-2.0-cxsmoke\r\n`, then echoes.
- `ws_echo_server.py PORT` — threaded HTTP/1.1 server: `GET /` returns a page containing `cxsmoke-ws`; a request with `Upgrade: websocket` gets the RFC 6455 handshake (`Sec-WebSocket-Accept = base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`, `101 Switching Protocols`), then echoes text frames (unmask client frames; reply unmasked; handle ping→pong and close). ~80 lines.
- `ws_client.py URL [--idle SECONDS]` (runs on the Mac) — `wss://host:port/` via `ssl.create_default_context()` (verification on, SNI = host); sends the upgrade; expects `101`; sends a masked text frame `hello`, expects the echo; if `--idle N`, sleeps N seconds, then sends `again` and expects the echo; prints `ok` and exits 0, else prints the failure and exits 1.

**Step 1:** Create the files. **Step 2: Verify locally on the Mac:** `python3 stacks/cxagents/scripts/smoke/echo_server.py 47899 127.0.0.1 & sleep 1; printf 'x\n' | nc -w 2 127.0.0.1 47899; kill %1` → `x`.

**Step 3: Commit**
```bash
git add stacks/cxagents/scripts/smoke
git commit -m "stacks/cxagents: stdlib test servers for the end-to-end smoke"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: End-to-end checks in `stacks/cxagents/scripts/smoke.sh`

**Verifies:** cxagents-node.AC6.1–AC6.7, AC7.1, AC7.3, AC7.4, AC9.5.

**Files:**
- Modify: `stacks/cxagents/scripts/smoke.sh` — add e2e checks, a `--long` flag, and update `check_ac5_6_downup`.

**Implementation:** host `H=cxagents.faun-fir.ts.net` (from `tailscale/tailnet.conf`: `cxagents.${TAILNET_DNS_SUFFIX}`). Setup (registered with the cleanup stack before anything starts): `X() { D exec connectome-shell "$@"; }`; copy the four servers into the shell (`D cp stacks/cxagents/scripts/smoke/. connectome-shell:/tmp/cxsmoke/`); start them detached (`D exec -d connectome-shell python3 /tmp/cxsmoke/<server> <port>`): ws/http server on 47801, echo on 47803, banner on 47804, a loopback-only `python3 -m http.server 47806 --bind 127.0.0.1`; wait until `X ss -ltn` shows each port. Cleanup: `X pkill -f /tmp/cxsmoke` and `X pkill -f 'http.server 4780'`, `X rm -rf /tmp/cxsmoke`. Guard each check with `running connectome-shell` and `running cxagents-forwarder`. Checks:
- `check_ac6_1` — `curl -fsS --max-time 15 "https://${H}:47801/"` (no `-k`) contains `cxsmoke-ws`.
- `check_ac6_2` — `curl -fsS --max-time 15 "http://${H}:47801/"` contains `cxsmoke-ws`.
- `check_ac6_3` — `python3 stacks/cxagents/scripts/smoke/ws_client.py "wss://${H}:47801/"` prints `ok`; with `--long`, also `--idle 600` (10 minutes; off by default — the smoke prints `[OFF] AC6.3 idle 10 min (run smoke --long)` otherwise).
- `check_ac6_4` — `printf 'ping\n' | nc -w 5 "$H" 47803` → `ping`; `nc -w 5 "$H" 47804 </dev/null | head -1` → `SSH-2.0-cxsmoke`.
- `check_ac6_5` — nothing on 47805: `start=$(date +%s); curl -sS --max-time 10 "http://${H}:47805/"` fails and the elapsed time is ≤ 3 s; then start `python3 -m http.server 47805 --bind 0.0.0.0` in the shell, wait for `ss`, and the same `curl` succeeds on the first try.
- `check_ac6_6` — `X ss -ltn | grep -q ':3100 '` (shell does listen); `nc -z -w 3 "$H" 3100` fails; `nc -z -w 3 "$H" 80` fails.
- `check_ac6_7` — `curl -sS --max-time 5 "http://${H}:47806/"` fails.
- `check_ac6_10_e2e` — `ip=$(tailscale status --json | jq -r '.Peer[]|select(.HostName=="cxagents")|.TailscaleIPs[0]')`; `curl -sk --max-time 10 "https://${ip}:47801/"` fails with a TLS handshake error (curl exit 35) — no SNI, clean failure.
- `check_ac7_1` — `out=$(X curl -fsS http://cxagents-forwarder:8080/status)` contains `target: connectome-shell`, `node:   https://${H}:<port>`, `range:  1024-65535`, `deny: 3100`, a line matching `^  47801  http=yes   https://${H}:47801$`, and `^  47803  http=no    \(raw TCP\)  ${H}:47803$`; `X curl -fsS 'http://cxagents-forwarder:8080/status?format=json&ports=47801,47803' | jq -e '.target=="connectome-shell" and (.listening|map(.port)|sort)==[47801,47803]'`.
- `check_ac7_3` — `X ss -ltn` shows `127.0.0.1:47806`; the status text has no `47806` line.
- `check_ac7_4` — a raw request from a throwaway container on the `cxagents` network (busybox `wget` hides non-2xx bodies, so use `nc`): `D run --rm --network cxagents alpine:3.20 sh -c 'printf "GET /status HTTP/1.0\r\nHost: x\r\n\r\n" | nc -w 5 cxagents-forwarder 8080'` — the response's status line contains `404` and the body contains `not a cxagents target`; `curl -sS --max-time 5 "http://${H}:8080/status"` from the Mac does not return a status document (connection fails: nothing listens on shell:8080).
- `check_ac9_5` — WebUI over `https://cxmini.${TAILNET_DNS_SUFFIX}:8768/`, basic auth from a temp `--netrc-file` built from `WEBUI_USER`/`WEBUI_PASS` in `stacks/connectome/.env` (read with `sed -n 's/^WEBUI_USER=//p'` into variables, never echoed; netrc file mode 600 in the temp dir): `-H 'Sec-Fetch-Site: same-site'` → HTTP 403; `-H 'Sec-Fetch-Site: cross-site'` → 403; `-H "Origin: https://${H}:47801"` → 403; `-H 'Sec-Fetch-Site: same-origin' -H "Origin: https://cxmini.${TAILNET_DNS_SUFFIX}:8768"` → 200; no extra headers → 200. (Use `-o /dev/null -w '%{http_code}'`.)
- `check_ac5_6_downup` (updated) — now that `connectome-shell` holds the `cxagents` network: `just connectome down` first (cleanup registers `just connectome up`), then `just cxagents down && just cxagents up`, then `just connectome up`; same node ID, `check` rc 0.

Run list order: the Phase 5 checks first except `check_ac5_6_downup`, then the e2e checks, then `check_ac5_6_downup` last (it restarts connectome).

**Step 1:** Implement. **Step 2: Verify (tell the user: the smoke restarts connectome once at the end):**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J stacks cxagents smoke
```
Expected: every check `[OK]` (`[OFF]` for the 10-minute idle unless `--long`), exit 0.

**Step 3: AC6.3 long idle and the browser check (operator):** run `stacks/cxagents/scripts/smoke.sh --long` once (≈11 minutes). Ask the user to open `https://cxagents.faun-fir.ts.net:47801/` in a browser on cxmacbook while a smoke server is up (start one by hand: `just -f $wt/justfile stacks connectome shell`, then `python3 -m http.server 47801`) and confirm there is no certificate warning (AC6.1 "browser shows no warning").

**Step 4: Commit**
```bash
git add stacks/cxagents/scripts/smoke.sh
git commit -m "stacks/cxagents: end-to-end smoke (https/http/wss/raw, deny ports, loopback, status, WebUI guard)"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_7 -->
### Task 7: Overlay absent path, and connectome's own suites

**Verifies:** cxagents-node.AC9.1 (without network), AC9.3.

**Files:** none (system state).

**Step 1: Without the network (operator-gated: the agent is down for ~1 minute)**
```bash
cd "$wt"; J="just -f $wt/justfile"
$J stacks connectome down
$J stacks cxagents down                     # removes network cxagents
docker --context colima-agents network inspect cxagents >/dev/null 2>&1 && echo "FAIL: network still exists" || echo "OK: network gone"
$J stacks connectome up 2>&1 | tee /tmp/claude-cx-up.log
grep -q 'network cxagents missing' /tmp/claude-cx-up.log && echo "OK: warning printed"
docker --context colima-agents inspect connectome-shell -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```
Expected: `OK: network gone`; `OK: warning printed`; shell networks `connectome_connectome onecli-agents` (no `cxagents`); connectome is up.

**Step 2: Restore**
```bash
$J stacks connectome down && $J stacks cxagents up && $J stacks connectome up
docker --context colima-agents inspect connectome-shell -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
rm -f /tmp/claude-cx-up.log
```
Expected: shell is on `cxagents` again.

**Step 3: connectome suites (AC9.3)**
```bash
$J stacks connectome lint && $J stacks connectome lint-test && $J stacks connectome smoke
```
Expected: all pass (smoke restarts containers and restores state, as before).

**Commit:** none (no repo change).
<!-- END_TASK_7 -->

---

**Phase 6 done when:** `stacks cxagents smoke` passes every end-to-end check (and `--long` once); the browser shows no certificate warning; connectome `up` joins `cxagents` when the network exists and warns and starts without it otherwise; the WebUI returns 403 for same-site/cross-site/foreign-Origin requests and works same-origin; connectome's `lint`, `lint-test`, `image-test` and `smoke` pass; `$wt/stacks/scripts/doctor.sh` shows no new FAIL.
