#!/usr/bin/env bash
# stacks/connectome/scripts/compose.sh [--warn] ARGS... — docker compose for
# this stack with the right file set: compose.yaml, plus compose.cxagents.yaml
# when the cxagents network exists (soft opt-in: agent previews are not
# essential; connectome's hard dependency is onecli only). --warn prints a
# warning when the overlay is skipped (used by `up`).
set -euo pipefail
stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ctx=colima-agents
warn=0
if [ "${1:-}" = --warn ]; then warn=1; shift; fi
files=(-f "${stack_dir}/compose.yaml")
if docker --context "$ctx" network inspect cxagents >/dev/null 2>&1; then
    files+=(-f "${stack_dir}/compose.cxagents.yaml")
elif [ "$warn" -eq 1 ]; then
    echo "connectome: network cxagents missing — starting without agent previews (dotfiles stacks cxagents up, then connectome up)" >&2
fi
exec docker --context "$ctx" compose --project-directory "$stack_dir" "${files[@]}" "$@"
