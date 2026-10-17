# syntax=docker/dockerfile:1
# connectome host image. Built by `dotfiles stacks connectome build` from the
# staged sources in ./src (git archives of the local clones at recorded SHAs).
# NEVER push this image to a public registry: connectome-host and
# discord-mcpl carry no license (all rights reserved).
ARG NODE_IMAGE=node:22-bookworm
ARG BUN_IMAGE=oven/bun:1-debian

FROM ${BUN_IMAGE} AS bun

FROM ${NODE_IMAGE} AS builder
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential python3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /src

# voice-kit first: discord-mcpl depends on it as file:../voice-kit.
COPY src/voice-kit ./voice-kit
RUN cd voice-kit && npm ci && npm run build

COPY src/discord-mcpl ./discord-mcpl
RUN cd discord-mcpl && npm ci && npm run build \
 && node --import tsx --test test/attachment-root.test.ts \
 && npm prune --omit=dev
RUN cd voice-kit && npm prune --omit=dev

COPY src/heartbeat-mcpl ./heartbeat-mcpl
RUN cd heartbeat-mcpl && npm ci && npm run build \
 && node --import tsx --test test/reminder-floor.test.ts \
 && npm prune --omit=dev

ARG TERM_SESSIONS_VERSION=1.6.0
COPY build/term-sessions /opt/term-sessions
RUN cd /opt/term-sessions && npm ci --omit=dev

COPY src/connectome-host ./connectome-host
# postinstall builds the WebUI into dist/web but swallows failures — assert it.
RUN cd connectome-host && bun install --frozen-lockfile && test -f dist/web/index.html \
 && bun test test/recipe-subagents.test.ts test/subagent-empty-inputs.test.ts

ARG CODEX_VERSION=0.162.1
ARG CODEX_SHA256=bf3ca2719f1143b1440fbd85c149379e696c782c50ad7991f8bfcec60b2600c1
RUN curl -fsSL -o /tmp/codex.tgz \
      "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-aarch64-unknown-linux-musl.tar.gz" \
 && echo "${CODEX_SHA256}  /tmp/codex.tgz" | sha256sum -c - \
 && tar -xzf /tmp/codex.tgz -C /tmp \
 && install -m 0755 /tmp/codex-aarch64-unknown-linux-musl /usr/local/bin/codex \
 && rm -f /tmp/codex.tgz /tmp/codex-aarch64-unknown-linux-musl

FROM ${BUN_IMAGE}
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/*
# Real Node for MCP servers (in this image `node` on PATH is a Bun symlink).
COPY --from=builder /usr/local/bin/node /opt/node/bin/node
COPY --from=builder /usr/local/bin/codex /usr/local/bin/codex
COPY --from=builder /src/connectome-host /opt/connectome
COPY --from=builder /src/voice-kit /opt/mcpl/voice-kit
COPY --from=builder /src/discord-mcpl /opt/mcpl/discord-mcpl
COPY --from=builder /src/heartbeat-mcpl /opt/mcpl/heartbeat-mcpl
COPY --from=builder /opt/term-sessions /opt/mcpl/term-sessions
# Per-vault onecli gateway CA (copied out of onecli-gateway by `build`).
COPY gateway-ca.crt /usr/local/share/ca-certificates/onecli-gateway.crt
RUN update-ca-certificates
COPY entrypoint.sh /usr/local/bin/connectome-entrypoint
COPY mcp-call.mjs /opt/connectome-tests/mcp-call.mjs
# /agent/cwd: image-owned, not writable by the runtime uid. Its only entries
# are links to the tracked mcpl-servers.json and to persistent logs/, so
# mcpl-servers.agent.json can never be written (invariant 3).
RUN chmod 0755 /usr/local/bin/connectome-entrypoint \
 && mkdir -p /agent/cwd /agent/recipes /agent/state /agent/outbox \
 && ln -s /agent/recipes/mcpl-servers.json /agent/cwd/mcpl-servers.json \
 && ln -s /agent/state/logs /agent/cwd/logs \
 && chown root:root /agent/cwd && chmod 0755 /agent/cwd \
 && chown bun:bun /agent/state /agent/outbox && chmod 0700 /agent/state
ENV DATA_DIR=/agent/state/data \
    CODEX_HOME=/agent/state/codex \
    CODEX_BINARY=/usr/local/bin/codex \
    OBSERVERS_FILE=/agent/recipes/observers.json \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/onecli-gateway.crt \
    CODEX_CA_CERTIFICATE=/etc/ssl/certs/ca-certificates.crt \
    NO_PROXY=localhost,127.0.0.1,shell \
    no_proxy=localhost,127.0.0.1,shell
USER bun
WORKDIR /agent/cwd
ENTRYPOINT ["/usr/local/bin/connectome-entrypoint"]
