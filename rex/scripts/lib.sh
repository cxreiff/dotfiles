# rex/scripts/lib.sh — paths shared by the rex scripts. Source, don't run.

REX_LABEL="com.cxreiff.dotfiles.rex"
REX_AGENT_PLIST="${HOME}/Library/LaunchAgents/${REX_LABEL}.plist"
REX_LOGDIR="${HOME}/Library/Logs"
REX_DOMAIN="gui/$(id -u)"

# The server binary Rex.app installs and updates; "Current" follows app updates
# on the next restart of the job.
REX_BIN="${HOME}/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

# The default local socket, where Rex.app and the rex CLI look for the server.
REX_LISTEN="unix://${HOME// /%20}/Library/Application%20Support/rex/server.sock"

# The socket `tailscale serve` forwards to. Kept free of spaces so the
# `tailscale serve ... unix:<path>` argument needs no escaping.
REX_SERVE_SOCK="${HOME}/.local/state/rex/serve.sock"

REX_APP_ID="com.superlogical.rex"
TAILSCALE="/opt/homebrew/bin/tailscale"

rex_cli() { "$REX_BIN" --autostart=false "$@"; }
