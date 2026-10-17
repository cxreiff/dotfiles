# connectome stack

One [connectome-host](https://github.com/anima-research/connectome-host) agent,
**clara**, reachable over Discord, running as two containers in the `agents`
Colima VM:

- `connectome` — the agent host (Bun/TypeScript) plus its MCP servers
  (discord-mcpl, heartbeat-mcpl, the term-sessions client) and the WebUI.
- `shell` — the agent's Linux workbench (node, tsc, cargo, python, uv, gh, …),
  reached through term-sessions. `/workspace` persists; `/workspace/outbox` is
  the only directory shared with `connectome` (read-only there).

The model is the operator's ChatGPT subscription (Codex, `openai-codex`
provider), brokered by the onecli v2 gateway (`stacks/onecli`). No model
credential is in either container: the host carries an onecli stub whose
tokens are the literal `onecli-managed`, and the gateway injects the real
token on `chatgpt.com`.

## Fresh-device setup

Prerequisites: the `agents` VM is up (`dotfiles stacks vm-agents-up`), and the
local clones under `~/Developer/connectome/` exist with their `local` branches
(see [Sources and local patches](#sources-and-local-patches)).

1. `dotfiles stacks onecli up` — onecli v2 must be running first (it owns the
   `onecli-agents` network).
2. `dotfiles stacks onecli policy` — creates the `connectome-host` /
   `connectome-shell` agents and the org rules.
3. `dotfiles stacks onecli import-openai` — dedicated ChatGPT device login,
   stored as the `openai` OAuth secret (only on a fresh vault).
4. `dotfiles stacks connectome init-env` — prompts for the model, Discord
   token, `guild:channel` whitelist and the operator's **numeric** Discord user
   id; generates the WebUI password and term-sessions token; syncs both `aoc_`
   tokens from onecli. Re-run it any time to re-sync the tokens.
5. `dotfiles stacks connectome build` — refuses dirty clones; writes
   `sources.lock`.
6. `dotfiles stacks connectome image-test` — 13 static checks on the images.
7. `dotfiles stacks connectome provision-codex` — writes the onecli Codex stub
   (with the real ChatGPT account id) and `config.toml` into the `state` volume.
8. `dotfiles stacks connectome up`, then `dotfiles stacks connectome serve`
   (WebUI at `https://cxmini.faun-fir.ts.net:8768`, basic auth from `.env`).
9. `dotfiles stacks connectome smoke` — 15 live checks.

Discord bot (one-time, developer portal): a dedicated application whose bot
has **Message Content** and **Server Members** privileged intents enabled,
invited with scope `bot` and permissions 274878008384 (View Channels, Send
Messages, Send Messages in Threads, Read Message History, Attach Files, Add
Reactions). The bot's Discord name must match the recipe's `agent.name`
(`clara`), or the agent treats @-mentions as addressed to someone else.

## .env keys

`stacks/connectome/.env` (mode 0600, created by `init-env`; never add an onecli
**user** API key here):

| Key | Source |
|---|---|
| `LLM_MODEL` | prompt (Codex model id, e.g. `gpt-6-sol`) |
| `DISCORD_TOKEN` | prompt (hidden) |
| `DISCORD_GUILD_ID` | prompt, `<guild id>:<channel id>[+<channel id>…]` |
| `DISCORD_OPERATOR_ID` | prompt, numeric user id (DM allowlist + admin) |
| `WEBUI_USER`, `WEBUI_PASS` | generated |
| `SESSION_SERVER_TOKEN` | generated (term-sessions daemon auth) |
| `HOST_ONECLI_TOKEN`, `SHELL_ONECLI_TOKEN` | synced from onecli agents |

`LLM_PROVIDER` is optional (default `openai-codex`). A model or provider swap
means a new session, not a flip on a live one.

## Sources and local patches

Images are built from local clones in `~/Developer/connectome/` at the SHAs in
`sources.lock`. Local patches are commits on a `local` branch in each clone;
`sources.lock` lists them by subject only.

| Clone | Upstream | Branch |
|---|---|---|
| `connectome-host` | anima-research/connectome-host | `local` |
| `discord-mcpl` | anima-research/discord-mcpl | `local` |
| `heartbeat-mcpl` | anima-research/heartbeat-mcpl | `local` |
| `voice-kit` | anima-research/voice-kit | `main` |

Local patches:

- **heartbeat-mcpl** — `local: refuse reminders below a 900 s floor` (refused,
  not clamped).
- **discord-mcpl** — `local: confine attachments to DISCORD_ATTACHMENT_ROOT
  (fd-verified)`. Worth proposing upstream.
- **connectome-host** — `local: recipe-configurable subagent maxDepth and
  maxExecutionMs`.
- **connectome-host** — `local: empty optional subagent inputs mean not given`
  (the model fills every tool field, so `model: ""` used to reach the provider
  verbatim instead of the default).

On a fresh device, clone each upstream, create `local` from the base SHA in
`sources.lock`, and re-apply the patches by hand (cherry-pick from a backup of
the old clones, or re-implement from the subjects). `build` refuses to run on
dirty clones.

## Usage caps (calibration)

Layered caps, innermost first: the 900 s reminder floor (patch) → heartbeat
wake `rate_limit` (drops bursts before inference) → onecli rule 1 (hard hourly
ceiling; when saturated, chat replies fail too until the window rolls) →
ChatGPT plan quota.

| Measured 2026-10-16 (PDT; 2026-10-17 UTC) | Value |
|---|---|
| `responses` POSTs per tool-using turn | 2 |
| per heartbeat tick (incl. the triggering DM turn) | 3 |
| burst of 3 DMs (2nd and 3rd 3.5 s after the 1st) | 2 (the last two coalesced) |
| work + one reviewer subagent + depth test | ~22 |
| autonomous subagent polish passes | ~35 in 4 min (~525/h) |
| **rule 1 (`cx-1-codex-responses-limit`)** | **1000 / hour** |
| **heartbeat wake `rate_limit`** | **6 tokens, refill 600000 ms** |
| per-app weekly ChatGPT cap | **not set** — operator's choice (personal plan; the agent may use all of it) |

Rule 1 is a runaway backstop, not a budget: 2× the heaviest measured hour. A
saturated rule 1 returns 429 to the agent; failed requests (e.g. bad model
ids) count too. `dotfiles stacks connectome ratelimit-check` proves the
ceiling (temporarily 2/hour, restored by trap); run it only when the agent is
idle.

Notes:

- The recipe's `modules.wake` only **seeds new sessions**. For the live session
  use `dotfiles stacks connectome set-heartbeat-rate <tokens> <ms>` (hot
  reload), and keep `recipes/agent.json` in sync.
- Accepted gap: the 900 s floor does not cover absolute `atIso` reminders, so
  many near-term one-shots remain possible. They are still capped by the
  heartbeat wake `rate_limit` (its `source: "heartbeat"` match covers every
  heartbeat-server event, reminders included), then by rule 1.
- Subagents share clara's onecli identity and quota. Sync subagents stop after
  `maxExecutionMs` (30 min); **async subagents have no default time limit**
  (upstream design) — rule 1 bounds what a runaway one can spend.

## Subagents

`modules.subagents` gives clara `subagent--spawn` (fresh context, e.g. an
independent reviewer) and `subagent--fork` (continues from her context).
Recipe settings: `defaultModel: gpt-6-luna`, `maxDepth: 1` (subagents cannot
spawn subagents; they are not even offered the tools), `maxExecutionMs:
1800000`. Valid model ids on the ChatGPT plan: `gpt-6-luna`, `gpt-6-sol`,
`gpt-6-astra`; others return 400.

When calling a subagent: `tools: []` (an empty array) means the subagent has
access to ALL tools (the default); to restrict to specific tools, pass a
non-empty array of tool names.

## Known issues

- **AC7.2 not verified live (accepted deferral, 2026-10-16).** Nobody has yet
  checked that a DM from another user, or a message in a non-whitelisted
  guild/channel, gets no reply. The bot is only in the operator's personal
  servers for now. The allowlists (`DISCORD_DM_USERS`, `DISCORD_GUILD_ID`) are
  enforced by discord-mcpl; before inviting the bot anywhere with other
  members, have a second account DM it and post in a non-whitelisted channel,
  and confirm `dotfiles stacks onecli requests 5` shows no new `responses` row.

- **`>>#channel` prefix in replies.** agent-framework 0.21.0 always offers the
  "reply without joining: prefix with `>>#channel`" option in channel
  invitations, but the default `locus` prose routing never parses prefixes, so
  the prefix was delivered verbatim. The recipe prompt tells clara not to use
  it.
- **The model refuses some security probes itself** (e.g. attaching
  `/proc/self/environ` or files outside the outbox), so the attachment guard is
  verified at the image level (`image-test`) rather than live.
- **Never use the WebUI "log in again" action**: it runs `account/logout`,
  deletes the onecli stub and starts a real login (blocked by onecli rule 6).
  Recover with `dotfiles stacks connectome provision-codex`.

## Architecture

Two containers in one Compose project, on two networks:

- **`connectome` (connectome-host):** the agent host (Bun/TypeScript). Runs one
  process via `bun src/index.ts <recipe> --headless`. Stores session state in `/agent/state`
  (named volume), collects logs at `/agent/state/data/headless.log` and logs/failures.log.
  CWD is `/agent/cwd` (image-owned, immutable — holds symlinks to `/agent/recipes/mcpl-servers.json`
  and `/agent/state/logs`). Mounts:
  - `/agent/recipes` — named volume, read-only (agent recipe and observers.json)
  - `/agent/state` — named volume, read-write (session data, codex config, heartbeat state)
  - `/agent/outbox` — named volume, read-only (shared transient output with shell)
- **`shell` (connectome-shell):** the agent's Linux workbench (node, Rust, Python, etc.).
  Reaches connectome via term-sessions over the `connectome` bridge network.
  Mounts:
  - `/workspace` — named volume, read-write (persistent workbench directory)
  - `/workspace/outbox` — shared from connectome's `/agent/outbox`, read-write (shell writes output)

**Filesystem layout inside containers:**

```
/agent/                       (connectome only)
  cwd/                        → image-owned, read-only (symlinks only)
    mcpl-servers.json         → symlink to /agent/recipes/mcpl-servers.json
    logs/                     → symlink to /agent/state/logs
  recipes/                    → named volume connectome_recipes (read-only)
    agent.json                (resolved recipe, mode 0600)
    observers.json            (hot-reloaded observer grants)
    mcpl-servers.json         (tracked MCP server config)
  state/                      → named volume connectome_state (read-write)
    data/
      headless.log            (40–50 MiB, capped at 10 MiB by backup pruning)
      llm-calls.*.jsonl       (one new file per start; full prompts; ~130 MB/day heavy use)
      .recipe.json            (unresolved ${VAR}s, mode 0600)
      codex/
        config.toml           (ChatGPT Codex provider stub, mode 0600)
        auth.json             (account id, mode 0600)
      outbox/                 (connectome writes, shell reads; cleared between runs)
      children/               (future: persona subagent state)
    logs/
      failures.log            (hard-coded frame-level error log)
    heartbeat/
      config.json             (wake interval, persist across restarts)
      reminders.json          (pending reminders, in-memory only)
  outbox/                     → named volume connectome_outbox (read-only here)

/workspace/                   (shell only)
  outbox/                     → connectome_outbox (read-write here)
  input/, output/             → workspace directories (agent creates on demand)
```

**Networks:**

- `onecli-agents` (external): both containers attached; used for inter-service discovery
  (connectome reaches `onecli-gateway:10255` here). Shell has direct egress through the
  VM's NAT for external services (not proxied through connectome).
- `connectome` (bridge, local): both containers attached; used for shell to reach connectome
  over the network (term-sessions service listens on the `connectome` hostname via the bridge).

## Provisioning

`dotfiles stacks connectome provision-codex` (run after `onecli import-openai`):

1. Fetches the Codex stub from onecli (`GET /v1/credential-stubs/codex`) with the operator's API key.
   The stub holds a parseable `access_token` and `account_id` (both marked `onecli-managed` and
   never refreshed by connectome — the gateway handles refresh).
2. Writes the stub to `connectome_state:/agent/state/codex/{config.toml, auth.json}` (the Codex provider config and account id).

This step must run **after** onecli is up and the vault is unlocked. It does not create the gateway
CA certificate — that's baked into the image at build time (copied from the live onecli gateway).

**Important:** never use the WebUI "log in again" action — it logs out the stub and blocks refresh.
Recover with another `provision-codex` run.

## Security invariants

Connectome has 9 security invariants, checked at build time (13 image tests + 4 integration tests in the build) and runtime (7 lint checks + 15 smoke tests). The invariants enforce:

1. **Code-execution features disabled** (`codeExecution`, `extensions`, `mcplAdmin` off; `modules.workspace` false).
   Protects against recipe injection.
   Checks: `lint.sh` invariant 1 (recipe config), `image-test.sh` checks 1-9 (full image suite).

2. **Fleet never bare `true`** (explicit children with allowed recipes under `/agent/recipes`).
   Prevents arbitrary recipe launch.
   Checks: `lint.sh` invariant 2 (recipe config).

4. **Outbox-only shared workspace** (connectome mounts read-only; shell has no binds).
   Limits connectome's file-write surface.
   Checks: `lint.sh` invariant 4 (compose volumes), `smoke.sh` AC9.4 (runtime volume mounts).

6. **No onecli user API key; no private-destination bypass; no host-gateway bind**.
   Prevents credential exposure and network escape.
   Checks: `lint.sh` invariant 6 (.env key names, compose config, onecli settings).

7. **`GATE_TELEMETRY` unset everywhere.** Prevents accidental telemetry.
   Checks: `lint.sh` invariant 7 (.env keys, compose env, Dockerfile).

8. **Discord filters fixed in recipe; no agent filter rewrites; dangerous tools disabled**.
   Prevents DM/guild bypass.
   Checks: `lint.sh` invariant 8 (recipe config, .env keys), `smoke.sh` AC7.3 (runtime env).

9. **`OBSERVERS_FILE` on the read-only `/agent/recipes` mount, not overridden**.
   Prevents observer privilege escalation via connectome.
   Checks: `lint.sh` invariant 9 (Dockerfile env, compose volume mount), `smoke.sh` AC8.3 (runtime read-only).

Run `dotfiles stacks connectome image-test` (13 build-time checks) and `dotfiles stacks connectome smoke`
(15 runtime checks). Both `lint` and `image-test` are included in `doctor`. See `scripts/{lint,image-test,smoke}.sh` for implementation.

## Known exposures (accepted)

- **WebUI port is basic-auth only.** The connectome WebUI listens on `127.0.0.1:18768` (internally :18768),
  published to Mac localhost only; protected by a 32-char password from `.env`. The shell can reach it over
  the container network but cannot reach the shell's own services (no cross-container port exposure).
- **LAN and Tailscale reachability.** The shell has direct egress through the VM's NAT (not proxied through
  connectome). It can reach the router admin, AdGuard, homebridge UI, this Mac's Tailscale SSH/DNS, and other
  Tailscale peers. Intended for agent tools (debugging, testing, e.g. `ssh` to a Tailscale node). Locking this
  down is future work.
- **Fleet children on the same trust domain.** Persona subagents share connectome's state volume and the same
  onecli identity (until separate `aoc_` tokens and `dataDir`s are implemented). A malicious persona can read
  the host's chronicle and llm-calls logs.
- **Fresh-device patches are manual.** Local branch patches on connectome sources are reapplied by hand on a
  fresh device; `sources.lock` lists the subjects but not the diffs. An incorrect re-implementation could
  introduce bugs or lose security hardening.
- **onecli path-rule bypass.** A dot-segment bypass (`.../../..`) can escape any `Network` path rule.
  Defense-in-depth only — the gateway blocks private destinations for proxied requests, and the
  onecli policy is explicit allow-list. Report bypass upstream.
- **Same-UID on the Mac.** An attacker with your UID can curl the onecli dashboard (unauth in VM)
  and steal credentials, or compromise connectome's container. Same-UID = vault compromise (see
  onecli/README.md).

