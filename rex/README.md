# rex

Remote access to the [Rex](https://www.superlogical.com/rex/docs) server on this host through the host's own tailnet node, instead of the built-in `<host>-rex` tsnet device that Rex.app's "Serve over Tailscale" setting creates.

This applies the "Tailscale Serve" setup from Rex's [Remote Access](https://www.superlogical.com/rex/docs/linux/remote-access) guide to macOS. That guide is written for Linux and FreeBSD, where the server is a service you launch yourself. On macOS, Rex.app launches the server as its own LaunchAgent (`com.superlogical.rex.server.<hash>` in `gui/<uid>`) and has no setting for `--extra-listen`. So this module provides that launch: a LaunchAgent, `com.cxreiff.dotfiles.rex`, with the same binary, socket and arguments as the app's job, plus the listener. When Rex.app starts and finds a server already running, it attaches to it.

```
client ──https──▶ cxmini.faun-fir.ts.net:443  (tailscaled, Tailscale Serve, root)
                       │ unix:~/.local/state/rex/serve.sock
                       ▼
                 rex server run --extra-listen tailnet-serve://…   (LaunchAgent, as cxreiff)
                       ▲
Rex.app / rex CLI ─────┘ unix:~/Library/Application Support/rex/server.sock
```

The listener uses `tailnet-serve://`, never `unix://`. With `unix://`, every caller would look like tailscaled's account (root). With `tailnet-serve`, Rex identifies callers from Serve's headers and admits only the node owner by default. Tagged devices can't be identified through Serve.

## Recipes

```sh
dotfiles rex install     # cutover: stops the Rex server (ends all programs in Rex). Run over SSH, outside Rex
dotfiles rex serve       # sudo tailscale serve --bg --https=443 unix:~/.local/state/rex/serve.sock (once per host)
dotfiles rex status      # read-only [OK]/[FAIL] checks
dotfiles rex restart     # stop + kickstart the agent (ends all programs in Rex; picks up a Rex.app update)
dotfiles rex logs        # tail ~/Library/Logs/com.cxreiff.dotfiles.rex.log
dotfiles rex unserve     # remove the :443 Serve entry
dotfiles rex uninstall   # unload the agent and hand the server back to Rex.app
```

`install` also:
- sets `rex.server.automatic-restart-enabled` to false, because the app would otherwise restart an idle server after an update using its own arguments, which drops the listener;
- sets `rex.server.tailnet-enabled` to false and signs out the built-in node.

Clients: `rex hosts add cxmini https://cxmini.faun-fir.ts.net` (CLI), or **Add Remote Host…** in Rex.app with the same address.

## Gotchas

- **The server needs a GUI login, as it does with Rex.app.** The agent runs in `gui/<uid>`, where Rex.app runs its own server, so programs in Rex terminals keep the login keychain, TCC grants and the pasteboard. That means it does not start at boot before a GUI login, unlike the stacks daemons (see "Boot autostart" in CLAUDE.md).
- **Rex.app updates:** with automatic restart off, the app shows "A newer server is available". Use `dotfiles rex restart`, not the app's Restart button. A clean exit leaves the agent stopped (`KeepAlive` only relaunches after a crash), so the app's button starts the app's own server without the listener. `dotfiles rex status` FAILs when the running server isn't the agent's.
- **Serve to a Unix socket needs root.** `tailscale serve … unix:` refuses an operator user, hence the `sudo` in `serve`. The Serve config lives in tailscaled and survives reboots.
- The serve socket path has no spaces, deliberately: tailscaled stores it as a `unix:` target string.
