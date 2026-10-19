# Human Test Plan: cxagents node

Implementation plan: `docs/implementation-plans/2026-10-17-cxagents-node/`. Automated coverage validated
2026-10-18: 59 automated/mixed acceptance criteria covered, 0 missing. Items marked *already verified*
were confirmed by the operator during execution.

## Prerequisites

- SSH session on cxmini. Before the merge: `wt=/Users/cxreiff/Developer/dotfiles/.worktrees/cxagents-node`,
  `J="just -f $wt/justfile"` (after the merge use `dotfiles` from `main`).
- All three VMs up; `$J stacks cxagents up && $J stacks connectome up` run from the worktree (re-run both
  after any pre-merge reboot).
- These must pass first: `stacks/cxagents/scripts/go.sh test -count=1 ./...`, `$J tailscale lint-test`,
  `$J stacks cxagents lint-test`, `$J stacks connectome lint-test`, `tailscale/scripts/keyscan.sh --repo`
  (rc 0), `$J tailscale smoke`, `$J stacks cxagents smoke`, `$J tailscale doctor-test`,
  `$J stacks cxagents doctor-test`, `$J stacks cxagents login-test`, `$J stacks cxagents image-test`,
  `./stacks/scripts/doctor.sh` (no `[FAIL]`).

## Phase 1/3: Tailnet policy and member connectivity (AC5.1, AC1.3)

*Already verified:* connectivity after both policy pushes.

| Step | Action | Expected |
|---|---|---|
| 1 | `$J tailscale policy-status` | `in-sync` |
| 2 | On cxmacbook open `https://cxmini.faun-fir.ts.net:8765` | FreshRSS loads, no certificate warning |
| 3 | On cxphone (Tailscale on) open `:8765` and `:8768` on `cxmini.faun-fir.ts.net` | FreshRSS loads; connectome WebUI prompts for basic auth and loads after sign-in |
| 4 | From cxmacbook: `ssh cxmini true; echo $?` | `0` |
| 5 | From cxmacbook mount a cxmini Taildrive share | Mounts and lists files |
| 6 | On cxmini: `/opt/homebrew/bin/tailscale ping -c 1 cxmacbook` | `pong` (an offline device is noted, not a failure) |

## Phase 2: adguard on the OAuth client (AC3.1 off path, AC3.2)

| Step | Action | Expected |
|---|---|---|
| 1 | `$J stacks adguard tailnet-dns-status \| jq -c .dns` | `["100.70.208.32"]` |
| 2 | `TAILSCALE_ENV_FILE=/nonexistent $wt/stacks/adguard/scripts/tailnet-dns.sh on; echo rc=$?` | stderr contains `restore tailscale/.env`, `rc=2`; step 1 output unchanged |
| 3 | Operator-gated (tailnet DNS briefly unfiltered): `$J stacks adguard tailnet-dns-off`, then `tailnet-dns-status` | `["1.1.1.1"]` |
| 4 | `$J stacks adguard tailnet-dns-on`, then `tailnet-dns-status` | `["100.70.208.32"]`; cxphone still resolves `cxmini.faun-fir.ts.net` |

## Phase 5: Node identity (AC5.4, AC5.5, AC5.6)

*Already verified:* identity across an agents-VM restart.

| Step | Action | Expected |
|---|---|---|
| 1 | Open https://login.tailscale.com/admin/machines | Exactly one `cxagents` machine, tag `tag:cxagents`, key expiry disabled; no `cxagents-1` |
| 2 | Run `$J stacks cxagents login-test`; open the case-3 admin URL in a browser | URL starts `https://login.tailscale.com/admin/machines/` and opens the right device page |
| 3 | `docker --context colima-agents inspect cxagents-forwarder \| grep -c tskey-` | `0` |
| 4 | Optional, disruptive: note `id:` from `docker --context colima-agents exec cxagents-forwarder /tailnet-forwarder check`; `vm-agents-down && vm-agents-up`, `onecli up`, `cxagents up`, `connectome up`; `check` again | Same `id:`, `node: cxagents`, `tags: tag:cxagents`, `online: yes`, no `problem:` lines |

## Phase 6: Agent server end to end (AC6.1, AC6.3, AC9.1, AC9.5)

*Already verified:* AC6.1 browser on cxmacbook, AC6.3 `smoke --long`, AC9.1 overlay-absent path.

