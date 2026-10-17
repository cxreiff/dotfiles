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

Phase 4 adds the architecture, provisioning, security invariants, threat model
and operations sections.
