# check=skip=SecretsUsedInArgOrEnv
# drydock — containerized Claude Code sandbox.
#
# (`check=skip=SecretsUsedInArgOrEnv` above: the `ENV GIT_CONFIG_KEY_0=…` block
#  near the bottom uses a git config KEY NAME (`commit.gpgsign`) as a value —
#  BuildKit's name-pattern lint false-flags `*_KEY*` as a secret. There are no
#  secrets in any ARG/ENV here.)
#
# Architecture: Docker-out-of-Docker (DooD) via /var/run/docker.sock bind mount.
# The container does NOT run a docker daemon. The CLI inside talks to the host's
# daemon, so sibling containers in any project's docker-compose stack are
# visible and `docker exec` / project Makefile targets work transparently.
#
# Build args mirror the host's UID/GID and the docker group GID so that files
# created from inside this container land on the host with the user's ownership
# and the docker socket is readable.

FROM debian:12-slim

# USER_NAME has NO default — it's supplied by the drydock CLI (`id -un`) so the
# container user / $HOME mirror the invoking host user. Building this image with
# a bare `docker build` (no --build-arg USER_NAME=...) is unsupported.
ARG USER_NAME
ARG USER_UID=1000
ARG USER_GID=1000
ARG HOST_DOCKER_GID=1001

RUN [ -n "${USER_NAME}" ] || { \
        echo 'ERROR: USER_NAME build-arg is required — invoke via the drydock CLI, not a bare docker build' >&2; \
        exit 1; \
    }

ENV DEBIAN_FRONTEND=noninteractive

# ── Base tooling ─────────────────────────────────────────────────────────────
# openssh-client: NOT pulled by `git` under --no-install-recommends; needed by
# the optional SSH deploy-key overlay (ssh) and the ssh-keyscan RUN below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        make \
        openssh-client \
        git \
        rsync \
        less \
        procps \
        vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI + Compose plugin ──────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Legacy `docker-compose` (v1 invocation) → `docker compose` (v2 plugin) shim
RUN printf '#!/bin/sh\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/docker-compose

# ── GitHub CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Pin github.com's host key (for the optional SSH deploy-key overlay) ──────
# Written to the system known_hosts so ssh verifies github.com against it and
# never creates/touches ~/.ssh/known_hosts. Refreshed on every `drydock build`.
RUN ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> /etc/ssh/ssh_known_hosts

# ── User + groups matching host ──────────────────────────────────────────────
RUN set -eux; \
    if getent group ${USER_GID} >/dev/null 2>&1; then \
        existing="$(getent group ${USER_GID} | cut -d: -f1)"; \
        if [ "$existing" != "${USER_NAME}" ]; then \
            groupmod -n ${USER_NAME} "$existing"; \
        fi; \
    else \
        groupadd -g ${USER_GID} ${USER_NAME}; \
    fi; \
    useradd -u ${USER_UID} -g ${USER_GID} -m -s /bin/bash ${USER_NAME}; \
    if getent group ${HOST_DOCKER_GID} >/dev/null 2>&1; then \
        existing_docker="$(getent group ${HOST_DOCKER_GID} | cut -d: -f1)"; \
        usermod -aG "$existing_docker" ${USER_NAME}; \
    else \
        groupadd -g ${HOST_DOCKER_GID} docker-host; \
        usermod -aG docker-host ${USER_NAME}; \
    fi

# ── Playwright / Chromium runtime libraries ─────────────────────────────────
# System libs the Playwright MCP's bundled Chromium dynamically links against
# (libglib-2.0.so.0, libnss3, libgbm1, …). debian:12-slim omits them. They must
# land at build time: the container runs non-root with no-new-privileges:true
# (INV-8), so `playwright install-deps` — which needs root — cannot run inside.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libglib2.0-0 libnss3 libnspr4 libdbus-1-3 libatk1.0-0 \
        libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libatspi2.0-0 \
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
        libxcb1 libxext6 libx11-6 libpango-1.0-0 libcairo2 libasound2 \
    && rm -rf /var/lib/apt/lists/*

# ── Container identity marker (baked as root, read-only to the agent) ────────
# Referenced by templates/hooks/drydock-session-start.sh to gate in-container
# behaviour. Content is a minimal fixed string — no version data that could
# go stale between builds (version stays in DRYDOCK_VERSION env var).
RUN echo 'drydock' > /etc/drydock-release

# ── Managed-settings drop-in: bake drydock's agent policy into the image ────
# Files land at /etc/claude-code/managed-settings.d/ — Claude Code auto-loads
# this directory on Linux at highest precedence (tamper-proof: non-root agent
# cannot write under /etc/). __HOME__ is resolved to /home/${USER_NAME} here
# so the deny rule paths and hook dedup string are correct for the in-container
# user. The sed pass is harmless no-op for files that contain no __HOME__.
COPY templates/managed-settings.d/ /etc/claude-code/managed-settings.d/
RUN sed -i "s|__HOME__|/home/${USER_NAME}|g" /etc/claude-code/managed-settings.d/*.json

USER ${USER_NAME}

# PATH order:
#   ~/.local/bin first → contains the host-shared claude/engram/gentle-ai/gga/uv binaries
#   ~/.local/share/pnpm → contains node (some MCP plugins are JS-based)
#   System paths after
ENV PATH=/home/${USER_NAME}/.local/bin:/home/${USER_NAME}/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Commits made inside the box are NOT GPG-signed by default. The host's
# ~/.gitconfig (mounted :ro) has commit.gpgsign=true, but ~/.gnupg is not
# mounted (and shouldn't be) — signing would just fail. GIT_CONFIG_* env wins
# over system/global/local config, so this is the clean off switch. The
# optional GPG overlay (docker-compose.gpg.yml) overrides it back on, signing
# with a throwaway sandbox key.
ENV GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=commit.gpgsign \
    GIT_CONFIG_VALUE_0=false

# WORKDIR is set per-invocation by the drydock CLI via env or compose override.
WORKDIR /home/${USER_NAME}

# Default: launch Claude Code interactively. Mounts provide the binary at runtime.
CMD ["claude"]
