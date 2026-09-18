
boxclaude() {
    sandbox-exec -p "(version 1)(allow default)(deny file-write* (require-all \
        (require-not (subpath \"$PWD\")) \
        (require-not (subpath \"/private/tmp\")) \
        (require-not (subpath \"/private/var/folders\")) \
        (require-not (subpath \"/dev\")) \
        (require-not (subpath \"$HOME/.claude\")) \
        (require-not (literal \"$HOME/.claude.json\"))))" \
        claude --sandbox --dangerously-skip-permissions
}

