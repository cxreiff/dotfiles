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
2. `dotfiles stacks onecli policy 1000` — creates the `connectome-host` /
   `connectome-shell` agents and the org rules, with rule 1 at the calibrated
   1000/hour (with no argument a fresh vault gets 60/hour).
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

Local patches (11 commits; `grep '^patch' sources.lock` is authoritative). Three
functional changes, the rest are follow-up fixes and tests to them:

- **heartbeat-mcpl** (2): reminders below a 900 s floor are refused, not
  clamped; tool descriptions match the floor.
- **discord-mcpl** (6): attachments are confined to `DISCORD_ATTACHMENT_ROOT`,
  checked on the opened file descriptor (symlinks, `/proc`, `..`, FIFOs and
  directories refused), read with a bounded loop so a growing file cannot pass
  the 25 MiB cap; plus test hardening. Worth proposing upstream.
- **connectome-host** (3): `modules.subagents` accepts `maxDepth` and
  `maxExecutionMs` from the recipe; empty optional spawn/fork inputs
  (`model: ""`, `maxTokens: 0`, `tools: []`, …) mean "not given", so the recipe
  defaults apply (`tools: []` therefore means all tools, not none).

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

Two containers in one Compose project (`stacks/connectome/compose.yaml`):

- **`connectome`** (image `connectome-host:local`): the agent host. The
  entrypoint seeds state, waits (bounded) for `gateway:10255`, then runs
  `bun /opt/connectome/src/index.ts /agent/recipes/agent.json --headless`. It
  runs the MCP servers as children (discord-mcpl, heartbeat-mcpl, and the
  term-sessions **client**) and serves the WebUI on port 18768, published on
  `127.0.0.1:18768` only (`dotfiles stacks connectome serve` puts it on the
  tailnet at port 8768).
- **`shell`** (image `connectome-shell:local`, hostname `shell`): the agent's
  workbench. It runs the term-sessions **daemon** (`session-server --headless`,
  port 3100, `SESSION_SERVER_TOKEN`); connectome's term-sessions client
  connects to `shell:3100`. It holds no host secrets: its environment is only
  its own onecli proxy (`HTTPS_PROXY` with `SHELL_ONECLI_TOKEN`), `NO_PROXY`
  and `SESSION_SERVER_TOKEN`.

Mounts:

| Container | Mount | Source | Mode |
|---|---|---|---|
| connectome | `/agent/state` | volume `connectome_state` | rw |
| connectome | `/agent/outbox` | volume `connectome_outbox` | **ro** |
| connectome | `/agent/recipes` | bind of the tracked `stacks/connectome/recipes/` | **ro** |
| shell | `/workspace` | volume `connectome_workspace` | rw |
| shell | `/workspace/outbox` | volume `connectome_outbox` | rw |