## Future: persona fleet children

Personas (future work) will be persistent fleet children with their own Discord identity, onecli
proxy token, and `dataDir`. Each persona gets its own `children[]` entry in the recipe and its own
`shell` container. The host and all personas share the connectome `state` and `recipes` volumes
(shared context, but each persona has its own `state/data/children/<name>/` subdirectory) and the
onecli gateway (shared credential broker). Seams kept now:

- Recipe structure supports `children[]` with explicit recipes and runtime env.
- Shell socket design allows one shell socket per persona (no namespace crossing).
- onecli proxy supports multiple identities (`aoc_` tokens) on one gateway.
- Discord-mcpl can host multiple bot tokens in one process (future: one per persona).

## Operations

**Startup/shutdown:**

- `dotfiles stacks connectome up`: starts both containers. Requires the `onecli-agents` network
  (exits with a guard message if onecli isn't running).
- `dotfiles stacks connectome down`: stops both containers. `onecli down` refuses while connectome
  exists.
- `dotfiles stacks connectome restart`: stops and starts.

**Logs:**

- `dotfiles stacks connectome logs` tails `headless.log` (agent's stdout/stderr) and `failures.log`
  (hard-coded frame-level error log). Run in the background or kill with Ctrl+C.

**Backup:**

- `dotfiles stacks connectome backup`: stop-based quiesce. Prunes `llm-calls.*.jsonl` older than
  14 days and caps `headless.log` to 10 MiB. Writes `~/.volume-backups/daily/connectome-YYYY-MM-DD.tgz`
  containing `connectome_state` and `connectome_workspace`. The `connectome_outbox` volume is not
  backed up (transient).
- `dotfiles stacks connectome restore <tarball>`: restores `state` and `workspace` on empty volumes
  only. Requires the agents VM running.

**Monitoring:**

- `dotfiles stacks connectome smoke`: 15 live checks (network, containers, schema, heartbeat, outbox).
  Runs after `up` or `provision-codex`.
- `dotfiles stacks connectome set-heartbeat-rate <tokens> <ms>`: hot-reload heartbeat wake policy on
  the live session (e.g. `8 60000` = 8 tokens per 60 seconds). Changes are not persisted to the recipe.
- `dotfiles stacks connectome ratelimit-check`: temporarily set rule 1 to 2/hour, restart the gateway,
  expect the 3rd POST to get 429, then restore the limit. Proves the rate-limit enforcement.

**Model or provider swap:**

Feeding one model's chronicle to another violates continuity (encrypted reasoning items are model-bound).
A model/provider swap requires a new session and a fresh `DATA_DIR` (not editing `LLM_MODEL` on a live session):

- Update `LLM_PROVIDER` and `LLM_MODEL` in `.env`.
- Delete the old session's state: `dotfiles stacks connectome down && docker --context colima-agents volume rm connectome_state`.
- Re-run `dotfiles stacks connectome init-env`, `dotfiles stacks connectome build`, `dotfiles stacks connectome provision-codex`, `dotfiles stacks connectome up`.

The old session's state is preserved in the tarball backup if you need to revert.
