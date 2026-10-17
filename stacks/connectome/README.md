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

Two containers in one Compose project:

- **`connectome` (connectome-host):** the agent host (Bun/TypeScript). Runs one
  process via `bun src/index.ts <recipe> --headless`. Mounts the `.recipe.json`
  from `/agent/recipes`, stores session state in `/agent/state`, collects logs
  at `/agent/state/data/headless.log` and `logs/failures.log`. CWD is `/agent/cwd`
  (holds `mcpl-servers.json`, heartbeat config, the shell socket). Reads-only mounts
  `/agent/recipes` (the tracked sources); read-write mounts `/agent/state` (named
  volumes) and `/agent/cwd` (bind mount of `stacks/connectome/recipes/clara/`).
  Shares `/agent/state/data/outbox` with `shell` read-only.
- **`shell` (connectome-shell):** the agent's Linux workbench (node, Rust, Python, etc.).
  Reaches connectome via term-sessions (over a Unix socket at `/agent/cwd/shell.sock`).
  Mounts `/workspace` (named volume, writable), with `/workspace/outbox` read-only from
  connectome's outbox. No network-wide mounts; egress is direct (not through connectome).

**Filesystem layout inside containers:**

```
/agent/
  cwd/              → bind mount: stacks/connectome/recipes/clara/ (readwrite for shell)
  recipes/          → bind mount: ~/Developer/connectome/*/recipes/ (readonly)
  state/            → named volume connectome_state (readwrite)
    data/
      headless.log            (40–50 MiB, capped at 10 MiB by backup pruning)
      llm-calls.*.jsonl       (one new file per start, full prompts; ~130 MB/day heavy use)
      .recipe.json            (unresolved ${VAR}s, mode 0600)
      outbox/                 (connectome writes; shell reads; cleared between runs)
      observers.json          (hot-reloaded observer grants)
      gateway.crt             (onecli gateway CA; image-test verifies fingerprint match)
    logs/
      failures.log            (hard-coded CWD-relative; write errors swallowed)
  outbox/           → read-only bind mount from connectome into shell

/workspace/         → named volume connectome_workspace (shell mounted readwrite)
  outbox/           → read-only from connectome's outbox
  input/, output/   → workspace directories (agent creates on demand)
```

**Networks:**

- `onecli-agents`: attached to connectome, shell, onecli gateway, and the provisioning shell.
  No external access; used for inter-service discovery (`onecli-gateway:10255` is reachable
  here). Shell also has direct egress through the VM's NAT (not via connectome).

## Provisioning

`dotfiles stacks connectome provision-codex` (run after `onecli import-openai`):

1. Fetches the Codex stub from onecli (`GET /v1/credential-stubs/codex`) with the operator's API key.
   The stub holds a parseable `access_token` and `account_id` (both marked `onecli-managed` and
   never refreshed by connectome — the gateway handles refresh).
2. Writes the stub to `connectome_state:/agent/state/data/config.toml` (the Codex provider config).

This step creates the agent's gateway CA certificate during onecli setup; it must run **after** onecli
is up and the vault is unlocked.

**Important:** never use the WebUI "log in again" action — it logs out the stub and blocks refresh.
Recover with another `provision-codex` run.

## Security invariants

Connectome's security invariants are checked at build time (`image-test`, 8 checks) and runtime (lints
in `doctor`, 7 checks). The invariants enforce:

1. **Code-execution features disabled** (`codeExecution`, `extensions`, `mcplAdmin` off; `modules.workspace` false).
   Protects against recipe injection. Checked at build.
2. **Fleet never bare `true`** (explicit children with allowed recipes under `/agent/recipes`).
   Prevents arbitrary recipe launch. Checked at build.
3. (reserved)
4. **Outbox-only shared workspace** (connectome mounts read-only; shell has no binds).
   Limits connectome's file-write surface. Checked at build and runtime.
5. (reserved)
6. **No onecli user API key; no private-destination bypass; no host-gateway bind**.
   Prevents credential exposure and network escape. Checked at runtime.
7. **`GATE_TELEMETRY` unset everywhere.** Prevents accidental telemetry.
   Checked at runtime.
8. **Discord filters fixed in recipe; no agent filter rewrites; dangerous tools disabled**.
   Prevents DM/guild bypass. Checked at runtime.
9. **`OBSERVERS_FILE` on the read-only `/agent/recipes` mount, not overridden**.
   Prevents observer privilege escalation via connectome. Checked at runtime.

Run `dotfiles stacks connectome image-test` (build-time checks) and `dotfiles stacks connectome lint`
(runtime checks); both are included in `doctor`. See `scripts/lint.sh` for implementation.

## Known exposures (accepted)

- **WebUI port is basic-auth only.** The shell can reach `localhost:7340` on the container network;
  protected by a 32-char password from `.env`.
- **LAN and Tailscale reachability.** The shell has direct egress through the VM's NAT. It can reach
  router admin, AdGuard, homebridge UI, this Mac's Tailscale SSH/DNS, and other Tailscale peers.
  Intended for agent tools (debugging, testing, e.g. `ssh` to a Tailscale node). Locking this down
  is future work.
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
(shared context) and the onecli gateway (shared credential broker). Seams kept now:

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
- `dotfiles stacks connectome ratelimit-check`: check current onecli policy quota usage and ChatGPT
  plan remaining tokens.
- `dotfiles stacks connectome probe`: test the onecli proxy (proves `aoc_` token validity).

**Model swap:**

Feeding one model's chronicle to another violates continuity (encrypted reasoning items are model-bound).
A model swap requires a new session — use `connectome restore` with a clean `state` volume, or update
`LLM_MODEL` in `.env`, re-run `init-env` to sync tokens, and `connectome restart`. The old session's
state is preserved in the tarball backup.