The shell writes files into `/workspace/outbox`; connectome attaches them by
their `/agent/outbox/...` path (read-only view of the same volume, and the
discord attachment guard's root).

Layout inside `connectome`:

```
/agent/cwd/                 image-owned, not writable (invariant 3)
  mcpl-servers.json   -> /agent/recipes/mcpl-servers.json
  logs                -> /agent/state/logs
/agent/recipes/             tracked files, read-only bind
  agent.json  observers.json  mcpl-servers.json  codex-config.toml
/agent/state/               volume connectome_state
  data/                     DATA_DIR: headless.log, llm-calls.*.jsonl,
                            .recipe.json, sessions/, children/
  codex/                    CODEX_HOME: auth.json (onecli stub), config.toml
  logs/                     failures.log
  heartbeat/                config.json (interval), reminders.json
  discord/                  watermark, DM-notice and muted-channel state
/agent/outbox/              volume connectome_outbox, read-only
```

`backup` prunes `llm-calls.*.jsonl` older than 14 days and, once
`headless.log` passes 50 MiB, truncates it to its last 10 MiB.

Networks:

- `onecli-agents` (external, owned by the onecli stack, not internal): both
  containers reach the gateway at `gateway:10255` with their own `aoc_`
  token, and it also gives them direct egress.
- `connectome` (this project's bridge): connectome to `shell:3100` for
  term-sessions. The api, web and postgres of onecli are not on either
  network.

## Provisioning

`dotfiles stacks connectome provision-codex` (after `onecli import-openai`,
with onecli up):

1. Reads the `openai` secret's `metadata.accountId` and the Codex credential
   stub (`GET /v1/credential-stubs/codex`) with the operator API key, on the
   Mac only.
2. Sets `tokens.account_id` to the **real** ChatGPT account id (an identifier,
   not a credential) and refuses unless both tokens are the placeholder
   `onecli-managed`. The gateway injects the real token on `chatgpt.com`.
3. Writes `/agent/state/codex/auth.json` (0600, container uid) and copies the
   tracked `recipes/codex-config.toml` to `/agent/state/codex/config.toml`.

The gateway CA is not part of this: `build` copies it from the running
gateway into both images.

Never use the WebUI "log in again" action: it runs `account/logout`, deletes
the stub and starts a real login (blocked by onecli rule 6). Recover with
another `provision-codex`.

## Security invariants

Ten invariants from the design. `dotfiles stacks doctor` runs the static ones
(`lint.sh`, which reads tracked files and `.env` key names only); the others
are checked by the image build, `image-test` or `smoke`.

| # | Invariant | Checked by |
|---|---|---|
| 1 | `codeExecution`, `extensions`, `modules.mcplAdmin` off; `modules.workspace` false; `modules.subagents.maxDepth` is 1 (subagents cannot spawn subagents) | `lint.sh` invariant 1 |
| 2 | `modules.fleet` absent or an explicit object (children + `allowedRecipes` under `/agent/recipes/`, no `..`); never `true` | `lint.sh` invariant 2 |
| 3 | `/agent/cwd` is not writable by the connectome uid; it holds only the `logs` and `mcpl-servers.json` symlinks | `image-test` (AC5.2 row), `smoke` AC5.2 |
| 4 | The only volume mounted in both containers is `outbox`, read-only in `connectome`; connectome binds are read-only; the shell has no binds | `lint.sh` invariant 4, `smoke` AC9.4 |
| 5 | No secret in any process's argv (`/proc/*/cmdline` is world-readable) | `smoke` AC5.8 (scans both containers once the MCP children run) |
| 6 | No onecli user API key in either container; `GATEWAY_ALLOW_PRIVATE_DESTINATIONS` never overlaps 172.16.0.0/12 (malformed entries fail); no `extra_hosts: host-gateway` | `lint.sh` invariant 6, `smoke` AC5.7 |
| 7 | `GATE_TELEMETRY` unset (`.env` keys, compose env, Dockerfile) | `lint.sh` invariant 7 |
| 8 | Discord DM/guild allowlists fixed in the recipe; no `DISCORD_FILTERS_FILE`; `filters_update`, `create_text_channel`, `delete_channel` disabled | `lint.sh` invariant 8, `smoke` AC7.3 |
| 9 | `OBSERVERS_FILE` (last assignment in the Dockerfile) is `/agent/recipes/observers.json` on the read-only recipes mount, not overridden | `lint.sh` invariant 9, `smoke` AC8.3 |
| 10 | The discord-mcpl attachment patch is applied: attachments outside `DISCORD_ATTACHMENT_ROOT`, `/proc/*`, symlinks out of the root and FIFOs are refused | In-build `attachment-root` tests (Dockerfile, `--test-timeout`), `image-test` AC7.5 row |

`dotfiles stacks connectome lint-test` proves each lint fails on a fixture
that violates exactly its invariant (34 fixtures, including the
sub-conditions above).

## Known exposures (accepted)

- **WebUI is basic-auth only.** It listens on 18768 inside `connectome`,
  published on `127.0.0.1:18768` and served on the tailnet by Tailscale serve
  (port 8768). Credentials are `WEBUI_USER` / `WEBUI_PASS` (64 hex chars) from
  `.env`. The `shell` container can reach it over the `connectome` network
  and also gets 401 without credentials (`smoke` AC8.2).
- **LAN and tailnet reachability.** `onecli-agents` is not internal, so both
  containers have direct egress through the VM's NAT, outside the gateway. The
  spike reached the router admin, AdGuard, the homebridge UI, this Mac's
  tailnet IP and other tailnet peers. The gateway's private-destination
  refusal only covers proxied traffic. Intended for now; lockdown is future
  work.
- **onecli path-rule bypass with the host token.** The gateway matches rules
  on the raw path: `GET /backend-api/codex/../me` (or `%2e%2e`) passes rule 2,
  chatgpt.com normalises it and answers with credentials injected. Policy
  globs can't close this; the real boundary is that only `connectome` holds
  the host `aoc_` token and it has no generic HTTP tool. The shell token is
  refused on `chatgpt.com` regardless (`probe` AC3.4). To report upstream.
- **Same trust domain for fleet children.** Future persona children are
  spawned with the host's entire environment (including the host `aoc_`
  token) until they get their own tokens via `children[].env`.
- **Fresh-device patches are manual.** `sources.lock` records patch subjects,
  not diffs; keep a copy of the `~/Developer/connectome` clones.
- **Same UID on the Mac.** Anything running as your user can read
  `stacks/*/.env` and the host onecli CLI's operator API key, which together
  open the vault. Same-UID compromise is vault compromise (see
  `stacks/onecli/README.md`, Threat model).

## Future: persona fleet children

Not built yet; the seams kept for it:

- Each persona is an explicit `modules.fleet.children[]` entry (lint
  invariant 2 rejects `fleet: true`) with its own tracked recipe under
  `/agent/recipes`, its own `dataDir` under `/agent/state/data/children/<name>`
  (the entrypoint already clears stale `ipc.sock`/`headless.pid` there), and
  its own Discord bot token and onecli `aoc_` token passed via
  `children[].env` (runtime-only at the pinned connectome-host commit).
- One `shell` daemon means personas would share one shell identity and see
  each other's term-sessions; add a `shell-<name>` container per persona once
  personas get distinct trust or credentials.
- Fleet children are distinct from `modules.subagents` (ephemeral, in-process,
  same identity; see Subagents).

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

A model or provider swap means a new session (a fresh `DATA_DIR`), not editing
`LLM_MODEL` under a live one: the chronicle's encrypted reasoning items are
model-bound. There is no recipe for it; the one manual step below moves the
old session aside inside the `state` volume (reversible), keeping the Codex
stub, heartbeat and Discord state. No rebuild is needed.

```sh
dotfiles stacks connectome backup        # restore point
$EDITOR stacks/connectome/.env           # change LLM_MODEL (and LLM_PROVIDER)
dotfiles stacks connectome down
docker --context colima-agents run --rm -v connectome_state:/s alpine \
    sh -c 'mv /s/data "/s/data.before-$(date +%Y%m%d)"'
dotfiles stacks connectome up            # entrypoint recreates data/
```

To go back: `down`, move the saved directory back to `data`, restore the old
`LLM_MODEL`, `up` (or `restore` the backup onto empty volumes).
