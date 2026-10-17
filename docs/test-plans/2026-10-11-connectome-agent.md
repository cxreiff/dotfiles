# Human test plan: connectome agent (2026-10-11-connectome-agent)

Coverage validation (2026-10-16, branch tip 6b256a1): 68 acceptance criteria,
65 covered by automated checks, 2 waived (AC1.1, AC1.2: nanoclaw paused, not
decommissioned), 1 pending (AC11.8: reboot autostart), 0 missing. Recorded
operator decisions: AC3.7 no per-app ChatGPT cap; AC7.2 deferred (personal
servers only); AC7.5 live check not exercised (verified at artifact level).

Automated checks referenced below: `stacks/connectome/scripts/{image-test,smoke,lint,lint-test,force-failure,ratelimit-check,build}.sh`,
`stacks/onecli/scripts/{probe,init-env}.sh`, `stacks/scripts/doctor.sh`, and
the clone unit tests (`heartbeat-mcpl/test/reminder-floor.test.ts`,
`discord-mcpl/test/attachment-root.test.ts`,
`connectome-host/test/{recipe-subagents,subagent-empty-inputs}.test.ts`), which
also run inside the image build.

## Prerequisites

- SSH session on cxmini; `colima-agents` running; onecli and connectome Up.
- These pass: `dotfiles stacks connectome lint-test`, `dotfiles stacks connectome image-test`,
  `dotfiles stacks doctor` (rc 0).
- The agent is idle before any step that restarts containers.

## Phase 4 Task 8: merge, reboot, final gate (AC11.8, AC12.1 final)

### Step 0: merge and re-home

| Step | Action | Expected |
|---|---|---|
| 0.1 | `git -C ~/Developer/dotfiles/.worktrees/connectome-agent status --short` | empty |
| 0.2 | (after confirming) `git -C ~/Developer/dotfiles merge --ff-only connectome-agent` | fast-forward to the branch tip |
| 0.3 | `sudo launchctl enable system/com.cxreiff.dotfiles.backup`; `sudo launchctl bootstrap system /Library/LaunchDaemons/com.cxreiff.dotfiles.backup.plist`; `sudo launchctl print system/com.cxreiff.dotfiles.backup \| head -3` | service printed, not "Could not find service" |
| 0.4 | Copy `stacks/{onecli,connectome}/.env` from the worktree to main with `install -m 600`; `stat` loop; `cmp` (phase_04 Task 8 Step 0) | every stack `600`; `OK: secrets copied` |
| 0.5 | `just -f ~/Developer/dotfiles/justfile stacks onecli up`, then `... stacks connectome up` | both rc 0 |
| 0.6 | `docker --context colima-agents inspect connectome -f '{{range .Mounts}}{{if eq .Destination "/agent/recipes"}}{{.Source}}{{end}}{{end}}'` | `/Users/cxreiff/Developer/dotfiles/stacks/connectome/recipes` (no `.worktrees`) |
| 0.7 | `dotfiles stacks backup-all` | tarballs for every stack, connectome before onecli, onecli/connectome tarballs 0600 |
| 0.8 | `dotfiles stacks doctor; echo rc=$?` | rc 0 before the reboot |

### Step 1: reboot

| Step | Action | Expected |
|---|---|---|
| 1.1 | `sudo fdesetup authrestart` | the host reboots without the FileVault console prompt |

### Step 2: after SSH-ing back in (no manual starts)

| Step | Action | Expected |
|---|---|---|
| 2.1 | `tail -n 40 ~/Library/Logs/com.cxreiff.dotfiles.startup.out.log` | VM start, then `up-all` with `=== onecli up ===` before `=== connectome up ===`, ending `up-all: all stacks up` |
| 2.2 | `tail -n 20 ~/Library/Logs/com.cxreiff.dotfiles.startup.err.log` | no `up-all: FAILED:`. If only adguard failed (Tailscale racing at boot), AC11.8 still holds when onecli and connectome are Up |
| 2.3 | `docker --context colima-agents ps --format '{{.Names}}\t{{.Status}}'` | onecli api/web/gateway/postgres Up (healthy); `connectome`, `connectome-shell` Up |
| 2.4 | `dotfiles stacks doctor; echo rc=$?` | no `[FAIL]`, rc 0 (onecli healthy, migrations exited 0, CA fingerprints match, both containers on onecli-agents, shell has no LLM grant, 7 invariants OK, six `.env` mode 0600) |
| 2.5 | DM the bot "ping after reboot" from the operator account | reply within about a minute |
| 2.6 | `dotfiles stacks onecli requests 5` | new `POST chatgpt.com /backend-api/codex/responses` 200 on the `connectome-host` agent |
| 2.7 | next morning: `ls -l ~/.volume-backups/daily/ \| grep "$(date +%F)"` | the 04:00 run wrote tarballs (backup daemon works) |

## End-to-end: cold boot to a working agent

After Step 2.1–2.6, ask the bot to run `uname -a && ls /workspace` in its shell
and report the output (aarch64 Linux and the workspace listing), then open
`https://cxmini.faun-fir.ts.net:8768` (basic auth from `stacks/connectome/.env`):
the quota meter shows usage and new messages appear live.

