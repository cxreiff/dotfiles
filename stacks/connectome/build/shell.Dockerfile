# syntax=docker/dockerfile:1
# connectome `shell` image — the agent's hands. Untrusted: holds only its own
# onecli token (HTTPS_PROXY) and the term-sessions daemon token.
ARG SHELL_BASE=mcr.microsoft.com/devcontainers/typescript-node:22-bookworm
ARG UV_VERSION=0.13.1

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ${SHELL_BASE}
USER root
ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv ripgrep fd-find jq build-essential ca-certificates curl gnupg \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=arm64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
COPY --from=uv /uv /uvx /usr/local/bin/
ARG TERM_SESSIONS_VERSION=1.6.0
# Locked install from the same lockfile as the connectome image; the version
# must match the one build.sh records in sources.lock.
COPY term-sessions /opt/term-sessions
RUN cd /opt/term-sessions && PUPPETEER_SKIP_DOWNLOAD=1 npm ci --omit=dev \
 && test "$(node -p "require('./node_modules/term-sessions-mcp/package.json').version")" = "${TERM_SESSIONS_VERSION}" \
 && ln -s /opt/term-sessions/node_modules/.bin/session-server /usr/local/bin/session-server
COPY gateway-ca.crt /usr/local/share/ca-certificates/onecli-gateway.crt
RUN update-ca-certificates
# No sudo: remove the devcontainer's passwordless entry and the binary.
RUN rm -f /etc/sudoers.d/* \
 && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
 && ! command -v sudo
RUN mkdir -p /workspace/outbox && chown -R node:node /workspace
USER node
ARG RUST_TOOLCHAIN=1.99.1
ENV RUSTUP_HOME=/home/node/.rustup \
    CARGO_HOME=/home/node/.cargo \
    PATH=/home/node/.cargo/bin:${PATH}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    GIT_SSL_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/onecli-gateway.crt \
    HEADLESS=true \
    SESSION_SERVER_HOST=0.0.0.0 \
    SESSION_SERVER_PORT=3100
WORKDIR /workspace
CMD ["session-server", "--headless"]