| Step | Action | Expected |
|---|---|---|
| 1 | `$J stacks connectome shell`, inside: `python3 -m http.server 47801 --bind 0.0.0.0` | Listening |
| 2 | On cxmacbook open `https://cxagents.faun-fir.ts.net:47801/` | Directory listing, padlock, no warning; certificate for `cxagents.faun-fir.ts.net` |
| 3 | Same URL on cxphone | Loads, no warning |
| 4 | `http://cxagents.faun-fir.ts.net:47801/` | Same listing over plain HTTP |
| 5 | On cxmacbook `http://cxagents.faun-fir.ts.net:3100/` | Times out (policy-blocked) |
| 6 | In the shell: `curl -s http://cxagents-forwarder:8080/status` | `target: connectome-shell`, `range:  1024-65535   deny: 3100`, a `47801  http=yes` line |
| 7 | Stop the server (Ctrl-C), reload step 2 | Fails quickly (reset), no long hang; restart the server and a reload works at once |
| 8 | `$J stacks cxagents smoke --long` (~11 min) | `[OK] cxagents-node.AC6.3 idle 10 min…`, no FAIL |
| 9 | Operator-gated: `$J stacks connectome down && $J stacks cxagents down && $J stacks connectome up` | stderr `connectome: network cxagents missing — starting without agent previews…`; shell networks lack `cxagents` |
| 10 | Restore: `$J stacks connectome down && $J stacks cxagents up && $J stacks connectome up` | No warning; shell back on `cxagents`; `connectome` container not on it |
| 11 | On cxmacbook use the WebUI at `https://cxmini.faun-fir.ts.net:8768` normally | Works, no 403 |
| 12 | Serve a page from the shell on 47801 that runs `fetch('https://cxmini.faun-fir.ts.net:8768/', {credentials:'include'})`; open it on cxmacbook, check DevTools → Network | The request gets 403 (`Sec-Fetch-Site: same-site`) |

## Phase 7: Stack ordering and doctor (AC9.4, AC4.5)

*Already verified:* AC9.4 live down-all/up-all order.

| Step | Action | Expected |
|---|---|---|
| 1 | Operator-gated (restarts every stack incl. DNS failover): `$J stacks down-all && $J stacks up-all 2>&1 \| grep '^=== '` | `=== onecli up ===`, `=== cxagents up ===`, `=== connectome up ===` in that order; `up-all: all stacks up` |
| 2 | Optional: `docker --context colima-agents stop cxagents-forwarder; ./stacks/scripts/doctor.sh \| sed -n '/--- cxagents ---/,$p'` | `[FAIL] cxagents: cxagents-forwarder is exited …`; then `$J stacks cxagents up` and doctor is clean |
| 3 | `./stacks/scripts/doctor.sh; echo rc=$?` | `--- Tailnet ---` and `--- cxagents ---` present, no `[FAIL]`, `rc=0` (from `main` before the PAT cutover a `TAILSCALE_PAT` WARN is expected) |

## End-to-end: fresh agent server from a prompt

1. In the connectome WebUI ask the agent: "Start a Vite dev server for a hello-world page and give me the URL."
2. The agent binds `0.0.0.0` on a port in 1024–65535 other than 3100, self-tests with
   `curl http://cxagents-forwarder:8080/status`, and replies with `https://cxagents.faun-fir.ts.net:<port>`.
3. Open it on cxmacbook: loads with no warning; live reload works after the agent edits the page (wss
   through the forwarder). If Vite blocks the host, the agent applies the `allowedHosts` fix from its prompt.

## End-to-end: post-merge cutover (AC3.1 live half, AC4.7, AC10.4)

1. Merge `cxagents-node` into `main`; from `main`: `dotfiles stacks cxagents up`, then `dotfiles stacks connectome up`.
2. `tailscale/README.md` "PAT revocation": `tailnet-dns-status` works; remove the PAT line from the live
   `stacks/adguard/.env` and its escrow copy; `tailnet-dns-status` still works; revoke the token in the admin console.
3. `dotfiles stacks doctor`: no `[FAIL]`, no `TAILSCALE_PAT` WARN.
4. Password manager: exact-host URI matching on every saved `*.faun-fir.ts.net` login (FreshRSS, Wallabag,
   Homebridge, AdGuard, connectome WebUI).
5. `git worktree remove .worktrees/cxagents-node`.

## Human verification required

| Criterion | Why manual | Steps |
|---|---|---|
| AC1.8 confirmed `--init` | Only on a genuinely new tailnet | `docs/migration-recovery.md` "New tailnet": `policy-push --init`, review the diff, `y`; `policy-status` → `in-sync` |
| AC3.1 off path, live PAT removal | Changes live DNS; post-merge | Phase 2 steps 3–4; post-merge step 2 |
| AC5.1 | Real client devices | Phase 1/3 steps 2–6 (already done) |
| AC5.5 URL text | Browser check of the console URL pattern | Phase 5 step 2 |
| AC5.6 VM restart | Disruptive | Phase 5 step 4 (already done) |
| AC6.1 browser certificate | Browser trust UI | Phase 6 steps 2–3 (cxmacbook already done) |
| AC6.3 10-min idle | ~11 minutes | Phase 6 step 8 (already done) |
| AC9.1 overlay absent | Takes the agent down | Phase 6 steps 9–10 (already done) |
| AC9.4 live order | Restarts every stack | Phase 7 step 1 (already done) |
| AC10.1 | Fresh-device rebuild not possible now | Read `docs/migration-recovery.md` "Tailnet and cxagents on a fresh device": restore `tailscale/.env` → `policy-status` → stale `cxmini` + name check → node-IP follow-ups → `cxagents build`/`image-test` → `login` (stale-device URL, delete, re-run) → `up` → onecli/connectome → doctor. Also the clean-slate insert and "New tailnet". Deferred: perform a real rebuild and reach doctor with no FAILs |
| AC10.2 | Docs review | `tailscale/README.md`: bootstrap paths (`policy-pull` adoption; `--init` new tailnet), client order (admin → push declaring `tag:cxagents` → authkeys), minting auth keys, settings checklist with the doctor check for each item, PAT revocation |
| AC10.3 | Docs review | CLAUDE.md: four areas incl. `tailscale/`, alias line, `mod tailscale`, new reproducible-vs-runtime rows, `tailscale`/`cxagents` command lines, up-all/down-all order, 10-section doctor, OAuth DNS-failover text, agents row with cxagents, node-IP bullet incl. `hosts.cxmini` + `policy-push`, "When editing" bullets |
| AC10.4 | Docs review + operator setting | `stacks/cxagents/README.md` "Accepted exposures" and "Operator step: password manager"; `stacks/connectome/README.md` "Known exposures (accepted)"; operator sets host matching (post-merge step 4) |

