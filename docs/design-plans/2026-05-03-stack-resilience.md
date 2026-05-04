# Stack Resilience Design

## Summary

This plan systematically hardens a personal homelab dotfiles repository across four concerns: data durability, DNS resilience, operational transparency, and clean-device reproducibility. The repository manages four Docker Compose stacks (AdGuard Home, FreshRSS, Homebridge, Wallabag) running inside Colima VMs on macOS, plus GNU Stow packages for shell and editor configuration. Today the stacks vary in how they handle persistent data (some use host bind mounts, others use named Docker volumes) and lack any automated backup, making recovery from a lost VM unnecessarily painful. The plan normalizes all four stacks to a uniform host bind-mount model under `~/.volumes/<stack>/`, adds a shared nightly backup mechanism with Grandfather-Father-Son rotation, and installs a launchd timer to run it automatically.

DNS resilience addresses a structural fragility: when AdGuard Home (the tailnet-wide DNS resolver) is stopped for maintenance, the Mac and connected devices lose DNS entirely. The fix uses the Tailscale REST API to toggle the tailnet's Global Nameservers between the AdGuard VM IP and a public fallback resolver, hooked directly into the `adguard up` and `adguard down` recipes so the switch happens automatically. The remaining work — a `doctor` command for day-to-day health checking, a `bridged-ip-changed` orchestration recipe for handling VM IP drift, fail-loudly bootstrap scripts, and a bifurcated new-device setup guide — all converge on the same goal: making the system's state legible and its recovery path executable from documentation alone, without relying on operator memory.

## Definition of Done

This design is complete when all seven criteria below are met, validated against new-device clean-setup as the north star (no operation depends on undocumented manual environment state).

1. **Data durability.** freshrss + wallabag run on host bind mounts under `~/.volumes/<stack>/` (matching the adguard/homebridge pattern). Existing data is migrated using the assumptions-first methodology with no data loss. Per-stack `backup` and `restore` recipes write/read tarballs in `~/.volume-backups/`. A launchd nightly timer runs `dotfiles stacks backup-all` with GFS rotation (7 daily + 4 weekly + 3 monthly).

2. **DNS resilience.** AGH being down (planned or otherwise) does NOT brick Mac DNS. Tailscale `dns-failover on/off` recipes auto-trigger from `adguard up`/`down`. Router-DNS-advertisement behavior is investigated on the user's RT-AC68U and the chosen config is documented; WAN DNS is set to a non-AGH resolver so the router itself survives AGH outages.

3. **Recreation cheap and honest.** A `bridged-ip-changed` recipe re-runs all the automatable refreshes (AGH config patch, both bridged-stack `serve` recipes, `advertise`) and prints a checklist of human-must-do steps. The misleading "in-place migration" section in `stacks/README.md` is replaced with clear "limactl rename is not viable; use clean-slate" guidance. The bridged-VM-IP dependency graph is documented in one place.

4. **Static-MAC research.** Documented as: "bridged MAC is qemu-deterministic from the lima instance directory path; stable across `colima delete -p bridged && colima start -p bridged`; only changes on profile rename or move." No code change required.

5. **Sanity recipes.** `dotfiles stacks doctor` checks: VMs running, contexts present, host mounts working, `~/.volumes/<stack>/` exists for stacks needing it, `.env` files have all expected keys (presence-only check, never reads values), homebridge `BRIDGE_USERNAME` matches `config.json`, Tailscale serve mappings match the current bridged VM IP. Bootstrap recipes fail loudly with actionable messages when state is unexpected.

6. **Documentation hardening.** `CLAUDE.md` gains a "reproducible vs runtime" section and a note about Colima's first-start config mutation being expected. `homebridge/README.md` documents `BRIDGE_USERNAME` and `HOMEKIT_PIN` as pairing-identity-critical. The homebridge pin generator rejects HomeKit reserved pins (`000-00-000`, `111-11-111`...`999-99-999`, `123-45-678`, `876-54-321`) by retrying.

7. **Code organization.** Every justfile recipe is ≤1–2 lines; anything more lives in `stacks/<stack>/scripts/` or `scripts/` next to the relevant justfile. The new-device clean-setup path is statically validated end-to-end against the README + committed scripts; nothing relies on undocumented manual environment state.

## Acceptance Criteria

### stack-resilience.AC1: Data durability — host bind mounts + backup/restore + nightly rotation

- **stack-resilience.AC1.1 Success:** `stacks/freshrss/compose.yaml` uses `${HOME}/.volumes/freshrss/{data,extensions}` bind mounts; the top-level `volumes:` block is removed.
- **stack-resilience.AC1.2 Success:** `stacks/wallabag/compose.yaml` uses `${HOME}/.volumes/wallabag/{data,images}` bind mounts; the top-level `volumes:` block is removed.
- **stack-resilience.AC1.3 Success:** After freshrss migration, login as user `cxreiff` succeeds and feeds present pre-migration are still present (data preserved).
- **stack-resilience.AC1.4 Success:** After wallabag migration, login as `ADMIN_USERNAME` succeeds (data preserved).
- **stack-resilience.AC1.5 Success:** `dotfiles stacks <stack> backup` creates `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz`; `tar tzf` lists expected paths.
- **stack-resilience.AC1.6 Success:** `dotfiles stacks backup-all` produces a fresh tarball for each of the four stacks AND runs `backup-rotate.sh` exactly once at the end.
- **stack-resilience.AC1.7 Success:** `backup-rotate.sh` promotes Sunday's daily tarball into `weekly/` (one per stack); promotes the 1st-of-month daily into `monthly/`. Idempotent — re-runs same day don't duplicate.
- **stack-resilience.AC1.8 Success:** `backup-rotate.sh` prunes `daily/` to last 7 per stack, `weekly/` to last 4 per stack, `monthly/` to last 3 per stack (by mtime).
- **stack-resilience.AC1.9 Success:** `dotfiles stacks backup-install` installs `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist`; `launchctl print` shows it scheduled for 4:00 daily.
- **stack-resilience.AC1.10 Success:** AGH container `Up` time crosses the AGH backup operation (AGH NEVER stopped during backup).
- **stack-resilience.AC1.11 Failure:** `dotfiles stacks <stack> restore <tarball>` against a non-empty `~/.volumes/<stack>/` exits non-zero unless `--force` is passed.
- **stack-resilience.AC1.12 Edge:** Same-day re-run of `backup` cleanly overwrites today's tarball without error.

