#!/usr/bin/env bash
# rex/scripts/install.sh
# Run the Rex server from our own LaunchAgent with a tailnet-serve listener, so
# remote clients reach it through this host's own tailnet node (Tailscale Serve)
# instead of Rex's built-in "<host>-rex" tsnet device. See rex/README.md.
#
# This is a cutover: it stops the running Rex server, which ends every program
# running in Rex (session layouts are restored). Run it from a shell that is
# NOT inside Rex, e.g. a plain SSH session.
#
# Steps: render + lint the plist; turn off the app's automatic server restart
# and built-in Tailscale; sign the built-in node out; quit Rex.app; stop the
# server; load our agent; wait for the server; reopen Rex.app.
#
# Exit codes:
#   0 — agent loaded and server answering
#   1 — refused to run inside Rex
#   2 — required file/tool missing
#   3 — server did not come up (see the log)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

template="${SCRIPT_DIR}/../com.cxreiff.dotfiles.rex.plist.template"

if [ -n "${REX_BLOCK:-}" ] && [ "${1:-}" != "--force" ]; then
    echo "rex install: this shell runs inside Rex, and the cutover stops the Rex server (ending this shell)." >&2
    echo "Run it from a plain SSH session instead (or pass --force to run it anyway)." >&2
    exit 1
fi

[ -f "$template" ] || { echo "template not found at ${template}" >&2; exit 2; }
[ -x "$REX_BIN" ] || { echo "Rex server binary not found at ${REX_BIN} (install Rex.app and launch it once)" >&2; exit 2; }
[ -S /var/run/tailscaled.socket ] || { echo "tailscaled LocalAPI socket missing (is tailscaled running?)" >&2; exit 2; }

mkdir -p "$(dirname "$REX_SERVE_SOCK")" "$REX_LOGDIR" "$(dirname "$REX_AGENT_PLIST")"
chmod 700 "$(dirname "$REX_SERVE_SOCK")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
sed \
    -e "s|__REX_BIN__|$(esc "$REX_BIN")|g" \
    -e "s|__LISTEN__|$(esc "$REX_LISTEN")|g" \
    -e "s|__SERVE_SOCK__|$(esc "$REX_SERVE_SOCK")|g" \
    -e "s|__HOME__|$(esc "$HOME")|g" \
    -e "s|__USER__|$(esc "$USER")|g" \
    -e "s|__SHELL__|$(esc "${SHELL:-/bin/zsh}")|g" \
    -e "s|__LOGDIR__|$(esc "$REX_LOGDIR")|g" \
    "$template" > "$tmp"
plutil -lint "$tmp" >/dev/null

# The app would otherwise restart an idle server on update with its own launch
# settings (dropping the listener), and re-enable the built-in node.
defaults write "$REX_APP_ID" rex.server.automatic-restart-enabled -bool false
defaults write "$REX_APP_ID" rex.server.tailnet-enabled -bool false
echo "Rex.app: automatic server restart off, Serve over Tailscale off"

if rex_cli server status 2>/dev/null | grep -q '^tailscale: running'; then
    echo "Signing the built-in Tailscale node out…"
    rex_cli server tailscale logout
fi

app_was_running=0
if pgrep -f '\.app/Contents/MacOS/Rex$' >/dev/null; then
    app_was_running=1
    echo "Quitting Rex.app…"
    pkill -TERM -f '\.app/Contents/MacOS/Rex$' || true
    for _ in $(seq 1 20); do pgrep -f '\.app/Contents/MacOS/Rex$' >/dev/null || break; sleep 0.5; done
fi

if rex_cli server status >/dev/null 2>&1; then
    echo "Stopping the running Rex server…"
    rex_cli server stop
    for _ in $(seq 1 20); do rex_cli server status >/dev/null 2>&1 || break; sleep 0.5; done
fi

cp "$tmp" "$REX_AGENT_PLIST"
chmod 644 "$REX_AGENT_PLIST"
launchctl bootout "${REX_DOMAIN}/${REX_LABEL}" 2>/dev/null || true
launchctl bootstrap "$REX_DOMAIN" "$REX_AGENT_PLIST"

echo "Waiting for the server…"
up=0
for _ in $(seq 1 40); do
    if rex_cli server status >/dev/null 2>&1 && [ -S "$REX_SERVE_SOCK" ]; then up=1; break; fi
    sleep 0.5
done
if [ "$up" -ne 1 ]; then
    echo "rex install: server did not come up; see ${REX_LOGDIR}/${REX_LABEL}.log" >&2
    exit 3
fi

if [ "$app_was_running" -eq 1 ]; then
    open -b "$REX_APP_ID" || echo "warning: could not reopen Rex.app; open it from the Mac" >&2
fi

echo
"${SCRIPT_DIR}/status.sh" || true
echo
echo "Next (once per host): dotfiles rex serve   # sudo tailscale serve --https=443 -> ${REX_SERVE_SOCK}"