## Optional: AC7.2 live (before inviting the bot into a server with other members)

| Step | Action | Expected |
|---|---|---|
| 1 | `dotfiles stacks onecli requests 5` | baseline |
| 2 | From a second Discord account that shares a server with the bot, DM it "hello" | no reply within 2 minutes |
| 3 | @mention the bot in a server/channel that is not the whitelisted one | no reply |
| 4 | `dotfiles stacks onecli requests 5` | no new `responses` row since step 1 |
| 5 | Control: DM from the operator account | reply and a new `responses` row |

## Optional: AC7.5 live (call the attachment guard directly)

The model declines to attempt these attachments, so call discord-mcpl's
`send_message` directly. This starts a second short-lived discord-mcpl client
with the bot token; run it while the agent is idle. `export` inside `sh -c`
keeps secrets out of process argv (invariant 5).

| Step | Action | Expected |
|---|---|---|
| 1 | `docker --context colima-agents exec connectome sh -c 'env \| cut -d= -f1 \| grep ^DISCORD'` | `DISCORD_TOKEN`, `DISCORD_GUILD_ID`, `DISCORD_OPERATOR_ID` present (names only) |
| 2 | Copy the whitelisted channel id from Discord | `<CH>` |
| 3 | `docker --context colima-agents exec connectome sh -c 'export DISCORD_DM_USERS="$DISCORD_OPERATOR_ID" DISCORD_ATTACHMENT_ROOT=/agent/outbox; cd /tmp; exec /opt/node/bin/node /opt/connectome-tests/mcp-call.mjs send_message "{\"channelId\":\"<CH>\",\"content\":\"guard test\",\"files\":[{\"path\":\"/proc/self/environ\"}]}" -- /opt/node/bin/node /opt/mcpl/discord-mcpl/dist/src/index.js --stdio'` | `isError: true`, "Attachment must be inside /agent/outbox"; nothing posted |
| 4 | `docker --context colima-agents exec connectome-shell ln -sf /etc/passwd /workspace/outbox/pw`; repeat step 3 with `"path":"/agent/outbox/pw"` | `isError: true`, "must be inside"; nothing posted |
| 5 | Repeat step 3 without `DISCORD_ATTACHMENT_ROOT` in the `export` and `"path":"/agent/outbox/hello.txt"` | `isError: true`, "disabled" |
| 6 | `docker --context colima-agents exec connectome-shell rm -f /workspace/outbox/pw` | cleaned up |

## Already verified by hand during execution (re-run only on a suspected regression)

DM and channel replies, tool list, shell via term-sessions, outbox attachment,
observers EROFS, heartbeat trigger and agent-initiated interval change, WebUI
quota meter, forced inference failure (AC5.4), usage calibration and the burst
drop (AC10.2), restore rehearsal onto empty volumes with conversation context
intact (AC11.7), subagents (Luna/Astra spawn; depth limit refuses a nested spawn).

## Traceability

| Criterion | Automated | Manual |
|---|---|---|
| AC1.1, AC1.2 | waived | none |
| AC1.3 | `pgrep` | none |
| AC2.1–AC2.8 | recipes; init-env temp-file tests; bootstrap grep; secrets API | bootstrap and device login (done) |
| AC3.1, AC3.4–AC3.6 | `probe.sh` | none |
| AC3.2, AC3.3 | policy/grants jq; doctor | none |
| AC3.7 | `policy.sh`, `set-heartbeat-rate.sh`, README table | calibration (done); no per-app cap (accepted) |
| AC4.1–AC4.5 | `build.sh`, `image-test.sh`, reminder-floor tests | none |
| AC5.1–AC5.3, AC5.6–AC5.8 | `smoke.sh`, `image-test.sh`, lints | none |
| AC5.4, AC5.5 | `force-failure.sh`; `smoke.sh` | operator DM / agent-initiated change (done) |
| AC6.1–AC6.4 | provision-codex verify; `onecli requests`; gateway log | DM reply, quota meter (done); Step 2.5–2.6 |
| AC7.1, AC7.3, AC7.4, AC7.6 | `smoke.sh`; lint 8; headless.log | done; Step 2.5 |
| AC7.2 | lint 8 (static) | optional AC7.2 table (deferred) |
| AC7.5 | attachment-root tests; image-test AC7.5 | optional AC7.5 table |
| AC8.1–AC8.3 | port check; `smoke.sh`; lint 9 | WebUI live updates (done); end-to-end |
| AC9.1–AC9.5 | `image-test.sh`, `smoke.sh`, lint 4 | shell command (done); end-to-end |
| AC10.1–AC10.3 | recipe jq; `set-heartbeat-rate.sh`; `ratelimit-check.sh` | trigger and burst (done) |
| AC11.1–AC11.7 | recipes; restore refusal and rehearsal; `smoke.sh` | context DM after restore (done) |
| AC11.8 | startup log, `ps`, doctor | Task 8 Steps 0–2 (pending) |
| AC12.1–AC12.5 | `doctor.sh`, `lint-test.sh` | Step 2.4 final gate |
| AC13.1–AC13.3 | heading and term greps | read-through (done) |