### stack-resilience.AC2: DNS resilience — tailnet-dns recipes + auto-hooks + router config

- **stack-resilience.AC2.1 Success:** `dotfiles stacks adguard tailnet-dns-on` sets Tailscale Global Nameservers to `[<bridged-vm-ip>]` via `POST /api/v2/tailnet/-/dns/nameservers`.
- **stack-resilience.AC2.2 Success:** `dotfiles stacks adguard tailnet-dns-off` sets Tailscale Global Nameservers to `["1.1.1.1"]` via the same endpoint.
- **stack-resilience.AC2.3 Success:** `dotfiles stacks adguard tailnet-dns-status` reports the current Global Nameservers JSON from the API.
- **stack-resilience.AC2.4 Success:** `dotfiles stacks adguard up` invokes `tailnet-dns-on` AFTER `wait-healthy.sh` confirms AGH responds to `dig`.
- **stack-resilience.AC2.5 Success:** `dotfiles stacks adguard down` invokes `tailnet-dns-off` BEFORE `compose down`.
- **stack-resilience.AC2.6 Success:** With AGH stopped via `dotfiles stacks adguard down`, the Mac resolves `example.com` successfully (DNS not bricked).
- **stack-resilience.AC2.7 Edge:** `tailnet-dns-on` or `-off` run twice in a row makes no second API write call (idempotent via GET comparison).
- **stack-resilience.AC2.8 Failure:** Tailscale API unreachable during `adguard up` — recipe exits non-zero with the curl error AND a recovery hint; AGH container remains running.
- **stack-resilience.AC2.9 Failure:** Tailscale API unreachable during `adguard down` — recipe exits non-zero with recovery hint; AGH container is NOT stopped (don't brick DNS while we can't fail it over first).
- **stack-resilience.AC2.10 Success:** Router WAN DNS is configured to a non-AGH resolver; documented in `stacks/adguard/README.md`.
- **stack-resilience.AC2.11 Success:** ASUSWRT DHCP-DNS-advertisement behavior is investigated and the chosen final config is documented in `stacks/adguard/README.md`.

### stack-resilience.AC3: Recreation cheap and honest — bridged-ip-changed + dependency-graph + rename rewrite

- **stack-resilience.AC3.1 Success:** `dotfiles stacks bridged-ip-changed` patches `~/.volumes/adguard/conf/AdGuardHome.yaml` `bind_hosts:`, restarts AGH, refreshes both `serve` mappings, re-runs `advertise`, and refreshes Tailscale Global NS via `tailnet-dns-on`.
- **stack-resilience.AC3.2 Success:** `bridged-ip-changed` prints a closing checklist with the live bridged-VM MAC (from `colima ssh ... ip link show col0`) and IP for the user's manual router + Tailscale admin steps.
- **stack-resilience.AC3.3 Success:** `stacks/README.md` "Renaming a Colima profile" section explicitly warns against `limactl rename` and points to the clean-slate procedure in `docs/migration-recovery.md`.
- **stack-resilience.AC3.4 Success:** `stacks/README.md` has a single "When the bridged VM IP changes" section enumerating every coupling (AGH config, both serve mappings, subnet route advertise, Tailscale Global NS, router DHCP reservation).
- **stack-resilience.AC3.5 Success:** `docs/migration-recovery.md` exists with the clean-slate procedure (extracted from the May 2026 recovery walk-through).

### stack-resilience.AC4: Static-MAC research

- **stack-resilience.AC4.1 Success:** `stacks/README.md` (or `stacks/adguard/README.md`) documents that the bridged VM MAC is qemu-deterministic from the lima instance directory path, stable across `colima delete -p bridged && colima start -p bridged`, only changes on profile rename or move of `~/.colima/_lima/`.

### stack-resilience.AC5: Sanity recipes — doctor + bootstrap fail-loudly

- **stack-resilience.AC5.1 Success:** `dotfiles stacks doctor` runs end-to-end and produces output for every defined check.
- **stack-resilience.AC5.2 Success:** Each check reports `[OK]`, `[WARN]`, or `[FAIL]` with a one-line message.
- **stack-resilience.AC5.3 Failure:** Intentionally breaking one check (e.g., `colima stop -p bridged`) makes `doctor` exit non-zero and clearly identifies the failing check.
- **stack-resilience.AC5.4 Success:** `doctor` never reads any `.env` value — only counts keys via `grep -c '^KEY='` and similar (auditable from script source).
- **stack-resilience.AC5.5 Success:** `doctor` completes in <5s on a healthy environment.
- **stack-resilience.AC5.6 Success:** `doctor` warns/fails when the latest backup tarball for any stack is older than 36 hours.
- **stack-resilience.AC5.7 Success:** `doctor` warns/fails when AGH `bind_hosts:` doesn't match the current bridged-VM `col0` IP.
- **stack-resilience.AC5.8 Success:** `doctor` warns/fails when homebridge `BRIDGE_USERNAME` from `.env` doesn't match `~/.volumes/homebridge/config.json` `bridge.username`.
- **stack-resilience.AC5.9 Failure:** Homebridge `bootstrap` invoked when `setupWizardComplete: true` AND `auth.json` lacks `ADMIN_USERNAME` exits with code 1 and prints "detected X but expected Y" + a one-line recovery hint.
- **stack-resilience.AC5.10 Failure:** Wallabag `bootstrap` invoked when default `wallabag` user is already deactivated AND `ADMIN_USERNAME` user does not exist exits with code 1 + description + recovery hint.
- **stack-resilience.AC5.11 Failure:** Bootstrap recipes exit with code 2 when prerequisites are missing (env key absent, container not running, API unreachable for preflight); code 3 when an upstream API/CLI returns an error during the actual bootstrap operation.

### stack-resilience.AC6: Documentation hardening + pin generator validation

