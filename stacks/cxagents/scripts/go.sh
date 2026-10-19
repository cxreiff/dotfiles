#!/usr/bin/env bash
# stacks/cxagents/scripts/go.sh ARGS... — run `go ARGS` in the digest-pinned
# builder from forwarder/Dockerfile (Go is not installed on the host). The
# source is bind-mounted (the agents VM mounts $HOME); module and build caches
# live in named volumes cxagents_gomod / cxagents_gobuild. CGO is off unless
# GO_CGO=1 (the race detector needs it; see race-test.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "${SCRIPT_DIR}/../forwarder" && pwd)"
builder="$(sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' "${src}/Dockerfile")"
[ -n "$builder" ] || { echo "go.sh: no builder FROM line in ${src}/Dockerfile" >&2; exit 2; }
exec docker --context colima-agents run --rm \
    -v "${src}:/src" -w /src \
    -v cxagents_gomod:/go/pkg/mod -v cxagents_gobuild:/root/.cache/go-build \
    -e GOTOOLCHAIN=local -e CGO_ENABLED="${GO_CGO:-0}" \
    "$builder" go "$@"
