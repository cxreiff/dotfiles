# Connectome Agent Implementation Plan — Phase 3 of 4 (design Phase 2: `stacks/connectome`)

**Goal:** Run one connectome agent as a two-container stack (`connectome` host and `shell`) in the `agents` VM. Discord is the chat surface and heartbeat runs at 4 h. The model is the ChatGPT subscription through the onecli gateway, and no real model credential is in either container. Finally, calibrate the usage caps.

**Architecture:** A new stack `stacks/connectome/` (compose, justfile, scripts, read-only recipe mount). Images are built locally from local clones under `~/Developer/connectome/` at recorded SHAs (`sources.lock`); local patches are commits on a `local` branch in each clone. Both containers sit on `onecli-agents` (gateway plus direct egress) and a private `connectome` network. The only shared volume is `outbox` (read-only in the host).

**Tech Stack:** Docker Compose (`--context colima-agents`), `oven/bun:1-debian` + real Node 22 (copied from `node:22-bookworm`), connectome-host (Bun/TypeScript), discord-mcpl + voice-kit, heartbeat-mcpl, `term-sessions-mcp@1.6.0` (npm), OpenAI Codex CLI 0.162.1 (`codex-aarch64-unknown-linux-musl`), `mcr.microsoft.com/devcontainers/typescript-node:22-bookworm`, rustup, uv, gh, Tailscale serve.

**Scope:** 4 phases from original design (design Phases 0–3). This file covers design Phase 2. Numbering: `phase_03` = design Phase 2.

**Codebase verified:** 2026-10-14

