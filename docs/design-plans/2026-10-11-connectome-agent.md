# Connectome Agent Design

**Status:** Approved by the user 2026-10-11 (revision 5, after adversarial
review rounds 1–3 and the spike). [Decisions](#decisions-made-by-the-user)
are the user's; [Proposed design](#proposed-design) is the approved plan.

## Summary

Replace nanoclaw (native Node host process + per-agent containers in the
`agents` Colima VM, credentials brokered by onecli v1) with Anima Labs'
[connectome-host](https://github.com/anima-research/connectome-host), run as a
two-container stack (`connectome` host + `shell`) in the `agents` VM, with
credentials brokered by a **fresh onecli v2 vault** so no model login or API key
lives in either container.

## Decisions made by the user

1. **Replace nanoclaw with Connectome.** Follow Connectome's idiomatic
   deployment where it doesn't conflict with decision 2; don't copy nanoclaw's
   topology.
2. **Credential protection via onecli.** The goal is to keep credentials out
   of the agent's reach. It is **not** to restrict internet access. Agents need
   open internet.
3. **Discord is the chat surface.** Telegram (only a user-account MCPL exists)
   and Signal (needs an Android device to register a numberless account) were
   considered and rejected.
4. **Model: ChatGPT-subscription quota first,** via the typical/supported path,
   with an easy seam for swapping provider/model later. **Claude:** API key
   only (pay-per-token, through onecli). Subscription OAuth for Claude in a
   third-party harness is prohibited by Anthropic's terms (see
   [findings](#models-and-terms)) and must not be used.
5. **onecli: latest release (v2.x), fresh vault, no tech debt kept.** The v1
   vault is archived as a tarball, not migrated.
6. **Vault key:** `SECRET_ENCRYPTION_KEY` lives in `stacks/onecli/.env`
   (0600, gitignored — upstream default and this repo's convention for every
   secret), with an escrow copy in the user's password manager. Volume
   tarballs then hold ciphertext only.
7. **Shell isolation:** the agent's shell runs in a **separate container**,
   not a uid split inside the host container.
8. **Scope:** one agent first. The design must leave clean seams for
   persistent fleet children (personas) to be added soon.
9. **nanoclaw:** not running anything important; pause it now, decommission
   before the onecli v2 cutover.
10. **Process:** an approved, adversarially reviewed design comes before any
    implementation.
11. **Discord connector:** `anima-research/discord-mcpl` `main` at a pinned
    SHA (plus `voice-kit`), not npm 0.1.4.
12. **Heartbeat at launch:** include `heartbeat-mcpl`.
13. **No shared workspace volume** between `connectome` and `shell`; the agent
    does all workspace file I/O through its shell.
14. **Agents may use the home network and tailnet** (LAN services, tailnet
    hosts) — intended, not just tolerated. Locking this down is future work,
    out of scope here (see [Known exposures](#known-exposures-accepted)).
15. **Quota meter:** the host identity may read
    `chatgpt.com/backend-api/wham/usage` (path confirmed in the spike).
16. **WebUI port:** `serve_port` 8768 / `internal_port` 18768.
17. **Shell base image:** reputable, tooling-rich, arm64-native —
    `mcr.microsoft.com/devcontainers/typescript-node:22-bookworm` plus Rust
    and the tools coding agents assume (see Phase 2). No sudo.
18. **Rate-limit numbers** are set after measuring real turns (spike: 1 request per simple turn; tool-using turns measured at Phase 2 bring-up)
    (~2–3× expected peak), plus a ChatGPT per-app weekly cap.
19. **Heartbeat interval:** 4 h initially.
20. **Reminders kept, with layered caps:** local patch raising the reminder
    floor to 15 min, a wake `rate_limit` on the heartbeat source, the onecli
    rate limit as the hard ceiling, the ChatGPT per-app cap as backstop.
21. **discord-mcpl attachment read is patched locally** (revised
    2026-10-11, superseding "accept for now"): attachments are confined to an
    outbox directory; also proposed upstream.
22. **Source of truth: local clones** of connectome-host and its MCPL
    servers on cxmini, built at recorded SHAs; local patches are local
    commits. No public forks (no dedicated agent GitHub account yet).

## Verified findings

Checked against source on 2026-10-11: connectome-host @ `56b5776`, onecli @
`5ce7970` (2.12.0), npm tarballs of membrane 0.5.86, agent-framework 0.21.0,
discord-mcpl 0.1.4, term-sessions-mcp 1.6.0, chronicle 0.4.0. Paths below are
relative to those repos.

### Connectome runtime

- TypeScript on Bun. One process runs one agent, defined by a JSON recipe.
  Idiomatic deployment is `bun src/index.ts <recipe> --headless` under
  systemd/launchd, one OS user per agent (`docs/DEPLOYMENTS.md`). No upstream
  Dockerfile; the sibling project `anima-research/connectome-cook` generates
  one and is the reference for image layout. Pre-1.0 and changes daily: pin a
  commit.
- **Licensing:** connectome-host and discord-mcpl have no license (all rights
  reserved by default); membrane, agent-framework, chronicle, context-manager,
  mcpl-core, term-sessions-mcp, voice-kit are MIT; heartbeat-mcpl has no license field. Fine for private use; **never push the
  built image to a public registry.**
- **Image needs real Node as well as Bun.** In `oven/bun:*-debian`, `node` is a
  symlink to Bun. MCPL servers are run under Node upstream
  (`DEV-ENVIRONMENT.md:102-103`); `node-pty` (term-sessions) has no linux
  prebuilds and needs `build-essential` + `python3`; term-sessions pulls
  puppeteer (set `PUPPETEER_SKIP_DOWNLOAD=1`); the WebUI is built by
  `postinstall` and silently skipped without npm. connectome-cook copies
  `node:*-bookworm` into the runtime for exactly this reason.
- **Native deps:** chronicle ships `linux-arm64-gnu` (glibc ≥ 2.34; bookworm
  is 2.36). OpenTUI and sharp have linux-arm64 glibc builds.
- **State is not all under `DATA_DIR`.** `DATA_DIR` holds session chronicle
  stores, memory, `.recipe.json` (unresolved `${VAR}`s, 0600),
  `llm-calls.<iso>.jsonl` (full prompts, one new file per start, never
  rotated), and `identity-key.pem` only if `modules.identity` is on. The
  **CWD** holds `mcpl-servers*.json`, `logs/failures.log`, default fleet child
  `dataDir`s (`./data/<name>`) and default workspace mounts (`./input`,
  `./output`).
- **Providers:** `anthropic`, `openai-codex`, `openai-responses`, `openrouter`,
  `bedrock`, `openai-compatible`, `mock`. Recipes substitute `${VAR:-default}`
  across the whole tree before validation, so provider and model can come from
  env. In subscription mode the model id must start `gpt-` or contain `codex`.
- **Model swaps:** feeding one model's chronicle to another is a continuity
  violation (`DEPLOYMENTS.md:19-23`); encrypted reasoning items are
  model-bound. `contextBudgetTokens` must fit under (window − max output) or
  every reply silently 400s (`AGENT-ONBOARDING.md` §11.1). **A model swap
  means a new session/`DATA_DIR`, not an env flip on a live chronicle.**
- **Wake/gate policies** (`always`, `defer`, `debounce`, `rate_limit`,
  `passive_sample`) decide which events cost inference, but the agent can
  change them itself (`wake_add_rule`/`wake_remove_rule` tools; live copy in
  `$DATA_DIR/sessions/<id>/config/gate.json`, append-only reconcile). They are a
  soft lever, not a ceiling.
- **MCP child env is allowlisted** (agent-framework `src/mcpl/transport.ts:116-148`).
  Proxy and CA vars pass through; anything else (including `DISCORD_*` and
  `NODE_USE_ENV_PROXY`) reaches a server only if the recipe maps it.
- **Code-running features that execute as the host process's user:**
  `codeExecution` (python subprocess), `modules.mcplAdmin` ("spawn arbitrary
  commands as the host user"), `extensions` (code loaded into the host),
  `modules.fleet` in its bare `true` form ("the agent may launch any recipe";
  launch paths resolve against CWD), and any recipe the agent can write (its
  `mcpServers[].command` runs as host; `${VAR}` in its prompt pulls host env
  into a readable context).
- **WebUI:** `modules.webui`, default `0.0.0.0:7340`. Refuses a non-loopback
  bind without `basicAuth`; checks basic auth on every request, including
  loopback. WS `Origin` must be loopback or equal the `Host` header, otherwise
  set `allowedOrigins`. Enabling it also enables `ObserversModule`, which gives
  the agent grant/revoke tools over `observers.json` (path overridable via
  `OBSERVERS_FILE`, default `DATA_DIR/observers.json`, hot-reloaded);
  granted observers bypass basic auth.
- **CWD-relative config is loaded unconditionally:** `mcpl-servers.json` and
  the agent-owned overlay `mcpl-servers.agent.json` ("loads unconditionally —
  no recipe opt-in needed") resolve from `process.cwd()`
  (`src/mcpl-config.ts:14,181-186`). A writable CWD is a host code-execution
  path.
- **agent-framework file tools follow symlinks** on write/sync
  (`materializeToFs`, `autoMaterialize`, `syncFromFs`; the `safePath` guard is
  lexical only). Any directory that both an untrusted party and connectome's
  workspace mounts can write is a write-anywhere-as-host primitive.
- **Approvals:** connectome has none for tool calls. `enabledTools`/`disabledTools`
  exist only **per MCPL server**; module tools (workspace, wake, observers,
  channel-mode) cannot be filtered. The only human-approval point in this
  design is onecli policy on credentialed requests.
- **Scheduling:** `@animalabs/heartbeat-mcpl@0.1.3` gives an
  agent-configurable heartbeat interval (≥ 60 s, default 4 h) plus any number
  of one-shot (`atIso`/delay) and recurring (≥ 5 s) reminders, persisted
  across restarts; every fire is an inference. Interval comes from
  `HEARTBEAT_CONFIG_FILE` (default `./heartbeat-config.json`), reminders from
  `HEARTBEAT_REMINDERS_FILE`; write failures are only logged. Ticks need a
  wake policy matching `source: "heartbeat"` placed before any skip rule.
- **`--headless` redirects stdout/stderr to `$DATA_DIR/headless.log`**
  (never rotated); `docker logs` is empty. `logs/failures.log` is hard-coded
  CWD-relative (`framework.ts:12485-12492`), write errors swallowed.

### Fleet (for the persona seam)

- `modules.fleet` gives persistent child agents: headless subprocesses, each
  with its own recipe, `dataDir`, optional autoStart/autoRestart.
- At ≥ `406dcc1` (2026-10-08), `children[].env` is **runtime-only** (never
  persisted) and survives `fleet--restart` (`docs/fleet-protocol.md` §4.2,
  §4.5). The agent cannot pass `env` through `fleet--launch`.
- Children are spawned with `{...process.env, ...env}`: they inherit the
  parent's **entire** env (`fleet-module.ts:1269-1281`).
- Re-adoption of children only works across a host restart, not a container
  restart. A launch refuses to clear a child's leftover `ipc.sock`/`headless.pid`
  unless the old PID is "confirmed gone" (§4.3); in a fresh PID namespace small
  PIDs get reused, so stale files can wedge autoStart.

### Discord connector

- Upstream runs `anima-research/discord-mcpl` from `main`, which is 100+
  commits (including DM-refusal fixes) ahead of npm `@animalabs/discord-mcpl@0.1.4`
  (2026-07-14). `main` depends on a sibling `voice-kit` checkout
  (`file:../voice-kit`). `antra-tess/discord-mcpl` is the stale fork.
- **Filters default to allow-all:** `DISCORD_GUILD_ID` unset → all guilds;
  `DISCORD_DM_USERS` unset/empty → DMs from anyone (`src/filters.ts:13-15`).
  `DISCORD_FILTERS_FILE` lets the agent's `filters_update` tool rewrite its
  own allowlist; even without it, `filters_update` can enable auto-replies to
  refused DMs (`setDmNotice`).
- **Attachments read any host file:** `send_message`/`reply_message`/`send_dm`
  take `files[].path` and only check `existsSync && isFile`
  (`src/discord-adapter.ts:79-87`) — including `/proc/<pid>/environ`, which
  `fetch_history` can then read back inline. See
  the [attachment patch](#phase-2--stacksconnectome) (decision 21).
- State files: `DISCORD_WATERMARK_FILE` (without it, offline catch-up is
  off), `DISCORD_DM_NOTICES_FILE` (default `$HOME/.local/state`),
  `DISCORD_MUTED_CHANNELS_FILE`. Voice loads only with
  `DISCORD_VOICE_CHANNEL_ID`; native deps (sharp, davey) have arm64 prebuilds.
- Under Bun, discord.js uses global `fetch`/`WebSocket` (honors
  `HTTPS_PROXY`); under Node it uses undici `request` and `ws` (does not).
  Either way the bot token is in the connector's env, so routing Discord via
  onecli buys nothing.

### Models and terms

- **ChatGPT subscription in third-party tools is explicitly supported by
  OpenAI** ("Sign in with ChatGPT"; plan usage counts against the user's
  limits, per-app weekly caps available).
- **Claude subscription in third-party tools is prohibited.** Claude Code's
  legal page: OAuth is "designed to support ordinary use of Claude Code and
  other native Anthropic applications"; developers "may not … route requests
  through Free, Pro, or Max plan credentials", enforced server-side since
  January 2026. connectome's `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_OAUTH_CREDENTIALS_FILE`
  path (Claude Code's OAuth client id, "You are Claude Code" system identity
  in `src/logging-adapter.ts:88`) is exactly that pattern. connectome has no
  `claude -p` provider. The compliant Claude-subscription route would be the
  unmodified Claude Code binary (e.g. `anima-research/mcpl-cc-bridge`, a Claude
  Code plugin hosting MCPL servers) — a different harness, out of scope here.
- **Codex auth in connectome:** `openai-codex` delegates auth to
  `codex app-server`, reading access token + account id from
  `$CODEX_HOME/auth.json` (`src/codex-subscription-adapter.ts:4-6,212`);
  inference itself goes from Bun `fetch` to
  `https://chatgpt.com/backend-api/codex/responses` with `Authorization: Bearer`,
  `ChatGPT-Account-Id`, `session_id`. "Gate mode" (`CODEX_GATE_TOKEN`) is for
  Anima's private gate (`gate.animalabs.ai`, not public/self-hostable); its
  code says "a gate token must never travel to the ChatGPT backend", and in
  gate mode no account-id header is sent and the WebUI quota meter is off.

### onecli v2

- Split services (`migrations`, `api`, `web`, `gateway`); API under `/v1`
  (`/api/*` aliased); healthchecks in every image; all four 2.12.0 images ship
  arm64; upstream itself uses `cap_drop: ALL` + `no-new-privileges`.
- Account login replaces v1's no-auth local mode. Registration is open with no
  switch: register immediately after first `up`. Dashboard access from the
  headless host is over `ssh -L 10254:… -L 10256:…`.
- `SECRET_ENCRYPTION_KEY`, `BETTER_AUTH_SECRET`, `GATEWAY_INTERNAL_SECRET` come
  from env. Gateway runs as uid 100:101 (alpine `adduser -S`); its CA is
  `app-data/gateway/ca.{pem,key}` (key 0600).
- **Proxy identity:** `HTTPS_PROXY=http://<lane>:<aoc_ token>@gateway:10255`.
  The token selects the agent identity. Lane `open` = raw tunnel; anything
  else = TLS MITM of **every** CONNECT. A CONNECT without a valid `aoc_`
  token gets 407 — there is no default identity in v2.
- **Injection:** in OAuth mode the `openai` secret is injected on
  `api.openai.com`, `chatgpt.com`, `*.chatgpt.com`, `*.openai.com`
  (`auth.openai.com` excluded): `Authorization: Bearer <access>` and
  `chatgpt-account-id`, **replacing** client-sent values case-insensitively
  (`inject/src/lib.rs:197-202`). The gateway refreshes and persists rotated
  tokens itself.
- **Injection is host-wide per secret.** A `Secret` allow rule naming the
  agent selects the secret, which is then injected on every host it covers;
  `Secret` targets have no path. Path scoping comes only from `Network` rules
  (`hostPattern` + prefix-glob `pathPattern` + `method`), evaluated
  first-match by priority.
- **Codex stub:** onecli serves a stub `auth.json` (`auth_mode: chatgpt`, a
  parseable id_token, `access_token`/`refresh_token`/`account_id` all
  `onecli-managed`) — onecli's supported flow for Codex clients
  (`packages/api/src/lib/codex-stubs.ts`). Fetching it
  (`GET /v1/credential-stubs/codex`) needs a **user** session/API key. When
  codex later refreshes (`POST auth.openai.com/oauth/token` with
  `refresh_token=onecli-managed`), the gateway answers a synthetic 200
  **before** policy evaluation and without any grant
  (`inject/src/default_interceptions.rs:52-110`), so a stub dropped once stays
  valid indefinitely.
- **Policy:** v2 injects only with an explicit allow rule naming the agent
  (empty identity never matches). Default-rule deny applies to credentialed
  non-LLM traffic only (`chatgpt.com` counts as an LLM host); **explicit block
  rules are unconditional**. Rules support rate limits and human approval.
  Budgets are inert in self-hosted OSS.
- **Private destinations are refused for proxied requests** (loopback,
  RFC1918, CGNAT 100.64/10 — i.e. Tailscale —, ULA, link-local) unless
  `GATEWAY_ALLOW_PRIVATE_DESTINATIONS` lists them. This does nothing for
  direct (non-proxied) connections.
- **The agent cannot reach the vault API.** In the `agents` VM, published
  ports bind VM-loopback only, `route_localnet=0`, no `host.docker.internal`
  by default; the gateway's own HTTP routes need a user session/API key, not
  an `aoc_` token.
- **A direct v1.21 → v2 jump drops all grants and policy** (the v1.43–1.45
  boot-time conversion was removed). Moot under decision 5 (fresh vault).

### Platform

- `agents` VM: `vz`, aarch64, virtiofs, Rosetta off, `binfmt: true` (an
  amd64-only image would silently run emulated — pin `platform: linux/arm64`).
  4 CPU / 6 GiB; host M4 16 GiB.
- virtiofs bind mounts don't enforce Linux ownership: per-uid isolation needs
  Docker named volumes in the VM (same precedent as onecli).

### Live state (2026-10-11 ~13:10)

- onecli **v1** running (`ghcr.io/onecli/onecli:latest`), volumes restored
  13:05 from the v1 backup. An earlier unapproved v2 upgrade was **rolled back
  by the user**; live state matches `main` again. No `onecli-agents` network,
  no v2 images.
- `stacks/onecli/.env` is mode **0644** (CLAUDE.md requires 0600).
- nanoclaw is live: `/Library/LaunchDaemons/com.nanoclaw-v2-0aae9b3d.plist`
  (KeepAlive, RunAtLoad), node PID up since 2026-09-13, image
  `nanoclaw-agent-v2-0aae9b3d` (~3 GB) in the `agents` VM.

## Proposed design

### Phase 0 — pause and decommission nanoclaw

1. Pause now (user-approved, needs the user's sudo):
   `sudo launchctl disable system/com.nanoclaw-v2-0aae9b3d && sudo launchctl bootout system/com.nanoclaw-v2-0aae9b3d`.
2. Before Phase 1: remove the plist, `docker --context colima-agents image rm nanoclaw-agent-v2-0aae9b3d`,
   archive `~/Developer/nanoclaw` state as the user sees fit. Its v1 grants and
   `aoc_` tokens die with the v1 vault.

### Phase 1 — onecli v2, fresh vault

1. Final v1 backup kept as an archive (`~/.volume-backups/archive/onecli-v1-final.tgz`,
   outside GFS rotation). Then `down`, remove `onecli_pgdata`/`onecli_app-data`.
2. `compose.yaml` per [Appendix A](#appendix-a-onecli-v2-compose), pinned
   `ONECLI_VERSION=2.12.0`.
3. `init-env` recipe: idempotently generates `SECRET_ENCRYPTION_KEY`,
   `BETTER_AUTH_SECRET`, `GATEWAY_INTERNAL_SECRET` into `.env` if absent,
   `chmod 600`, never prints values; prints a reminder to escrow the key in the
   password manager.
4. `up` = `compose up -d --wait`. Register the account immediately (over
   `ssh -L`). Mint an API key; host CLI upgraded and pointed at
   `http://127.0.0.1:10256`. `bootstrap` recipe rewritten for this flow (v1
   local-mode logic deleted).
5. Vault content: the `openai` secret in OAuth mode from a **dedicated**
   `codex login` uploaded to onecli, after which that login is not used
   elsewhere (refresh-token rotation would invalidate one side).
6. Agents and rules (see [onecli identities](#onecli-identities)).

### Phase 2 — `stacks/connectome`

Two containers, both `platform: linux/arm64`, in the `agents` VM
(`--context colima-agents`). They share no volume except the read-only-in-host `outbox` (decision 13, 21).

**Sources (decision 22).** Local clones under `~/Developer/connectome/`:
`connectome-host`, `discord-mcpl`, `voice-kit`, `heartbeat-mcpl` (plus
`term-sessions-mcp` from npm, pinned). Local patches are commits on a
`local` branch in each clone. The `build` recipe refuses dirty trees, builds
from the checked-out SHAs, and writes them to a tracked
`stacks/connectome/sources.lock` (SHAs only, no patch content). Known gap: a
fresh device can rebuild only from upstream SHAs; local patch commits must be
re-applied by hand (listed by subject in `sources.lock`). Initial local
patches:
- heartbeat-mcpl: reminder floor 5 s → 900 s.
- discord-mcpl: attachments only from `DISCORD_ATTACHMENT_ROOT`
  (`/agent/outbox`). The patch opens the path, verifies via the open fd
  (`fstat` regular file; `/proc/self/fd/N` link target inside the root) and
  uploads the **buffer read from that fd** — so symlinks out of the root,
  `/proc/*`, and check-then-swap races are refused. Unset root ⇒ all
  attachments refused.

**`connectome` (host)** — trusted.
- Multi-stage image: a `node:22-bookworm` stage builds voice-kit (tsc) then
  discord-mcpl, heartbeat-mcpl, the term-sessions-mcp frontend, and the
  WebUI (`build-essential`, `python3`, `PUPPETEER_SKIP_DOWNLOAD=1`); runtime
  is `oven/bun:1-debian` + copied real `node` + a pinned linux-arm64 Codex
  CLI. MCP entries invoke the absolute node path. connectome ≥ `406dcc1`.
- Runs as a non-root uid; `cap_drop: ALL`, `no-new-privileges`.
- Holds: `DISCORD_TOKEN`, WebUI basic-auth credentials (`WEBUI_PASS` long
  random, generated by `init-env`), the host's onecli `aoc_` token (all from
  `stacks/connectome/.env`, 0600), and the Codex stub (no real credential).
- **Filesystem layout:**
  - `/agent/cwd` — image-owned (root:root 0755, not writable by the uid);
    the **`WORKDIR`/CWD**. Contains only symlinks
    `mcpl-servers.json → /agent/recipes/mcpl-servers.json` and
    `logs → /agent/state/logs`. So `mcpl-servers.agent.json` can never be
    written, CWD config is tracked, and `logs/failures.log` persists.
  - `/agent/recipes` — repo bind mount, **read-only**: recipes,
    `mcpl-servers.json`, `observers.json` (`{"observers":[]}`), codex
    `config.toml` template.
  - `/agent/state` — named volume `state`, host-owned 0700:
    `DATA_DIR=/agent/state/data`, `CODEX_HOME=/agent/state/codex`,
    `logs/`, `heartbeat/`, `discord/`, explicit absolute child `dataDir`s.
  - `modules.workspace: false` — no in-process file tools (all file work goes
    through the shell; decision 13).
  - Smoke test asserts positives, since failed writes are swallowed: after a
    forced inference failure, `/agent/state/logs/failures.log` exists; after
    `heartbeat_configure`, `/agent/state/heartbeat/config.json` changed.
- **Model:** `openai-codex` provider, `LLM_MODEL` from `.env`. The Codex
  app-server reads the onecli stub; inference goes through the gateway, which
  swaps in the real bearer and account id. **No fallback path:** gate mode
  needs Anima's private gate.
- **Codex provisioning (operator, host-side, once — `provision-codex`
  recipe):** fetch `/v1/credential-stubs/codex` from `127.0.0.1:10256` with
  the operator's API key on the Mac; set `tokens.account_id` to the **real**
  ChatGPT account id (an identifier, not a credential — Codex ≥ 0.162 runs
  "workspace routing discovery" and refuses a stub whose account id isn't in
  `wham/accounts/check`; spike-verified); write it as `codex/auth.json` (host uid,
  0600) into the `state` volume via a throwaway container, together with
  `codex/config.toml` from the tracked template: `[features] apps = false,
  plugins = false`; `[analytics] enabled = false`; `[otel] metrics_exporter =
  "none"` (avoids startup calls to `/backend-api/ps/…` and
  `ab.chatgpt.com` that rule 6 would block). No user API key ever enters a
  container. Recovery is re-running the recipe; **never** use the WebUI "log
  in again" action (it runs `account/logout`, deletes the stub and starts a
  real device-code login — which rule 6 makes fail closed anyway).
- **Proxy and TLS:** `HTTPS_PROXY=http://x:${HOST_ONECLI_TOKEN}@gateway:10255`.
  The gateway CA is per-vault, so the `build` recipe copies it out
  (`docker exec onecli-gateway cat /app/data/gateway/ca.pem`) into the build
  context and runs `update-ca-certificates` at image build (both images); a
  fresh vault means a rebuild, and doctor compares the image CA fingerprint
  with the gateway's. Env: `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`
  (system bundle, so direct TLS still works), `NODE_EXTRA_CA_CERTS=<gateway
  ca>`, `CODEX_CA_CERTIFICATE=<system bundle>` (codex's own variable),
  `NO_PROXY=localhost,127.0.0.1,shell`.
- **Start-up tolerance:** dockerd restarts `unless-stopped` containers in no
  particular order at VM boot, so the entrypoint waits (bounded) for
  `gateway:10255`, and deletes stale `ipc.sock`/`headless.pid` under child
  `dataDir`s (no child survives a container restart).
- **WebUI:** recipe `modules.webui: {port: 18768, host: "0.0.0.0",
  basicAuth: {username: "${WEBUI_USER}", password: "${WEBUI_PASS}"},
  allowedOrigins: ["https://cxmini.faun-fir.ts.net:8768"]}` (belt-and-braces;
  the same-origin rule also accepts it if `tailscale serve` preserves `Host`),
  published `127.0.0.1:18768`; `serve` recipe publishes via Tailscale on 8768.
  `OBSERVERS_FILE=/agent/recipes/observers.json` (read-only): the agent still
  sees `observers--grant/revoke`, but every write fails with EROFS (module
  tools can't be filtered). Optionally `observersSurface: "utilities"` to
  hide the schemas.
- **Discord:** discord-mcpl with `DISCORD_TOKEN`, `DISCORD_GUILD_ID`
  (guild:channel whitelist), `DISCORD_DM_USERS` and `DISCORD_ADMIN_USERS` =
  operator's user id, `DISCORD_WATERMARK_FILE`, `DISCORD_DM_NOTICES_FILE`,
  `DISCORD_MUTED_CHANNELS_FILE` under `/agent/state/discord/`. **No
  `DISCORD_FILTERS_FILE`**; server entry `disabledTools: ["filters_update",
  "create_text_channel", "delete_channel"]`. Its own new bot application — not
  nanoclaw's.
- **Heartbeat:** heartbeat-mcpl (`--stdio`) with
  `HEARTBEAT_CONFIG_FILE=/agent/state/heartbeat/config.json` and
  `HEARTBEAT_REMINDERS_FILE=/agent/state/heartbeat/reminders.json`; the
  entrypoint seeds `config.json` with `{"intervalSeconds": 14400}` if absent
  (the recipe can't set it). `modules.wake.policies` starts with a
  `rate_limit` rule for `{scope: ["mcpl:push-event"], source: "heartbeat"}`
  (e.g. 6 tokens, refill 1 per 10 min) placed before any skip rule;
  `enabledFeatureSets` includes `heartbeat`. Reminders kept (decision 20).

**`shell`** — untrusted (the agent's hands).
- Image `FROM mcr.microsoft.com/devcontainers/typescript-node:22-bookworm`
  (Microsoft-maintained, arm64; Node/TS, git, zsh, common CLI utils) plus a
  pinned Rust toolchain (rustup), python3/pip/uv, ripgrep, fd, jq,
  build-essential, gh CLI. The image's passwordless sudo entry is removed.
  (`devcontainers/universal` rejected: amd64-only, would run emulated.)
- Runs the term-sessions daemon (`HEADLESS`, host `0.0.0.0`, port 3100,
  `SESSION_SERVER_TOKEN` via env, never argv); gateway CA in system trust;
  `SSL_CERT_FILE` (system bundle), `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`,
  `NODE_EXTRA_CA_CERTS`.
- Non-root, `cap_drop: ALL`, `no-new-privileges`.
- Holds only: the daemon token and its **own** onecli `aoc_` token in
  `HTTPS_PROXY`. No access to `state`. (Discord token / WebUI password are
  reachable indirectly — see Known exposures.)
- Volume `workspace` (named) at `/workspace`, mounted **only** here.
- Volume `outbox` (named) at `/workspace/outbox`, read-write: the agent
  stages files it wants to send on Discord here. It is the one volume also
  mounted in `connectome` (at `/agent/outbox`, `:ro`), and only the patched
  discord-mcpl reads it. Nothing in `connectome` writes it, so the
  symlink-write hazard behind decision 13 doesn't apply.
- The host's term-sessions **frontend** (stdio MCP server in `connectome`,
  no filesystem tools of its own) connects with `SESSION_SERVER_HOST=shell`.

**Networks**
- `onecli-agents` (owned by the onecli project, `external: true` here): both
  containers, for the gateway. Not `internal`, so it also provides direct
  egress (decision 2).
- `connectome` (project-private): host ↔ shell daemon.
- The connectome `up` recipe fails with a clear message if `onecli-agents`
  doesn't exist ("run `dotfiles stacks onecli up` first").

**Security invariants** (lint = static check of tracked recipes/compose and
`.env` **key names**, never values; run by `doctor`):
1. `codeExecution`, `modules.mcplAdmin`, `extensions` are off;
   `modules.workspace` is `false`. *(lint)*
2. `modules.fleet` is never `true`; only the object form with explicit
   `children` and `allowedRecipes` under `/agent/recipes`. *(lint)*
3. CWD (`/agent/cwd`) is not writable by the connectome uid; its only
   writable link is `logs/`. *(build test)*
4. No volume is mounted in both `connectome` and `shell`, except `outbox`,
   which is `:ro` in `connectome`. *(compose lint)*
5. No secret is passed as argv anywhere (`/proc/*/cmdline` is world-readable).
6. No onecli user API key in either container (no such key name in
   `stacks/connectome/.env`); `GATEWAY_ALLOW_PRIVATE_DESTINATIONS` never covers
   172.16/12; no `extra_hosts: host-gateway`. *(lint)*
7. `GATE_TELEMETRY` unset. *(lint)*
8. Discord filters set as above; no filters file; `disabledTools` as above.
   *(lint)*
9. `OBSERVERS_FILE` points at the read-only mount. *(lint)*
10. discord-mcpl attachment patch applied: the image smoke test asserts
    `send_message` with `files: [{path: "/proc/self/environ"}]` and with a
    symlink out of the outbox are both refused. *(build test)*

### onecli identities

In onecli 2.12, **policy rules are org-wide** (org rules refuse agent
identities; the per-workspace rules API returns 410), and **per-agent scoping
comes only from secret grants**. New LLM secrets **auto-attach to every
agent** (and new agents get every existing LLM secret), so grants must be
corrected explicitly after any secret or agent is created.

Org rules (apply to every agent; lower priority evaluated first; created in
this order or fixed with `PUT /v1/org/policy/rules/order`):

| # | Target | Action |
|---|---|---|
| 1 | Network `chatgpt.com` `POST /backend-api/codex/responses*` | allow + `rateLimit`/`rateLimitWindow` (hard usage ceiling; counted per rule × agent token; in-memory, resets on gateway restart) |
| 2 | Network `chatgpt.com` `/backend-api/codex/*` | allow |
| 3 | Network `chatgpt.com` `GET /backend-api/wham/usage` | allow (quota meter via codex `account/rateLimits/read`) |
| 4 | Network `chatgpt.com` `GET /backend-api/wham/accounts/check` | allow (**required**: Codex workspace routing discovery) |
| 5 | Network `chatgpt.com` `GET /backend-api/wham/rate-limit-reset-credits` | allow (optional; meter asks for it, non-fatal if blocked) |
| 6 | Network `chatgpt.com`, `*.chatgpt.com`, `*.openai.com` (incl. `auth.openai.com`), `api.openai.com` | block |

Grants: `connectome-host` ← `openai` (OAuth); `connectome-shell` ← nothing
(remove the auto-attached `openai` grant; doctor asserts the shell has no
LLM grant). Without an LLM grant the gateway itself refuses the shell on
`chatgpt.com` (401 `access_restricted`), including bypass paths.

The synthetic stub refresh on `auth.openai.com` is answered before policy, so
rule 6 doesn't break it but does make any real login fail closed.

**Path rules are defense-in-depth only.** The spike showed the gateway
matches the **raw** path: `GET /backend-api/codex/../me` and
`/backend-api/codex/%2e%2e/me` pass rule 2, chatgpt.com normalizes them, and
they return the account profile **with credentials injected**. Prefix globs
can't express "contains `..`", so policy can't close it. The real boundary
is that only the `connectome` container holds the host `aoc_` token (no
generic HTTP tool in the host; discord attachment patch, decision 21). To
report upstream to onecli (normalize or reject dot-segments before rule
matching).

**Usage caps, soft to hard (decision 20):** reminder floor 15 min (local
patch) → wake `rate_limit` on heartbeat events (drops bursts before
inference; agent-mutable) → onecli rule 1 rate limit (hard; when saturated,
chat replies also fail until the window rolls) → ChatGPT per-app weekly cap.
Subscription usage is quota, not dollars: exhausting it blocks the user's own
Codex use until the window resets.

### Phase 3 — operations integration

- **`stacks/justfile`:** `up-all` … `onecli up` → `connectome up`;
  `down-all`: `connectome down` before `onecli down`; `ps-all`, `pull-all`
  include connectome. `up-all` continues past an individual stack's failure
  and reports a summary, so e.g. an expired Tailscale PAT failing `adguard up`
  no longer prevents onecli/connectome from starting at boot.
- **onecli `up`** = `compose up -d --wait`. Phase 1 acceptance check: `--wait`
  treats the one-shot `migrations` exiting 0 as success on compose 5.1.3;
  if not, `up -d --wait api web gateway`.
- **Network lifecycle:** onecli owns `onecli-agents`. Quiesce for backups uses
  `compose stop`/`start` (both stacks), never `down`/`up`. The onecli `down`
  recipe refuses while connectome containers exist (`down-all` orders it).
- **connectome recipes:** `build` (sources check, CA copy, `sources.lock`),
  `provision-codex`, `init-env`, `up`/`down`/`ps`/`pull`, `shell` (exec into
  `shell`), `logs` (tails `$DATA_DIR/headless.log` and `failures.log` via
  `docker exec`, since `docker logs` is empty), `serve`, `backup`/`restore`.
- **Backups:** `connectome backup` stops both containers, prunes
  `llm-calls.*.jsonl` older than 14 days and truncates `headless.log` past a
  size cap, tars `state` and `workspace` via throwaway alpine (onecli's
  pattern), then starts them. `backup-all` runs connectome before onecli so
  connectome's tarball is consistent; connectome is up again and briefly
  loses the gateway during onecli's backup (harmless at 04:00). onecli
  backup: ciphertext + CA only; the key is in `.env` + password manager.
  Tarballs are runtime data under `~/.volume-backups/` and inherit FileVault
  protection.
- **Restore:** same refuse-non-empty semantics as onecli.
- **doctor:** onecli api/web/gateway healthy, migrations exited 0, CA owned by
  gateway uid (`docker exec onecli-gateway stat`), image CA fingerprint =
  gateway CA, `onecli-agents` exists with `connectome`/`shell` attached,
  connectome volumes present, backup age, `.env` mode 0600 for every stack,
  invariant lints, `llm-calls`/`headless.log` size warning.
- **Docs:** rewrite `stacks/onecli/README.md` (v2, auth, key location, threat
  model), new `stacks/connectome/README.md` (sources, provisioning, known
  exposures), CLAUDE.md (onecli key/FileVault paragraph,
  Reproducible-vs-runtime table, Colima table, stack lists),
  `docs/migration-recovery.md`.

### Spike results (2026-10-11)

Run against a **separate, throwaway** onecli 2.12.0 project (`onecli-spike`:
own volumes, network `onecli-spike-agents`, ports 2025x) alongside the live
v1 vault, with a dedicated `codex login` imported as the `openai` OAuth
secret (local copy deleted after import), and a minimal connectome-host
(`0c86e8e`) image: `oven/bun:1-debian`, Codex CLI 0.162.1
(`codex-aarch64-unknown-linux-musl`), gateway CA via `update-ca-certificates`,
non-root, `cap_drop: ALL`, `no-new-privileges`, image-owned read-only CWD,
`openai-codex` provider, model `gpt-6-luna`. Files under
`~/Developer/connectome/spike/`.

| # | Check | Result |
|---|---|---|
| 0 | `compose up -d --wait` with one-shot `migrations` (compose 5.1.3) | ✅ exit 0, all healthy in 28 s |
| 0 | Headless onecli bootstrap by curl (sign-up → `/v1/auth/session` → API key → agents → secret → grants → org rules) | ✅ no browser needed |
| 1 | connectome → Codex app-server (stub) → gateway → `POST /backend-api/codex/responses` | ✅ 200, agent replied — after two fixes: rule 4 (`wham/accounts/check`) and real `account_id` in the stub |
| 1 | `config.toml` (apps/plugins/analytics/otel off) | ✅ no blocked requests at startup |
| 1 | `account/read`, `account/rateLimits/read` | ✅ (meter also requests `wham/rate-limit-reset-credits` → rule 5) |
| 2 | Block rule on other chatgpt.com paths, `api.openai.com` | ✅ 403 `blocked_by_policy` |
| 2 | Dot-segment / `%2e%2e` bypass | ❌ **bypasses path rules** with host token (see onecli identities); `..%2f` rejected upstream; shell token refused regardless |
| 3 | Requests per turn | simple turn = 1 `responses` POST; startup = `codex/models` + `accounts/check`. Tool-using turns and heartbeat-coalescing not measured (needs MCP servers) — measure during Phase 2 bring-up before fixing rule-1 numbers |
| 4 | Direct LAN/tailnet reach from the agents network (no proxy) | router admin `192.168.1.1` **200**; AdGuard admin `192.168.1.78:18689` **302**; homebridge UI `:18767` **200**; this Mac's tailnet IP `:22`/`:53` connect; other tailnet peers routable |
| — | Uncredentialed internet | ✅ 200 |

Other observations: the Codex model list includes `gpt-6-astra/sol/luna`,
`gpt-5.6-*` (272k context); onecli's dashboard links say `localhost:10254`
unless `ONECLI_EXTERNAL_URL` is set; `account/read` reports plan `free`
(from the stub's fake id_token — cosmetic; usage limits come from the real
account).

The spike environment (stack, volumes, images, files, and the dedicated
login it held) was torn down afterwards; Phase 1 starts from a fresh login.

### Known exposures (accepted)

- **`shell` can reach the WebUI port** on the container networks; protected by
  basic auth only.
- **LAN and tailnet reachability (decision 14).** `shell` has direct egress
  through the VM's NAT. Spike-measured: router admin, AdGuard admin,
  homebridge UI, this Mac's tailnet SSH/DNS, and other tailnet peers are all
  reachable. The gateway's private-destination refusal only covers proxied
  traffic. Intended for now (decision 14); lockdown is future work.
- **onecli path-rule bypass** via dot-segments for any holder of the host
  `aoc_` token (see onecli identities).
- **Same trust domain for host and fleet children.** Children inherit the
  host's entire env.
- **Fresh-device rebuild of local patches** is manual (decision 22).

### Future — persona fleet children (seams kept now)

- Each persona is an explicit `children[]` entry with its own tracked recipe
  under `/agent/recipes`, its own `dataDir` under
  `/agent/state/data/children/<name>`, and its own Discord bot token and
  onecli token delivered via `children[].env`
  (`${PERSONA_X_DISCORD_TOKEN}`, `HTTPS_PROXY` with
  `${PERSONA_X_ONECLI_TOKEN}`) — runtime-only at the pinned commit.
- A single `shell` daemon means personas share one shell identity and can
  see each other's sessions (`session.list`) → add one `shell-<name>`
  container per persona when personas get distinct trust or credentials.

## Open questions

None blocking. Values deferred to the spike: rule-1 rate limit, heartbeat
wake `rate_limit` numbers, ChatGPT per-app weekly cap.

## Appendix A: onecli v2 compose

Trimmed from upstream `docker/docker-compose.yml` (2.12.0). This was the
version deployed during the rolled-back attempt; it is correct against source
except where noted. Changes for Phase 1: `.env` provides the three secrets
(decision 6); the `up` recipe uses `--wait`.

```yaml
name: onecli

# Trimmed from upstream docker/docker-compose.yml (onecli v2 split stack).
# Dropped: the hosted-agents `runner` + `ssh-terminator` (docker-socket
# mounts; we run our own agents) and the Slack `channel-adapter`. Postgres
# is not published — nothing outside the compose network needs it.
#
# Agents reach the gateway over the `onecli-agents` network. That network
# keeps api/web/postgres unreachable from agents; it is NOT `internal`, so it
# also gives agent containers direct egress (by design). Agent stacks join it
# as an external network and use `gateway:10255` as their proxy.

x-common: &common
  restart: unless-stopped
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  env_file:
    - path: .env
      required: false

x-db-url: &db-url postgresql://${POSTGRES_USER:-onecli}:${POSTGRES_PASSWORD:-onecli}@postgres:5432/${POSTGRES_DB:-onecli}

services:
  postgres:
    image: postgres:18-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-onecli}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-onecli}
      POSTGRES_DB: ${POSTGRES_DB:-onecli}
    volumes:
      - pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-onecli}"]
      interval: 5s
      timeout: 3s
      start_period: 15s
      retries: 10
    networks:
      - onecli

  # One-shot schema migration; api waits for it to exit 0.
  migrations:
    <<: *common
    image: ghcr.io/onecli/onecli-migrations:${ONECLI_VERSION:-2.12.0}
    container_name: onecli-migrations
    restart: "no"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: *db-url
    networks:
      - onecli

  api:
    <<: *common
    image: ghcr.io/onecli/onecli-api:${ONECLI_VERSION:-2.12.0}
    container_name: onecli-api
    depends_on:
      postgres:
        condition: service_healthy
      migrations:
        condition: service_completed_successfully
    ports:
      - "127.0.0.1:${ONECLI_API_PORT:-10256}:10256"
    environment:
      DATABASE_URL: *db-url
      MAX_ORGS_PER_USER: 1
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET:?set BETTER_AUTH_SECRET in .env}
      SECRET_ENCRYPTION_KEY: ${SECRET_ENCRYPTION_KEY:?set SECRET_ENCRYPTION_KEY in .env}
      GATEWAY_INTERNAL_SECRET: ${GATEWAY_INTERNAL_SECRET:?set GATEWAY_INTERNAL_SECRET in .env}
      ONECLI_APP_PORT: ${ONECLI_APP_PORT:-10254}
      ONECLI_API_PORT: ${ONECLI_API_PORT:-10256}
      ONECLI_GATEWAY_PORT: ${ONECLI_GATEWAY_PORT:-10255}
      GATEWAY_INTERNAL_URL: http://gateway:10255
      # Proxy address handed to agent containers by /v1/container-config.
      # Resolves on the `onecli-agents` network.
      ONECLI_AGENT_PROXY_ADDRESS: gateway:10255
    volumes:
      # The api serves the gateway's CA (app-data/gateway/ca.pem).
      - app-data:/app/data:ro
    networks:
      - onecli

  web:
    <<: *common
    image: ghcr.io/onecli/onecli-web:${ONECLI_VERSION:-2.12.0}
    container_name: onecli-web
    depends_on:
      api:
        condition: service_healthy
    ports:
      - "127.0.0.1:${ONECLI_APP_PORT:-10254}:10254"
    environment:
      DATABASE_URL: *db-url
      MAX_ORGS_PER_USER: 1
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET:?set BETTER_AUTH_SECRET in .env}
      SECRET_ENCRYPTION_KEY: ${SECRET_ENCRYPTION_KEY:?set SECRET_ENCRYPTION_KEY in .env}
      ONECLI_APP_PORT: ${ONECLI_APP_PORT:-10254}
      ONECLI_API_PORT: ${ONECLI_API_PORT:-10256}
      ONECLI_GATEWAY_PORT: ${ONECLI_GATEWAY_PORT:-10255}
      GATEWAY_INTERNAL_URL: http://gateway:10255
      API_INTERNAL_URL: http://api:10256
    networks:
      - onecli

  gateway:
    <<: *common
    image: ghcr.io/onecli/onecli-gateway:${ONECLI_VERSION:-2.12.0}
    container_name: onecli-gateway
    depends_on:
      api:
        condition: service_healthy
    ports:
      - "127.0.0.1:${ONECLI_GATEWAY_PORT:-10255}:10255"
    environment:
      DATABASE_URL: *db-url
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET:?set BETTER_AUTH_SECRET in .env}
      SECRET_ENCRYPTION_KEY: ${SECRET_ENCRYPTION_KEY:?set SECRET_ENCRYPTION_KEY in .env}
      GATEWAY_INTERNAL_SECRET: ${GATEWAY_INTERNAL_SECRET:?set GATEWAY_INTERNAL_SECRET in .env}
      ONECLI_APP_PORT: ${ONECLI_APP_PORT:-10254}
      INTERNAL_API_URL: http://api:10256
    volumes:
      # CA cert + key (gateway/ca.{pem,key}); generated on first start in a
      # fresh vault, owned by the gateway uid.
      - app-data:/app/data
    networks:
      - onecli
      - agents

volumes:
  pgdata:
  app-data:

networks:
  onecli:
    driver: bridge
  agents:
    name: onecli-agents
    driver: bridge
```