- **stack-resilience.AC6.1 Success:** `CLAUDE.md` contains a "Reproducible vs runtime" section enumerating what's in repo vs runtime/environment.
- **stack-resilience.AC6.2 Success:** `CLAUDE.md` has a note about Colima first-start config mutations being expected (rare lifecycle event, not runtime churn) and that we commit them.
- **stack-resilience.AC6.3 Success:** `stacks/homebridge/README.md` has a "Pairing identity" section explaining `BRIDGE_USERNAME` and `HOMEKIT_PIN` are pairing-identity-critical, never regenerate after pairing, restoring `~/.volumes/homebridge/` is the only "same identity" path.
- **stack-resilience.AC6.4 Success:** `stacks/homebridge/scripts/gen-pin.sh` exists and produces valid `XXX-XX-XXX` 8-digit pins on stdout.
- **stack-resilience.AC6.5 Failure:** Running `gen-pin.sh` 100 times in a loop produces zero pins matching the 12-entry HomeKit reserved list.
- **stack-resilience.AC6.6 Success:** `stacks/homebridge/.env.example` `HOMEKIT_PIN` comment references `gen-pin.sh` as the canonical generator.

### stack-resilience.AC7: Code organization + new-device clean-setup validation

- **stack-resilience.AC7.1 Success:** Every justfile recipe is ≤1–2 lines; recipes that need more delegate to a script in `stacks/scripts/` or `stacks/<stack>/scripts/`.
- **stack-resilience.AC7.2 Success:** `stacks/scripts/` directory contains the stacks-shared scripts: `doctor.sh`, `tar-stack.sh`, `restore-stack.sh`, `backup-rotate.sh`, `bridged-ip-changed.sh`, `backup-install.sh`, `lib/check.sh`.
- **stack-resilience.AC7.3 Success:** Per-stack `scripts/` directories exist for stacks needing them: `stacks/adguard/scripts/{tailnet-dns.sh, wait-healthy.sh}`, `stacks/wallabag/scripts/{bootstrap.sh}`, `stacks/homebridge/scripts/{bootstrap.sh, gen-pin.sh}`. (No per-stack `backup.sh` — single shared `stacks/scripts/backup.sh` handles all four.)
- **stack-resilience.AC7.4 Success:** Top-level `README.md` documents Stage 1 (universal: brew base + clone + `dotfiles stow setup-base`) without referencing container concepts. `stow/README.md` documents per-package setup (`setup-base`, `setup-colima`). `stacks/README.md` documents Stages 2 + 3 (containers + per-stack) with `dotfiles stow setup-colima` as an explicit prerequisite.
- **stack-resilience.AC7.5 Success:** Each stage's walkthrough references only earlier-step deliverables or documented manual actions; Stage 1 has no container dependencies; Stages 2 + 3 declare their stow-side prerequisites; no step depends on undocumented manual environment state.
- **stack-resilience.AC7.6 Success:** Phase 8 audit produces a documented gap list; every gap is fixed within the same plan execution.
- **stack-resilience.AC7.7 Success:** `dotfiles stow setup-base` stows only `base`; `dotfiles stow setup-colima` stows only `colima`; aggregate `setup` stows both.

## Glossary

- **AdGuard Home (AGH)**: Self-hosted DNS server and network-wide ad blocker. In this setup it serves as the tailnet's recursive DNS resolver, running in a dedicated bridged Colima VM.
- **Colima**: A macOS tool that runs Docker-compatible container runtimes inside lightweight Linux VMs. This repo uses two profiles: `shared` (vz/vzNAT) for general stacks, and `bridged` (qemu/socket_vmnet) for stacks that need a real LAN IP (AdGuard, Homebridge).
- **bridged networking**: A VM network mode where the VM gets its own IP on the physical LAN (via `socket_vmnet`), as opposed to NAT where the VM shares the host's IP. Required here so AdGuard receives DNS queries with real client source IPs and Homebridge advertises HomeKit on the LAN.
- **vzNAT**: Apple Virtualization Framework NAT networking used by Colima's `shared` profile (which uses the vz VM type). Fast and low-overhead but does not support bridged networking, so client source IPs are not visible to containers.
- **qemu**: An open-source machine emulator used by Colima's `bridged` profile specifically because it supports bridged networking via `socket_vmnet`. Slower than `vz` but necessary for AdGuard and Homebridge.
- **socket_vmnet**: A macOS daemon that provides bridged networking support for QEMU-based VMs, giving the VM a real LAN IP address.
- **GNU Stow**: A symlink farm manager used to deploy dotfiles from `stow/` into `$HOME`. Each subdirectory under `stow/` is a "package" whose contents get symlinked into the home directory.
- **host bind mount**: A Docker volume type where a specific directory on the host filesystem is mounted directly into the container, as opposed to a Docker-managed named volume. Bind mounts make data location explicit, portable, and easy to back up with standard tools.
- **named volume**: A Docker-managed persistent volume with an opaque storage location under Docker's data root. Harder to back up and migrate than host bind mounts.
- **Tailscale**: A VPN mesh networking tool that creates a private "tailnet" across the user's devices. Used here both for remote access to self-hosted services (via `tailscale serve`) and as the DNS distribution mechanism for AdGuard.
- **tailnet**: The private network formed by all of a user's Tailscale-connected devices.
- **Tailscale Global Nameservers**: A Tailscale setting that pushes a DNS server address to all devices on the tailnet. Configured here to point at the AdGuard VM IP so all tailnet devices benefit from DNS filtering.
- **Tailscale serve**: A Tailscale feature that publishes a local HTTP service at a stable `https://<hostname>.ts.net` URL accessible within the tailnet.
- **Tailscale PAT (Personal Access Token)**: An API credential used to authenticate programmatic calls to the Tailscale REST API. Needed here with `dns:write` scope to toggle Global Nameservers.
- **`just` / justfile**: A command runner (similar to `make` but simpler). All user-facing commands in this repo are defined in justfiles and invoked via `dotfiles <subcommand>`.
- **just subsequent dependency (`recipe: dep && post`)**: just syntax where `post` runs after the recipe body completes successfully; if the body fails, `post` is skipped. Used here to declare per-stack quiesce intent (`backup: down && up`).
- **GFS rotation (Grandfather-Father-Son)**: A backup retention scheme that keeps backups at three time granularities — daily (short-term), weekly (medium-term), and monthly (long-term) — pruning older copies at each tier to bound storage use.
- **launchd**: macOS's system and service manager, used here to schedule the nightly backup as a user-level `LaunchAgent`.
- **`LaunchAgent` / plist**: A launchd job definition stored as a `.plist` XML file in `~/Library/LaunchAgents/`. Runs under the user's account and can fire on a schedule or on wake from sleep.
- **lima / limactl**: The underlying VM management layer that Colima uses. `limactl rename` is a lima command that renames a VM profile but does not rewrite hardcoded paths in the VM's configuration, making it unsafe for profile renames.
- **doctor recipe**: A read-only diagnostic command (`dotfiles stacks doctor`) that runs a series of checks across infrastructure and per-stack state, reporting `[OK]`, `[WARN]`, or `[FAIL]` for each.
- **bootstrap recipe**: A one-time setup command that initializes application state after a stack's first `up` — e.g., creating the first admin user in Wallabag or completing the Homebridge setup wizard.
- **FOSUserBundle**: A Symfony bundle providing user management CLI commands, used by Wallabag to create and manage user accounts from the command line inside the container.
- **Config UI X**: The Homebridge web UI, which also exposes an HTTP API used by the homebridge bootstrap script to complete the setup wizard and create the first admin user.
- **`BRIDGE_USERNAME`**: The Homebridge MAC address used as a pairing identity with HomeKit. Changing it after pairing breaks the HomeKit relationship and requires re-pairing all accessories.
- **HomeKit reserved pins**: Pin codes that Apple prohibits for HomeKit pairing (`000-00-000` through `999-99-999` repeating digits, `123-45-678`, `876-54-321`). The `gen-pin.sh` script retries until it produces a non-reserved pin.
- **RT-AC68U / ASUSWRT**: The user's ASUS home router and its firmware. Its DHCP DNS advertisement behavior — whether and how it tells LAN clients which DNS servers to use — is investigated in Phase 6.
- **subnet route / `advertise`**: A Tailscale feature where a node advertises a LAN subnet to the tailnet so other tailnet devices can reach LAN IPs without being on the LAN.
- **`colima list | awk`**: The idiom used throughout the repo to discover the bridged VM's current LAN IP from Colima's runtime state. Scripts that need the IP use this pattern rather than hardcoding it.
- **assumptions-first methodology**: An approach to migration/recovery where preconditions are explicitly verified before any destructive step is taken, so failures are caught early with clear diagnostics rather than mid-operation.