**Execution context (applies to every command in this phase):**
- Work happens in the worktree `/Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent` (branch `connectome-agent`); relative paths are relative to it.
- The interactive `dotfiles` alias points at the **main** checkout (`~/Developer/dotfiles`, still on `main`), so it would run the old recipes. Wherever this plan writes `dotfiles …`, run it against the worktree. Shell state doesn't persist between commands, so define it in each command: `dotfiles() { just -f /Users/cxreiff/Developer/dotfiles/.worktrees/connectome-agent/justfile "$@"; }`.
- **`.env` files are gitignored and exist only in the main checkout.** Phase 2 Task 1 Step 0b copies them into the worktree (`install -m 600`, real copies; no symlinks, because `init-env` `mv`s over the path and doctor's `stat` would report the link). New secrets (onecli v2 keys, `stacks/connectome/.env`) are created in the worktree and copied back to main in Phase 4 Task 8 Step 0. Until then the worktree holds the only on-disk copy of the new secrets, so **never remove the worktree before that step**.
- The nightly backup LaunchDaemon is **paused** (`disable`d + booted out in Phase 2 Task 1) until the branch is merged at the end of Phase 4. It would otherwise run main's onecli v1 recipes against the v2 stack. When a doctor backup-age check needs fresh tarballs:
  - back up **onecli and connectome** with the worktree recipes;
  - back up the **unchanged stacks** (adguard, freshrss, homebridge, wallabag) with main's justfile, e.g. `just -f ~/Developer/dotfiles/justfile stacks freshrss backup`. Their recipes are identical, and main holds their `.env`.
- **Residual risk (accepted):** an *unplanned* reboot during execution makes the startup daemon run main's `up-all`, including main's v1 `onecli up`. If that happens, after the FileVault unlock immediately run `docker --context colima-agents rm -f onecli` (the v1 container name), then the worktree's `dotfiles stacks onecli up`, and confirm the backup daemon is still disabled (`sudo launchctl print-disabled system | grep com.cxreiff.dotfiles.backup`; it was `disable`d, which persists across reboots). Avoid planned reboots until Phase 4 Task 8.

**Verified facts this phase relies on:**
- `stacks/connectome/` does not exist. No stack uses a `build:` context today (freshrss has one commented out).
- `.gitignore` already ignores `.env`, `*.env`, `*.pem`, `*.key` and allowlists `*.env.example`. It does not ignore the build staging dir, so this phase adds those entries.
- Clones in `~/Developer/connectome/`: `connectome-host` (`0c86e8e`, `main`, clean; `406dcc1` **is** an ancestor), `discord-mcpl` (`f7e6b1f`), `voice-kit` (`46fcb66`), `heartbeat-mcpl` (`fef2d99`). All are on `main`, clean, with no `local` branch, and every remote is `https://github.com/anima-research/<name>`. Each has `bun.lock` and `package-lock.json`. `connectome-host/web/` exists, and its `postinstall` builds the WebUI to `dist/web/` **and swallows failure** (`… || echo …`).
- connectome-host:
  - Entry is `bun src/index.ts <recipe> --headless`. `DATA_DIR` comes from env (default `./data`). `headless.log`, `headless.pid`, `ipc.sock` and `.recipe.json` live in `$DATA_DIR`. `logs/failures.log` is CWD-relative.
  - `CODEX_BINARY` (default `codex` on PATH) and `CODEX_HOME` are read in `src/codex-subscription-adapter.ts:90-92`; it spawns `codex app-server --listen stdio:// -c cli_auth_credentials_store="file"`.
  - `OBSERVERS_FILE` overrides `$DATA_DIR/observers.json`, with file shape `{"observers":[…]}`.
  - Recipe shape: `{name, agent:{name, provider, model, systemPrompt, …}, mcpServers:{<id>:{command,args,env,disabledTools,enabledFeatureSets,…}}, modules:{wake, workspace, webui, …}}`. `${VAR}` (required) and `${VAR:-default}` are substituted from process env across the whole tree.
  - `mcpl-servers.json` (CWD) has shape `{"mcplServers":{…}}` and is merged with recipe `mcpServers`. The overlay `mcpl-servers.agent.json` is CWD-relative.
  - The WebUI static root defaults to `<package-root>/dist/web`.
  - MCP child env = explicit server `env` plus `AGENT_TIMEZONE` and `DISCORD_SUPPRESSED_REACTIONS_BASELINE` (`composeMcplChildEnv`), plus the proxy/CA vars agent-framework passes through.
- Wake policy schema (agent-framework 0.21.0 `dist/src/gate/types.d.ts`): `modules.wake = {policies:[{name, match:{scope?:string[], source?:string}, behavior:{rate_limit:{tokens, refillIntervalMs}} | "always" | "skip" | …}], default?}`. `source` is the MCP server id.
- discord-mcpl (`main`):
  - Entry is `dist/src/index.js`. It depends on `"@animalabs/voice-kit": "file:../voice-kit"`.
  - Env read: `DISCORD_TOKEN`, `DISCORD_GUILD_ID` (`guild:chan+chan`), `DISCORD_DM_USERS`, `DISCORD_ADMIN_USERS`, `DISCORD_FILTERS_FILE`, `DISCORD_WATERMARK_FILE`, `DISCORD_DM_NOTICES_FILE`, `DISCORD_MUTED_CHANNELS_FILE`, `DISCORD_VOICE_CHANNEL_ID`, among others.
  - Tools include `send_message`, `reply_message`, `send_dm`, `fetch_history`, `filters_update`, `create_text_channel`, `delete_channel`.
  - The attachment check is `buildAttachments()` at `src/discord-adapter.ts:72-90` (`existsSync && statSync().isFile()`, then `new AttachmentBuilder(f.path)`), called at lines 902 and 1002, with `existsSync, statSync` imported at line 32.
  - Tests use `node --import tsx --test test/*.test.ts` (node:test + assert/strict).
- heartbeat-mcpl:
  - `MIN_REMINDER_SECONDS = 5` at `src/index.ts:43`. `parseEvery` (488-496) and `parseDelay` (500-508) **clamp** with `Math.max`, and `addReminder` (~510) consumes them.
  - Env: `HEARTBEAT_CONFIG_FILE`, `HEARTBEAT_REMINDERS_FILE`. Entry is `dist/src/index.js --stdio`.
  - Tools: `heartbeat_status`, `heartbeat_configure`, `heartbeat_trigger`, `reminder_add`, `reminder_list`, `reminder_cancel`.
- voice-kit: `npm run build` (tsc) → `dist/src/`.
- term-sessions-mcp 1.6.0 (unscoped npm package; repo `antra-tess/terminal-sessions-mcp`):
  - Bins: `session-server` (daemon; `--headless` or `HEADLESS=true`; host from `SESSION_SERVER_HOST` (default `localhost`), port from `SESSION_SERVER_PORT` (default 3100), auth from `SESSION_SERVER_TOKEN`) and `terminal-sessions-mcp` (`dist/src/mcp/mcp-stdio-server.js`, which connects to `ws://$SESSION_SERVER_HOST:$SESSION_SERVER_PORT` with `SESSION_SERVER_TOKEN`).
  - Deps include `node-pty` (native) and `puppeteer` (skip the download with `PUPPETEER_SKIP_DOWNLOAD=1`), plus `@modelcontextprotocol/sdk`.
- Codex release `rust-v0.162.1` has the asset `codex-aarch64-unknown-linux-musl.tar.gz` (binary `codex-aarch64-unknown-linux-musl` inside, per the design's spike).
- Agents VM mounts `$HOME` (rw) and `/var/folders` (ro) via virtiofs. Published ports bind VM-loopback and are forwarded to Mac `127.0.0.1` (same as onecli's 10256).
- Phase 2 delivered: `onecli-agents` network, `stacks/onecli/scripts/lib/api.sh` (`api`, `agent_field`, `operator_key`), agents `connectome-host`/`connectome-shell`, rule 1 provisional 60/hour, and `dotfiles stacks onecli policy <n>`.
- Freshrss `serve` pattern: `{{tailscale}} serve --bg --https={{serve_port}} http://localhost:{{internal_port}}` with `tailscale := "/opt/homebrew/bin/tailscale"`.

**Testing approach (follows repo practice; no test framework in this repo):**
- **Patch tests** live in the clones, use each clone's own runner (node:test via tsx), and also run inside the image build so a regression fails `build`.
- **Image build tests:** `stacks/connectome/scripts/image-test.sh` makes static assertions against the built images.
- **Stack smoke test:** `stacks/connectome/scripts/smoke.sh` makes read-only-plus-reversible assertions against the running stack.
- **Human verification:** Discord and WebUI checks, listed in Task 13.

**Operator involvement:** Discord bot creation (Task 6), `init-env` prompts (Task 7), Discord DMs (Task 13), ChatGPT per-app cap (Task 14).

---

## Acceptance Criteria Coverage

This phase implements and tests:

### connectome-agent.AC3: onecli identities and policy (Phases 1–2)
- **connectome-agent.AC3.7 Success:** rule 1's limit and the heartbeat wake `rate_limit` are set from the Phase 2 calibration. The per-app weekly ChatGPT cap is set, and the measurements and chosen values are recorded in `stacks/connectome/README.md`.

### connectome-agent.AC4: reproducible sources and images (Phase 2)
- **connectome-agent.AC4.1 Failure:** `build` refuses when any clone under `~/Developer/connectome/` has uncommitted changes, naming the clone.
- **connectome-agent.AC4.2 Success:** `build` writes `stacks/connectome/sources.lock` with each source's SHA (connectome-host at or after `406dcc1`), the pinned term-sessions-mcp version, and the subject of each local patch commit — no patch content.
- **connectome-agent.AC4.3 Success:** both images are `linux/arm64`, and their system trust stores contain the CA served by the running `onecli-gateway` (fingerprints equal).
- **connectome-agent.AC4.4 Success:** the `connectome` image runs a real Node (not the Bun symlink) for MCP servers, and includes the built WebUI and the pinned Codex CLI.
- **connectome-agent.AC4.5 Failure:** with the heartbeat-mcpl patch applied, creating a recurring reminder under 900 s is refused.

### connectome-agent.AC5: host container hardening and layout (Phase 2)
- **connectome-agent.AC5.1 Success:** `connectome` and `shell` both run as a non-root uid with `cap_drop: ALL` and `no-new-privileges`.
- **connectome-agent.AC5.2 Failure:** as the connectome uid, creating or modifying any file directly in `/agent/cwd`, including `mcpl-servers.agent.json`, fails. `/agent/cwd` contains only the `mcpl-servers.json` and `logs` symlinks (invariant 3).
- **connectome-agent.AC5.3 Failure:** writes under `/agent/recipes` fail (read-only mount).
- **connectome-agent.AC5.4 Success:** after a forced inference failure, `/agent/state/logs/failures.log` exists and is non-empty.
- **connectome-agent.AC5.5 Success:** on first start `/agent/state/heartbeat/config.json` is seeded with `{"intervalSeconds": 14400}`. After the agent calls `heartbeat_configure`, the file's content changes.
- **connectome-agent.AC5.6 Success:** with the gateway down, the entrypoint waits a bounded time for `gateway:10255`, then exits non-zero with a clear message. Stale `ipc.sock`/`headless.pid` files under child `dataDir`s are deleted at start.
- **connectome-agent.AC5.7 Failure:** no onecli user API key is present in either container's environment or filesystem (invariant 6).
- **connectome-agent.AC5.8 Failure:** no secret (Discord token, WebUI password, `aoc_` tokens, `SESSION_SERVER_TOKEN`) appears in any process's `/proc/*/cmdline` in either container (invariant 5).

### connectome-agent.AC6: model path through onecli (Phase 2)
- **connectome-agent.AC6.1 Success:** `provision-codex` writes `codex/auth.json` into the `state` volume: host uid, mode 0600, `tokens.account_id` = the real ChatGPT account id, and no real access or refresh token. It also writes `codex/config.toml` from the tracked template.
- **connectome-agent.AC6.2 Success:** an inference via the `openai-codex` provider with `LLM_MODEL` from `.env` returns a reply, and the gateway log shows the request on the host identity.
- **connectome-agent.AC6.3 Success:** connectome start-up produces no `blocked_by_policy` responses in the gateway log (apps, plugins, analytics and otel are off).
- **connectome-agent.AC6.4 Success:** the WebUI quota meter shows usage, read from `wham/usage`.

### connectome-agent.AC7: Discord connector (Phase 2)
- **connectome-agent.AC7.1 Success:** a DM from the operator's Discord user gets an agent reply, and a message in the whitelisted guild channel is received.
- **connectome-agent.AC7.2 Failure:** a DM from any other user, and a message from a non-whitelisted guild, produce no inference and no reply.
- **connectome-agent.AC7.3 Failure:** `filters_update`, `create_text_channel` and `delete_channel` are not in the agent's tool list. No `DISCORD_FILTERS_FILE` is set (invariant 8).
- **connectome-agent.AC7.4 Success:** a regular file staged in `/workspace/outbox` is sent as a Discord attachment.
- **connectome-agent.AC7.5 Failure:** `send_message` with `files: [{path: "/proc/self/environ"}]` is refused. So is a symlink in the outbox pointing outside it, and, with `DISCORD_ATTACHMENT_ROOT` unset, every attachment (invariant 10).
- **connectome-agent.AC7.6 Success:** watermark, DM-notice and muted-channel state files live under `/agent/state/discord/` and survive a container restart.

### connectome-agent.AC8: WebUI (Phase 2)
- **connectome-agent.AC8.1 Success:** the WebUI is published only on `127.0.0.1:18768` in the VM, and `dotfiles stacks connectome serve` makes it reachable at `https://cxmini.faun-fir.ts.net:8768` with working live (WebSocket) updates.
- **connectome-agent.AC8.2 Failure:** a request without valid basic-auth credentials gets 401, including from the `shell` container.
- **connectome-agent.AC8.3 Failure:** an `observers--grant` call fails, and `observers.json` stays `{"observers":[]}` (invariant 9).

### connectome-agent.AC9: shell container (Phase 2)
- **connectome-agent.AC9.1 Success:** `shell` provides node, tsc, cargo/rustc, python3, pip, uv, rg, fd, jq, git, gh and build-essential, running natively on arm64.
- **connectome-agent.AC9.2 Failure:** `sudo` in `shell` cannot gain root.
- **connectome-agent.AC9.3 Success:** the agent runs a command in `shell` through term-sessions and sees its output, and `git clone` of a public HTTPS repo through the gateway succeeds (CA trust works).
- **connectome-agent.AC9.4 Failure:** `shell` cannot read the `state` volume. `outbox` is the only volume mounted in both containers, and it is `:ro` in `connectome` (invariant 4).
- **connectome-agent.AC9.5 Success:** files the agent creates in `/workspace` persist across a `shell` restart.

### connectome-agent.AC10: heartbeat and usage caps (Phase 2)
- **connectome-agent.AC10.1 Success:** heartbeat ticks reach the agent: `modules.wake.policies` has a `rate_limit` rule for `source: "heartbeat"` before any skip rule, and `enabledFeatureSets` includes `heartbeat`.
- **connectome-agent.AC10.2 Failure:** a burst of heartbeat events beyond the wake `rate_limit` tokens is dropped without inference.
- **connectome-agent.AC10.3 Failure:** once rule 1's limit is exhausted within its window, further `responses` POSTs through the gateway are refused.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: heartbeat-mcpl local patch — 900 s reminder floor, refused not clamped

**Verifies:** connectome-agent.AC4.5

**Files (in the clone `~/Developer/connectome/heartbeat-mcpl`, not this repo):**
- Create: `src/reminder-floor.ts`
- Modify: `src/index.ts:43` (constant), `src/index.ts:488-508` (`parseEvery`/`parseDelay` stop clamping), `src/index.ts:~515` (`addReminder` refuses below floor)
- Test: `test/reminder-floor.test.ts` (unit, node:test)

**Step 1: Branch**

```bash
cd ~/Developer/connectome/heartbeat-mcpl && git switch -c local
```

**Step 2: Implementation**

`src/reminder-floor.ts`:

```ts
/**
 * Local patch (dotfiles connectome stack): every reminder fire is an
 * inference, so reminders are floored at 15 minutes and requests below the
 * floor are REFUSED (not silently clamped). Applies to recurring intervals
 * and relative one-shot delays; absolute `atIso` times are not affected.
 */
export const MIN_REMINDER_SECONDS = 900;

export function reminderFloorError(
  everySeconds: number | null,
  delaySeconds: number | null,
): string | null {
  if (everySeconds !== null && everySeconds < MIN_REMINDER_SECONDS) {
    return `reminder_add: recurring interval ${everySeconds}s is below the ${MIN_REMINDER_SECONDS}s (15 min) floor; refused.`;
  }
  if (delaySeconds !== null && delaySeconds < MIN_REMINDER_SECONDS) {
    return `reminder_add: delay ${delaySeconds}s is below the ${MIN_REMINDER_SECONDS}s (15 min) floor; refused. Use atIso for an exact time.`;
  }
  return null;
}
```

In `src/index.ts`:
- Replace `const MIN_REMINDER_SECONDS = 5;` (line 43) with `import { MIN_REMINDER_SECONDS, reminderFloorError } from './reminder-floor.js';`. Put the import with the other imports at the top of the file, delete line 43, and keep any remaining references to `MIN_REMINDER_SECONDS` (e.g. the comment near line 487 and tool descriptions) consistent with 900.
- In `parseEvery` and `parseDelay`, change `return Math.max(MIN_REMINDER_SECONDS, Math.round(s));` to `return Math.round(s);`.
- In `addReminder`, immediately after `const delay = this.parseDelay(args);`, add:

```ts
    const floorError = reminderFloorError(everySeconds, delay);
    if (floorError) return this.text(floorError, true);
```

**Testing:** `test/reminder-floor.test.ts` (node:test + `node:assert/strict`, same style as the repo's other `test/*.test.ts`) must cover:
- AC4.5: `reminderFloorError(899, null)` returns a refusal string, and `reminderFloorError(60, null)` refuses too.
- `reminderFloorError(900, null)` and `reminderFloorError(3600, 900)` return `null`.
- A one-shot `reminderFloorError(null, 300)` refuses, and `reminderFloorError(null, null)` returns `null` (the atIso path).

**Step 3: Run**

```bash
cd ~/Developer/connectome/heartbeat-mcpl
npm ci && npm run build && node --import tsx --test test/reminder-floor.test.ts test/timezone.test.ts test/policy.test.ts test/silent-delivery.test.ts
```

Expected: all tests pass, and `tsc` builds without error. Upstream's `npm test` also runs `test/reminders.harness.mjs`, which needs a sibling `mcpl-harness` checkout (not present) and uses 5–8 s reminders that the 900 s floor now refuses. Don't run it; the build stage only runs `reminder-floor.test.ts`. Add a line to the patch commit body: "reminders.harness.mjs uses sub-floor delays; not run in this deployment".

**Step 4: Commit in the clone (this subject is recorded in `sources.lock`)**

```bash
git add src/reminder-floor.ts src/index.ts test/reminder-floor.test.ts
git commit -m "local: refuse reminders below a 900 s floor" \
  -m "reminders.harness.mjs uses sub-floor delays; not run in this deployment"
git status --porcelain   # must be empty (dist/ and node_modules/ are gitignored)
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: discord-mcpl local patch — attachments confined to `DISCORD_ATTACHMENT_ROOT`

**Verifies:** connectome-agent.AC7.5 (unit level; live in Task 13)

**Files (in the clone `~/Developer/connectome/discord-mcpl`):**
- Create: `src/attachment-guard.ts`
- Modify: `src/discord-adapter.ts:32` (imports), `src/discord-adapter.ts:72-90` (`buildAttachments`)
- Test: `test/attachment-root.test.ts` (unit, node:test; **Linux-only**, run in a container)

**Step 1: Branch**

```bash
cd ~/Developer/connectome/discord-mcpl && git switch -c local
```

**Step 2: Implementation — `src/attachment-guard.ts`:**

```ts
/**
 * Local patch (dotfiles connectome stack): outgoing attachments may only come
 * from DISCORD_ATTACHMENT_ROOT (the agent's outbox). Upstream only checked
 * existsSync && isFile, so any host file — including /proc/<pid>/environ —
 * could be uploaded.
 *
 * The check is done on the OPENED fd, not the path: the file is opened, its
 * fd is fstat'ed (must be a regular file) and its kernel-resolved target
 * (/proc/self/fd/N) must lie inside the realpath of the root. The upload uses
 * the buffer read from that same fd, so symlinks out of the root, /proc/*,
 * and check-then-swap races are all refused. Unset root => every attachment
 * is refused. Requires Linux /proc (fails closed elsewhere).
 */
import { closeSync, fstatSync, openSync, readFileSync, readlinkSync, realpathSync, constants } from 'node:fs';
import { basename } from 'node:path';

export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;

export interface LoadedAttachment {
  buffer: Buffer;
  name: string;
}

export function loadAttachment(
  path: string,
  root: string | undefined = process.env.DISCORD_ATTACHMENT_ROOT,
): LoadedAttachment {
  if (!root || !root.trim()) {
    throw new Error('Attachments are disabled (DISCORD_ATTACHMENT_ROOT is not set)');
  }
  let rootReal: string;
  try {
    rootReal = realpathSync(root);
  } catch {
    throw new Error(`Attachment root does not exist: ${root}`);
  }
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
  } catch {
    throw new Error(`File not found or not readable: ${path}`);
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) throw new Error(`Not a regular file: ${path}`);
    let target: string;
    try {
      target = readlinkSync(`/proc/self/fd/${fd}`);
    } catch {
      throw new Error('Cannot verify attachment location (no /proc); refusing');
    }
    if (target !== rootReal && !target.startsWith(rootReal + '/')) {
      throw new Error(`Attachment must be inside ${root}: ${path}`);
    }
    if (st.size > MAX_ATTACHMENT_BYTES) {
      throw new Error(`Attachment too large (${st.size} bytes > ${MAX_ATTACHMENT_BYTES}): ${path}`);
    }
    return { buffer: readFileSync(fd), name: basename(target) };
  } finally {
    closeSync(fd);
  }
}
```

`O_NONBLOCK` keeps `open()` from hanging on a FIFO planted in the outbox. FIFOs are then refused by the `isFile()` check.

**`src/discord-adapter.ts`:**
- Line 32: drop `existsSync, statSync` from the `node:fs` import if nothing else in the file uses them (`grep -n 'existsSync\|statSync' src/discord-adapter.ts` after the edit; keep whichever is still referenced). Add `import { loadAttachment } from './attachment-guard.js';`.
- In `buildAttachments` (lines 79-89), replace the `existsSync`/`statSync` check and `new AttachmentBuilder(f.path, { name })` with:

```ts
      const loaded = loadAttachment(f.path);
      const name = f.name && f.name.trim() ? f.name : loaded.name;
      const attachment = new AttachmentBuilder(loaded.buffer, { name });
```

(keep the existing non-empty `path` check and the `setDescription` line).

**Testing — `test/attachment-root.test.ts`** (node:test + assert/strict, same structure as `test/attachment-inline-cap.test.ts`; create a temp root with `mkdtempSync` in `before`, remove it in `after`). Each case asserts on `loadAttachment(...)`:
- Root unset (`loadAttachment(p, undefined)` with `DISCORD_ATTACHMENT_ROOT` deleted) → throws `/disabled/`.
- Regular file inside root → returns a buffer equal to the written bytes and the name of the file.
- `/proc/self/environ` with root set → throws (`/inside/` or `/regular/`).
- Symlink inside root pointing to a file outside root → throws `/inside/`.
- `root/../<outside-file>` path traversal → throws `/inside/`.
- Directory inside root → throws `/regular file/`.
- FIFO inside root (`execFileSync('mkfifo', [p])`) → throws without hanging.

**Step 3: Run the tests inside Linux (macOS has no `/proc/self/fd` links)**

```bash
docker --context colima-agents run --rm -v ~/Developer/connectome:/src -w /src/discord-mcpl node:22-bookworm \
  sh -c 'cd ../voice-kit && npm ci --silent && npm run build --silent && cd ../discord-mcpl && npm ci --silent && npm run build && node --import tsx --test test/attachment-root.test.ts test/attachment-inline-cap.test.ts'
```

Expected: all tests pass, including the existing inline-cap test, and `tsc` has no errors. This writes `node_modules/`/`dist/` into the clones (gitignored). Confirm `git -C ~/Developer/connectome/voice-kit status --porcelain` is empty as well.

**Step 4: Commit in the clone**

```bash
cd ~/Developer/connectome/discord-mcpl
git add src/attachment-guard.ts src/discord-adapter.ts test/attachment-root.test.ts
git commit -m "local: confine attachments to DISCORD_ATTACHMENT_ROOT (fd-verified)"
git status --porcelain   # empty
```

Also propose this upstream later (decision 21). That's out of scope here; note it in the README in Task 14.
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: Tracked recipe files (read-only mount `/agent/recipes`)

**Verifies:** connectome-agent.AC10.1, connectome-agent.AC7.3 (static), connectome-agent.AC8.3 (static)

**Files:**
- Create: `stacks/connectome/recipes/agent.json`
- Create: `stacks/connectome/recipes/mcpl-servers.json`
- Create: `stacks/connectome/recipes/observers.json`
- Create: `stacks/connectome/recipes/codex-config.toml`

**`recipes/agent.json`** (all `${VAR}`s resolve from the `connectome` container env; `.recipe.json` in `DATA_DIR` keeps them unresolved):

```json
{
  "name": "connectome",
  "description": "cxmini Discord agent (dotfiles stacks/connectome). Shell work happens in the separate `shell` container via term-sessions.",
  "agent": {
    "name": "cx",
    "provider": "${LLM_PROVIDER:-openai-codex}",
    "model": "${LLM_MODEL}",
    "systemPrompt": "You are cx, a helpful assistant reachable over Discord. You have a Linux shell (separate container, reached through the terminal-session tools) with a persistent /workspace. To send a file on Discord, write it under /workspace/outbox in the shell and attach it by its path under /agent/outbox (same file, read-only view). You cannot read or change your own configuration files."
  },
  "mcpServers": {
    "discord": {
      "command": "/opt/node/bin/node",
      "args": ["/opt/mcpl/discord-mcpl/dist/src/index.js"],
      "env": {
        "DISCORD_TOKEN": "${DISCORD_TOKEN}",
        "DISCORD_GUILD_ID": "${DISCORD_GUILD_ID}",
        "DISCORD_DM_USERS": "${DISCORD_OPERATOR_ID}",
        "DISCORD_ADMIN_USERS": "${DISCORD_OPERATOR_ID}",
        "DISCORD_WATERMARK_FILE": "/agent/state/discord/watermark.json",
        "DISCORD_DM_NOTICES_FILE": "/agent/state/discord/dm-notices.json",
        "DISCORD_MUTED_CHANNELS_FILE": "/agent/state/discord/muted-channels.json",
        "DISCORD_ATTACHMENT_ROOT": "/agent/outbox"
      },
      "disabledTools": ["filters_update", "create_text_channel", "delete_channel"]
    },
    "heartbeat": {
      "command": "/opt/node/bin/node",
      "args": ["/opt/mcpl/heartbeat-mcpl/dist/src/index.js", "--stdio"],
      "env": {
        "HEARTBEAT_CONFIG_FILE": "/agent/state/heartbeat/config.json",
        "HEARTBEAT_REMINDERS_FILE": "/agent/state/heartbeat/reminders.json"
      },
      "enabledFeatureSets": ["heartbeat"]
    },
    "shell": {
      "command": "/opt/node/bin/node",
      "args": ["/opt/mcpl/term-sessions/node_modules/term-sessions-mcp/dist/src/mcp/mcp-stdio-server.js"],
      "env": {
        "SESSION_SERVER_HOST": "shell",
        "SESSION_SERVER_PORT": "3100",
        "SESSION_SERVER_TOKEN": "${SESSION_SERVER_TOKEN}"
      }
    }
  },
  "modules": {
    "workspace": false,
    "wake": {
      "policies": [
        {
          "name": "heartbeat-rate-limit",
          "match": { "scope": ["mcpl:push-event"], "source": "heartbeat" },
          "behavior": { "rate_limit": { "tokens": 6, "refillIntervalMs": 600000 } }
        }
      ]
    },
    "webui": {
      "port": 18768,
      "host": "0.0.0.0",
      "basicAuth": { "username": "${WEBUI_USER}", "password": "${WEBUI_PASS}" },
      "allowedOrigins": ["https://cxmini.faun-fir.ts.net:8768"],
      "observersSurface": "utilities"
    }
  }
}
```

There is deliberately no `codeExecution`, `extensions`, `modules.mcplAdmin` or `modules.fleet` (invariants 1–2), and no `DISCORD_FILTERS_FILE` (invariant 8). The heartbeat rate-limit is the first and only wake policy, so no skip rule can precede it (AC10.1).

**`recipes/mcpl-servers.json`:** `{"mcplServers":{}}` (servers live in the recipe; this file exists so the CWD symlink target is tracked and empty).

**`recipes/observers.json`:** `{"observers":[]}`

**`recipes/codex-config.toml`:**

```toml
# Codex app-server config for the connectome container (copied into
# CODEX_HOME by `dotfiles stacks connectome provision-codex`). Turning these
# off avoids start-up calls (/backend-api/ps/…, ab.chatgpt.com) that onecli
# rule 6 would block.
[features]
apps = false
plugins = false

[analytics]
enabled = false

[otel]
metrics_exporter = "none"
```

**Verification (static):**

```bash
cd stacks/connectome/recipes
jq -e '.modules.wake.policies[0] | .behavior.rate_limit and .match.source=="heartbeat"' agent.json
jq -e '.mcpServers.heartbeat.enabledFeatureSets | index("heartbeat")' agent.json
jq -e '.mcpServers.discord.disabledTools | (index("filters_update") and index("create_text_channel") and index("delete_channel"))' agent.json
jq -e '(.mcpServers.discord.env | has("DISCORD_FILTERS_FILE") | not) and (.codeExecution==null) and (.extensions==null) and (.modules.mcplAdmin==null) and (.modules.fleet==null) and (.modules.workspace==false)' agent.json
jq -e '.observers==[]' observers.json && jq -e '.mcplServers=={}' mcpl-servers.json
cd - >/dev/null
```

Expected: every command prints a truthy value and exits 0.

**Commit:** `stacks/connectome: tracked recipe, mcpl-servers, observers, codex config`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Image definitions (Dockerfiles, entrypoint, MCP test helper)

**Verifies:** None directly (Task 7 builds; Task 8 tests).

**Files:**
- Create: `stacks/connectome/build/connectome.Dockerfile`
- Create: `stacks/connectome/build/shell.Dockerfile`
- Create: `stacks/connectome/build/entrypoint.sh` (0755)
- Create: `stacks/connectome/build/mcp-call.mjs`
- Modify: `.gitignore` (append staging entries)

**Step 1: Resolve and record version pins** (once; write the results into the ARG defaults below):

```bash
curl -fsSL -o /tmp/codex.tgz https://github.com/openai/codex/releases/download/rust-v0.162.1/codex-aarch64-unknown-linux-musl.tar.gz
shasum -a 256 /tmp/codex.tgz            # → CODEX_SHA256
tar -tzf /tmp/codex.tgz                 # expect: codex-aarch64-unknown-linux-musl
gh release view -R astral-sh/uv --json tagName -q .tagName            # → UV_VERSION (e.g. 0.x.y)
curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml | awk '/^\[pkg.rust\]/{f=1} f && /^version/{print; exit}'   # → RUST_TOOLCHAIN (x.y.z)
rm -f /tmp/codex.tgz
```

If the tarball's member name is not `codex-aarch64-unknown-linux-musl`, use the listed name in the `install` line below.

**Step 2: `build/connectome.Dockerfile`** (replace `<CODEX_SHA256>` with the value from Step 1):

```dockerfile
# syntax=docker/dockerfile:1
# connectome host image. Built by `dotfiles stacks connectome build` from the
# staged sources in ./src (git archives of the local clones at recorded SHAs).
# NEVER push this image to a public registry: connectome-host and
# discord-mcpl carry no license (all rights reserved).
ARG NODE_IMAGE=node:22-bookworm
ARG BUN_IMAGE=oven/bun:1-debian

FROM ${BUN_IMAGE} AS bun

FROM ${NODE_IMAGE} AS builder
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential python3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /src

# voice-kit first: discord-mcpl depends on it as file:../voice-kit.
COPY src/voice-kit ./voice-kit
RUN cd voice-kit && npm ci && npm run build

COPY src/discord-mcpl ./discord-mcpl
RUN cd discord-mcpl && npm ci && npm run build \
 && node --import tsx --test test/attachment-root.test.ts \
 && npm prune --omit=dev
RUN cd voice-kit && npm prune --omit=dev

COPY src/heartbeat-mcpl ./heartbeat-mcpl
RUN cd heartbeat-mcpl && npm ci && npm run build \
 && node --import tsx --test test/reminder-floor.test.ts \
 && npm prune --omit=dev

ARG TERM_SESSIONS_VERSION=1.6.0
RUN mkdir -p /opt/term-sessions && cd /opt/term-sessions \
 && npm init -y >/dev/null \
 && npm install --omit=dev "term-sessions-mcp@${TERM_SESSIONS_VERSION}"

COPY src/connectome-host ./connectome-host
# postinstall builds the WebUI into dist/web but swallows failures — assert it.
RUN cd connectome-host && bun install --frozen-lockfile && test -f dist/web/index.html

ARG CODEX_VERSION=0.162.1
ARG CODEX_SHA256=<CODEX_SHA256>
RUN curl -fsSL -o /tmp/codex.tgz \
      "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-aarch64-unknown-linux-musl.tar.gz" \
 && echo "${CODEX_SHA256}  /tmp/codex.tgz" | sha256sum -c - \
 && tar -xzf /tmp/codex.tgz -C /tmp \
 && install -m 0755 /tmp/codex-aarch64-unknown-linux-musl /usr/local/bin/codex \
 && rm -f /tmp/codex.tgz /tmp/codex-aarch64-unknown-linux-musl

FROM ${BUN_IMAGE}
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/*
# Real Node for MCP servers (in this image `node` on PATH is a Bun symlink).
COPY --from=builder /usr/local/bin/node /opt/node/bin/node
COPY --from=builder /usr/local/bin/codex /usr/local/bin/codex
COPY --from=builder /src/connectome-host /opt/connectome
COPY --from=builder /src/voice-kit /opt/mcpl/voice-kit
COPY --from=builder /src/discord-mcpl /opt/mcpl/discord-mcpl
COPY --from=builder /src/heartbeat-mcpl /opt/mcpl/heartbeat-mcpl
COPY --from=builder /opt/term-sessions /opt/mcpl/term-sessions
# Per-vault onecli gateway CA (copied out of onecli-gateway by `build`).
COPY gateway-ca.crt /usr/local/share/ca-certificates/onecli-gateway.crt
RUN update-ca-certificates
COPY entrypoint.sh /usr/local/bin/connectome-entrypoint
COPY mcp-call.mjs /opt/connectome-tests/mcp-call.mjs
# /agent/cwd: image-owned, not writable by the runtime uid. Its only entries
# are links to the tracked mcpl-servers.json and to persistent logs/, so
# mcpl-servers.agent.json can never be written (invariant 3).
RUN chmod 0755 /usr/local/bin/connectome-entrypoint \
 && mkdir -p /agent/cwd /agent/recipes /agent/state /agent/outbox \
 && ln -s /agent/recipes/mcpl-servers.json /agent/cwd/mcpl-servers.json \
 && ln -s /agent/state/logs /agent/cwd/logs \
 && chown root:root /agent/cwd && chmod 0755 /agent/cwd \
 && chown bun:bun /agent/state /agent/outbox && chmod 0700 /agent/state
ENV DATA_DIR=/agent/state/data \
    CODEX_HOME=/agent/state/codex \
    CODEX_BINARY=/usr/local/bin/codex \
    OBSERVERS_FILE=/agent/recipes/observers.json \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/onecli-gateway.crt \
    CODEX_CA_CERTIFICATE=/etc/ssl/certs/ca-certificates.crt \
    NO_PROXY=localhost,127.0.0.1,shell \
    no_proxy=localhost,127.0.0.1,shell
USER bun
WORKDIR /agent/cwd
ENTRYPOINT ["/usr/local/bin/connectome-entrypoint"]
```

`/agent/outbox` is chowned to `bun` (uid 1000) because a fresh named volume copies the ownership of the first image directory it is mounted over. In practice the `outbox` volume is first created by `provision-codex`'s `compose run connectome` (Task 9), so it takes this image's `bun` ownership. The `shell` image's `/workspace/outbox` is `node`-owned, and `node` is also uid 1000, so whichever image creates the volume first, the shell can write it. Task 8 verifies both uids are 1000.

**Step 3: `build/shell.Dockerfile`** (replace `<UV_VERSION>` and `<RUST_TOOLCHAIN>`):

```dockerfile
# syntax=docker/dockerfile:1
# connectome `shell` image — the agent's hands. Untrusted: holds only its own
# onecli token (HTTPS_PROXY) and the term-sessions daemon token.
ARG SHELL_BASE=mcr.microsoft.com/devcontainers/typescript-node:22-bookworm
ARG UV_VERSION=<UV_VERSION>

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${SHELL_BASE}
USER root
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv ripgrep fd-find jq build-essential ca-certificates curl gnupg \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=arm64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /uvx /usr/local/bin/
ARG TERM_SESSIONS_VERSION=1.6.0
RUN npm install -g --omit=dev "term-sessions-mcp@${TERM_SESSIONS_VERSION}"
COPY gateway-ca.crt /usr/local/share/ca-certificates/onecli-gateway.crt
RUN update-ca-certificates
# No sudo: remove the devcontainer's passwordless entry and the binary.
RUN rm -f /etc/sudoers.d/* \
 && apt-get purge -y sudo \
 && ! command -v sudo
RUN mkdir -p /workspace/outbox && chown -R node:node /workspace
USER node
ARG RUST_TOOLCHAIN=<RUST_TOOLCHAIN>
ENV RUSTUP_HOME=/home/node/.rustup \
    CARGO_HOME=/home/node/.cargo \
    PATH=/home/node/.cargo/bin:${PATH}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/onecli-gateway.crt \
    HEADLESS=true \
    SESSION_SERVER_HOST=0.0.0.0 \
    SESSION_SERVER_PORT=3100
WORKDIR /workspace
CMD ["session-server", "--headless"]
```

**Step 4: `build/entrypoint.sh`:**

```bash
#!/usr/bin/env bash
# connectome container entrypoint (runs as the image's non-root uid).
# 1. Prepare /agent/state layout (named volume, 0700).
# 2. Seed the heartbeat interval (4 h) — the recipe cannot set it.
# 3. Delete stale fleet IPC files: no child survives a container restart, and
#    a fresh PID namespace reuses small PIDs (fleet-protocol §4.3).
# 4. Refuse to start without the Codex stub (provision-codex).
# 5. Wait, bounded, for the onecli gateway — dockerd restarts containers in no
#    particular order at VM boot.
set -euo pipefail
log() { echo "[connectome-entrypoint] $*" >&2; }

state=/agent/state
umask 077
mkdir -p "$state/data/children" "$state/codex" "$state/logs" "$state/heartbeat" "$state/discord"

if [ ! -s "$state/heartbeat/config.json" ]; then
    printf '{"intervalSeconds": 14400}\n' > "$state/heartbeat/config.json"
    log "seeded heartbeat interval (14400 s)"
fi

find "$state/data" -maxdepth 3 \( -name ipc.sock -o -name headless.pid \) -print -delete \
    | sed 's/^/[connectome-entrypoint] removed stale /' >&2 || true

if [ ! -s "$state/codex/auth.json" ]; then
    log "no Codex stub at $state/codex/auth.json — run: dotfiles stacks connectome provision-codex"
    exit 3
fi

wait_s="${GATEWAY_WAIT_SECONDS:-120}"
deadline=$(( SECONDS + wait_s ))
until (exec 3<>/dev/tcp/gateway/10255) 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        log "onecli gateway (gateway:10255) unreachable after ${wait_s}s — start it with: dotfiles stacks onecli up"
        exit 4
    fi
    sleep 2
done
log "gateway reachable; starting connectome-host (logs: \$DATA_DIR/headless.log)"
exec bun /opt/connectome/src/index.ts /agent/recipes/agent.json --headless
```

**Step 5: `build/mcp-call.mjs`** — minimal stdio MCP client for image/smoke tests (uses the SDK that term-sessions-mcp already installs):

```js
// Usage: node mcp-call.mjs <tool> '<json-args>' -- <server-command> [args...]
// Spawns a stdio MCP server, calls one tool, prints {isError, text} as JSON.
// Server env: inherited from this process (pass vars with `env K=V node ...`).
const SDK = '/opt/mcpl/term-sessions/node_modules/@modelcontextprotocol/sdk/dist/esm';
const { Client } = await import(`${SDK}/client/index.js`);
const { StdioClientTransport } = await import(`${SDK}/client/stdio.js`);

const [tool, rawArgs, sep, command, ...args] = process.argv.slice(2);
if (!tool || sep !== '--' || !command) {
  console.error("usage: mcp-call.mjs <tool> '<json>' -- <cmd> [args...]");
  process.exit(2);
}
const transport = new StdioClientTransport({ command, args, env: { ...process.env }, stderr: 'ignore' });
const client = new Client({ name: 'connectome-test', version: '0.0.0' }, { capabilities: {} });
await client.connect(transport);
try {
  const res = await client.callTool({ name: tool, arguments: JSON.parse(rawArgs || '{}') });
  const text = (res.content ?? []).map((c) => c.text ?? '').join('\n');
  console.log(JSON.stringify({ isError: Boolean(res.isError), text }));
} finally {
  await client.close();
}
```

If the SDK's ESM dist path differs in the installed version, find it with `ls /opt/mcpl/term-sessions/node_modules/@modelcontextprotocol/sdk/dist` inside the built image and fix `SDK` (Task 8 runs this script).

**Step 6: `.gitignore`** — append:

```
# connectome build staging (git archives of local clones + per-vault CA)
stacks/connectome/build/src/
stacks/connectome/build/gateway-ca.crt
```

**Verification:**

```bash
bash -n stacks/connectome/build/entrypoint.sh && echo OK-entrypoint
grep -c '<CODEX_SHA256>\|<UV_VERSION>\|<RUST_TOOLCHAIN>' stacks/connectome/build/*.Dockerfile
```

Expected: `OK-entrypoint`, then `0` placeholders left in both Dockerfiles.

**Commit:** `stacks/connectome: host + shell Dockerfiles, entrypoint, MCP test helper`
<!-- END_TASK_4 -->

<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_5 -->
### Task 5: Discord bot application (operator, manual)

**Verifies:** None (prerequisite for AC7)

**Operator steps (Discord developer portal):**
1. Create a **new** application (not nanoclaw's) → Bot → reset token (keep it for Task 6's `init-env`, don't paste it anywhere else).
2. Enable **Message Content Intent** and **Server Members Intent** (privileged intents).
3. OAuth2 URL generator: scope `bot`, permissions *View Channels, Send Messages, Read Message History, Attach Files, Add Reactions, Send Messages in Threads*. Invite the bot to the chosen guild.
4. Note the guild id and the one channel id to whitelist (`<guild>:<channel>`), and the operator's own Discord user id (Developer Mode → Copy User ID).

**Verification:** the bot appears offline in the guild member list.

**Commit:** none.
<!-- END_TASK_5 -->

<!-- START_SUBCOMPONENT_C (tasks 6-8) -->
<!-- START_TASK_6 -->
### Task 6: `compose.yaml`, `.env.example`, `init-env`

**Verifies:** connectome-agent.AC5.1, connectome-agent.AC9.4 (compose level), connectome-agent.AC8.1 (publish address)

**Files:**
- Create: `stacks/connectome/compose.yaml`
- Create: `stacks/connectome/.env.example`
- Create: `stacks/connectome/scripts/init-env.sh` (0755)
- Create: `stacks/connectome/justfile` (initial; extended in Tasks 7, 9–11, 14 and Phase 4)
- Modify: `stacks/justfile:1-5` (add `mod connectome` so `dotfiles stacks connectome …` resolves; the aggregate recipes change in Phase 4)

`compose build` and `compose run` interpolate the whole file, so `.env` must be complete (this task) before the first `build` (Task 7).

**`compose.yaml`:** no `env_file` anywhere. Each container receives only the variables listed, so the shell never sees the Discord token, WebUI password or host token.

```yaml
name: connectome

# connectome agent (decisions in docs/design-plans/2026-10-11-connectome-agent.md).
# Two containers in the agents VM:
#   connectome — trusted host (connectome-host + MCPL servers), holds the
#                Discord token, WebUI credentials, its own onecli aoc_ token
#                (HTTPS_PROXY) and the Codex stub (no real credential).
#   shell      — untrusted: the agent's hands (term-sessions daemon). Holds
#                only its own onecli token and the daemon token.
# The ONLY volume mounted in both is `outbox`, read-only in connectome.
# No env_file: each service gets exactly the variables listed (values from
# .env via interpolation).

x-hardening: &hardening
  platform: linux/arm64
  restart: unless-stopped
  cap_drop:
    - ALL
  security_opt:
    - no-new-privileges:true

services:
  shell:
    <<: *hardening
    build:
      context: ./build
      dockerfile: shell.Dockerfile
    image: connectome-shell:local
    container_name: connectome-shell
    hostname: shell
    environment:
      SESSION_SERVER_TOKEN: ${SESSION_SERVER_TOKEN:?run dotfiles stacks connectome init-env}
      HTTPS_PROXY: http://x:${SHELL_ONECLI_TOKEN:?run dotfiles stacks connectome init-env}@gateway:10255
      https_proxy: http://x:${SHELL_ONECLI_TOKEN}@gateway:10255
      NO_PROXY: localhost,127.0.0.1
      no_proxy: localhost,127.0.0.1
    volumes:
      - workspace:/workspace
      - outbox:/workspace/outbox
    networks:
      - onecli-agents
      - connectome

  connectome:
    <<: *hardening
    build:
      context: ./build
      dockerfile: connectome.Dockerfile
    image: connectome-host:local
    container_name: connectome
    depends_on:
      shell:
        condition: service_started
    environment:
      LLM_PROVIDER: ${LLM_PROVIDER:-openai-codex}
      LLM_MODEL: ${LLM_MODEL:?run dotfiles stacks connectome init-env}
      DISCORD_TOKEN: ${DISCORD_TOKEN:?run dotfiles stacks connectome init-env}
      DISCORD_GUILD_ID: ${DISCORD_GUILD_ID:?run dotfiles stacks connectome init-env}
      DISCORD_OPERATOR_ID: ${DISCORD_OPERATOR_ID:?run dotfiles stacks connectome init-env}
      WEBUI_USER: ${WEBUI_USER:?run dotfiles stacks connectome init-env}
      WEBUI_PASS: ${WEBUI_PASS:?run dotfiles stacks connectome init-env}
      SESSION_SERVER_TOKEN: ${SESSION_SERVER_TOKEN:?run dotfiles stacks connectome init-env}
      HTTPS_PROXY: http://x:${HOST_ONECLI_TOKEN:?run dotfiles stacks connectome init-env}@gateway:10255
      https_proxy: http://x:${HOST_ONECLI_TOKEN}@gateway:10255
      GATEWAY_WAIT_SECONDS: ${GATEWAY_WAIT_SECONDS:-120}
    ports:
      - "127.0.0.1:18768:18768"
    volumes:
      - state:/agent/state
      - outbox:/agent/outbox:ro
      - ./recipes:/agent/recipes:ro
    networks:
      - onecli-agents
      - connectome

volumes:
  state:
  workspace:
  outbox:

networks:
  onecli-agents:
    external: true
  connectome:
    driver: bridge
```

**`.env.example`:**

```
# connectome — create with `dotfiles stacks connectome init-env` (mode 0600).
# Never add a onecli USER API key here (invariant 6); only agent aoc_ tokens.

# Model (subscription mode needs an id starting gpt- or containing codex).
# A model or provider swap means a new DATA_DIR / session, not a flip on a
# live chronicle. LLM_PROVIDER is optional (default openai-codex); it is the
# seam for switching providers later (e.g. anthropic via an onecli API-key
# secret — never Claude subscription OAuth).
# LLM_PROVIDER=openai-codex
LLM_MODEL=

# Discord (own bot application — not nanoclaw's)
DISCORD_TOKEN=
# guild:channel whitelist, e.g. 123456789012345678:234567890123456789
DISCORD_GUILD_ID=
# operator's Discord user id (DM allowlist + admin)
DISCORD_OPERATOR_ID=

# WebUI basic auth (WEBUI_PASS generated, 64 hex)
WEBUI_USER=
WEBUI_PASS=

# term-sessions daemon token (generated)
SESSION_SERVER_TOKEN=

# onecli agent tokens (aoc_…), synced from the onecli API by init-env
HOST_ONECLI_TOKEN=
SHELL_ONECLI_TOKEN=
```

**`scripts/init-env.sh`:**

```bash
#!/usr/bin/env bash
# stacks/connectome/scripts/init-env.sh
# Create/complete stacks/connectome/.env (mode 0600) without printing values:
#   - prompts (hidden input for the token) for Discord values if absent;
#   - generates WEBUI_PASS and SESSION_SERVER_TOKEN if absent;
#   - ALWAYS re-syncs HOST_ONECLI_TOKEN / SHELL_ONECLI_TOKEN from the onecli
#     API (agents connectome-host / connectome-shell), so a regenerated token
#     is picked up by re-running this.
# Env: CONNECTOME_ENV_FILE overrides the target (tests).
# Exit codes: 0 ok; 2 missing prereq; 3 onecli API failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../onecli/scripts/lib/api.sh
source "${SCRIPT_DIR}/../../onecli/scripts/lib/api.sh"
env_file="${CONNECTOME_ENV_FILE:-${SCRIPT_DIR}/../.env}"

umask 077
[ -f "$env_file" ] || : > "$env_file"
chmod 600 "$env_file"

has() { grep -qE "^$1=.+" "$env_file"; }
set_key() {  # set_key KEY VALUE — replaces any existing line; value never echoed
    local tmp; tmp=$(mktemp "${env_file}.XXXXXX")
    grep -vE "^$1=" "$env_file" > "$tmp" || true
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$env_file"
}
prompt() {  # prompt KEY "question" [hidden] [default]
    has "$1" && return 0
    local v
    if [ "${3:-}" = hidden ]; then read -r -s -p "$2: " v; echo; else read -r -p "$2${4:+ [$4]}: " v; fi
    v="${v:-${4:-}}"
    [ -n "$v" ] || { echo "init-env: $1 is required" >&2; exit 2; }
    set_key "$1" "$v"; echo "init-env: set $1"
}

prompt LLM_MODEL "Codex model id" "" "gpt-6-luna"
prompt DISCORD_TOKEN "Discord bot token (hidden)" hidden
prompt DISCORD_GUILD_ID "Discord guild:channel whitelist"
prompt DISCORD_OPERATOR_ID "Operator Discord user id"
has WEBUI_USER || { set_key WEBUI_USER operator; echo "init-env: set WEBUI_USER=operator"; }
has WEBUI_PASS || { set_key WEBUI_PASS "$(openssl rand -hex 32)"; echo "init-env: generated WEBUI_PASS"; }
has SESSION_SERVER_TOKEN || { set_key SESSION_SERVER_TOKEN "$(openssl rand -hex 32)"; echo "init-env: generated SESSION_SERVER_TOKEN"; }

for pair in HOST_ONECLI_TOKEN:connectome-host SHELL_ONECLI_TOKEN:connectome-shell; do
    key="${pair%%:*}"; ident="${pair#*:}"
    tok=$(agent_field "$ident" accessToken) || exit 3
    case "$tok" in aoc_*) ;; *) echo "init-env: no aoc_ token for agent ${ident} (run: dotfiles stacks onecli policy)" >&2; exit 3 ;; esac
    set_key "$key" "$tok"; unset tok
    echo "init-env: synced ${key} from onecli agent ${ident}"
done
echo "init-env: done ($(basename "$env_file") mode $(stat -f %Lp "$env_file"))"
```

**`stacks/connectome/justfile`** (initial):

```just
context := "colima-agents"
tailscale := "/opt/homebrew/bin/tailscale"
serve_port := "8768"
internal_port := "18768"

default:
    @just --list

# Create/complete .env (prompts for Discord values; generates WebUI/daemon
# secrets; re-syncs the two onecli agent tokens). Never prints values.
init-env:
    @./scripts/init-env.sh
```

**`stacks/justfile`** — insert `mod connectome` between `mod adguard` and `mod freshrss` (lines 1-5 become `mod adguard` / `mod connectome` / `mod freshrss` / `mod homebridge` / `mod onecli` / `mod wallabag`). Check with `just -f stacks/justfile --list | grep -c connectome` → ≥ 1.

**Step 1: Operator runs `init-env`**

```bash
dotfiles stacks connectome init-env
stat -f %Lp stacks/connectome/.env
cut -d= -f1 stacks/connectome/.env | sort | tr '\n' ' '
```

Expected: mode `600`. The keys are exactly `DISCORD_GUILD_ID DISCORD_OPERATOR_ID DISCORD_TOKEN HOST_ONECLI_TOKEN LLM_MODEL SESSION_SERVER_TOKEN SHELL_ONECLI_TOKEN WEBUI_PASS WEBUI_USER`.

**Step 2: Static compose check**

```bash
docker --context colima-agents compose -f stacks/connectome/compose.yaml config --format json \
 | jq -r '.services | to_entries[] | "\(.key) caps=\(.value.cap_drop) sec=\(.value.security_opt) vols=\([.value.volumes[] | "\(.source):\(.target):\(.read_only // false)"])"'
docker --context colima-agents compose -f stacks/connectome/compose.yaml config --format json \
 | jq -r '.services.shell.environment | keys | join(" ")'
```

Expected: both services `caps=["ALL"]` and `sec=["no-new-privileges:true"]`. Shell volumes are `workspace` and `outbox`. Connectome volumes are `state`, `outbox:/agent/outbox:true` and the recipes bind `:true`. The shell env keys are only `HTTPS_PROXY NO_PROXY SESSION_SERVER_TOKEN https_proxy no_proxy`.

**Commit:** `stacks/connectome: compose, .env.example, init-env; register module`
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: `build` script and recipes

**Verifies:** connectome-agent.AC4.1 (AC4.2 checked in Task 8)

**Files:**
- Create: `stacks/connectome/scripts/build.sh` (0755)
- Modify: `stacks/connectome/justfile` (add `build`, `image-test`)

**`scripts/build.sh`:**

```bash
#!/usr/bin/env bash
# stacks/connectome/scripts/build.sh
# Build both connectome images from the local clones (decision 22):
#   1. refuse if any clone has uncommitted changes (names the clone);
#   2. require connectome-host >= 406dcc1 (runtime-only fleet env);
#   3. stage `git archive HEAD` of each clone into build/src/<name>;
#   4. copy the per-vault onecli gateway CA into build/gateway-ca.crt;
#   5. write sources.lock (SHAs, upstream bases, local patch SUBJECTS only);
#   6. docker compose build.
#
# Env: CONNECTOME_SOURCES (default ~/Developer/connectome).
# Exit codes: 0 ok; 1 dirty clone / too-old source; 2 missing prereq; 3 build failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
sources="${CONNECTOME_SOURCES:-${HOME}/Developer/connectome}"
ctx=colima-agents
clones=(connectome-host discord-mcpl voice-kit heartbeat-mcpl)
TERM_SESSIONS_VERSION=1.6.0

for c in "${clones[@]}"; do
    [ -d "${sources}/${c}/.git" ] || { echo "build: missing clone ${sources}/${c}" >&2; exit 2; }
    if [ -n "$(git -C "${sources}/${c}" status --porcelain)" ]; then
        echo "build: clone '${c}' has uncommitted changes (${sources}/${c}); commit or stash them first" >&2
        exit 1
    fi
done
if ! git -C "${sources}/connectome-host" merge-base --is-ancestor 406dcc1 HEAD 2>/dev/null; then
    echo "build: connectome-host HEAD is older than 406dcc1 (runtime-only fleet env); update the clone" >&2
    exit 1
fi

docker --context "$ctx" inspect onecli-gateway >/dev/null 2>&1 \
    || { echo "build: onecli-gateway not running (run: dotfiles stacks onecli up)" >&2; exit 2; }

rm -rf "${stack_dir}/build/src"
mkdir -p "${stack_dir}/build/src"
for c in "${clones[@]}"; do
    mkdir -p "${stack_dir}/build/src/${c}"
    git -C "${sources}/${c}" archive --format=tar HEAD | tar -x -C "${stack_dir}/build/src/${c}"
done

docker --context "$ctx" exec onecli-gateway cat /app/data/gateway/ca.pem > "${stack_dir}/build/gateway-ca.crt"
grep -q 'BEGIN CERTIFICATE' "${stack_dir}/build/gateway-ca.crt" \
    || { echo "build: could not read gateway CA" >&2; exit 2; }

# Written to a temp file and moved into place only after a successful build,
# so a failed build never leaves an updated (committable) lock behind.
lock="${stack_dir}/sources.lock"
lock_tmp=$(mktemp "${stack_dir}/.sources.lock.XXXXXX")
trap 'rm -f "$lock_tmp"' EXIT
{
    # Deterministic (no timestamp/image ids): same sources => no git diff.
    echo "# Generated by \`dotfiles stacks connectome build\`. Do not edit."
    echo "# Local patches are listed by subject only; re-apply by hand on a fresh device (see README)."
    for c in "${clones[@]}"; do
        d="${sources}/${c}"
        base=$(git -C "$d" merge-base HEAD origin/main 2>/dev/null || echo unknown)
        echo "source ${c} sha=$(git -C "$d" rev-parse HEAD) branch=$(git -C "$d" rev-parse --abbrev-ref HEAD) upstream=$(git -C "$d" remote get-url origin) base=${base}"
        if [ "$base" != unknown ]; then
            git -C "$d" log --reverse --format="patch ${c} %s" "${base}..HEAD"
        fi
    done
    echo "npm term-sessions-mcp ${TERM_SESSIONS_VERSION}"
    echo "codex $(sed -n 's/^ARG CODEX_VERSION=//p' "${stack_dir}/build/connectome.Dockerfile")"
} > "$lock_tmp"

docker --context "$ctx" compose -f "${stack_dir}/compose.yaml" build --pull \
    --build-arg TERM_SESSIONS_VERSION="${TERM_SESSIONS_VERSION}" \
    || { echo "build: docker compose build failed; sources.lock unchanged" >&2; exit 3; }

mv "$lock_tmp" "$lock"
echo "build: images built; wrote $(basename "$lock")"
```

**justfile** — add:

```just
# Build both images from ~/Developer/connectome clones (refuses dirty trees),
# copy the gateway CA in, and write sources.lock.
build:
    @./scripts/build.sh

# Static assertions against the built images.
image-test:
    @./scripts/image-test.sh
```

**Testing (AC4.1):**

```bash
touch ~/Developer/connectome/voice-kit/DIRTY
./stacks/connectome/scripts/build.sh; echo "rc=$?"
rm ~/Developer/connectome/voice-kit/DIRTY
```

Expected: `build: clone 'voice-kit' has uncommitted changes …`, `rc=1`.

AC4.2 is verified after the first real build (Task 8).

**Commit:** `stacks/connectome: build script (clean-tree check, CA copy, sources.lock)`
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Image build tests (`image-test`)

**Verifies:** connectome-agent.AC4.2, connectome-agent.AC4.3, connectome-agent.AC4.4, connectome-agent.AC4.5, connectome-agent.AC5.2 (image layout), connectome-agent.AC7.5 (artifact level), connectome-agent.AC9.1, connectome-agent.AC9.2

**Files:**
- Create: `stacks/connectome/scripts/image-test.sh` (0755)

**Implementation:** Every script below starts like `build.sh`: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"; repo_root="$(cd "$stack_dir/../.." && pwd)"`. `just` runs it with cwd `stacks/connectome`, so every path is built from these, e.g. `$stack_dir/compose.yaml`, `$stack_dir/.env`, `$stack_dir/sources.lock`, `$repo_root/stacks/onecli/scripts/lib/api.sh`. Never use repo-root-relative paths. A `check`/`pass`/`fail` style script (source `$repo_root/stacks/scripts/lib/check.sh` for `pass`/`fail`; exit 1 if `__check_failed`). Every check runs a throwaway container from the built image with `--rm --network none` (and `--entrypoint` overridden) unless it needs the gateway. Checks:

| # | AC | Command (inside `docker --context colima-agents run --rm --network none --entrypoint sh <img> -c '…'` unless noted) | Pass when |
|---|---|---|---|
| 1 | 4.3 | `docker image inspect -f '{{.Os}}/{{.Architecture}}' connectome-host:local connectome-shell:local` | both `linux/arm64` |
| 2 | 4.3 | `sha256sum /usr/local/share/ca-certificates/onecli-gateway.crt` in each image vs `docker exec onecli-gateway cat /app/data/gateway/ca.pem \| shasum -a 256` | hashes equal |
| 3 | 4.3 | in each image: the CA's base64 body (lines between BEGIN/END of the gateway PEM, first 60 chars of line 2) is found by `grep -cF` in `/etc/ssl/certs/ca-certificates.crt` | count ≥ 1 |
| 4 | 4.4 | host: `/opt/node/bin/node -p 'process.versions.bun ? "BUN" : process.version'` | starts with `v22.` |
| 5 | 4.4 | host: `test -f /opt/connectome/dist/web/index.html && codex --version` | prints `codex-cli 0.162.1` |
| 6 | 5.2 | host (runs as image user): `id -u; ls -A /agent/cwd; readlink /agent/cwd/mcpl-servers.json /agent/cwd/logs; touch /agent/cwd/mcpl-servers.agent.json 2>&1; touch /agent/cwd/x 2>&1; echo rc=$?` | uid ≠ 0; listing exactly `logs mcpl-servers.json`; links → `/agent/recipes/mcpl-servers.json`, `/agent/state/logs`; both touches `Permission denied`, `rc=1` |
| 7 | 4.5 | host: `cd /tmp && env HEARTBEAT_CONFIG_FILE=/tmp/c.json HEARTBEAT_REMINDERS_FILE=/tmp/r.json /opt/node/bin/node /opt/connectome-tests/mcp-call.mjs reminder_add '{"message":"x","everySeconds":60}' -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio` | JSON `isError: true`, text contains `900` |
| 8 | 4.5 | same with `'{"message":"x","everySeconds":900}'` | `isError: false` |
| 9 | 7.5 | host: `/opt/node/bin/node --input-type=module -e "…"` importing `/opt/mcpl/discord-mcpl/dist/src/attachment-guard.js`: with `DISCORD_ATTACHMENT_ROOT=/tmp/ob` (create it, add `ok.txt`, a symlink `evil → /etc/passwd`), call `loadAttachment` on `/tmp/ob/ok.txt` (must succeed), `/proc/self/environ`, `/tmp/ob/evil`, and with the root env unset on `/tmp/ob/ok.txt` (all three must throw); print `ok`/`refused` per case | `ok refused refused refused` |
| 10 | 9.1 | shell: `uname -m; node -v; tsc -v; cargo -V; rustc -V; python3 -V; pip -V; uv -V; rg -V; fd -V; jq -V; git --version; gh --version; gcc --version \| head -1; make -v \| head -1` | `aarch64`, every command succeeds |
| 11 | 9.2 | shell: `id -u; command -v sudo \|\| echo NO_SUDO; su -c true root </dev/null 2>&1; echo rc=$?` | uid ≠ 0, `NO_SUDO`, `rc` ≠ 0 |
| 12 | — | shell and host: `id -u` both `1000` (shared `outbox` ownership relies on it) | both `1000` |
| 13 | 4.2 | host side: `$stack_dir/sources.lock` has 4 `source` lines with 40-hex `sha=`, `connectome-host`'s sha has `406dcc1` as ancestor, `npm term-sessions-mcp 1.6.0`, `patch heartbeat-mcpl local: refuse reminders below a 900 s floor`, `patch discord-mcpl local: confine attachments…`, and `! grep -E '^[-+]{1}[^-+]' sources.lock` (no diff content) | all true |

Write the script so each row is one `pass`/`fail` line naming the AC.

**Step 1: Run build then tests** (requires Task 6's `compose.yaml` and complete `.env`, and Phase 2's gateway up):

```bash
dotfiles stacks connectome build
dotfiles stacks connectome image-test; echo "rc=$?"
cat stacks/connectome/sources.lock
```

Expected: build succeeds (the in-build patch tests pass), all 13 rows `[OK]`, `rc=0`, and `sources.lock` shows SHAs and patch subjects only.

**Commit:** `stacks/connectome: image build tests` (and commit the generated `stacks/connectome/sources.lock` in the same commit).
<!-- END_TASK_8 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_9 -->
### Task 9: `provision-codex`

**Verifies:** connectome-agent.AC6.1, connectome-agent.AC5.7 (provisioning never puts the operator key in a container)

**Files:**
- Create: `stacks/connectome/scripts/provision-codex.sh` (0755)
- Modify: `stacks/connectome/justfile` (add `provision-codex`)

**Implementation:**

```bash
#!/usr/bin/env bash
# stacks/connectome/scripts/provision-codex.sh
# Operator-side, once (and for recovery): write the onecli Codex stub into the
# connectome `state` volume as codex/auth.json (0600, image uid) plus
# codex/config.toml from the tracked template. The stub's tokens are the
# literal "onecli-managed"; tokens.account_id is set to the REAL ChatGPT
# account id (an identifier, not a credential — Codex >= 0.162 refuses a stub
# whose account id fails workspace routing discovery). The operator's onecli
# API key is used here on the Mac only; it never enters a container.
# Never use the WebUI "log in again" action: it runs account/logout, deletes
# this stub and starts a real login (which onecli rule 6 blocks anyway).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../onecli/scripts/lib/api.sh
source "${SCRIPT_DIR}/../../onecli/scripts/lib/api.sh"
stack_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"

account_id=$(api GET /v1/org/secrets \
    | jq -r '(if type=="array" then . else (.secrets // .data // []) end)[] | select(.type=="openai") | .metadata.accountId // empty' | head -1)
[ -n "$account_id" ] || { echo "provision-codex: openai secret has no accountId (run: dotfiles stacks onecli import-openai)" >&2; exit 3; }

stub=$(api GET /v1/credential-stubs/codex | jq -r 'if type=="object" and has("content") then .content else tojson end')
auth=$(jq -c --arg a "$account_id" '.tokens.account_id = $a' <<<"$stub") \
    || { echo "provision-codex: stub is not JSON" >&2; exit 3; }
jq -e '.tokens.access_token=="onecli-managed" and .tokens.refresh_token=="onecli-managed"' <<<"$auth" >/dev/null \
    || { echo "provision-codex: stub carries non-placeholder tokens; refusing" >&2; exit 3; }

docker --context colima-agents compose -f "${stack_dir}/compose.yaml" run --rm --no-deps -T \
    --entrypoint sh connectome -c '
        umask 077
        mkdir -p /agent/state/codex
        cat > /agent/state/codex/auth.json
        cp /agent/recipes/codex-config.toml /agent/state/codex/config.toml
        chmod 600 /agent/state/codex/auth.json /agent/state/codex/config.toml
        ls -ln /agent/state/codex' <<<"$auth"
unset auth stub
echo "provision-codex: wrote codex/auth.json (account id set) and codex/config.toml"
```

`compose run` uses the image's user, so the files are owned by the connectome uid. It also creates the `connectome_state` volume with compose labels when it doesn't exist yet, and needs `onecli-agents` present and `.env` complete.

**justfile** — add:

```just
# Write the onecli Codex stub (+ real account id) and codex config.toml into
# the state volume. Run once after build; re-run to recover. Never use the
# WebUI "log in again" action.
provision-codex:
    @./scripts/provision-codex.sh
```

**Step 1: Run**

```bash
dotfiles stacks connectome provision-codex
```

**Verification (AC6.1):**

```bash
docker --context colima-agents compose -f stacks/connectome/compose.yaml run --rm --no-deps -T --entrypoint sh connectome -c '
  id -u; stat -c "%u %a" /agent/state/codex/auth.json
  /opt/node/bin/node -e "const a=require(\"/agent/state/codex/auth.json\");console.log(a.tokens.access_token, a.tokens.refresh_token, /^[0-9a-f-]{8,}$/i.test(a.tokens.account_id)?\"ACCOUNT_ID_OK\":\"BAD\")"
  cmp /agent/recipes/codex-config.toml /agent/state/codex/config.toml && echo CONFIG_MATCH'
```

Expected: the uid (e.g. `1000`) equals the file owner, with mode `600`. The output reads `onecli-managed onecli-managed ACCOUNT_ID_OK` and `CONFIG_MATCH`. The account id equals `metadata.accountId` of the openai secret; `ACCOUNT_ID_OK` checks only its shape, without printing it.

**Commit:** `stacks/connectome: provision-codex (onecli stub into state volume)`
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Lifecycle recipes and first start

**Verifies:** connectome-agent.AC5.5 (seed), connectome-agent.AC6.3, connectome-agent.AC8.1 (publish + serve)

**Files:**
- Modify: `stacks/connectome/justfile` (add recipes below)

**Recipes to add:**

```just
# Fails clearly if onecli (which owns the onecli-agents network) is not up.
up:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! docker --context {{context}} network inspect onecli-agents >/dev/null 2>&1; then
        echo "connectome: network onecli-agents missing — run \`dotfiles stacks onecli up\` first" >&2
        exit 1
    fi
    docker --context {{context}} compose up -d

down:
    docker --context {{context}} compose down

restart:
    docker --context {{context}} compose restart

ps:
    docker --context {{context}} compose ps -a

# Images are built locally; refresh the base images so the next build uses them.
pull:
    docker --context {{context}} pull node:22-bookworm
    docker --context {{context}} pull oven/bun:1-debian
    docker --context {{context}} pull mcr.microsoft.com/devcontainers/typescript-node:22-bookworm

# Interactive shell in the agent's `shell` container.
shell:
    docker --context {{context}} exec -it connectome-shell bash

# --headless sends stdout/stderr to $DATA_DIR/headless.log (docker logs is
# empty past the entrypoint), so tail the files inside the container.
logs:
    docker --context {{context}} exec connectome sh -c 'touch /agent/state/logs/failures.log; tail -n 50 -F /agent/state/data/headless.log /agent/state/logs/failures.log'

serve:
    {{tailscale}} serve --bg --https={{serve_port}} http://localhost:{{internal_port}}
```

**Step 1: First start**

```bash
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dotfiles stacks connectome up
sleep 20
docker --context colima-agents logs connectome 2>&1 | tail -5
docker --context colima-agents exec connectome cat /agent/state/heartbeat/config.json
docker --context colima-agents exec connectome tail -n 20 /agent/state/data/headless.log
docker --context colima-agents logs onecli-gateway --since "$started" 2>&1 | grep -cE 'BLOCKED|RATE LIMITED|refused'
dotfiles stacks onecli requests 5
```

Expected:
- the entrypoint lines `seeded heartbeat interval` and `gateway reachable`;
- `{"intervalSeconds": 14400}`;
- `headless.log` showing the MCP servers connected (discord logged in, heartbeat, shell) with no fatal errors;
- a gateway refusal count of `0` (AC6.3). The gateway's stdout prints `BLOCKED by policy rule …` / `RATE LIMITED …` / `egress guard: refused …` lines, not the `blocked_by_policy` JSON code, hence the grep. If it isn't 0, list those lines and stop: a start-up request is hitting rule 6, and the codex config or the rules table needs revisiting with the user.
- `onecli requests 5` lists the start-up requests (`GET /backend-api/codex/models`, `GET /backend-api/wham/accounts/check`) with status 200 on the `connectome-host` agent id (`source stacks/onecli/scripts/lib/api.sh; agent_field connectome-host id`). None of the statuses is 403. This is the request log used for every count below.

**Step 2: Publish and serve (AC8.1)**

```bash
docker --context colima-agents port connectome
dotfiles stacks connectome serve
/opt/homebrew/bin/tailscale serve status | grep -A1 ':8768'
curl -s -o /dev/null -w '%{http_code}\n' https://cxmini.faun-fir.ts.net:8768/
```

Expected: `18768/tcp -> 127.0.0.1:18768` only, and serve maps `:8768` → `http://localhost:18768`. The unauthenticated curl gets `401` (AC8.2 from the tailnet side). The WebSocket check is in Task 13.

**Commit:** `stacks/connectome: lifecycle, logs and serve recipes`
<!-- END_TASK_10 -->

<!-- START_TASK_11 -->
### Task 11: Stack smoke test (`smoke`)

**Verifies:** connectome-agent.AC5.1, connectome-agent.AC5.2, connectome-agent.AC5.3, connectome-agent.AC5.5, connectome-agent.AC5.6, connectome-agent.AC5.7, connectome-agent.AC5.8, connectome-agent.AC7.3 (env), connectome-agent.AC7.6, connectome-agent.AC8.2, connectome-agent.AC8.3 (file), connectome-agent.AC9.3 (git clone), connectome-agent.AC9.4, connectome-agent.AC9.5

**Files:**
- Create: `stacks/connectome/scripts/smoke.sh` (0755)
- Modify: `stacks/connectome/justfile` (add `smoke`)

**Implementation:** Every script below starts like `build.sh`: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"; repo_root="$(cd "$stack_dir/../.." && pwd)"`. `just` runs it with cwd `stacks/connectome`, so every path is built from these, e.g. `$stack_dir/compose.yaml`, `$stack_dir/.env`, `$stack_dir/sources.lock`, `$repo_root/stacks/onecli/scripts/lib/api.sh`. Never use repo-root-relative paths. Source `$repo_root/stacks/scripts/lib/check.sh`. Define `D() { docker --context colima-agents "$@"; }` and `X() { D exec "$@"; }`. **Every** docker call in `smoke.sh` (and in `image-test.sh`) goes through `D`, never bare `docker`: the active context is the unbound `default` (CLAUDE.md). Below, "`docker restart`/`inspect`" means `D restart`/`D inspect`. Each numbered check prints one `pass`/`fail` line naming its AC, and the script exits 1 on any fail. The script restores everything it changes (it restarts containers, so it must not run during an active conversation).

1. **AC5.1:** for `connectome` and `connectome-shell`: `X <c> id -u` ≠ `0`; `docker inspect -f '{{json .HostConfig.CapDrop}} {{json .HostConfig.SecurityOpt}}'` contains `"ALL"` and `no-new-privileges:true`.
2. **AC5.2:** `X connectome sh -c 'touch /agent/cwd/mcpl-servers.agent.json'` fails; `X connectome sh -c 'echo x >> /agent/cwd/mcpl-servers.json'` fails (the target is on the RO mount); `X connectome ls -A /agent/cwd` = `logs mcpl-servers.json`.
3. **AC5.3:** `X connectome touch /agent/recipes/x` fails with `Read-only file system`.
4. **AC5.5:** this proves the heartbeat server, running as the connectome uid, really persists `heartbeat_configure` at the configured path. Write failures are only logged, so this positive check matters. Save the sha of `X connectome cat /agent/state/heartbeat/config.json`. Spawn a second heartbeat process with the live server's file env (the `HEARTBEAT_*` vars are set per MCP server, not in the container env, so pass them explicitly): `X connectome env HEARTBEAT_CONFIG_FILE=/agent/state/heartbeat/config.json HEARTBEAT_REMINDERS_FILE=/agent/state/heartbeat/reminders.json /opt/node/bin/node /opt/connectome-tests/mcp-call.mjs heartbeat_configure '{"intervalHours":5}' -- /opt/node/bin/node /opt/mcpl/heartbeat-mcpl/dist/src/index.js --stdio`. Assert the sha changed and the file contains `18000`. Repeat with `{"intervalHours":4}` and assert it contains `14400`. Restart `connectome` so the live server rereads it. Task 13 covers the agent-initiated path.
5. **AC5.6 (stale files):** `X connectome sh -c 'mkdir -p /agent/state/data/children/smoke && : > /agent/state/data/children/smoke/headless.pid && : > /agent/state/data/children/smoke/ipc.sock'`, then `docker restart connectome`, wait 10 s, and assert both files are gone. Remove the dir.
6. **AC5.6 (bounded wait):** first `D stop connectome`. The throwaway container runs the real entrypoint, whose stale-file cleanup would otherwise delete the **live** host's top-level `headless.pid`/`ipc.sock` in the shared `state` volume. Then `D stop onecli-gateway`, set a `trap` that runs `D start onecli-gateway`, waits until it is healthy, then runs `D start connectome`, and run `D compose -f $stack_dir/compose.yaml run --rm --no-deps -e GATEWAY_WAIT_SECONDS=6 connectome`. The entrypoint's own bound is the timeout (macOS has no `timeout(1)`), and the run must return within ~15 s. Assert rc = 4 and that the output contains `unreachable after 6s`.
7. **AC5.7:** for both containers, `X <c> sh -c 'env; grep -rIhoE "(^|[^a])oc_[0-9a-f]{32,}" /agent /home /workspace /etc /tmp 2>/dev/null'` piped to `grep -cE '(^|[^a])oc_[0-9a-f]{32,}'` → `0`. On the Mac, `cut -d= -f1 $stack_dir/.env | grep -ciE 'API_KEY|ONECLI_KEY|^OC_'` → `0`.
8. **AC5.8:** load the values of `DISCORD_TOKEN WEBUI_PASS HOST_ONECLI_TOKEN SHELL_ONECLI_TOKEN SESSION_SERVER_TOKEN` from `$stack_dir/.env` into a `mktemp` file (0600, deleted on exit). For both containers, dump `X <c> sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < $f; echo; done'` and count `grep -cF -f <values-file>` → `0`. Print counts only, never matches.
9. **AC7.3 (env side):** `X connectome sh -c 'cat /proc/*/environ 2>/dev/null | tr "\0" "\n" | grep -c "^DISCORD_FILTERS_FILE="'` → `0`, and `jq` on the tracked recipe has `disabledTools` (as Task 3).
10. **AC7.6:** after the restart in step 4/5, `X connectome ls /agent/state/discord` lists `watermark.json`, and any of `dm-notices.json`/`muted-channels.json` that discord-mcpl has created so far. Assert `watermark.json` exists; the others are created lazily on first use, so report them as `[OFF]` if absent rather than fail.
11. **AC8.2:** `X connectome-shell curl -s -o /dev/null -w '%{http_code}' http://connectome:18768/` → `401`; from the Mac `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18768/` → `401`; with correct creds via `curl -K <(printf 'user = "%s:%s"\n' "$WEBUI_USER" "$WEBUI_PASS")` → `200`.
12. **AC8.3 (file):** `X connectome cat /agent/recipes/observers.json` = `{"observers":[]}` and `X connectome touch /agent/recipes/observers.json` fails.
13. **AC9.3 (CA trust):** `X connectome-shell sh -c 'rm -rf /tmp/hw && git clone --depth 1 https://github.com/octocat/Hello-World /tmp/hw && git -C /tmp/hw log --oneline -1'` succeeds (HTTPS through the gateway's MITM with the gateway CA trusted).
14. **AC9.4:** `X connectome-shell ls /agent/state` fails (no such path). Compose mounts: `D inspect -f '{{range .Mounts}}{{.Name}}:{{.RW}} {{end}}'` for both containers; the intersection of named volumes is exactly `connectome_outbox`, and on `connectome` it is `:false`.
15. **AC9.5:** `X connectome-shell sh -c 'echo smoke > /workspace/.smoke-persist'`, `docker restart connectome-shell`, then the file still reads `smoke`. Remove it.

**justfile** — add:

```just
# Smoke test against the running stack (restarts containers; restores state).
smoke:
    @./scripts/smoke.sh
```

**Verification:**

```bash
dotfiles stacks connectome smoke; echo "rc=$?"
```

Expected: every line is `[OK]` (or `[OFF]` for lazily-created discord state files) and `rc=0`.

**Commit:** `stacks/connectome: stack smoke test`
<!-- END_TASK_11 -->

<!-- START_TASK_12 -->
### Task 12: Forced inference failure → `failures.log`

**Verifies:** connectome-agent.AC5.4

**Files:**
- Create: `stacks/connectome/scripts/force-failure.sh` (0755)
- Modify: `stacks/connectome/justfile` (add `force-failure`)

The model is **not** changed: per the design's model-swap rule, swapping models on a live chronicle is a continuity violation. Instead, inference is made to fail by taking the gateway away briefly. Shell state doesn't persist between commands, so a single script does all of it, and its own trap guarantees the gateway comes back.

**`scripts/force-failure.sh`:**

```bash
#!/usr/bin/env bash
# AC5.4: stop the onecli gateway, wait (bounded) for the operator's DM to
# produce a failures.log record, ALWAYS restart the gateway.
# Exit: 0 record appeared; 1 timed out.
set -uo pipefail
D() { docker --context colima-agents "$@"; }
restore() {
    D start onecli-gateway >/dev/null
    for _ in $(seq 1 30); do
        [ "$(D inspect -f '{{.State.Health.Status}}' onecli-gateway 2>/dev/null)" = healthy ] && break
        sleep 2
    done
    echo "force-failure: gateway restarted ($(D inspect -f '{{.State.Health.Status}}' onecli-gateway))"
}
trap restore EXIT
size() { D exec connectome sh -c 'wc -c < /agent/state/logs/failures.log 2>/dev/null || echo 0' | tr -d ' '; }
before=$(size)
D stop onecli-gateway >/dev/null
echo "force-failure: gateway stopped — send the bot ONE Discord DM now (waiting up to 180 s)"
for _ in $(seq 1 90); do
    if [ "$(size)" -gt "$before" ]; then
        echo "force-failure: new failures.log record:"
        D exec connectome tail -n 1 /agent/state/logs/failures.log
        exit 0
    fi
    sleep 2
done
echo "force-failure: no failures.log record within 180 s" >&2
exit 1
```

**justfile** — add:

```just
# AC5.4: briefly stop the gateway; the operator DMs; expect a failures.log record.
force-failure:
    @./scripts/force-failure.sh
```

**Step:** run `dotfiles stacks connectome force-failure; echo rc=$?` and the operator sends one DM when prompted.

Expected: a new `failures.log` record naming the inference failure (a proxy/connection error), `rc=0`, and `gateway restarted (healthy)`. Afterwards a second DM gets a normal reply.

**Commit:** `stacks/connectome: force-failure check (AC5.4)`
<!-- END_TASK_12 -->

<!-- START_TASK_13 -->
### Task 13: End-to-end and human verification (Discord, WebUI, gateway identity)

**Verifies:** connectome-agent.AC5.5 (agent-initiated), connectome-agent.AC6.2, connectome-agent.AC6.4, connectome-agent.AC7.1, connectome-agent.AC7.2, connectome-agent.AC7.3 (tool list), connectome-agent.AC7.4, connectome-agent.AC7.5 (live), connectome-agent.AC8.1 (WebSocket), connectome-agent.AC8.3 (live), connectome-agent.AC9.3 (term-sessions), connectome-agent.AC10.1 (tick reaches agent)

**Files:** none. The executor records the outcome of each check in the commit message of Task 14.

**Request log:** allowed gateway requests are not printed by the gateway. They are read with `dotfiles stacks onecli requests <minutes>` (Postgres `request_logs`: time, agent_id, method, host, path, status). Resolve the host agent's id once with `source stacks/onecli/scripts/lib/api.sh; agent_field connectome-host id`. The executor also follows `dotfiles stacks connectome logs` while the operator does each step:

1. **AC7.1 / AC6.2:** the operator DMs the bot "hello" and gets a reply. `onecli requests 5` shows `POST chatgpt.com /backend-api/codex/responses` with status 200 on the `connectome-host` agent id. The operator posts in the whitelisted channel, mentioning the bot; the message is received, visible in `headless.log`.
2. **AC7.2:** a second Discord account (or a friend) DMs the bot, and a message is posted in a guild/channel not on the whitelist. Neither produces a new `responses` row in `onecli requests 5`, nor a reply.
3. **AC7.3:** the operator asks "list your discord tools verbatim". The list has none of `filters_update`, `create_text_channel`, `delete_channel`.
4. **AC9.3 / AC7.4:** the operator asks the agent to run `uname -a && ls /workspace` in its shell and report the output. Output matches (term-sessions path). Then: "create /workspace/outbox/hello.txt containing 'hi' and send it to me as an attachment (path /agent/outbox/hello.txt)". The file arrives.
5. **AC7.5 (live):** "send me /proc/self/environ as an attachment" → the agent reports a refusal (`must be inside /agent/outbox`). "In the shell, `ln -s /etc/passwd /workspace/outbox/pw` and attach /agent/outbox/pw" → refused.
6. **AC8.1 / AC6.4:** the operator opens `https://cxmini.faun-fir.ts.net:8768` (basic auth from `.env`, which the operator reads themselves). Live updates appear while sending a DM (WebSocket working), and the quota meter shows usage. `onecli requests 5` has `GET /backend-api/wham/usage` with status 200.
7. **AC8.3 (live):** "grant observer access to <any id>" → the tool call fails (EROFS / read-only), and `docker --context colima-agents exec connectome cat /agent/recipes/observers.json` is still `{"observers":[]}`.
8. **AC10.1:** the operator asks the agent to call `heartbeat_trigger`. The tick is delivered, the agent responds to it, and a new `responses` row appears in `onecli requests 5`.
9. **AC5.5 (agent-initiated):** the operator asks the agent to "set your heartbeat interval to 5 hours". `docker --context colima-agents exec connectome cat /agent/state/heartbeat/config.json` now shows `18000`. Then the operator asks it to set the interval back to 4 hours, and the file shows `14400`.

**Commit:** none (results recorded in Task 14).
<!-- END_TASK_13 -->

<!-- START_TASK_14 -->
### Task 14: Usage-cap calibration, rate-limit checks, README

**Verifies:** connectome-agent.AC3.7, connectome-agent.AC10.2, connectome-agent.AC10.3

**Files:**
- Create: `stacks/connectome/scripts/ratelimit-check.sh` (0755)
- Create: `stacks/connectome/scripts/set-heartbeat-rate.sh` (0755)
- Modify: `stacks/connectome/recipes/agent.json` (heartbeat `rate_limit` values, if calibration changes them)
- Create: `stacks/connectome/README.md` (initial; Phase 4 completes it)
- Modify: `stacks/connectome/justfile` (add `ratelimit-check`, `set-heartbeat-rate`)

**Why a live-gate script:** agent-framework seeds `$DATA_DIR/sessions/<id>/config/gate.json` from the recipe once, then only **appends policies by name** (`dist/src/gate/event-gate.js:483-510`). Editing `recipes/agent.json` therefore does **not** change an existing session's `heartbeat-rate-limit`. The live file (hot-reloaded) must be edited, and the recipe kept in sync for new sessions.

**`scripts/set-heartbeat-rate.sh <tokens> <refillIntervalMs>`:**

```bash
#!/usr/bin/env bash
# Set the heartbeat wake rate_limit in every live session gate.json (hot-
# reloaded) — the recipe only seeds new sessions. Keep recipes/agent.json in
# sync by hand. Exit: 0 ok; 2 usage; 3 no session found.
set -euo pipefail
[[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: set-heartbeat-rate.sh <tokens> <refillIntervalMs>" >&2; exit 2; }
docker --context colima-agents exec -e T="$1" -e R="$2" connectome /opt/node/bin/node -e '
  const fs = require("fs"), path = require("path");
  const root = "/agent/state/data/sessions";
  const files = fs.existsSync(root) ? fs.readdirSync(root).map(s => path.join(root, s, "config", "gate.json")).filter(f => fs.existsSync(f)) : [];
  if (!files.length) { console.error("no session gate.json found"); process.exit(3); }
  for (const f of files) {
    const g = JSON.parse(fs.readFileSync(f, "utf8"));
    const p = (g.policies || []).find(p => p.name === "heartbeat-rate-limit");
    if (!p) { console.error(`${f}: no heartbeat-rate-limit policy`); process.exit(3); }
    p.behavior = { rate_limit: { tokens: Number(process.env.T), refillIntervalMs: Number(process.env.R) } };
    fs.writeFileSync(f + ".tmp", JSON.stringify(g, null, 2) + "\n"); fs.renameSync(f + ".tmp", f);
    console.log(`${f}: heartbeat-rate-limit = ${process.env.T} tokens / ${process.env.R} ms`);
  }'
```

If the live file turns out not to be hot-reloaded (the WebUI gate stats still show the old values), follow it with `docker --context colima-agents restart connectome`. Restarting does not re-seed an existing session.

**justfile** — add:

```just
# Set the heartbeat wake rate_limit in the live session gate(s).
set-heartbeat-rate tokens refill_ms:
    @./scripts/set-heartbeat-rate.sh {{tokens}} {{refill_ms}}

# AC10.3: exhaust a temporary 2/hour rule 1 and expect the gateway refusal.
ratelimit-check:
    @./scripts/ratelimit-check.sh
```

**Step 1: Measure (design "Usage-cap calibration" 1)** — with the provisional 60/hour in place. Counts come from `dotfiles stacks onecli requests <minutes>`, filtered to `POST … /backend-api/codex/responses` rows on the host agent id:
- The operator asks for a tool-using task that runs ≥ 3 shell commands. Count the `responses` rows between the DM and the final reply.
- Trigger one heartbeat (`heartbeat_trigger` via the agent) and count again.
- Burst coalescing: the operator sends 3 DMs within ~2 s; count the POSTs.
- Record the numbers.

**Step 2: AC10.2 burst drop** — run `dotfiles stacks connectome set-heartbeat-rate 1 3600000` (live gate). Ask the agent to call `heartbeat_trigger` three times in one turn. `onecli requests` shows inference for at most the first trigger beyond the turn itself, and the WebUI gate stats (`rateLimitState.deniedCount`) or `headless.log` show the rest denied. Restore with `dotfiles stacks connectome set-heartbeat-rate 6 600000`.

**Step 3: AC10.3 hard ceiling** — `scripts/ratelimit-check.sh`. Every script below starts like `build.sh`: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; stack_dir="$(cd "$SCRIPT_DIR/.." && pwd)"; repo_root="$(cd "$stack_dir/../.." && pwd)"`. `just` runs it with cwd `stacks/connectome`, so every path is built from these, e.g. `$stack_dir/compose.yaml`, `$stack_dir/.env`, `$stack_dir/sources.lock`, `$repo_root/stacks/onecli/scripts/lib/api.sh`. Never use repo-root-relative paths. It reads `HOST_ONECLI_TOKEN` from `$stack_dir/.env` with `grep '^HOST_ONECLI_TOKEN=' "$stack_dir/.env" | cut -d= -f2-` into an exported `HOST_TOKEN`, never echoed, and sources `$repo_root/stacks/onecli/scripts/lib/api.sh` for the rule read:
1. Read the current rule-1 limit from the API (`api GET /v1/org/policy/rules`, `cx-1-codex-responses-limit` → `.rateLimit`) and remember it. Set rule 1 to 2/hour by calling the script directly (no `dotfiles` alias/function exists inside a script): `"${repo_root}/stacks/onecli/scripts/policy.sh" 2`.
2. Reset the gateway's in-memory counter. It is keyed by rule logical id × agent token × the fixed clock-hour window, so the PATCH does **not** reset it, and Step 1's measurement turns already counted this hour. Run `docker --context colima-agents restart onecli-gateway` and wait until it is `healthy`. Avoid starting within a minute of the top of the hour, when the window rolls over.
3. From a throwaway `curlimages/curl` on `onecli-agents`, with `HOST_TOKEN` from `.env` passed as `-e` and the gateway CA mounted (same pattern as `stacks/onecli/scripts/probe.sh`), POST `{}` to `https://chatgpt.com/backend-api/codex/responses` three times.
4. Assert the third response is the gateway's rate-limit refusal (HTTP 429, body containing `rate`), while the first two are not refused by the gateway. They are expected to be 4xx from chatgpt.com for the empty body. Also confirm the gateway stdout shows a `RATE LIMITED` line.
5. Always (via `trap`) restore rule 1 with `"${repo_root}/stacks/onecli/scripts/policy.sh" <remembered value>`.

The counter is in-memory and resets on gateway restart. Run this only when the agent is idle.

**Step 4: Set final values (design calibration 2–4)**
- Rule 1 = measured POSTs per turn × the operator's expected peak turns per hour × 2–3: `dotfiles stacks onecli policy <N>`.
- Heartbeat wake `rate_limit`: start at 6 tokens / 600000 ms and adjust from the measurements. Apply to the live session with `dotfiles stacks connectome set-heartbeat-rate <tokens> <ms>`, **and** write the same values into `recipes/agent.json` (it seeds new sessions only). Confirm in the WebUI gate stats that the new values are active.
- The operator sets a ChatGPT per-app weekly cap for this login in ChatGPT settings.

**Step 5: README** — create `stacks/connectome/README.md` with sections: `# connectome stack`, `## Fresh-device setup` (onecli up → policy → import-openai → connectome init-env → build → provision-codex → up → serve), `## .env keys`, `## Sources and local patches` (clone list; `local` branches; the two patch subjects; fresh-device re-application by hand; propose the discord patch upstream), `## Usage caps (calibration)` — a table with the measurement date, POSTs per tool-using turn, per heartbeat tick, the burst behaviour, the chosen rule-1 limit, the heartbeat rate-limit values, and "per-app weekly cap set: yes (date)". Under usage caps, also note that the recipe only seeds new sessions (use `set-heartbeat-rate` for live ones), and the accepted gap: the 900 s reminder floor does not cover absolute `atIso` reminders, so many near-term one-shots remain possible. They are still capped by the heartbeat wake `rate_limit` (its `source: "heartbeat"` match covers every event from the heartbeat server, reminders included), then by rule 1 and the per-app cap. Phase 4 adds the threat model and known exposures.

**Verification:**

```bash
dotfiles stacks connectome ratelimit-check; echo "rc=$?"
source stacks/onecli/scripts/lib/api.sh
api GET /v1/org/policy/rules | jq -r '(if type=="array" then . else (.rules // .data) end)[] | select(.name=="cx-1-codex-responses-limit") | "\(.rateLimit)/\(.rateLimitWindow)"'
jq '.modules.wake.policies[0].behavior' stacks/connectome/recipes/agent.json
docker --context colima-agents exec connectome sh -c 'cat /agent/state/data/sessions/*/config/gate.json' | grep -A3 heartbeat-rate-limit
grep -A12 '## Usage caps' stacks/connectome/README.md
```

Expected: `rc=0`. The rule shows the calibrated value and the recipe the chosen tokens/refill. The README table is filled in with today's date.

**Commit:** `stacks/connectome: calibrate usage caps; README` (include the Task 13 human-check outcomes in the commit body).
<!-- END_TASK_14 -->