## Traceability

| Acceptance criterion | Automated test | Manual step |
|---|---|---|
| AC1.1, AC1.2, AC1.4, AC1.6 | tailscale smoke `check_ac1_1/1_2/1_4/1_6` | — |
| AC1.3 | smoke `check_ac1_3`; doctor policy check | Phase 1/3 step 1 |
| AC1.5 | smoke `check_ac1_5_*`; tailscale lint-test | — |
| AC1.7 | smoke `check_ac1_5_validate`, `check_ac1_7_cxagents` | — |
| AC1.8 | smoke `check_ac1_8_refuse/_init` | New tailnet `--init` (deferred) |
| AC2.1–AC2.5 | smoke `check_ac2_*`; keyscan, keyscan-test | — |
| AC2.6 | tailscale doctor-test scope/tags fixtures | — |
| AC3.1 | tailnet-dns-test; git grep; keyscan | Phase 2 steps 3–4; post-merge step 2 |
| AC3.2 | tailnet-dns.sh `api_fail` path (operational) | Phase 2 step 2 |
| AC3.3 | git grep; keyscan; doctor keyscan check | — |
| AC4.1–AC4.3, AC4.6, AC4.7 | tailscale doctor-test | Phase 7 step 3; post-merge step 3 |
| AC4.4, AC4.5 | cxagents doctor-test; check_test.go | Phase 7 step 2 (optional) |
| AC5.1 | policy `tests` on every validate | Phase 1/3 steps 2–6 |
| AC5.2 | smoke `check_ac5_2` | — |
| AC5.3 | cxagents smoke `check_ac5_3`; smoke-test.sh | — |
| AC5.4 | main_test login tests; cxagents lint inv4 | Phase 5 steps 1, 3 |
| AC5.5 | login-test.sh; statefile_test.go | Phase 5 step 2 |
| AC5.6 | smoke `check_ac5_6_restart/_downup` | Phase 5 step 4 |
| AC5.7 | login-test 6c/6d; image-test 6; main_test | — |
| AC6.1 | smoke `check_ac6_1` | Phase 6 steps 2–3 |
| AC6.2 | smoke `check_ac6_2` | Phase 6 step 4 |
| AC6.3 | smoke `check_ac6_3`; handler_test | Phase 6 step 8 |
| AC6.4, AC6.7, AC6.10 | handler_test; smoke `check_ac6_4/6_7/6_10_e2e` | — |
| AC6.5 | handler_test; decide_test; smoke `check_ac6_5` | Phase 6 step 7 |
| AC6.6 | smoke `check_ac6_6`; routes/decide tests; lint inv2/inv6 | Phase 6 step 5 |
| AC6.8 | routes_test; main_test; image-test 5; lint inv6 | — |
| AC6.9, AC6.11, AC6.12 | handler_test; decide_test; caps_test; netcheck/resolve tests | — |
| AC7.1, AC7.3, AC7.4 | smoke `check_ac7_*`; status_test | Phase 6 step 6 |
| AC7.2, AC7.5, AC7.6 | status_test.go | — |
| AC8.1 | smoke `check_ac8_1` | — |
| AC8.2, AC8.3 | cxagents lint-test; image-test 1, 2, 4 | — |
| AC8.4 | build.sh preconditions; image-test 3 | — |
| AC9.1 | compose.sh; cxagents doctor check 6 | Phase 6 steps 9–10 |
| AC9.2 | prompt phrase grep | End-to-end: fresh agent server |
| AC9.3 | connectome lint/lint-test/image-test/smoke | — |
| AC9.4 | `just --show up-all/down-all` | Phase 7 step 1 |
| AC9.5 | connectome-host `73316f5` bun tests; smoke `check_ac9_5` | Phase 6 steps 11–12 |
| AC10.1 | keyscan; recipe existence; doctor rc 0 | Docs review; fresh-device rebuild (deferred) |
| AC10.2, AC10.3 | keyscan; `just --list` | Docs review |
| AC10.4 | keyscan | Docs review; post-merge step 4 |