## Architecture

The design extends the existing `stacks/` pattern uniformly. After this work, all four stacks (adguard, freshrss, homebridge, wallabag) keep their persistent state in host bind mounts under `~/.volumes/<stack>/`, and a single shared backup mechanism tars those directories nightly with GFS rotation into `~/.volume-backups/`. State on disk is the single source of truth; VMs and containers are disposable.

DNS resilience is handled by a `tailnet-dns` script (in `stacks/adguard/scripts/`) that toggles Tailscale's tailnet-wide Global Nameservers via the Tailscale REST API. The script is hooked into `adguard up` and `adguard down` so planned maintenance never strands the tailnet on a dead resolver. Tailscale's CLI does not support this configuration ([tailscale#5430](https://github.com/tailscale/tailscale/issues/5430)) and its multi-resolver fallback is unreliable on macOS ([tailscale#12677](https://github.com/tailscale/tailscale/issues/12677)) — using the API as a deliberate switch is the only reliable mechanism. A personal access token (`dns:write` scope) lives in `stacks/adguard/.env`.

The bridged VM IP is **pinned** via router DHCP reservation as a setup step. This eliminates the frequent-friction case of VM recreate (qemu-deterministic MAC ⇒ same DHCP lease ⇒ same IP). A `bridged-ip-changed` orchestration recipe handles the rare cases where the IP does change (router replacement, subnet renumbering, lost reservation) by re-running every automatable refresh and printing a checklist of manual steps. Doctor (`dotfiles stacks doctor`) is the day-to-day tripwire that detects drift between repo state and runtime state — ~12 read-only checks across infrastructure, per-stack state, and external dependencies. Bootstrap recipes (wallabag, homebridge) gain a fail-loudly contract with explicit assumptions, structured exit codes, and recovery hints — replacing the silent "assume bootstrap already ran" pattern that cost us during the recovery exercise.

Code organization respects two rules: justfile recipes are ≤1–2 lines, with logic delegated to scripts; scripts colocate with their layer (stacks-shared in `stacks/scripts/`, per-stack in `stacks/<stack>/scripts/`). The launchd plist for nightly backups installs to `~/Library/LaunchAgents/` and is **not** part of stow — it's per-machine setup, distinct from config dotfiles, and the audience for stow is broader than the audience for the stacks side of the repo.

## Existing Patterns

This design follows several well-established patterns from the existing stacks tree, and extends them uniformly:

- **Per-stack file layout** (`stacks/<stack>/{justfile, compose.yaml, README.md, .env.example}`, optional config templates): unchanged. New per-stack `scripts/` directory follows the user constraint.
- **Host bind mount convention** (`~/.volumes/<stack>/`): currently followed by `adguard` and `homebridge`. This design extends it to `freshrss` and `wallabag`, removing their last named-volume dependencies. After migration, all four stacks share the same volume model.
- **Justfile context idiom** (`docker --context colima-<profile>`): unchanged. New scripts that need docker access reuse this idiom.
- **Live-VM-IP discovery** (`colima list | awk '/^bridged/'`): used today by `adguard serve` and `adguard advertise`. The new `tailnet-dns.sh`, `wait-healthy.sh`, and `bridged-ip-changed.sh` reuse this exact awk pattern for consistency.
- **`.env` conventions** (tracked `.env.example`, gitignored `.env` at mode `0600`, `.gitignore` allowlists `*.env.example`): unchanged. Adguard's `.env.example` gains a `TAILSCALE_PAT` placeholder.
- **Bootstrap recipe pattern** (wallabag uses FOSUserBundle CLI; homebridge uses Config UI X HTTP API): structure unchanged. Both gain the fail-loudly contract on top of existing flow.
- **Init recipe convention** (`mkdir -p` for host volume dirs as a recipe dependency): currently followed by `adguard`. Freshrss and wallabag gain the same shape.
- **`init` as a `up` prerequisite** (just dependency syntax: `up: init`): existing `adguard` pattern, extended uniformly.

No fundamentally new pattern is introduced. The design fills in inconsistencies and adds operational tooling.

## Implementation Phases

8 phases, ordered by dependency. Each phase ends with a runnable verification.

<!-- START_PHASE_1 -->
### Phase 1: Doctor recipe (verification foundation)

**Goal:** Establish the read-only `dotfiles stacks doctor` recipe so later phases have a single command to verify expected state. Doctor begins as a minimal skeleton and expands as later phases add their own concerns.

**Components:**
- `stacks/scripts/` — new directory for stacks-shared scripts.
- `stacks/scripts/doctor.sh` — initial skeleton with infrastructure checks: both Colima profiles Running, both docker contexts present and resolvable, `socket_vmnet` daemon running. ~30 lines initially.
- `stacks/justfile` — gains a `doctor` recipe (one-line delegation: `./scripts/doctor.sh`).
- `stacks/scripts/lib/check.sh` — small shared helper exporting `pass()`, `warn()`, `fail()` for consistent `[OK]/[WARN]/[FAIL]` output. Used by all later additions to doctor.

**Dependencies:** None (first phase).

**ACs covered:** `stack-resilience.AC5.1`, `stack-resilience.AC5.2`, `stack-resilience.AC5.3`, `stack-resilience.AC5.4`, `stack-resilience.AC5.5` (subset — initial infra checks; later phases add per-stack checks).

**Done when:** `dotfiles stacks doctor` runs end-to-end, reports `[OK]` for all infra checks against the current healthy environment, exits 0; intentionally breaking one check (e.g., `colima stop -p bridged`) makes doctor exit non-zero with a clear `[FAIL]` line and a one-line hint.
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: Backup + restore mechanism (host-bind stacks)

**Goal:** Per-stack `backup` and `restore` recipes for the two stacks that already use host bind mounts (adguard, homebridge). Proves the mechanism end-to-end before extending it to freshrss/wallabag in Phase 3. Single shared backup script; per-stack quiesce intent declared via flag in each stack's recipe.

**Components:**
- `stacks/scripts/backup.sh` — single shared script: takes `<stack-name>`. Does `mkdir -p ~/.volume-backups/daily/` and tars `~/.volumes/<stack>/` into `~/.volume-backups/daily/<stack>-YYYY-MM-DD.tgz` (overwrites same-day). ~10 lines, no quiesce logic — quiesce is declared at the justfile-recipe level via just's `down && up` subsequent dependency syntax.
- `stacks/scripts/restore.sh` — shared script: takes `<stack-name>` and `<tarball-path>`. Refuses if `~/.volumes/<stack>/` is non-empty unless `--force`. Caller is responsible for stopping the stack (restore typically only runs at first-up time anyway).
- `stacks/adguard/justfile` — gains `backup: ../scripts/backup.sh adguard` and `restore: ../scripts/restore.sh adguard {{tarball}}` (no quiesce — AGH stays up always; tar runs against live state).
- `stacks/homebridge/justfile` — gains `backup: down && up\n    ../scripts/backup.sh homebridge` and `restore: ../scripts/restore.sh homebridge {{tarball}}`. The `down && up` syntax runs `just down` before the body and `just up` after on success. **Trade-off accepted:** a tar failure leaves the container stopped (subsequents don't fire on body failure). For unattended nightly use, launchd's stderr log captures the failure to `~/.volume-backups/.log/`; manual `just up` recovers in seconds. Promoted to a trap-based safety net only if this trade-off proves painful.
- No per-stack `backup.sh`/`restore.sh` scripts — the shared script is the only one.
- Doctor extension: doctor checks that latest tarball in `daily/` is < 36 hours old per stack (initially WARN, since backups aren't scheduled yet — Phase 4 will install the launchd timer).

**Dependencies:** Phase 1 (doctor exists; reuses `lib/check.sh` for the new check).

**ACs covered:** `stack-resilience.AC1.5`, `stack-resilience.AC1.10`, `stack-resilience.AC5.6` (latest-backup check).

**Done when:** `dotfiles stacks adguard backup` writes a valid tarball at the expected path. AGH container `Up` time crosses the backup operation (verifying it stayed running). `dotfiles stacks homebridge backup` writes a tarball; homebridge container restarted (verified by uptime reset). Both tarballs extract correctly with `tar tzf`. `dotfiles stacks doctor` reports the new backup-age check.
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: Migrate freshrss + wallabag to bind mounts

**Goal:** Move freshrss and wallabag from named Docker volumes to `~/.volumes/<stack>/` host bind mounts. Migration is **execution-time work**, not committed scripts — the implementation plan documents the assumptions-first procedure, not the repo. Repo-committed outputs are the new compose mounts and the new `init` + `backup`/`restore` recipes.

**Components:**
- `stacks/freshrss/compose.yaml` — drop top-level `volumes:` block; swap to `${HOME}/.volumes/freshrss/data:/var/www/FreshRSS/data` and `${HOME}/.volumes/freshrss/extensions:/var/www/FreshRSS/extensions`.
- `stacks/freshrss/justfile` — `init` recipe (mkdir on host paths) becomes a `up` prerequisite, matching adguard. `backup: down && up\n    ../scripts/backup.sh freshrss` (just-subsequent pattern; same trade-off note as homebridge in Phase 2) and `restore: ../scripts/restore.sh freshrss {{tarball}}`.
- `stacks/wallabag/compose.yaml` — same shape: `${HOME}/.volumes/wallabag/data:/var/www/wallabag/data`, `${HOME}/.volumes/wallabag/images:/var/www/wallabag/web/assets/images`.
- `stacks/wallabag/justfile` — `init`, `backup` (with `down && up` subsequent), `restore` mirroring freshrss.
- Stack READMEs note the bind-mount paths.
- **Migration procedure (in implementation plan, not committed):** per-stack: pre-flight (verify `~/.volumes/<stack>/` doesn't exist, current `compose.yaml` still uses the named volume, fresh backup tarball from Phase 2 mechanism exists); `compose down`; `mkdir -p ~/.volumes/<stack>/<dir>`; one-shot `docker run --rm -v <stack>_<vol>:/src -v ~/.volumes/<stack>/<dir>:/dst alpine cp -av /src/. /dst/`; edit `compose.yaml`; `compose up -d`; smoke-test (HTTP 302 + log line confirming user data recognized); doctor.
- Doctor extension: per-stack `~/.volumes/<stack>/` exists and is non-empty for all four stacks now.

**Dependencies:** Phase 2 (backup mechanism — used to take pre-migration safety tarball).

**ACs covered:** `stack-resilience.AC1.1`, `stack-resilience.AC1.2`, `stack-resilience.AC1.3`, `stack-resilience.AC1.4`.

**Done when:** Both `compose.yaml` files use bind mounts (no `volumes:` top-level block). `~/.volumes/{freshrss,wallabag}/` are populated. `dotfiles stacks freshrss up` and `wallabag up` start cleanly. Smoke-test: freshrss serves the `cxreiff` user (login works); wallabag serves the admin user (login works). `dotfiles stacks doctor` is all-green.
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: backup-all + GFS rotation + launchd timer

**Goal:** Aggregate `backup-all` recipe, GFS promotion + pruning, and the nightly launchd timer that runs at 4am.

**Components:**
- `stacks/justfile` — `backup-all` recipe with one line per stack (matching `up-all` style) followed by `./scripts/backup-rotate.sh`.
- `stacks/scripts/backup-rotate.sh` — promotes the most recent daily into `weekly/` on Sundays (idempotent: skip if today's weekly already exists), promotes into `monthly/` on the 1st of each month, prunes `daily/` to last 7 / `weekly/` to last 4 / `monthly/` to last 3 by file mtime.
- `stacks/scripts/backup-install.sh` — templates and installs `~/Library/LaunchAgents/com.cxreiff.dotfiles.backup.plist` (substitutes user's `$HOME` path), `launchctl bootstrap gui/$uid` to load. Idempotent: `launchctl bootout` first if already loaded.
- `stacks/justfile` — `backup-install` recipe (one-line delegation).
- launchd plist runs `dotfiles stacks backup-all` daily at 4:00 local; `StandardOutPath`/`StandardErrorPath` to `~/.volume-backups/.log/{stdout,stderr}.log`; fires-on-wake if Mac asleep at 4am.
- Doctor extension: latest backup < 36h old per stack now hard-FAIL (timer is supposed to be running).

**Dependencies:** Phases 2 + 3 (per-stack `backup` recipes exist for all four stacks).

**ACs covered:** `stack-resilience.AC1.6`, `stack-resilience.AC1.7`, `stack-resilience.AC1.8`, `stack-resilience.AC1.9`.

**Done when:** `dotfiles stacks backup-all` writes a fresh tarball for each of the four stacks. `dotfiles stacks backup-install` installs and loads the plist. `launchctl print gui/$uid/com.cxreiff.dotfiles.backup` shows it scheduled for 4am. Manually run `launchctl kickstart` of the plist; verify the next-day tarballs appear and stdout/stderr logs land in `~/.volume-backups/.log/`. Force a Sunday + first-of-month rotation by running `backup-rotate.sh` with `TZ=…` or by stubbing `date`; verify weekly + monthly tarballs appear and old dailies prune.
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: `tailnet-dns` recipe + adguard up/down hooks

**Goal:** Toggle Tailscale tailnet-wide Global Nameservers between AGH and a public fallback (1.1.1.1) via the Tailscale API. Auto-trigger from `adguard up`/`down` so planned maintenance never strands the tailnet.

**Components:**
- `stacks/adguard/.env.example` — gains `TAILSCALE_PAT` placeholder with comment explaining how to generate (admin → Settings → Keys, scope `dns:write`, recommended 90-day expiry). Tailnet identifier is the literal `-` per Tailscale API; no second variable needed.
- `stacks/adguard/scripts/tailnet-dns.sh` — three subcommands `on`, `off`, `status`. Sources `.env`. Preflight: `TAILSCALE_PAT` non-empty, `api.tailscale.com` reachable. Reads bridged VM IP via existing `colima list | awk` idiom. `on` → `POST /api/v2/tailnet/-/dns/nameservers` body `{"dns":["<vm-ip>"]}`; `off` → body `{"dns":["1.1.1.1"]}`. Idempotent (compares against `GET` first). `status` prints current nameservers JSON. ~50 lines.
- `stacks/adguard/scripts/wait-healthy.sh` — polls `dig @<vm-ip> example.com +time=2 +tries=1` until success or 60s timeout. ~10 lines.
- `stacks/adguard/justfile` — three new recipes (`tailnet-dns-on`, `-off`, `-status`), each one-line delegation. `up` and `down` recipes hook in:
  ```
  up: init
      docker --context {{context}} compose up -d
      ./scripts/wait-healthy.sh && ./scripts/tailnet-dns.sh on
  down:
      ./scripts/tailnet-dns.sh off
      docker --context {{context}} compose down
  ```
  (Each line ≤2; orchestration logic stays in scripts.)
- Doctor extension: queries `tailnet-dns.sh status`, compares against AGH container state (running ⇒ NS should be AGH IP; stopped ⇒ NS should be 1.1.1.1).
- adguard/README.md gains a "DNS failover" section explaining the API token setup and the auto-hook behavior.

**Dependencies:** Phase 1 (doctor) — for the new state-consistency check.

**ACs covered:** `stack-resilience.AC2.1`, `stack-resilience.AC2.2`, `stack-resilience.AC2.3`, `stack-resilience.AC2.4`, `stack-resilience.AC2.5`, `stack-resilience.AC2.6`, `stack-resilience.AC2.7`, `stack-resilience.AC2.8`, `stack-resilience.AC2.9`.

**Done when:** `tailnet-dns-status` reports current Tailscale Global NS state. `tailnet-dns-on` sets NS to bridged VM IP (verified via `tailnet-dns-status`). `tailnet-dns-off` sets NS to `1.1.1.1`. Re-running either is a no-op. `dotfiles stacks adguard down` flips NS to fallback before stopping; `up` flips back to AGH after AGH responds to `dig`. With AGH down + NS = `1.1.1.1`, `dig example.com` from the Mac succeeds. Failure-mode tests: temporarily revoke PAT — `up`/`down` exits non-zero with the API error and a recovery hint; AGH state is preserved (not stopped during a failed `down`).
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: `bridged-ip-changed` orchestration + router-DNS investigation

**Goal:** Single recipe that re-runs every automatable refresh after the bridged VM's IP changes. Investigate the user's RT-AC68U DHCP advertisement behavior and document the final router-side configuration (including WAN DNS being non-AGH so the router itself survives AGH outages).

**Components:**
- `stacks/scripts/bridged-ip-changed.sh` — resolve current VM IP via `colima list`, patch `~/.volumes/adguard/conf/AdGuardHome.yaml` `bind_hosts:` (sed with `.bak`), `dotfiles stacks adguard restart`, drop-and-re-add Tailscale serve mappings for `:8689` and `:8767`, `dotfiles stacks adguard advertise`, `dotfiles stacks adguard tailnet-dns-on` (refreshes Global NS to new IP). At the end, prints a checklist with the live MAC (from `colima ssh -p bridged -- ip link show col0`) and the resolved IP for the user to update router DHCP reservation and Tailscale admin route approval.
- `stacks/justfile` — `bridged-ip-changed` recipe (one-line delegation).
- `stacks/README.md` — new "When the bridged VM IP changes" section enumerating the dependency graph + pointing at the recipe. Replaces the misleading "in-place migration" content with: "Renames are not viable in place. `limactl rename` doesn't rewrite hardcoded paths in `lima.yaml`. Use clean-slate per `docs/migration-recovery.md`." Adds the static-MAC research outcome inline (qemu-deterministic; stable across recreate of same name).
- `stacks/adguard/README.md` — new "Pin bridged VM IP" setup step **before** the AGH wizard step: "Read the bridged VM MAC via `colima ssh -p bridged -- ip link show col0`. Set router DHCP reservation: MAC → chosen IP. Restart bridged VM. Document the chosen IP."
- `docs/migration-recovery.md` — extracted from the recovery walk-through (Phase A–F sequence we did) as ops reference.
- **Router-DNS investigation (executed during plan, results documented):** test ASUSWRT settings to determine: (a) does setting "DNS Server 1/2" under LAN → DHCP Server propagate both to DHCP clients? (b) does setting "Advertise the router's IP in addition to user-specified DNS = No" change client-visible nameservers? Document the final config (WAN DNS = `1.1.1.1` or similar non-AGH, plus whatever DHCP-DNS-advertisement the testing reveals as best for client-side fallback).
- adguard/README.md documents the chosen final router config.
- Doctor extension: AGH `bind_hosts:` IP equals current bridged-VM `col0` IP. Tailscale serve mappings for `:8689` and `:8767` point at current bridged-VM IP.

**Dependencies:** Phase 5 (`tailnet-dns-on` is invoked from within `bridged-ip-changed`).

**ACs covered:** `stack-resilience.AC3.1`, `stack-resilience.AC3.2`, `stack-resilience.AC3.3`, `stack-resilience.AC3.4`, `stack-resilience.AC3.5`, `stack-resilience.AC4.1`, `stack-resilience.AC2.10`, `stack-resilience.AC2.11`, `stack-resilience.AC5.7`.

**Done when:** Manually changing the bridged VM IP (e.g., temporarily revoking router reservation + restarting VM) and running `dotfiles stacks bridged-ip-changed` results in: AGH config patched, AGH restarted, Tailscale serve mappings refreshed to new IP, subnet route re-advertised, Tailscale Global NS updated. Doctor reports `[OK]` after. The printed checklist accurately reflects the new MAC + IP. Router-side investigation results are documented in adguard/README.md.
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: Documentation hardening + pin generator + bootstrap fail-loudly

**Goal:** All documentation hardening + pin generator work + bootstrap recipe upgrades. Mostly text + small scripts; cohesive because all about robustness of existing pieces.

**Components:**
- `CLAUDE.md` — new "Reproducible vs runtime" section after "Repo shape": what's in repo (structure, configs, scripts, READMEs, `.env.example`), what's runtime/environment-specific (`.env`, `~/.volumes/`, bridged VM MAC + IP, Tailscale tailnet name + PAT). Plus a note about Colima first-start mutations being expected and committed (rare; lifecycle event, not runtime churn).
- `stacks/homebridge/README.md` — new "Pairing identity" section near the top: `BRIDGE_USERNAME` and `HOMEKIT_PIN` are pairing-identity-critical, never regenerate after pairing, restoring `~/.volumes/homebridge/` is the only "same identity" path.
- `stacks/homebridge/scripts/gen-pin.sh` — ~15 lines. Generates random 8 digits, formats as `XXX-XX-XXX`, retries until non-reserved. Reserved list: 12 entries (`000-00-000`...`999-99-999`, `123-45-678`, `876-54-321`). Prints to stdout for the user to copy into `.env`.
- `stacks/homebridge/.env.example` — `HOMEKIT_PIN` comment points at `gen-pin.sh`.
- `stacks/wallabag/scripts/bootstrap.sh` — replaces the inline justfile bootstrap. Adds fail-loudly contract: explicit assumptions (FOSUserBundle CLI present, default `wallabag` user exists, ADMIN_USERNAME/EMAIL/PASSWORD in env), structured exit codes (`0` success, `1` unexpected-state, `2` missing-prereq, `3` API/CLI error). On unexpected state: one-line "detected X but expected Y" + one-line recovery hint.
- `stacks/wallabag/justfile` — `bootstrap` recipe becomes one-line delegation.
- `stacks/homebridge/scripts/bootstrap.sh` — same upgrade. Existing logic (setup-wizard token + create-first-user) gets fail-loudly contract added on top. Exit codes match wallabag's.
- `stacks/homebridge/justfile` — `bootstrap` recipe becomes one-line delegation.
- Doctor extension: homebridge `BRIDGE_USERNAME` from `.env` matches `~/.volumes/homebridge/config.json` `bridge.username`. Homebridge `setupWizardComplete: true`. `.env` files have all keys from `.env.example` (presence-only via `grep -c`).

**Dependencies:** Phase 1 (doctor — for the new homebridge identity check).

**ACs covered:** `stack-resilience.AC5.8`, `stack-resilience.AC5.9`, `stack-resilience.AC5.10`, `stack-resilience.AC5.11`, `stack-resilience.AC6.1`, `stack-resilience.AC6.2`, `stack-resilience.AC6.3`, `stack-resilience.AC6.4`, `stack-resilience.AC6.5`, `stack-resilience.AC6.6`.

**Done when:** All doc additions present. `gen-pin.sh` invoked 100 times in a loop produces no reserved pins (verified by grep). Bootstrap recipes deliberately broken (e.g., delete `~/.volumes/homebridge/auth.json` mid-state, or remove a required env key) exit with the right code (1 / 2 / 3) and print a recognizable description + recovery hint. Doctor reports the new homebridge identity check.
<!-- END_PHASE_7 -->

<!-- START_PHASE_8 -->
### Phase 8: New-device clean-setup audit + bifurcated docs

**Goal:** Static-read audit confirming the new-device clean-setup path is end-to-end coherent across **three independent stages** — most users only do Stage 1 (base dotfiles), opt in to Stage 2 (containers), and Stage 3 (per-stack) only for stacks they want.

**Bifurcation:** The previous "13-step walkthrough" was wrong as a single sequence. Container/stacks setup is opt-in for a minority of devices using this repo. Documentation must reflect that.

- **Stage 1 (universal):** brew base packages (just, stow, plus editor + shell tools), `git clone`, `dotfiles stow setup-base`. Editor + shell config land. Most devices stop here.
- **Stage 2 (only on container-running devices):** brew container packages (`colima`, `docker`, `socket_vmnet`, `gettext`, `jq`, `tailscale`), `dotfiles stow setup-colima`, `dotfiles stacks vm-up`. Per-machine, per-user opt-in.
- **Stage 3 (per-stack):** for each stack the user wants to run, follow that stack's README (`.env` setup, first-up, bootstrap, serve).

**Per-package stow:** `stow/justfile` gains per-package recipes — `setup-base`, `setup-colima`, `restow-base`, `restow-colima`, `unstow-base`, `unstow-colima`, `status-base`, `status-colima`. The existing aggregate `setup` / `restow` / `unstow` / `status` recipes call both packages and remain for the user-case where both are wanted in one shot.

**Components:**
- `stow/justfile` — gains per-package recipes for `base` and `colima` (8 new one-line recipes). Aggregates remain.
- `README.md` (top-level) — Stage 1 only. Brew base packages, `git clone`, `dotfiles stow setup-base`. References `stow/README.md` for per-package details and `stacks/README.md` for the container side. Does not document container setup.
- `stow/README.md` — descriptions of each package (`base`, `colima`), per-package vs aggregate setup commands, restow/unstow/status. Does not mention containers or stacks.
- `stacks/README.md` — Stages 2 and 3. Explicit prereq: `dotfiles stow setup-colima`. Brew container packages list. `vm-up`. Per-stack pointers. The container-side walkthrough is scoped to this audience.
- Per-stack `<stack>/README.md` — stack-specific `.env`, bootstrap, serve, restore-from-backup, etc.
- Audit procedure (executed during plan, not committed):
  1. Read every README in dependency order: top-level `README.md`, `stow/README.md`, then `stacks/README.md`, then per-stack READMEs.
  2. Read every script in `stacks/scripts/` and `stacks/<stack>/scripts/`.
  3. For each step in each stage, confirm: (a) the prerequisite is created by an earlier step in the same or a documented earlier stage OR (b) the prerequisite is documented as a manual action with explicit instructions.
  4. Confirm: each stage references only its own brew package set; Stage 1 doesn't require container-side packages.
  5. Confirm: every env variable referenced is present in the relevant `.env.example`.
  6. Confirm: every script's preflight checks (per Phase 1's standard) reference clear remediation.
- Output: a gap list (issues found in the audit), each fixed in the same phase.

**Dependencies:** All previous phases.

**ACs covered:** `stack-resilience.AC7.1`, `stack-resilience.AC7.2`, `stack-resilience.AC7.3`, `stack-resilience.AC7.4`, `stack-resilience.AC7.5`, `stack-resilience.AC7.6`.

**Done when:** Audit completes. Every gap found has a corresponding fix committed in this phase. Stage 1 walkthrough in top-level `README.md` reads cleanly without referencing container concepts. Stages 2 + 3 in `stacks/README.md` list `dotfiles stow setup-colima` as an explicit prerequisite. Per-package stow recipes work (`dotfiles stow setup-base` stows only `base`; `dotfiles stow setup-colima` stows only `colima`). `dotfiles stacks doctor` runs all-green on the user's current device after all phases.
<!-- END_PHASE_8 -->

## Additional Considerations

**State-of-the-art DNS resilience trade-off accepted.** Tailscale macOS multi-resolver fallback is broken upstream ([tailscale#12677](https://github.com/tailscale/tailscale/issues/12677)). The design accepts that a Tailscale Global NS pointing at AGH is a deliberate single-direction switch (controllable via `tailnet-dns`), not a transparent failover. Cellular ad blocking depends on this switch being in the `on` state and AGH being healthy. If the issue is fixed upstream, the design can simplify by listing both AGH and 1.1.1.1 as Global NS and dropping the toggling logic.

**Backup quiesce trade-off.** AGH is backed up while running (no `compose stop`) — accepts a tiny window where AGH's query log might be mid-write, captured partial. Query logs are append-only with line-buffered writes; worst case is a truncated last line, which AGH ignores on next start. Not worth the network-disturbance cost of stopping. SQLite-backed stacks (freshrss, wallabag, homebridge) DO stop briefly via just's `down && up` subsequent dependency — partial transactions would corrupt the SQLite DB.

**Backup failure-mode trade-off.** Quiesce is via just's `down && up` subsequent (runs `up` after the body on success). just doesn't have an "always-after" subsequent, so a body failure (tar error: disk full, permission, etc.) leaves the container stopped. Accepted trade-off for simplicity: launchd's stderr log captures the failure to `~/.volume-backups/.log/` and a manual `just up` recovers in seconds. Promoted to a `trap`-based shell safety net only if this trade-off proves painful.

**Tailscale PAT expiry.** The `dns:write` PAT defaults to a configured expiry (recommended 90 days). Doctor doesn't auto-rotate; it does verify the token is currently valid (responds 200 to a `GET`). Manual rotation is documented in the README. Future enhancement: a `tailnet-dns-status` warning when the token is within 14 days of expiry (Tailscale API returns `expires` field).

**Static-read audit limitations.** Phase 8 validates the documented path on paper, not on hardware. A real fresh-device test is the gold standard but isn't in scope (no spare Mac). Phase 8 is the best available proxy. Trade-off accepted; future device-replacement is the natural live test.

**No explicit test framework.** This is a homelab dotfiles repo with shell scripts and YAML, not application code. "Tests" for each phase are operational (running the recipe, observing the effect, doctor-green); no test runner introduced. Doctor itself acts as the ongoing assertion suite.
