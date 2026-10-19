#!/usr/bin/env bash
# stacks/cxagents/scripts/race-test.sh — `go test -race -count=1 ./...` in the
# pinned builder. The race detector needs cgo, so this runs go.sh with
# GO_CGO=1. Only the test run is cgo; the binary and image stay CGO_ENABLED=0.
# build.sh runs this before the image build.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GO_CGO=1
exec "${SCRIPT_DIR}/go.sh" test -race -count=1 ./...
