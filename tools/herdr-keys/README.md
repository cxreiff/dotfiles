# herdr-keys

Herdr maneuvers too compound for a plain herdr keybinding, called by the
`[[keys.command]]` shell bindings in `stow/base/.config/herdr/config.toml`
(stowed to `~/.config/herdr/config.toml`).

```sh
dotfiles tools install-herdr-keys   # cargo build --release, install to ~/.local/bin/herdr-keys
dotfiles tools test-herdr-keys      # unit tests (spatial landing, sidebar order)
```

Needs a Rust toolchain (`rustup`/`cargo` on `PATH`). The config calls the
binary by absolute path (`$HOME/.local/bin/herdr-keys`), because herdr runs
bindings from its server with whatever `PATH` the server started with.

## Commands

| Command | Behavior |
|---|---|
| `nav left\|right` | Focus the pane in that direction. At the tab's edge, go to the previous/next tab, wrapping around. |
| `nav up\|down` | Focus the pane in that direction. At the tab's edge, go to the previous/next workspace **in sidebar order**, wrapping around. |
| `new pane <dir>` | Split the focused pane, with the new pane on the `<dir>` side. Focused, cwd follows the pane. |
| `new tab left\|right` | New tab directly left/right of the current tab. Focused. |
| `new workspace up\|down` | New workspace directly above/below the current sidebar row (or the whole worktree group it is in). Focused. |

When `nav` crosses into another tab or workspace it lands spatially: on the
target's pane at the edge you came through, aligned with the center of the
pane you left (proportionally, if the tabs are different sizes). When the
center falls exactly on a seam, the target's remembered pane wins. A zoomed
target keeps its zoomed pane.

Sidebar order is not `workspace.list` order. A worktree group (two or more
workspaces sharing a repo key, one of them the primary checkout) renders as
one block at its first member's list position, primary first. A collapsed
group shows only the primary plus the focused child. `src/sidebar.rs` ports
herdr's `workspace_entries` (v0.9.0, `src/client/shell/sidebar.rs`), the same
function herdr's own `next_workspace`/`previous_workspace` use, and reads
collapsed groups from the client's preferences file
(`~/.local/state/herdr/client-shell/local-<hash>.json`). It was checked
against herdr's native next/previous_workspace, expanded and collapsed.

## Latency

A keypress takes about 10 ms to reach a focus change. About 9.5 ms of that is
herdr launching the binding through `/bin/sh -lc` (a login shell, so
`path_helper` runs). herdr-keys itself adds about 1 ms:

- Plain `std` plus `serde_json`, linked only against libSystem. Exec costs
  about 0.35 ms more than `/usr/bin/true`.
- It talks to the API socket directly, about 0.2 ms per request, where the
  herdr CLI costs 3 to 17 ms per call. An in-tab `nav` is one request. A
  `nav` that crosses an edge or a `new` is 3 or 4.
- It writes each request in one `write` right after `connect`. The herdr
  server reads a new connection non-blocking and sleeps 100 ms (about 250 ms
  observed) if the line has not arrived yet (`read_initial_request_line` in
  `src/api/server.rs`). A client that pauses between connect and write hits
  that stall on every request.
- It raises itself to the `USER_INTERACTIVE` QoS class, so it still runs
  promptly if the server, and so the bindings it spawns, was started niced or
  at background priority.
- `scripts/install.sh` copies to a temp file and renames it over the old
  binary. Overwriting a signed arm64 executable in place can get later
  launches SIGKILLed through the kernel's cached code signature. The script
  also clears xattrs, so Gatekeeper never assesses the binary. It runs the
  binary once, so the first-launch signature check happens before the first
  keypress.

Trace a binding by prefixing its command in the config:
`HERDR_KEYS_TRACE=/tmp/herdr-keys.log $HOME/.local/bin/herdr-keys nav left`.
Each line shows elapsed time since start and per-request round trips. With
stdout and stderr going to `/dev/null` under herdr, this is also where errors
show up.

## Known limitation: multiple clients

herdr exposes no client-scoped API to shell bindings. A public focus change
that switches tab or workspace (`pane.focus`, `tab.focus`, `workspace.focus`,
create with focus) moves **every attached client** there. herdr's native
next/previous keys move only the pressing client. So with two clients on
different workspaces, crossing an edge with herdr-keys pulls both along.
Moves inside a tab, and the source pane, do follow the pressing client:
herdr exports that client's view as `HERDR_ACTIVE_*`.
