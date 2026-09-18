
# Codex defers its SessionStart hooks until the first turn, so invocation and
# return from the CLI provide the actual terminal lifecycle.
codex() {
    if [ -n "${ZELLIJ:-}" ] && [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then
        "$HOME/.local/bin/token-meter-codex" "$@"
    else
        command codex "$@"
    fi
}
